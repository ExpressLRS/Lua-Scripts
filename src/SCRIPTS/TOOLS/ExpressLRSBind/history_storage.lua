---------------------------------------------------------------------------
-- Bind Phrase History Storage                                           --
-- Loaded via loadScript() from ExpressLRSBind/main.lua with             --
-- (FileStorage); returns the History table.                             --
--                                                                       --
-- The last MAX phrases, newest first, persisted as indexed keys h1..hN  --
-- (the ELRSVTXAdmin presets c1..c6 idiom). Worst case                   --
-- MAX * (3 + 52 + 1) = 280 bytes, inside FileStorage's bounded 512-byte --
-- read; raising MAX or the phrase length must revisit that budget or    --
-- the tail entries truncate silently. No table.insert/remove: B&W      --
-- radios ship without the table library, so shifts are plain loops.     --
---------------------------------------------------------------------------

local FileStorage = ...

-- Where the history lives on the SD card
local PATH = "/SCRIPTS/TOOLS/ExpressLRSBind/history.txt"

local MAX = 5

-- The file layout, declared once: FileStorage writes these keys in this order.
local SAVE_KEYS = {}
for i = 1, MAX do
  SAVE_KEYS[i] = "h" .. i
end

local History = {
  MAX = MAX,
  -- items[1] is the most recent phrase
  items = {},
}

local function save()
  local values = {}
  for i = 1, #History.items do
    values[SAVE_KEYS[i]] = History.items[i]
  end
  FileStorage.write(PATH, SAVE_KEYS, values)
end

--- Put phrase at the front, dropping an existing copy (a re-used phrase
-- moves up instead of duplicating) and trimming past MAX.
function History.add(phrase)
  if phrase == nil or phrase == "" then
    return
  end
  local items = History.items
  for i = #items, 1, -1 do
    if items[i] == phrase then
      for j = i, #items - 1 do
        items[j] = items[j + 1]
      end
      items[#items] = nil
    end
  end
  for j = math.min(#items + 1, MAX), 2, -1 do
    items[j] = items[j - 1]
  end
  items[1] = phrase
  save()
end

function History.remove(idx)
  local items = History.items
  if items[idx] == nil then
    return
  end
  for j = idx, #items - 1 do
    items[j] = items[j + 1]
  end
  items[#items] = nil
  save()
end

function History.clear()
  History.items = {}
  save()
end

-- Initialize from file. h1..hN are read in order; the first missing key
-- ends the list, so a hand-edited file with gaps loads its head only.
local kv = FileStorage.read(PATH)
if kv then
  for i = 1, MAX do
    local v = kv[SAVE_KEYS[i]]
    if v == nil then
      break
    end
    History.items[i] = v
  end
end

return History
