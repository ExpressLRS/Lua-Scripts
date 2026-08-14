---------------------------------------------------------------------------
-- GC-Guarded Script Loader                                              --
-- Loaded via loadScript() with no arguments; returns the loader         --
-- function. The one library part that cannot load itself: consumers     --
-- bootstrap it with a bare loadScript call.                             --
--                                                                       --
-- A full collection before each load frees the previous compile's       --
-- parser scratch; the firmware runs no GC between loadScript calls, so  --
-- on a fresh install (no .luac yet) the compile peaks would otherwise   --
-- stack -- the cause of the B&W out-of-memory on a tool's first launch. --
---------------------------------------------------------------------------

--- Load a script chunk and run it, passing the remaining arguments
-- through. Raises with the path when the script is missing or fails to
-- compile, which names the culprit in the firmware's error screen.
-- @param path  absolute SD path
-- @return the chunk's return value
local function loader(path, ...)
  collectgarbage("collect")
  local chunk = loadScript(path)
  if chunk == nil then
    error(path)
  end
  return chunk(...)
end

return loader
