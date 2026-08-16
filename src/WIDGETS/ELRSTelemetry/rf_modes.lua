---------------------------------------------------------------------------
-- ELRS RF Mode Tables                                                   --
-- Loaded via loadScript() from ELRSTelemetry/elrsinfo.lua with no       --
-- arguments; returns the RfModes table.                                 --
--                                                                       --
-- Pure data plus its selector: the packet-rate names ExpressLRS reports  --
-- through the RFMD sensor, and the receiver sensitivity floor each rate  --
-- is rated to. Both are keyed by the module's firmware major version and --
-- change on ExpressLRS's release clock, which is why they live apart     --
-- from the polling policy that consumes them.                           --
--                                                                       --
-- RFMD is a 0-based sensor and these are 1-based Lua arrays, so the +1   --
-- lives here, next to the literals that define the convention. Callers   --
-- pass the raw sensor value.                                            --
---------------------------------------------------------------------------

local RfModes = {}

-- Names and floors for the currently selected major version, or nil while no
-- ELRS module has answered a device ping.
---@type table?
RfModes._names = nil
---@type table?
RfModes._floors = nil

-- Effective major version of the tables currently built. The only version
-- datum kept, purely so select() can skip rebuilds.
---@type number?
RfModes._maj = nil

-- ============================================================================
-- Selection
-- ============================================================================

--- Install the lookup tables for an ELRS major version.
-- The highest known version at or below vMaj wins, so newer firmware
-- degrades to the newest known tables instead of losing its rate names.
-- Rebuilt only when the effective version changes (first answer, module
-- swap across reconnects), never per frame.
function RfModes.select(vMaj)
  local effMaj
  if vMaj >= 4 then
    effMaj = 4
  elseif vMaj == 3 then
    effMaj = 3
  end
  if RfModes._maj == effMaj then
    return
  end
  RfModes._maj = effMaj

  if effMaj == 4 then
    -- selene: allow(mixed_table)
    RfModes._names = {
      "25Hz",
      "50Hz",
      "100Hz",
      "100HzFull",
      "150Hz",
      "200Hz",
      "200HzFull",
      "250Hz",
      "333HzFull",
      "500Hz",
      "D50",
      "K1000Full",
      [21] = "25Hz",
      [22] = "50Hz",
      [23] = "100Hz",
      [24] = "100HzFull",
      [25] = "150Hz",
      [26] = "200Hz",
      [27] = "200HzFull",
      [28] = "250Hz",
      [29] = "333HzFull",
      [30] = "500Hz",
      [31] = "D250",
      [32] = "D500",
      [33] = "F500",
      [34] = "F1000",
      [35] = "DK250",
      [36] = "DK500",
      [37] = "K1000",
      [101] = "X100Full",
      [102] = "X150",
    }
    -- selene: allow(mixed_table)
    RfModes._floors = {
      -123,
      -120,
      -117,
      -112,
      0,
      -112,
      -111,
      -111,
      0,
      0,
      -112,
      -101,
      [21] = 0,
      [22] = -115,
      [23] = 0,
      [24] = -112,
      [25] = -112,
      [26] = 0,
      [27] = 0,
      [28] = -108,
      [29] = -105,
      [30] = -105,
      [31] = -104,
      [32] = -104,
      [33] = -104,
      [34] = -104,
      [35] = -103,
      [36] = -103,
      [37] = -103,
      [101] = -112,
      [102] = -112,
    }
  elseif effMaj == 3 then
    RfModes._names = {
      "",
      "25Hz",
      "50Hz",
      "100Hz",
      "100HzFull",
      "150Hz",
      "200Hz",
      "250Hz",
      "333HzFull",
      "500Hz",
      "D250",
      "D500",
      "F500",
      "F1000",
      "D50",
      "200HzFull",
      "DK500",
      "K1000",
      "9K1000",
      "K1000Full",
    }
    RfModes._floors = {
      0,
      -123,
      -115,
      -117,
      -112,
      -112,
      -112,
      -108,
      -105,
      -105,
      -104,
      -104,
      -104,
      -104,
      -112,
      -111,
      -103,
      -103,
      0,
      -101,
    }
  else
    RfModes._names = nil
    RfModes._floors = nil
  end
end

-- ============================================================================
-- Lookup
-- ============================================================================

--- Packet-rate name for an RFMD sensor value.
-- Falls back to "RFMD<n>" for a rate this firmware version's table does not
-- name, and for every rate while no module has answered yet.
function RfModes.name(rfmd)
  local names = RfModes._names
  return (names and names[rfmd + 1]) or table.concat({ "RFMD", tostring(rfmd) })
end

--- Rated receiver sensitivity in dBm for an RFMD sensor value, or nil when
--- the rate is unknown. Rates the tables carry as 0 are unrated, not 0 dBm.
function RfModes.floor(rfmd)
  local floors = RfModes._floors
  return floors and floors[rfmd + 1]
end

-- ============================================================================
-- Return module
-- ============================================================================

return RfModes
