---------------------------------------------------------------------------
-- EdgeTX Version Gate                                                   --
-- Loaded via loadScript() with no arguments; returns the isSupported    --
-- function.                                                             --
--                                                                       --
-- The one home of the package's minimum EdgeTX requirement. The tools   --
-- check it once at load and hand the result to their UI chunk, whose    --
-- preCheck owns the presentation. Keep the manifest's                   --
-- min_edgetx_version (edgetx.yml) in step with this ladder.             --
---------------------------------------------------------------------------

--- True when the running firmware meets the minimum: 2.11.6, 2.12.1
-- or 3.0.
local function isSupported()
  local _ver, _radio, maj, minor, rev = getVersion()

  if maj >= 3 then
    return true
  elseif maj == 2 and minor == 12 and rev >= 1 then
    return true
  elseif maj == 2 and minor == 11 and rev >= 6 then
    return true
  end

  return false
end

return isSupported
