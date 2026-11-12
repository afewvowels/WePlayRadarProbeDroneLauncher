local C = require("shared")
local P = C.mod_path

------------------------------------------------------------------------------
-- GRAPHICS CONFIG
-- Sizes and shifts come from the <name>.lua files pack_sprites.py writes
-- (graphics/entity/drone.lua, probe.lua). Until those exist, the fallback
-- sizes below are used with zero shift, which leaves shadows misaligned.
--
-- `size` scales the art in game relative to how it was rendered
-- (1 = rendered size at 64 px per tile).
------------------------------------------------------------------------------
local function load_meta(name)
  local ok, meta = pcall(require, "graphics.entity." .. name)
  if ok and type(meta) == "table" then return meta end
  return {}
end

local function layer(name, kind, fallback, size)
  local meta = load_meta(name)[kind] or fallback
  local shift = meta.shift or { 0, 0 }
  return {
    file = P .. "/graphics/entity/" .. name .. "-" .. kind .. ".png",
    width = meta.width, height = meta.height,
    scale = 0.5 * size,
    shift = { shift[1] * size, shift[2] * size },
  }
end

local PROBE_SIZE = 0.5 -- the probe was modelled ~2x too big; 0.5 fits its 2x2 footprint

local G = {
  drone_diffuse  = layer("drone", "diffuse", { width = 166, height = 139 }, 1),
  drone_shadow   = layer("drone", "shadow",  { width = 187, height = 119 }, 1),
  probe_diffuse  = layer("probe", "diffuse", { width = 321, height = 346 }, PROBE_SIZE),
  probe_shadow   = layer("probe", "shadow",  { width = 457, height = 232 }, PROBE_SIZE),
  buoy_diffuse   = layer("probe-water", "diffuse", { width = 325, height = 320 }, PROBE_SIZE),
  buoy_shadow    = layer("probe-water", "shadow",  { width = 411, height = 205 }, PROBE_SIZE),
  -- Launcher: 4 frames (north, east, south, west), one per runway direction.
  launcher_diffuse = layer("launcher", "diffuse", { width = 324, height = 330 }, 1),
  launcher_shadow  = layer("launcher", "shadow",  { width = 419, height = 233 }, 1),
}
local LINE_LENGTH = 8 -- frames per row in every packed sheet

------------------------------------------------------------------------------
-- Sounds
------------------------------------------------------------------------------
data:extend({
  {
    type = "sound",
    name = "rpdl-drone-launch",
    filename = P .. "/sounds/drone-launch.ogg",
    volume = 0.8,
    audible_distance_modifier = 1.0,
    aggregation = { max_count = 2, remove = true },
  },
  {
    type = "sound",
    name = "rpdl-drone-flying",
    filename = P .. "/sounds/drone-flying.ogg",
    volume = 0.5,
    audible_distance_modifier = 0.7,
    aggregation = { max_count = 3, remove = true },
  },
})

------------------------------------------------------------------------------
-- Drone flight sprites: one sprite prototype per direction, drawn by script
------------------------------------------------------------------------------
local sprites = {}
for i = 0, C.directions - 1 do
  local col, row = i % LINE_LENGTH, math.floor(i / LINE_LENGTH)
  local d, s = G.drone_diffuse, G.drone_shadow
  sprites[#sprites + 1] = {
    type = "sprite",
    name = "rpdl-drone-" .. i,
    filename = d.file,
    x = col * d.width, y = row * d.height,
    width = d.width, height = d.height,
    shift = d.shift,
    scale = d.scale,
    flags = { "no-crop" },
  }
  sprites[#sprites + 1] = {
    type = "sprite",
    name = "rpdl-drone-shadow-" .. i,
    filename = s.file,
    x = col * s.width, y = row * s.height,
    width = s.width, height = s.height,
    shift = s.shift,
    scale = s.scale,
    flags = { "no-crop" },
  }
end
data:extend(sprites)

------------------------------------------------------------------------------
-- Item group
------------------------------------------------------------------------------
-- Our own crafting-menu row. data-final-fixes.lua moves the row to sit right
-- after the radar's row, wherever the radar ends up once overhauls (Krastorio 2,
-- Space Exploration, ...) have finished rearranging things.
local SUBGROUP, ORDER = C.subgroup, ""
data:extend({
  { type = "item-subgroup", name = C.subgroup, group = "logistics", order = "z-rpdl" },
})

data:extend({
  { type = "recipe-category", name = C.launch_category },
})

------------------------------------------------------------------------------
-- Items
------------------------------------------------------------------------------
data:extend({
  {
    type = "item",
    name = C.drone_item,
    icon = P .. "/graphics/icons/survey-drone.png",
    icon_size = 64,
    subgroup = SUBGROUP,
    order = ORDER .. "b",
    stack_size = 10,
  },
  {
    type = "item",
    name = C.launcher,
    icon = P .. "/graphics/icons/drone-launcher.png",
    icon_size = 64,
    subgroup = SUBGROUP,
    order = ORDER .. "a",
    place_result = C.launcher_placer,
    stack_size = 10,
  },
})

------------------------------------------------------------------------------
-- Recipes
------------------------------------------------------------------------------
data:extend({
  {
    type = "recipe",
    name = C.drone_item,
    enabled = false,
    energy_required = 10,
    ingredients = {
      { type = "item", name = "radar",              amount = 1 },
      { type = "item", name = "engine-unit",        amount = 1 },
      { type = "item", name = "steel-plate",        amount = 4 },
      { type = "item", name = "electronic-circuit", amount = 4 },
    },
    results = { { type = "item", name = C.drone_item, amount = 1 } },
  },
  {
    type = "recipe",
    name = C.launcher,
    enabled = false,
    energy_required = 20,
    ingredients = {
      { type = "item", name = "steel-plate",        amount = 50 },
      { type = "item", name = "stone-brick",        amount = 50 },
      { type = "item", name = "electronic-circuit", amount = 20 },
      { type = "item", name = "engine-unit",        amount = 10 },
      { type = "item", name = "radar",              amount = 4 },
    },
    results = { { type = "item", name = C.launcher, amount = 1 } },
  },
  -- The "launch" itself: the launcher crafts this, which eats one drone.
  -- control.lua watches the machine's finished-craft counter and launches a drone.
  {
    type = "recipe",
    name = C.launch_recipe,
    categories = { C.launch_category },
    icon = P .. "/graphics/icons/survey-drone.png",
    icon_size = 64,
    subgroup = SUBGROUP,
    order = ORDER .. "c",
    enabled = true,
    hide_from_player_crafting = true,
    hidden_in_factoriopedia = true,
    energy_required = settings.startup["rpdl-launch-interval"].value, -- seconds of launch prep per drone
    ingredients = { { type = "item", name = C.drone_item, amount = 1 } },
    results = {},
  },
})

------------------------------------------------------------------------------
-- Launcher (5x5 assembling machine with a fixed "launch" recipe)
--
-- Same approach as WePlay: Long Haul Logistics: players and robots build a
-- rotatable placer, and control.lua swaps it for the launcher prototype whose
-- runway faces that way. R / Shift+R rotate placed launchers.
------------------------------------------------------------------------------
local LAUNCHER_COLLISION = { { -2.4, -2.4 }, { 2.4, 2.4 } }
local LAUNCHER_SELECTION = { { -2.5, -2.5 }, { 2.5, 2.5 } }

-- One frame (0-3) cut from a 4-frame sheet
local function frame_layer(def, frame, extra)
  local s = {
    filename = def.file,
    width = def.width, height = def.height,
    x = frame * def.width,
    shift = def.shift,
    scale = def.scale,
  }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

data:extend({
  {
    type = "simple-entity-with-owner",
    name = C.launcher_placer,
    localised_name = { "entity-name." .. C.launcher },
    icon = P .. "/graphics/icons/drone-launcher.png",
    icon_size = 64,
    hidden_in_factoriopedia = true,
    flags = { "placeable-player", "player-creation", "not-upgradable" },
    minable = { mining_time = 1, result = C.launcher },
    placeable_by = { item = C.launcher, count = 1 },
    max_health = 800,
    collision_box = LAUNCHER_COLLISION,
    selection_box = LAUNCHER_SELECTION,
    render_layer = "object",
    picture = {
      sheets = {
        {
          filename = G.launcher_diffuse.file,
          width = G.launcher_diffuse.width, height = G.launcher_diffuse.height,
          frames = 4,
          shift = G.launcher_diffuse.shift,
          scale = G.launcher_diffuse.scale,
        },
        {
          filename = G.launcher_shadow.file,
          width = G.launcher_shadow.width, height = G.launcher_shadow.height,
          frames = 4,
          shift = G.launcher_shadow.shift,
          scale = G.launcher_shadow.scale,
          draw_as_shadow = true,
        },
      },
    },
  },
})

for frame, dir in ipairs(C.launcher_dirs) do
  data:extend({
    {
      type = "assembling-machine",
      name = C.launcher_by_dir[(frame - 1) * 4],
      localised_name = { "entity-name." .. C.launcher },
      localised_description = { "entity-description." .. C.launcher },
      icon = P .. "/graphics/icons/drone-launcher.png",
      icon_size = 64,
      hidden_in_factoriopedia = dir ~= "north",
      flags = { "placeable-neutral", "placeable-player", "player-creation" },
      minable = { mining_time = 1, result = C.launcher },
      placeable_by = { item = C.launcher, count = 1 },
      max_health = 800,
      corpse = "big-remnants",
      collision_box = LAUNCHER_COLLISION,
      selection_box = LAUNCHER_SELECTION,
      crafting_categories = { C.launch_category },
      fixed_recipe = C.launch_recipe,
      show_recipe_icon = false,
      show_recipe_icon_on_map = false,
      crafting_speed = 1,
      module_slots = 0,
      allowed_effects = {},
      energy_source = {
        type = "electric",
        usage_priority = "secondary-input",
        emissions_per_minute = { pollution = 2 },
      },
      energy_usage = "500kW",
      graphics_set = {
        animation = {
          layers = {
            frame_layer(G.launcher_diffuse, frame - 1),
            frame_layer(G.launcher_shadow, frame - 1, { draw_as_shadow = true }),
          },
        },
      },
    },
  })
end

-- R / Shift+R on a placed launcher turns its runway (handled in control.lua).
data:extend({
  { type = "custom-input", name = "rpdl-rotate",         key_sequence = "", linked_game_control = "rotate" },
  { type = "custom-input", name = "rpdl-reverse-rotate", key_sequence = "", linked_game_control = "reverse-rotate" },
})

------------------------------------------------------------------------------
-- Probe (land) and buoy (water): radars with free power, removed by script
-- once their sweep is done.
------------------------------------------------------------------------------
local function rotated(def, extra)
  local s = {
    filename = def.file,
    width = def.width, height = def.height,
    shift = def.shift,
    scale = def.scale,
    direction_count = C.directions,
    line_length = LINE_LENGTH,
  }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end

local probe = {
  type = "radar",
  name = C.probe,
  icon = P .. "/graphics/icons/survey-probe.png",
  icon_size = 64,
  flags = { "placeable-neutral", "player-creation", "not-blueprintable", "not-deconstructable", "placeable-off-grid" },
  max_health = 150,
  collision_box = { { -0.9, -0.9 }, { 0.9, 0.9 } },
  selection_box = { { -1, -1 }, { 1, 1 } },
  energy_source = { type = "void" },
  energy_usage = C.probe_power_kw .. "kW",
  energy_per_sector = math.floor(C.probe_power_kw * C.sector_seconds) .. "kJ",
  energy_per_nearby_scan = "50kJ",
  max_distance_of_sector_revealed = C.scan_radius_chunks,
  max_distance_of_nearby_sector_revealed = C.nearby_radius_chunks,
  connects_to_other_radars = false,
  rotation_speed = 0.01,
  pictures = {
    layers = {
      rotated(G.probe_diffuse),
      rotated(G.probe_shadow, { draw_as_shadow = true }),
    },
  },
}

local buoy = table.deepcopy(probe)
buoy.name = C.buoy
-- Only fits on water: collides with land tiles and other objects, not water.
buoy.collision_mask = { layers = { ground_tile = true, object = true } }
buoy.pictures = {
  layers = {
    rotated(G.buoy_diffuse),
    rotated(G.buoy_shadow, { draw_as_shadow = true }),
  },
}

data:extend({ probe, buoy })

------------------------------------------------------------------------------
-- Technologies
------------------------------------------------------------------------------
local tech_icon = { icon = P .. "/graphics/icons/survey-drone.png", icon_size = 64 }

-- Prerequisites: engine, plus whichever technology unlocks the radar (if any;
-- the radar may be available from the start).
local function tech_unlocking(recipe)
  if data.raw.technology[recipe] then return recipe end
  for name, tech in pairs(data.raw.technology) do
    for _, effect in pairs(tech.effects or {}) do
      if effect.type == "unlock-recipe" and effect.recipe == recipe then return name end
    end
  end
end
local survey_prereqs = { "engine" }
local radar_tech = tech_unlocking("radar")
if radar_tech and radar_tech ~= "engine" then table.insert(survey_prereqs, 1, radar_tech) end

local red_green = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 } }
local red_green_blue = { { "automation-science-pack", 1 }, { "logistic-science-pack", 1 }, { "chemical-science-pack", 1 } }

data:extend({
  {
    type = "technology",
    name = "rpdl-survey-drones",
    icon = tech_icon.icon,
    icon_size = tech_icon.icon_size,
    prerequisites = survey_prereqs,
    effects = {
      { type = "unlock-recipe", recipe = C.drone_item },
      { type = "unlock-recipe", recipe = C.launcher },
    },
    unit = {
      count = 100,
      ingredients = red_green,
      time = 30,
    },
  },
})

for level = 1, C.range_levels do
  data:extend({
    {
      type = "technology",
      name = C.range_tech .. "-" .. level,
      icon = tech_icon.icon,
      icon_size = tech_icon.icon_size,
      upgrade = true,
      prerequisites = { level == 1 and "rpdl-survey-drones" or (C.range_tech .. "-" .. (level - 1)) },
      effects = {
        {
          type = "nothing",
          effect_description = { "modifier-description.rpdl-drone-range", tostring(math.floor(C.range_bonus(level))) },
        },
      },
      unit = {
        count = 150 * level,
        ingredients = level == 1 and red_green or red_green_blue,
        time = 30,
      },
    },
  })
end
