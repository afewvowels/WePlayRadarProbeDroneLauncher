local C = require("shared")

--[[
How it works
  * Launchers are assembling machines with a fixed "launch" recipe that eats
    one survey drone. Every few ticks we compare each launcher's
    products_finished counter; each new finished craft = one drone launched.
  * Drones aren't entities: they're two script-drawn sprites (body + shadow)
    moved every tick in a straight line toward their target.
  * On arrival the drone lands (smoke/splash), and a probe or buoy (a radar
    with free power) is placed, nudged, or lost depending on the setting.
  * Probes are removed after C.probe_lifetime_ticks, once their sweep is done.

storage layout
  launchers[unit_number] = { entity = LuaEntity, finished = uint }
  drones[]               = { surface, force, sx, sy, tx, ty, dx, dy, dist, traveled,
                             dir, body, shadow, next_sound, reservation }
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

local function register_launcher(entity)
  if not (entity and entity.valid and entity.name == C.launcher) then return end
  if not entity.active then entity.active = true end -- never leave one stuck paused
  storage.launchers[entity.unit_number] = {
    entity = entity,
    finished = entity.products_finished or 0,
  }
end

local function rescan_launchers()
  storage.launchers = {}
  for _, surface in pairs(game.surfaces) do
    for _, e in pairs(surface.find_entities_filtered({ name = C.launcher })) do
      register_launcher(e)
      -- Clear "nothing to scout" alerts left over from 0.1.4
      for _, player in pairs(e.force.players) do
        player.remove_alert({ entity = e, type = defines.alert_type.custom })
      end
    end
  end
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

  local dx, dy = target.x - origin.x, target.y - origin.y
  local dist = sqrt(dx * dx + dy * dy)
  if dist < 1 then return end
  dx, dy = dx / dist, dy / dist

  -- Ask the game to start generating the landing area while the drone flies.
  surface.request_to_generate_chunks(target, 1)

  local dir = direction_index(dx, dy)
  local drone = {
    surface = surface.index,
    force = force.index,
    sx = origin.x, sy = origin.y,
    tx = target.x, ty = target.y,
    dx = dx, dy = dy,
    dist = dist,
    traveled = 0,
    dir = dir,
    next_sound = game.tick + C.flying_sound_interval,
    reservation = reserve(surface, cx, cy),
    shadow = rendering.draw_sprite({
      sprite = "rpdl-drone-shadow-" .. dir,
      target = origin,
      surface = surface,
      render_layer = "lower-object-above-shadow",
      tint = { r = 0, g = 0, b = 0, a = 0.5 },
    }),
    body = rendering.draw_sprite({
      sprite = "rpdl-drone-" .. dir,
      target = origin,
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
    orientation = drone.dir / C.directions,
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

local function update_drones()
  local drones = storage.drones
  if #drones == 0 then return end
  local tick = game.tick
  local speed = settings.global["rpdl-flight-speed"].value / 60 -- tiles per tick
  local show_icons = settings.global["rpdl-drone-map-icons"].value

  for i = #drones, 1, -1 do
    local d = drones[i]
    d.traveled = d.traveled + speed

    if d.traveled >= d.dist or not (d.body and d.body.valid) then
      destroy_visuals(d)
      table.remove(drones, i)
      land_drone(d)
    else
      local x = d.sx + d.dx * d.traveled
      local y = d.sy + d.dy * d.traveled
      -- Climb out, cruise, then descend.
      local alt = C.cruise_altitude * min(1, d.traveled / C.ramp_tiles, (d.dist - d.traveled) / C.ramp_tiles)
      d.body.target = { x = x, y = y - alt }
      d.shadow.target = { x = x + alt * 0.8, y = y + alt * 0.3 }

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
      if show_icons and d.traveled - (d.last_trail or -C.trail_step) >= C.trail_step then
        d.last_trail = d.traveled
        local surface, force = game.surfaces[d.surface], game.forces[d.force]
        if surface and force then
          local r = C.trail_radius
          surface.request_to_generate_chunks({ x = x, y = y }, 0)
          force.chart(surface, { { x - r, y - r }, { x + r, y + r } })
          -- Chunks far out may not exist yet on the first pass; catch them a bit later.
          local back = min(C.trail_lag, d.traveled)
          local bx, by = x - d.dx * back, y - d.dy * back
          force.chart(surface, { { bx - r, by - r }, { bx + r, by + r } })
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
  register_launcher(event.entity or event.destination)
end

local built_filter = { { filter = "name", name = C.launcher } }
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

script.on_event(defines.events.on_tick, update_drones)
script.on_nth_tick(15, poll_launchers)
script.on_nth_tick(60, expire_probes)
