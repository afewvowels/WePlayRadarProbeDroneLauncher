local C = require("shared")

--[[
How it works
  * Launchers are assembling machines with a fixed "launch" recipe that eats
    one survey drone. Every few ticks we compare each launcher's
    products_finished counter; each new finished craft = one drone launched.
  * Launchers come in four runway directions (one prototype each). Players and
    robots build a rotatable placer that is swapped for the matching launcher;
    R / Shift+R rotate a placed launcher by swapping it again.
  * Drones aren't entities: they're two script-drawn sprites (body + shadow)
    moved every tick along a path. With fancy flights on (the default) that's
    a takeoff roll down the runway, a straight climb-out, a turn-radius arc
    toward the target, and a straight final approach (as in Long Haul Logistics).
  * On arrival the drone lands (smoke/splash), and a probe or buoy (a radar
    with free power) is placed, nudged, or lost depending on the setting.
  * Probes are removed after C.probe_lifetime_ticks, once their sweep is done.

storage layout
  launchers[unit_number] = { entity = LuaEntity, finished = uint }
  drones[]               = { surface, force, points, cumulative, total, roll_up, s, segment,
                             tx, ty, frame, body, shadow, marker, next_sound, reservation }
  probes[unit_number]    = { entity, expires, reservation }
  reservations[id]       = { surface, cx, cy }   -- chunk targets already claimed
]]

local floor, sqrt, min, max = math.floor, math.sqrt, math.min, math.max
local TWO_PI = 2 * math.pi

------------------------------------------------------------------------------
-- Storage
------------------------------------------------------------------------------
local function init_storage()
  storage.launchers = storage.launchers or {}
  storage.drones = storage.drones or {}
  storage.probes = storage.probes or {}
  storage.reservations = storage.reservations or {}
  storage.next_reservation = storage.next_reservation or 1
end

local DIR_BY_LAUNCHER, LAUNCHER_NAMES = {}, {}
for dir, name in pairs(C.launcher_by_dir) do
  DIR_BY_LAUNCHER[name] = dir
  LAUNCHER_NAMES[#LAUNCHER_NAMES + 1] = name
end

-- The launcher's input slots. The inventory define was renamed in Factorio 2.x
-- (assembling_machine_input -> crafter_input), so accept either.
local INPUT_INVENTORY = defines.inventory.crafter_input or defines.inventory.assembling_machine_input

local function is_launcher(entity)
  return entity and entity.valid and DIR_BY_LAUNCHER[entity.name] ~= nil
end

local function register_launcher(entity)
  if not is_launcher(entity) then return end
  if not entity.active then entity.active = true end -- never leave one stuck paused
  storage.launchers[entity.unit_number] = {
    entity = entity,
    finished = entity.products_finished or 0,
  }
end

local function rescan_launchers()
  storage.launchers = {}
  for _, surface in pairs(game.surfaces) do
    for _, e in pairs(surface.find_entities_filtered({ name = LAUNCHER_NAMES })) do
      register_launcher(e)
      -- Clear "nothing to scout" alerts left over from 0.1.4
      for _, player in pairs(e.force.players) do
        player.remove_alert({ entity = e, type = defines.alert_type.custom })
      end
    end
  end
end

-- Replace a launcher (or the placer) with the launcher facing `direction`,
-- keeping its drones, health, quality and owner.
local function swap_launcher(old, direction)
  local surface, position, force, quality = old.surface, old.position, old.force, old.quality
  local health, last_user = old.health, old.last_user

  local stacks = {}
  if is_launcher(old) then
    local inv = INPUT_INVENTORY and old.get_inventory(INPUT_INVENTORY)
    if inv then
      for i = 1, #inv do
        if inv[i].valid_for_read then
          stacks[#stacks + 1] = { name = inv[i].name, count = inv[i].count, quality = inv[i].quality }
        end
      end
    end
    -- A launch already in progress has used up its drone; give that one back too.
    local ok, crafting = pcall(function() return old.is_crafting() end)
    if ok and crafting then stacks[#stacks + 1] = { name = C.drone_item, count = 1 } end
    storage.launchers[old.unit_number] = nil
  end
  local viewers = {}
  for _, player in pairs(game.connected_players) do
    if player.opened == old then viewers[#viewers + 1] = player end
  end
  old.destroy()

  local launcher = surface.create_entity({
    name = C.launcher_by_dir[direction] or C.launcher,
    position = position,
    force = force,
    quality = quality,
    player = last_user,
    create_build_effect_smoke = false,
  })
  if not launcher then return end
  if health then launcher.health = health end
  for _, stack in pairs(stacks) do
    local inserted = launcher.insert(stack)
    if inserted < stack.count then
      surface.spill_item_stack({ position = position, stack = { name = stack.name, count = stack.count - inserted, quality = stack.quality } })
    end
  end
  register_launcher(launcher)
  for _, player in pairs(viewers) do player.opened = launcher end
  return launcher
end

------------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------------
local function gps(surface, pos)
  return string.format("[gps=%d,%d,%s]", floor(pos.x), floor(pos.y), surface.name)
end

-- Spawn the first effect entity that exists (vanilla names can change).
local function try_effect(surface, names, pos)
  for _, name in ipairs(names) do
    if prototypes.entity[name] then
      surface.create_entity({ name = name, position = pos })
      return
    end
  end
end

local LAND_PUFF  = { "medium-explosion", "explosion" }
local WATER_PUFF = { "water-splash" }

local function drone_range(force)
  local level = 0
  for i = 1, C.range_levels do
    local tech = force.technologies[C.range_tech .. "-" .. i]
    if tech and tech.researched then level = i end
  end
  local range = C.base_range
  for i = 1, level do range = range + C.range_bonus(i) end
  return range
end

-- Orientation 0 = north, 0.25 = east (clockwise), like Factorio.
local function direction_index(dx, dy)
  local orientation = (math.atan2(dx, -dy) / TWO_PI) % 1
  return floor(orientation * C.directions + 0.5) % C.directions
end

local function reserve(surface, cx, cy)
  local id = storage.next_reservation
  storage.next_reservation = id + 1
  storage.reservations[id] = { surface = surface.index, cx = cx, cy = cy }
  return id
end

local function release(id)
  if id then storage.reservations[id] = nil end
end

local function near_reservation(surface, cx, cy, radius)
  local r2 = radius * radius
  for _, r in pairs(storage.reservations) do
    if r.surface == surface.index then
      local ddx, ddy = r.cx - cx, r.cy - cy
      if ddx * ddx + ddy * ddy < r2 then return true end
    end
  end
  return false
end

local function is_hazard_tile(tile)
  if not (tile and tile.valid) then return true end
  local n = tile.name
  return n:find("lava", 1, true) ~= nil
      or n == "out-of-map"
      or n:find("empty-space", 1, true) ~= nil
end

------------------------------------------------------------------------------
-- Targeting: nearest uncharted chunk, pushed outward so the probe's sweep
-- covers mostly new ground. Falls back to a random direction.
------------------------------------------------------------------------------
local function find_target(surface, force, origin, range)
  local ocx, ocy = origin.x / 32, origin.y / 32
  local max_r = floor(range / 32)
  local spacing = C.scan_radius_chunks * 0.8

  -- March outward along evenly spaced rays (random starting angle) and keep the
  -- closest uncharted, unclaimed chunk. Cost is rays x range, not range squared.
  local best_dist, best_angle
  local offset = math.random() * TWO_PI
  for i = 0, C.target_rays - 1 do
    local angle = offset + i * TWO_PI / C.target_rays
    local cos_a, sin_a = math.cos(angle), math.sin(angle)
    local limit = best_dist and min(best_dist, max_r) or max_r
    for r = 1, limit do
      local cx, cy = floor(ocx + cos_a * r), floor(ocy + sin_a * r)
      if not force.is_chunk_charted(surface, { cx, cy }) then
        if not near_reservation(surface, cx, cy, spacing) then
          if not best_dist or r < best_dist or (r == best_dist and math.random() < 0.5) then
            best_dist, best_angle = r, angle
          end
        end
        break
      end
    end
  end

  local found = best_dist ~= nil
  local angle, dist
  if found then
    -- Push past the edge of the charted area so the sweep covers mostly new ground.
    angle = best_angle
    dist = min(best_dist + C.scan_radius_chunks * 0.6, max_r) * 32
  else
    -- Everything in range is charted: fly out anyway and refresh the map.
    angle = math.random() * TWO_PI
    dist = range * (0.3 + 0.7 * math.random())
  end
  local pos = { x = origin.x + math.cos(angle) * dist, y = origin.y + math.sin(angle) * dist }
  return pos, floor(pos.x / 32), floor(pos.y / 32), found
end

------------------------------------------------------------------------------
-- Flight paths (ported from WePlay: Long Haul Logistics)
-- A path is a list of points walked at a varying speed. Fancy: takeoff roll
-- down the runway, climb straight out, arc-straight-arc turn (a "Dubins
-- path") onto a straight final approach, touchdown. Plain: one straight line.
------------------------------------------------------------------------------
local function fancy_flights()
  return settings.global["rpdl-fancy-flights"].value
end

local function dir_vector(direction)
  local o = direction / 16 * TWO_PI
  return { x = math.sin(o), y = -math.cos(o) }
end

local function offset(p, dir, k)
  return { x = p.x + dir.x * k, y = p.y + dir.y * k }
end

local function heading_frame(from, to)
  return direction_index(to.x - from.x, to.y - from.y)
end

local function smoothstep(t)
  if t <= 0 then return 0 end
  if t >= 1 then return 1 end
  return t * t * (3 - 2 * t)
end

local function phi_of(d) return math.atan2(d.x, -d.y) end -- 0 = north, clockwise
local function left_of(d) return { x = d.y, y = -d.x } end
local function right_of(d) return { x = -d.y, y = d.x } end
local function side_normal(d, side) return side == "L" and left_of(d) or right_of(d) end

local function turn_delta(from_phi, to_phi, side)
  if side == "R" then return (to_phi - from_phi) % TWO_PI end
  return (from_phi - to_phi) % TWO_PI
end

-- Shortest arc-straight-arc path from p0 (heading d0) to p1 (heading d1).
local function add_turn_path(points, p0, d0, p1, d1)
  local R = C.turn_radius
  local best
  for _, a_side in pairs({ "L", "R" }) do
    for _, b_side in pairs({ "L", "R" }) do
      local c0 = offset(p0, side_normal(d0, a_side), R)
      local c1 = offset(p1, side_normal(d1, b_side), R)
      local wx, wy = c1.x - c0.x, c1.y - c0.y
      local dist = sqrt(wx * wx + wy * wy)
      local straight, dir
      if a_side == b_side then
        if dist < 1e-6 then dir, straight = d0, 0 else dir, straight = { x = wx / dist, y = wy / dist }, dist end
      elseif dist >= 2 * R then
        straight = sqrt(dist * dist - 4 * R * R)
        local w = { x = wx / dist, y = wy / dist }
        local angle = math.atan2(2 * R, straight) * (a_side == "L" and 1 or -1)
        local n = left_of(w)
        dir = { x = w.x * math.cos(angle) + n.x * math.sin(angle), y = w.y * math.cos(angle) + n.y * math.sin(angle) }
      end
      if dir then
        local phi0, phis, phi1 = phi_of(d0), phi_of(dir), phi_of(d1)
        local turn0, turn1 = turn_delta(phi0, phis, a_side), turn_delta(phis, phi1, b_side)
        local length = R * turn0 + straight + R * turn1
        if not best or length < best.length then
          best = { length = length, a = a_side, b = b_side, c0 = c0, c1 = c1, s = dir,
                   phi0 = phi0, phis = phis, turn0 = turn0, turn1 = turn1 }
        end
      end
    end
  end
  if not best then
    points[#points + 1] = p1
    return
  end

  -- Points every ~2 tiles around each arc; the straight is just its end point.
  local function arc(center, side, start_phi, delta)
    local steps = max(1, math.ceil(R * delta / 2))
    local k = side == "L" and 1 or -1
    for i = 1, steps do
      local phi = start_phi + (side == "R" and 1 or -1) * delta * i / steps
      points[#points + 1] = { x = center.x + k * R * math.cos(phi), y = center.y + k * R * math.sin(phi) }
    end
  end
  arc(best.c0, best.a, best.phi0, best.turn0)
  points[#points + 1] = offset(best.c1, side_normal(best.s, best.b), -R) -- start of the second arc
  arc(best.c1, best.b, best.phis, best.turn1)
end

-- Launcher centre + runway direction -> path to the landing site.
local function build_path(origin, direction, target)
  local points, roll_up = {}, 0
  if not fancy_flights() then
    points[1] = { x = origin.x, y = origin.y }
    points[2] = { x = target.x, y = target.y }
  else
    local d0 = dir_vector(direction)
    points[1] = offset(origin, d0, -C.runway_back)  -- tower end
    points[2] = offset(origin, d0, C.runway_front)  -- lift off past the stripes
    points[3] = offset(points[2], d0, C.climb_out)  -- climb straight out
    local p0 = points[3]
    -- Final approach: a straight run into the landing site, lined up from the climb-out.
    local vx, vy = target.x - p0.x, target.y - p0.y
    local len = sqrt(vx * vx + vy * vy)
    if len < 1 then
      points[4] = { x = target.x, y = target.y }
    else
      local d1 = { x = vx / len, y = vy / len }
      local final = offset(target, d1, -C.approach)
      add_turn_path(points, p0, d0, final, d1)
      points[#points + 1] = { x = target.x, y = target.y }
    end
  end

  local cumulative = { 0 }
  for i = 2, #points do
    local dx, dy = points[i].x - points[i - 1].x, points[i].y - points[i - 1].y
    cumulative[i] = cumulative[i - 1] + sqrt(dx * dx + dy * dy)
  end
  if fancy_flights() then roll_up = cumulative[2] end
  return points, cumulative, max(0.001, cumulative[#points]), roll_up
end

-- Speed ramps up on the takeoff roll and eases off on the final approach.
-- `cruise` is tiles per tick from the flight speed setting.
local function speed_at(d, cruise)
  local s = d.s
  local up
  if s < d.roll_up then
    up = cruise * (0.125 + 0.5 * s / d.roll_up)
  else
    up = min(cruise, cruise * (0.625 + 0.375 * (s - d.roll_up) / 10))
  end
  local down = min(cruise, cruise * (0.5 + 0.5 * (d.total - s) / 12))
  return max(0.03, min(up, down))
end

local function altitude_at(d)
  local air = d.total - d.roll_up
  if air <= 0 then return 0 end
  local climb = min(C.climb_distance, air / 2)
  local up = smoothstep((d.s - d.roll_up) / climb)
  local down = smoothstep((d.total - d.s) / climb)
  return C.cruise_altitude * up * down
end

-- Where the drone is now, and the path segment it's on.
local function path_position(d)
  local points, cumulative = d.points, d.cumulative
  local i = d.segment
  while i < #points - 1 and cumulative[i + 1] <= d.s do i = i + 1 end
  d.segment = i
  local a, b = points[i], points[i + 1]
  local length = cumulative[i + 1] - cumulative[i]
  local t = length > 0 and (d.s - cumulative[i]) / length or 1
  return { x = a.x + (b.x - a.x) * t, y = a.y + (b.y - a.y) * t }, a, b
end

------------------------------------------------------------------------------
-- Launching
------------------------------------------------------------------------------
-- Tell the force once per range level when there's nothing new left to find.
local function warn_no_target(force, range)
  storage.warned = storage.warned or {}
  range = math.floor(range)
  local key = force.index .. ":" .. range
  if storage.warned[key] then return end
  storage.warned[key] = true
  force.print({ "rpdl.no-target", tostring(range) })
end

local function launch_drone(launcher)
  local surface, force, origin = launcher.surface, launcher.force, launcher.position
  local range = drone_range(force)
  local target, cx, cy, found = find_target(surface, force, origin, range)
  if not found then warn_no_target(force, range) end

  -- Ask the game to start generating the landing area while the drone flies.
  surface.request_to_generate_chunks(target, 1)

  local points, cumulative, total, roll_up = build_path(origin, DIR_BY_LAUNCHER[launcher.name] or 0, target)
  local frame = heading_frame(points[1], points[2])
  local drone = {
    surface = surface.index,
    force = force.index,
    points = points,
    cumulative = cumulative,
    total = total,
    roll_up = roll_up,
    s = 0,
    segment = 1,
    tx = target.x, ty = target.y,
    frame = frame,
    next_sound = game.tick + C.flying_sound_interval,
    reservation = reserve(surface, cx, cy),
    -- Shadow first so the plane always draws on top of it.
    shadow = rendering.draw_sprite({
      sprite = "rpdl-drone-shadow-" .. frame,
      target = points[1],
      surface = surface,
      render_layer = "air-object",
      tint = { r = 0, g = 0, b = 0, a = 0.5 },
    }),
    body = rendering.draw_sprite({
      sprite = "rpdl-drone-" .. frame,
      target = points[1],
      surface = surface,
      render_layer = "air-object",
    }),
  }
  storage.drones[#storage.drones + 1] = drone
  surface.play_sound({ path = "rpdl-drone-launch", position = origin })
end

local function poll_launchers()
  for unit, rec in pairs(storage.launchers) do
    local e = rec.entity
    if not (e and e.valid) then
      storage.launchers[unit] = nil
    else
      local done = e.products_finished
      if done > rec.finished then
        for _ = 1, done - rec.finished do launch_drone(e) end
      end
      rec.finished = done
    end
  end
end

------------------------------------------------------------------------------
-- Landing
------------------------------------------------------------------------------
local function lose_drone(surface, force, pos, reason_key, drone)
  try_effect(surface, LAND_PUFF, pos)
  release(drone.reservation)
  force.print({ "rpdl.probe-lost", { "rpdl." .. reason_key }, gps(surface, pos) })
end

local function find_spot(surface, force, name, pos, mode)
  if mode == "fail" then
    if surface.can_place_entity({ name = name, position = pos, force = force }) then return pos end
    return nil
  end
  local spot = surface.find_non_colliding_position(name, pos, C.nudge_radius, 0.5)
  if spot and not is_hazard_tile(surface.get_tile(spot.x, spot.y)) then return spot end
  return nil
end

local function land_drone(drone)
  local surface = game.surfaces[drone.surface]
  local force = game.forces[drone.force]
  if not (surface and surface.valid and force and force.valid) then
    release(drone.reservation)
    return
  end

  local pos = { x = drone.tx, y = drone.ty }
  local chunk = { floor(pos.x / 32), floor(pos.y / 32) }
  if not surface.is_chunk_generated(chunk) then
    surface.request_to_generate_chunks(pos, 1)
    surface.force_generate_chunk_requests()
  end

  local mode = settings.global["rpdl-landing-mode"].value

  if mode == "fail" and is_hazard_tile(surface.get_tile(pos.x, pos.y)) then
    return lose_drone(surface, force, pos, "reason-hazard", drone)
  end

  -- Try both forms and keep whichever spot is closest to where it came down.
  local best, best_name, best_d2
  for _, name in ipairs({ C.probe, C.buoy }) do
    local spot = find_spot(surface, force, name, pos, mode)
    if spot then
      local ddx, ddy = spot.x - pos.x, spot.y - pos.y
      local d2 = ddx * ddx + ddy * ddy
      if not best_d2 or d2 < best_d2 then
        best, best_name, best_d2 = spot, name, d2
      end
    end
  end

  if not best then
    return lose_drone(surface, force, pos, "reason-blocked", drone)
  end

  if mode == "risky" and math.random() < settings.global["rpdl-risky-failure-chance"].value then
    return lose_drone(surface, force, best, "reason-malfunction", drone)
  end

  local probe = surface.create_entity({ name = best_name, position = best, force = force })
  if not (probe and probe.valid) then
    return lose_drone(surface, force, best, "reason-blocked", drone)
  end

  try_effect(surface, best_name == C.buoy and WATER_PUFF or LAND_PUFF, best)
  storage.probes[probe.unit_number] = {
    entity = probe,
    expires = game.tick + C.probe_lifetime_ticks,
    reservation = drone.reservation,
  }
end

------------------------------------------------------------------------------
-- Flight (every tick)
------------------------------------------------------------------------------
-- Map-view icon for a drone, pointed along its flight path (optional, per setting)
local function create_marker(drone, surface, position)
  drone.marker = rendering.draw_sprite({
    sprite = "item/" .. C.drone_item,
    target = position,
    surface = surface,
    render_mode = "chart",
    orientation = drone.frame / C.directions,
    x_scale = 0.5, y_scale = 0.5,
    scale_with_zoom = true,
  })
end

local function destroy_visuals(drone)
  for _, key in ipairs({ "body", "shadow", "marker" }) do
    local obj = drone[key]
    if obj and obj.valid then obj.destroy() end
  end
end

-- Drones launched by 1.0.x flew a straight line; give them a two-point path.
local function upgrade_old_drone(d)
  d.points = { { x = d.sx, y = d.sy }, { x = d.tx, y = d.ty } }
  d.cumulative = { 0, d.dist }
  d.total = max(0.001, d.dist)
  d.roll_up, d.segment = 0, 1
  d.s = d.traveled or 0
  d.frame = d.dir or 0
end

local function update_drones()
  local drones = storage.drones
  if #drones == 0 then return end
  local tick = game.tick
  local cruise = settings.global["rpdl-flight-speed"].value / 60 -- tiles per tick
  local show_icons = settings.global["rpdl-drone-map-icons"].value
  local banking = settings.global["rpdl-banking"].value

  for i = #drones, 1, -1 do
    local d = drones[i]
    if not d.points then upgrade_old_drone(d) end
    d.s = d.s + speed_at(d, cruise)

    if d.s >= d.total or not (d.body and d.body.valid) then
      destroy_visuals(d)
      table.remove(drones, i)
      land_drone(d)
    else
      local pos, a, b = path_position(d)
      local x, y = pos.x, pos.y
      local alt = altitude_at(d)

      -- Banking: on each new path segment, measure how hard the path turns.
      -- Arcs at the full turn radius give a full bank (+ right, - left).
      if d.segment ~= d.bank_seg then
        d.bank_seg = d.segment
        local phi = math.atan2(b.x - a.x, a.y - b.y)
        local turn = 0
        if d.seg_phi then turn = (phi - d.seg_phi + math.pi) % TWO_PI - math.pi end
        local length = max(0.001, d.cumulative[d.segment + 1] - d.cumulative[d.segment])
        d.bank_target = max(-1, min(1, turn / length * C.turn_radius))
        d.seg_phi = phi
      end
      -- Ease toward it, and stay level near the ground (takeoff roll, touchdown).
      local level = banking and (d.bank_target or 0) * min(1, alt / C.cruise_altitude) or 0
      d.bank = (d.bank or 0) + (level - (d.bank or 0)) * C.bank_ease

      -- Face along the current path segment.
      local frame = heading_frame(a, b)
      if frame ~= d.frame then
        d.frame = frame
        d.body.sprite = "rpdl-drone-" .. frame
        if d.shadow and d.shadow.valid then d.shadow.sprite = "rpdl-drone-shadow-" .. frame end
        if d.marker and d.marker.valid then d.marker.orientation = frame / C.directions end
      end
      -- Squeeze the sprite along the wing axis (approximated with screen-axis
      -- scales, so diagonal headings squeeze a blend of both) and slide it
      -- toward the inside of the turn.
      local sx, sy, ox, oy = 1, 1, 0, 0
      local bank = d.bank
      if bank > 0.005 or bank < -0.005 then
        local phi = frame / C.directions * TWO_PI
        local wx, wy = math.cos(phi), math.sin(phi) -- wing axis; also "right" of the heading
        local squeeze = C.bank_squeeze * math.abs(bank)
        sx, sy = 1 - squeeze * wx * wx, 1 - squeeze * wy * wy
        ox, oy = wx * C.bank_slide * bank, wy * C.bank_slide * bank
      end
      d.body.target = { x = x + ox, y = y - alt + oy }
      d.body.x_scale, d.body.y_scale = sx, sy
      if d.shadow and d.shadow.valid then
        d.shadow.target = { x = x + alt * 0.5 + ox, y = y + oy }
        d.shadow.x_scale, d.shadow.y_scale = sx, sy
      end

      -- Map icons follow the setting live, even for drones already in the air.
      local has_marker = d.marker and d.marker.valid
      if show_icons then
        if has_marker then
          d.marker.target = { x = x, y = y }
        else
          local surface = game.surfaces[d.surface]
          if surface then create_marker(d, surface, { x = x, y = y }) end
        end
      elseif has_marker then
        d.marker.destroy()
        d.marker = nil
      end

      -- Narrow chart trail along the flight path, so it can be followed on the map.
      if show_icons and d.s - (d.last_trail or -C.trail_step) >= C.trail_step then
        d.last_trail = d.s
        local surface, force = game.surfaces[d.surface], game.forces[d.force]
        if surface and force then
          local r = C.trail_radius
          surface.request_to_generate_chunks({ x = x, y = y }, 0)
          force.chart(surface, { { x - r, y - r }, { x + r, y + r } })
          -- Chunks far out may not exist yet on the first pass; catch the last spot again.
          local prev = d.prev_trail
          if prev then force.chart(surface, { { prev.x - r, prev.y - r }, { prev.x + r, prev.y + r } }) end
          d.prev_trail = { x = x, y = y }
        end
      end

      if tick >= d.next_sound then
        d.next_sound = tick + C.flying_sound_interval
        local surface = game.surfaces[d.surface]
        if surface then surface.play_sound({ path = "rpdl-drone-flying", position = { x = x, y = y } }) end
      end
    end
  end
end

------------------------------------------------------------------------------
-- Probe lifetime
------------------------------------------------------------------------------
local function expire_probes()
  local tick = game.tick
  for unit, p in pairs(storage.probes) do
    local e = p.entity
    if not (e and e.valid) then
      release(p.reservation)
      storage.probes[unit] = nil
    elseif tick >= p.expires then
      local surface, pos, force = e.surface, e.position, e.force
      try_effect(surface, e.name == C.buoy and WATER_PUFF or LAND_PUFF, pos)
      if settings.global["rpdl-announce-finished"].value then
        force.print({ "rpdl.probe-finished", gps(surface, pos) })
      end
      e.destroy()
      release(p.reservation)
      storage.probes[unit] = nil
    end
  end
end

------------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------------
script.on_init(function()
  init_storage()
  rescan_launchers()
end)

script.on_configuration_changed(function()
  init_storage()
  rescan_launchers()
end)

local function on_built(event)
  local entity = event.entity or event.destination
  if not (entity and entity.valid) then return end
  if entity.name == C.launcher_placer then
    -- Swap the placer for the launcher whose runway faces the same way.
    swap_launcher(entity, entity.direction)
  else
    register_launcher(entity)
  end
end

local built_filter = { { filter = "name", name = C.launcher_placer } }
for _, name in ipairs(LAUNCHER_NAMES) do built_filter[#built_filter + 1] = { filter = "name", name = name } end

for _, name in ipairs({
  "on_built_entity",
  "on_robot_built_entity",
  "on_space_platform_built_entity",
  "script_raised_built",
  "script_raised_revive",
}) do
  local id = defines.events[name]
  if id then script.on_event(id, on_built, built_filter) end
end
script.on_event(defines.events.on_entity_cloned, on_built, built_filter)

-- R / Shift+R over a placed launcher turns its runway.
local function on_rotate(event, reverse)
  local player = game.get_player(event.player_index)
  if not player then return end
  local cursor = player.cursor_stack
  if cursor and cursor.valid_for_read then return end -- holding something: let the game rotate that
  local entity = player.selected
  if is_launcher(entity) and entity.force == player.force then
    swap_launcher(entity, (DIR_BY_LAUNCHER[entity.name] + (reverse and 12 or 4)) % 16)
  end
end
script.on_event("rpdl-rotate", function(event) on_rotate(event, false) end)
script.on_event("rpdl-reverse-rotate", function(event) on_rotate(event, true) end)

script.on_event(defines.events.on_tick, update_drones)
script.on_nth_tick(15, poll_launchers)
script.on_nth_tick(60, expire_probes)
