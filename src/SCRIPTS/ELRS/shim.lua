---------------------------------------------------------------------------
-- B&W Compatibility Layer                                               --
--                                                                       --
-- Polyfill for table.concat, which is missing on B&W radios.            --
--                                                                       --
-- Lives in /SCRIPTS/ELRS/ alongside crsf.lua so it is available to     --
-- both color widgets and B&W telemetry scripts.                         --
--                                                                       --
-- Usage: local shim = loadScript("/SCRIPTS/ELRS/shim.lua")()           --
---------------------------------------------------------------------------

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

return shim
