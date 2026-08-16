---------------------------------------------------------------------------
-- ELRS TX Module Info                                                   --
-- Loaded via loadScript() from ELRSTelemetry/main.lua with (crsf);      --
-- returns the ElrsInfo singleton.                                       --
--                                                                       --
-- Stateful companion to the CRSF singleton: DEVICE_INFO cache, the RF   --
-- mode tables it selects, and the model-match status, all fed by        --
-- drain(). Loaded once per Lua state and shared by every instance of    --
-- this widget, so the poll rate limits below are one set of counters    --
-- however many instances the user has placed.                           --
--                                                                       --
-- Per background tick: elrsinfo:drain() to ingest the queue (which also --
-- refreshes crsf.hasTelemetry as it empties), then elrsinfo:update() to --
-- pump the outgoing requests.                                           --
---------------------------------------------------------------------------

local crsf = ...

local RfModes = loadScript("/WIDGETS/ELRSTelemetry/rf_modes.lua")()

local ElrsInfo = {}

-- The RF mode lookup, re-exported so consumers reach the tables through the
-- module that answered the device ping rather than loading them themselves.
ElrsInfo.rfModes = RfModes

-- ============================================================================
-- State
-- ============================================================================

-- Device info cache (populated by the DEVICE_INFO handler): name, isElrs
ElrsInfo.deviceInfo = {}

-- Model match comes from the ELRS_STATUS answers updateModelMatch() asks for.
-- The module recomputes the flag as it answers and never sends one unasked, so
-- the value is exactly as old as the last answer.
---@type boolean?
ElrsInfo.modelMismatch = nil

-- Device info polling
ElrsInfo._lastDevPoll = 0

-- ELRS status polling
ElrsInfo._lastStatusPoll = 0

-- Set once an ELRS_STATUS answer has arrived, so a match is asked about once
-- rather than polled. Cleared with the rest of the per-connection state on any
-- hasTelemetry edge in update(), and by resetModelMatch() on widget create.
---@type boolean?
ElrsInfo._statusAnswered = nil

-- hasTelemetry as last seen by update(), to detect connection edges.
ElrsInfo._wasConnected = false

-- ============================================================================
-- Helpers
-- ============================================================================

--- RSSI of the antenna currently in use, or nil while unknown.
local function getActiveRssi()
  local ant = crsf.getSensorValue("ANT")
  return (ant == 1) and crsf.getSensorValue("2RSS") or crsf.getSensorValue("1RSS")
end

-- ============================================================================
-- Outgoing requests
-- ============================================================================

--- Ask the TX module for its DEVICE_INFO if it is not cached yet.
-- Addressed to the module itself, so it stays off the air. EdgeTX pings once
-- at module init, but that answer lands before any widget's Lua queue exists
-- (queues are created lazily on the first crossfireTelemetryPop), so widgets
-- must ask themselves. Rate-limited to at most once per second, permanently
-- quiet once answered.
local function requestDeviceInfo()
  if ElrsInfo.deviceInfo.name then
    return
  end
  local now = getTime()
  if now - ElrsInfo._lastDevPoll < 100 then
    return
  end
  ElrsInfo._lastDevPoll = now
  crsf:pingDevices(crsf.CONST.ADDRESS_TX)
end

-- Weakest link a status request will be spent on (rule 4 below).
local MODEL_MATCH_MIN_RSSI = -70

--- Whether a status request is worth the frame it costs, right now.
-- requestElrsStatus() is answered locally by the module, but the push still
-- replaces one RC-channels frame on the handset->module UART, so every rule
-- below weighs one answer against one frame. All of them must hold.
local function canRequestStatus(now)
  -- 1. Connected. The module reports no model-match verdict without a link,
  --    and the answer would carry nothing to display.
  if not crsf.hasTelemetry then
    return false
  end
  -- 2. ExpressLRS. The fieldId=0 request is an ELRS convention; a TBS module
  --    answers device pings but never this, and would be asked forever.
  if not ElrsInfo.deviceInfo.isElrs then
    return false
  end
  -- 3. No answer yet, or the last one was a mismatch. One answer settles a
  --    match, but the module recomputes the flag as it answers and announces
  --    nothing on its own, while every way out of a mismatch -- receiver
  --    number, model select, the tool's Model Match switch, a rebind -- is
  --    applied over a link the handset never sees drop. Latching there would
  --    pin the warning on screen for the rest of the session.
  if ElrsInfo._statusAnswered and not ElrsInfo.modelMismatch then
    return false
  end
  -- 4. Strong link. A mismatch is caught next to the quad; out at range every
  --    RC-channels frame is worth more than the answer is.
  local rssi = getActiveRssi()
  if rssi == nil or rssi <= MODEL_MATCH_MIN_RSSI then
    return false
  end
  -- 5. At most once per second, which is as fresh as an answer gets: the
  --    module latches its own packet counters on a 1 s watchdog.
  return now - ElrsInfo._lastStatusPoll >= 100
end

--- Keep modelMismatch current, one request per second at the very most.
local function updateModelMatch()
  local now = getTime()
  if not canRequestStatus(now) then
    return
  end
  ElrsInfo._lastStatusPoll = now
  crsf:requestElrsStatus()
end

--- Forget the model-match verdict, so the next tick asks for a fresh one.
-- Called from widget create(), which runs again for every instance of every
-- model; this singleton outlives them, so without it the previous model's
-- verdict carries over. deviceInfo stays -- the module did not change.
function ElrsInfo:resetModelMatch()
  self.modelMismatch = nil
  self._statusAnswered = nil
end

--- Per-tick pump; call right after drain() so the tick's frames are
-- ingested and hasTelemetry is current. Any hasTelemetry edge wipes the
-- per-connection state before updateModelMatch() runs: a stale
-- modelMismatch can neither survive a disconnect nor suppress the next
-- connection's status poll via a late-arriving answer. hasTelemetry only
-- refreshes as a drain empties the queue, so a dying connection's
-- ELRS_STATUS always lands before the edge is observed here.
function ElrsInfo:update()
  local connected = crsf.hasTelemetry
  if connected ~= self._wasConnected then
    self._wasConnected = connected
    self.modelMismatch = nil
    self._statusAnswered = nil
  end
  requestDeviceInfo()
  updateModelMatch()
end

-- ============================================================================
-- Frame handlers
-- ============================================================================

-- DEVICE_INFO handler: caches module name/identity and selects the RF tables
local function onDeviceInfo(data)
  local info = crsf:decodeDeviceInfo(data)
  if info == nil or info.id ~= crsf.CONST.ADDRESS_TX then
    return -- short frame (the ping retries) or not the TX module
  end
  ElrsInfo.deviceInfo.name = info.name
  ElrsInfo.deviceInfo.isElrs = info.isElrs
  RfModes.select(info.vMaj)
end

-- ELRS_STATUS handler: latches the answer and updates modelMismatch
local function onElrsStatus(data)
  local status = crsf:decodeElrsStatus(data)
  if status == nil or status.id ~= crsf.CONST.ADDRESS_TX then
    return
  end
  ElrsInfo._statusAnswered = true
  ElrsInfo.modelMismatch = status.modelMismatch
end

--- Route one frame into the info cache. Frames of other types are
-- dropped: this singleton is its widget's only queue consumer (pop is
-- destructive per instance), and the firmware delivers every instance its
-- own copy of each frame.
function ElrsInfo:_onFrame(command, data)
  if command == crsf.CONST.FRAMETYPE_DEVICE_INFO then
    onDeviceInfo(data)
  elseif command == crsf.CONST.FRAMETYPE_ELRS_STATUS then
    onElrsStatus(data)
  end
end

--- Drain the calling script instance's pop queue into the info cache.
function ElrsInfo:drain()
  crsf.drain(self, self._onFrame)
end

-- ============================================================================
-- Return singleton
-- ============================================================================

return ElrsInfo
