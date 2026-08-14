---------------------------------------------------------------------------
-- Deferred Callback Timer                                               --
-- Loaded via loadScript() with no arguments; returns the Defer table.   --
--                                                                       --
-- A single-slot setTimeout: at most one callback is pending at a time,  --
-- and scheduling a new one replaces it. That replacement is the point,  --
-- not a limitation -- a consumer sequencing wire traffic (send, retry,  --
-- follow-up) wants a new action to cancel whatever was pending. A       --
-- consumer needing independent timers needs a different tool.           --
--                                                                       --
-- Each loadScript() execution returns a fresh table, so every consumer  --
-- owns a private slot. poll() must be called once per run() tick.       --
---------------------------------------------------------------------------

local Defer = {
  _cb = nil,
}

--- Schedule fn(ctx) to run once no sooner than ticks from now, replacing
-- any pending callback.
-- @param ticks  delay in getTime() units (10 ms)
-- @param fn     callback
-- @param ctx   passed to fn; nil is fine
function Defer.setTimeout(ticks, fn, ctx)
  Defer._cb = {
    start = getTime(),
    ticks = ticks,
    fn = fn,
    ctx = ctx,
  }
end

--- Drop the pending callback, if any.
function Defer.clear()
  Defer._cb = nil
end

--- Run the pending callback when its delay has elapsed. The slot is
-- cleared before the call so the callback may schedule a successor.
function Defer.poll()
  local cb = Defer._cb
  if cb == nil then
    return
  end
  if getTime() - cb.start < cb.ticks then
    return
  end
  Defer._cb = nil
  cb.fn(cb.ctx)
end

return Defer
