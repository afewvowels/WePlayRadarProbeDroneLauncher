-- Constants shared by the data stage (data.lua) and the runtime (control.lua).
-- Tweak balance here.
local C = {}

C.mod_path        = "__WePlayRadarProbeDroneLauncher__"

-- Prototype names
C.launcher        = "rpdl-drone-launcher"        -- the item, and the north-facing launcher
C.launcher_placer = "rpdl-drone-launcher-placer" -- what players and robots build; swapped on build
-- One launcher prototype per runway direction (defines.direction values: 0 N, 4 E, 8 S, 12 W).
-- North keeps the original name so launchers from older saves carry on as-is.
C.launcher_dirs   = { "north", "east", "south", "west" }  -- frame order in the sprite sheets
C.launcher_by_dir = {
  [0]  = C.launcher,
  [4]  = C.launcher .. "-east",
  [8]  = C.launcher .. "-south",
  [12] = C.launcher .. "-west",
}
C.drone_item      = "rpdl-survey-drone"
C.probe           = "rpdl-survey-probe"
C.buoy            = "rpdl-survey-buoy"
C.launch_recipe   = "rpdl-launch-drone"
C.launch_category = "rpdl-launch"
C.range_tech      = "rpdl-drone-range"   -- levels: rpdl-drone-range-1 .. -N
C.subgroup        = "rpdl-survey"        -- crafting-menu row for the launcher and drone

-- Graphics
C.directions      = 64                   -- drone flight frames (frame 0 = north, clockwise)

-- Probe scanning
C.scan_radius_chunks   = 8               -- slow sweep radius (8 chunks = 256 tiles)
C.nearby_radius_chunks = 1               -- small always-live area around the probe
C.sector_seconds       = 0.5             -- seconds to scan one chunk
C.probe_power_kw       = 1000            -- internal (free) power; sector energy derives from this

-- How long a probe lives: every chunk in its radius once, plus 15% slack
local chunks = (2 * C.scan_radius_chunks + 1) ^ 2
C.probe_lifetime_ticks = math.ceil(chunks * C.sector_seconds * 60 * 1.15)

-- Flight
-- Range comes from startup settings (see settings.lua).
-- Each research level doubles the previous level's bonus: 1024, 2048, 4096 by default,
-- so range goes 1024 -> 2048 -> 4096 -> 8192 tiles.
C.base_range       = settings.startup["rpdl-base-range"].value
C.first_range_bonus = settings.startup["rpdl-range-per-level"].value

function C.range_bonus(level)            -- bonus granted by one research level
  return C.first_range_bonus * 2 ^ (level - 1)
end

C.target_rays = 48                        -- directions sampled when looking for uncharted land
C.range_levels    = 3
-- Flight speed is a runtime mod setting (tiles per second), see settings.lua
C.cruise_altitude = 4                    -- tiles the sprite is lifted at cruise height
C.climb_distance  = 16                   -- tiles spent climbing to / descending from cruise height

-- Fancy flight paths (same numbers as WePlay: Long Haul Logistics)
C.runway_back     = 1.5                  -- tiles from launcher centre to the tower end of the runway
C.runway_front    = 2.5                  -- tiles from launcher centre to the striped end (lift-off)
C.climb_out       = 15                   -- straight climb past the runway before turning
C.approach        = 15                   -- straight final approach into the landing site
C.turn_radius     = 20                   -- tightest turn a drone makes (bigger = lazier arcs)

-- Banking (faked by squeezing the sprite along its wings in turns)
C.bank_squeeze    = 0.35                 -- wings shrink by up to 35% at full bank
C.bank_slide      = 0.3                  -- tiles the plane slides toward the inside of the turn
C.bank_ease       = 0.06                 -- per tick: how quickly it rolls into and out of a bank

-- Flight trail (only with the "Show drones on the map" setting)
C.trail_radius    = 8                    -- tiles charted around the drone; touches 1-4 chunks
C.trail_step      = 16                   -- chart again every this many tiles flown
C.trail_lag       = 32                   -- also re-chart this far behind, once its chunk has generated

-- Landing
C.nudge_radius    = 16                   -- how far a bad landing may be nudged (tiles)

-- Sound
C.flying_sound_interval = 27             -- ticks; length of drone-flying.ogg (~0.46 s)

return C
