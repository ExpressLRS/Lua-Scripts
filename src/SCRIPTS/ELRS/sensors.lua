---------------------------------------------------------------------------
-- Telemetry Sensor Reader                                               --
--                                                                       --
-- Generic EdgeTX telemetry access: read a sensor value by name, with a  --
-- cached getFieldInfo string->ID lookup. Nothing here is CRSF-specific. --
-- Loaded by /SCRIPTS/ELRS/crsf.lua, which exposes the reader to every   --
-- consumer as crsf.getSensorValue (and swaps in the simulator mock's    --
-- reader when active).                                                  --
--                                                                       --
-- The cache is keyed by name but the IDs in it belong to one model, so  --
-- whoever owns the model-change edge must call resetCache().            --
---------------------------------------------------------------------------

local Sensors = {}

-- Field ID cache (string sensor name -> numeric ID)
Sensors._vCache = {}

--- Forget every cached ID. Call on a model change.
-- A telemetry field's ID encodes a slot in the *current* model's sensor list
-- (MIXSRC_FIRST_TELEM + 3 * index, resolved against g_model.telemetrySensors),
-- so an ID cached under one model addresses a different sensor under the next.
-- The cache lives in a singleton that outlives model changes, so nothing
-- invalidates it on its own.
function Sensors.resetCache()
  Sensors._vCache = {}
end

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
