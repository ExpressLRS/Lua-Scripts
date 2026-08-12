---------------------------------------------------------------------------
-- Key=Value File Storage                                                --
-- Loaded via loadScript() with no arguments; returns FileStorage.       --
--                                                                       --
-- Generic line-oriented "key=value" persistence for script settings.    --
-- Knows nothing about any schema: keys and values are plain strings,    --
-- typing and defaults belong to the caller.                             --
---------------------------------------------------------------------------

local FileStorage = {}

-- A settings file is a handful of short lines; one bounded read keeps the
-- parser simple and caps a corrupt file's blast radius.
local READ_MAX = 512

--- Parse a "key=value" line using plain string.find (no regex).
--- Returns key, value strings or nil if no '=' found.
local function parseKV(line)
  local eq = string.find(line, "=", 1, true)
  if not eq then
    return nil, nil
  end
  return string.sub(line, 1, eq - 1), string.sub(line, eq + 1)
end

--- Read a key=value file into a table of strings, later duplicates of a
--- key winning. Returns nil when the file cannot be opened.
function FileStorage.read(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = io.read(f, READ_MAX)
  io.close(f)
  local kv = {}
  if not data or #data == 0 then
    return kv
  end
  -- Split by newlines using plain string.find
  local pos = 1
  while pos <= #data do
    local nl = string.find(data, "\n", pos, true)
    local line
    if nl then
      line = string.sub(data, pos, nl - 1)
      pos = nl + 1
    else
      line = string.sub(data, pos)
      pos = #data + 1
    end
    local key, val = parseKV(line)
    if key and val then
      kv[key] = val
    end
  end
  return kv
end

--- Write one "key=value" line per entry of keys, in that order. Values may
--- be strings or numbers; keys absent from values are skipped. Returns true
--- on success, nil when the file cannot be opened for writing.
function FileStorage.write(path, keys, values)
  local f = io.open(path, "w")
  if not f then
    return nil
  end
  local lines = {}
  for i = 1, #keys do
    local val = values[keys[i]]
    if val ~= nil then
      lines[#lines + 1] = table.concat({ keys[i], "=", val, "\n" })
    end
  end
  io.write(f, table.concat(lines))
  io.close(f)
  return true
end

return FileStorage
