---------------------------------------------------------------------------
-- Telemetry Sensor Reader                                               --
--                                                                       --
-- Generic EdgeTX telemetry access: read a sensor value by name, with a  --
-- cached getFieldInfo string->ID lookup. Nothing here is CRSF-specific. --
-- Loaded by /SCRIPTS/ELRS/crsf.lua, which exposes the reader to every   --
-- consumer as crsf.getSensorValue (and swaps in the simulator mock's    --
-- reader when active).                                                  --
---------------------------------------------------------------------------

local Sensors = {}

-- Field ID cache (string sensor name -> numeric ID)
Sensors._vCache = {}

--- Read a telemetry sensor value by name.
-- Caches the getFieldInfo string->ID lookup once it succeeds; a sensor that is
-- not discovered yet is retried on every call, so it starts reading as soon as
-- EdgeTX creates it (e.g. sensor discovery running after the widget loaded).
-- getValue is called every time.
function Sensors.getSensorValue(id)
  local cid = Sensors._vCache[id]
  if cid == nil then
    local info = getFieldInfo(id)
    if info == nil then
      return nil
    end
    cid = info.id
    Sensors._vCache[id] = cid
  end
  return getValue(cid)
end

return Sensors
