local C = require("shared")

-- Put our crafting-menu row directly after the radar's row, in the same tab.
-- Done in final fixes so it follows wherever overhaul mods (Krastorio 2,
-- Space Exploration, ...) have moved the radar by now.
local row = data.raw["item-subgroup"][C.subgroup]
local radar = data.raw.item["radar"]
local radar_row = radar and radar.subgroup and data.raw["item-subgroup"][radar.subgroup]

if row and radar_row and radar_row.group then
  row.group = radar_row.group
  -- "d" < "d-rpdl" < "e": sorts right after the radar's row, before the next one.
  row.order = (radar_row.order or "z") .. "-rpdl"
end
