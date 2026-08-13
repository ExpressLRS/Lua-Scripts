---------------------------------------------------------------------------
-- 6POS Preset Storage                                                   --
-- Loaded via loadScript() from ELRSVTXAdmin/main.lua with (FileStorage) --
-- and shared by every widget instance; returns the PresetsStorage table.--
--                                                                       --
-- Settings store: six preset collections, the active collection, the    --
-- sources and flags, and their persistence as a key=value file -- plus  --
-- the radio-wide automation latches, which live here because an edge    --
-- must be consumed exactly once per radio. The automation that acts on  --
-- them lives in VTXAdmin.                                               --
---------------------------------------------------------------------------

local FileStorage = ...

-- Where the settings live on the SD card
local PATH = "/WIDGETS/ELRSVTXAdmin/presets.txt"

-- Six collections of six slots, one slot per 6POS switch position.
local COLLECTION_COUNT = 6
local SLOT_COUNT = 6

-- The file layout, declared once: FileStorage writes these keys in this order.
-- Scalars first, then one line per collection -- "band,channel" pairs joined
-- with ";". Worst case ~225 bytes, well inside FileStorage's bounded 512-byte
-- read; outgrowing that cap would truncate silently and the next save would
-- write defaults over the tail collections, so keep the budget in mind here.
local SAVE_KEYS = { "enabled", "source", "autoPushVtx", "pushSource", "collection" }
local COLLECTION_KEYS = {}
for c = 1, COLLECTION_COUNT do
  COLLECTION_KEYS[c] = table.concat({ "c", c })
  SAVE_KEYS[#SAVE_KEYS + 1] = COLLECTION_KEYS[c]
end

local PresetsStorage = {
  -- Exposed for the editor's collection dropdown, so the count has one home.
  COLLECTION_COUNT = COLLECTION_COUNT,

  -- collections[c][i] = { band, channel }, c and i both 1..6.
  collections = {},

  -- The active collection's slots: an alias of collections[collection], the
  -- same table and never a copy, so writes through items land in the
  -- collection. Every reader indexes PresetsStorage.items on each access and
  -- none holds it across calls, so re-pointing it here switches the 6POS
  -- automation, the cheatsheet and the editor rows at once.
  items = {},

  -- Active collection, 1..6. Selects both what the 6POS switch applies and
  -- what the full-screen preset rows edit -- one selector, no second mode.
  collection = 1,

  -- Radio-wide automation latches, never persisted. They live on the shared
  -- store rather than on a widget instance because an edge -- a 6POS movement,
  -- a collection change, a push trigger -- must be consumed exactly once per
  -- radio: the first instance whose session can act consumes it, and the rest
  -- see no edge.
  latch = {
    lastPos = -1, -- last consumed 6POS position (cheatsheet highlight reads this)
    lastCollection = -1, -- the collection lastPos was resolved through
    stablePos = -1, -- debounce candidate
    stableTime = 0,
    ---@type boolean? push trigger level; nil until the source adopt seeds it
    pushLastHigh = nil,
    pushSourceSeen = 0, -- the source pushLastHigh was sampled from
  },

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

--- Split a "band,channel;band,channel;..." collection line into up to
--- SLOT_COUNT slots, using plain string.find (no regex). Invalid or missing
--- segments stay nil so the caller fills defaults per slot.
local function splitSlots(val)
  local slots = {}
  local pos = 1
  for i = 1, SLOT_COUNT do
    local semi = string.find(val, ";", pos, true)
    local segment
    if semi then
      segment = string.sub(val, pos, semi - 1)
      pos = semi + 1
    else
      segment = string.sub(val, pos)
      pos = #val + 1
    end
    local band, channel = splitBandChannel(segment)
    if band and channel then
      slots[i] = { band = band, channel = channel }
    end
  end
  return slots
end

--- Schema: enabled/autoPushVtx are "1"/"0" booleans, source/pushSource are
--- source IDs, collection is the active index 1..6, and c1..c6 are collection
--- lines of "band,channel" pairs joined with ";", slots defaulting to
--- Raceband R1..R6.
function PresetsStorage.load()
  local kv = FileStorage.read(PATH) or {}
  PresetsStorage.enabled = (kv.enabled == "1")
  PresetsStorage.source = tonumber(kv.source) or 0
  PresetsStorage.autoPushVtx = (kv.autoPushVtx == "1")
  PresetsStorage.pushSource = tonumber(kv.pushSource) or 0

  local collections = {}
  for c = 1, COLLECTION_COUNT do
    local slots = splitSlots(kv[COLLECTION_KEYS[c]] or "")
    -- Fill missing slots with Raceband defaults (R1..R6)
    for i = 1, SLOT_COUNT do
      if not slots[i] then
        slots[i] = { band = 5, channel = i }
      end
    end
    collections[c] = slots
  end
  PresetsStorage.collections = collections

  local collection = tonumber(kv.collection) or 1
  if collection < 1 or collection > COLLECTION_COUNT then
    collection = 1
  end
  PresetsStorage.collection = collection
  PresetsStorage.items = collections[collection]
end

function PresetsStorage.save()
  local values = {
    enabled = PresetsStorage.enabled and "1" or "0",
    source = PresetsStorage.source,
    autoPushVtx = PresetsStorage.autoPushVtx and "1" or "0",
    pushSource = PresetsStorage.pushSource,
    collection = PresetsStorage.collection,
  }
  for c = 1, COLLECTION_COUNT do
    local slots = PresetsStorage.collections[c]
    local parts = {}
    for i = 1, SLOT_COUNT do
      parts[i] = table.concat({ slots[i].band, ",", slots[i].channel })
    end
    values[COLLECTION_KEYS[c]] = table.concat(parts, ";")
  end
  FileStorage.write(PATH, SAVE_KEYS, values)
end

--- Make a collection active and persist the choice. A single assignment, never
--- an in-place rebuild: display.lua and fullscreen.lua index items[i] from
--- LVGL callbacks that can land on any frame, and a half-built table there is
--- a nil index -- which makes the build fail silently and the whole UI vanish.
function PresetsStorage.selectCollection(c)
  if c < 1 or c > COLLECTION_COUNT then
    return
  end
  if c == PresetsStorage.collection then
    return
  end
  PresetsStorage.collection = c
  PresetsStorage.items = PresetsStorage.collections[c]
  PresetsStorage.save()
end

-- Initialize presets from file
PresetsStorage.load()

return PresetsStorage
