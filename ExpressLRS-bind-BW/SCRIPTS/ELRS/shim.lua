---------------------------------------------------------------------------
-- B&W Compatibility Layer                                               --
--                                                                       --
-- Polyfills for standard Lua library functions missing on B&W radios    --
-- (table.concat, table.remove) and shared helpers (sensor value cache). --
--                                                                       --
-- Lives in /SCRIPTS/ELRS/ alongside crsf.lua so it is available to     --
-- both color widgets and B&W telemetry scripts.                         --
--                                                                       --
-- Usage: local shim = loadScript("/SCRIPTS/ELRS/shim.lua")()           --
---------------------------------------------------------------------------

-- B&W compatibility adaptation generated with ChatGPT (OpenAI)
-- Based on the original ELRS Bind Manager and EdgeTX/ExpressLRS code
-- Requested and tested by: [Bartosz Pracz / bartoszp1992]

local shim = {}

-- ============================================================================
-- table.concat polyfill
-- On color LCD radios the table library is available; on B&W it is not.
-- ============================================================================

if table and table.concat then
  shim.tableConcat = table.concat
else
  shim.tableConcat = function(t, sep, i, j)
    i = i or 1
    j = j or #t
    if i > j then
      return ""
    end
    local r = t[i] or ""
    for k = i + 1, j do
      if sep then
        r = r .. sep
      end
      r = r .. (t[k] or "")
    end
    return r
  end
end

-- ============================================================================
-- table.remove polyfill
-- Removes and returns the element at pos (default: last element).
-- Shifts subsequent elements down to close the gap.
-- ============================================================================

if table and table.remove then
  shim.tableRemove = table.remove
else
  shim.tableRemove = function(t, pos)
    local n = #t
    if n == 0 then
      return nil
    end
    pos = pos or n
    local val = t[pos]
    for i = pos, n - 1 do
      t[i] = t[i + 1]
    end
    t[n] = nil
    return val
  end
end

-- ============================================================================
-- Cached sensor value reader
-- Wraps getFieldInfo() + getValue() with a string->ID cache so the name
-- lookup is only done once per sensor. Avoids repeated string searches in
-- the source table on every call.
-- ============================================================================

local vCache = {}

function shim.getSensorValue(name)
  local cid = vCache[name]
  if cid == nil then
    local info = getFieldInfo(name)
    cid = info and info.id or 0
    vCache[name] = cid
  end
  return cid ~= 0 and getValue(cid) or nil
end

return shim
