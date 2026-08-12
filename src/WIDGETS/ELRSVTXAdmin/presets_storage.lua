---------------------------------------------------------------------------
-- 6POS Preset Storage                                                   --
-- Loaded via loadScript() from ELRSVTXAdmin/loadable.lua with           --
-- (FileStorage); returns the PresetsStorage table.                      --
--                                                                       --
-- Pure settings store: the preset slots, sources and flags, and their   --
-- persistence as a key=value file. The automation that acts on them     --
-- lives in VTXAdmin.                                                    --
---------------------------------------------------------------------------

local FileStorage = ...

-- Where the settings live on the SD card
local PATH = "/WIDGETS/ELRSVTXAdmin/presets.txt"

-- The file layout, declared once: FileStorage writes these keys in this order.
local SAVE_KEYS = { "enabled", "source", "autoPushVtx", "pushSource", "p1", "p2", "p3", "p4", "p5", "p6" }

local PresetsStorage = {
  items = {},
  enabled = false,
  source = 0, -- 6POS source ID (0 = not configured)
  autoPushVtx = false, -- auto push to VTX on 6POS change
  pushSource = 0, -- source ID for manual "Send VTx" trigger (0 = not configured)
}

--- Split "band,channel" using plain string.find (no regex).
local function splitBandChannel(val)
  local comma = string.find(val, ",", 1, true)
  if not comma then
    return nil, nil
  end
  return tonumber(string.sub(val, 1, comma - 1)), tonumber(string.sub(val, comma + 1))
end

--- Schema: enabled/autoPushVtx are "1"/"0" booleans, source/pushSource are
--- source IDs, p1..p6 are "band,channel" pairs defaulting to Raceband R1..R6.
function PresetsStorage.load()
  local kv = FileStorage.read(PATH) or {}
  local enabled = (kv.enabled == "1")
  local source = tonumber(kv.source) or 0
  local autoPushVtx = (kv.autoPushVtx == "1")
  local pushSource = tonumber(kv.pushSource) or 0
  local p = {}
  for i = 1, 6 do
    local val = kv[table.concat({ "p", i })]
    if val then
      local b, ch = splitBandChannel(val)
      if b and ch then
        p[i] = { band = b, channel = ch }
      end
    end
    -- Fill missing positions with Raceband defaults (R1..R6)
    if not p[i] then
      p[i] = { band = 5, channel = i }
    end
  end
  PresetsStorage.items = p
  PresetsStorage.enabled = enabled
  PresetsStorage.source = source
  PresetsStorage.autoPushVtx = autoPushVtx
  PresetsStorage.pushSource = pushSource

  print(table.concat({
    "VTXAdmin: presets loaded - enabled=",
    tostring(enabled),
    " source=",
    source,
    " autoPushVtx=",
    tostring(autoPushVtx),
    " pushSource=",
    pushSource,
  }))
  for i = 1, 6 do
    print(table.concat({ "VTXAdmin:   preset ", i, ": band=", p[i].band, " ch=", p[i].channel }))
  end
end

function PresetsStorage.save()
  print(table.concat({ "VTXAdmin: saving presets to ", PATH }))
  local values = {
    enabled = PresetsStorage.enabled and "1" or "0",
    source = PresetsStorage.source,
    autoPushVtx = PresetsStorage.autoPushVtx and "1" or "0",
    pushSource = PresetsStorage.pushSource,
  }
  for i = 1, 6 do
    values[table.concat({ "p", i })] =
      table.concat({ PresetsStorage.items[i].band, ",", PresetsStorage.items[i].channel })
  end
  if FileStorage.write(PATH, SAVE_KEYS, values) then
    print("VTXAdmin: presets saved OK")
  else
    print(table.concat({ "VTXAdmin: ERROR - could not open ", PATH, " for writing" }))
  end
end

-- Initialize presets from file
PresetsStorage.load()

return PresetsStorage
