---------------------------------------------------------------------------
-- ELRS TX Module Info                                                   --
--                                                                       --
-- Opt-in stateful companion to the CRSF singleton: DEVICE_INFO cache    --
-- (module name, version-keyed RFMOD/RFRSSI lookup tables) and the       --
-- model-match status, fed by drain(). Loaded once per                   --
-- Lua state and shared by every widget instance; widgets that do not    --
-- need this data never load it, so they never pay for the tables.       --
--                                                                       --
-- Per background tick: elrsinfo:drain() to ingest the queue (which also --
-- refreshes crsf.hasTelemetry as it empties), then elrsinfo:update() to --
-- pump the outgoing requests.                                           --
---------------------------------------------------------------------------

local crsf = ...

local ElrsInfo = {}

-- ============================================================================
-- State
-- ============================================================================

-- Device info cache (populated by the DEVICE_INFO handler):
-- name, isElrs, RFMOD, RFRSSI
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

-- Effective major version of the RFMOD/RFRSSI tables currently built. The
-- only version datum kept, purely so selectRfTables() can skip rebuilds.
---@type number?
ElrsInfo._rfMaj = nil

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

--- Install the RFMOD/RFRSSI lookup tables for an ELRS major version.
-- The highest known version at or below vMaj wins, so newer firmware
-- degrades to the newest known tables instead of losing its rate names.
-- Rebuilt only when the effective version changes (first answer, module
-- swap across reconnects), never per frame.
local function selectRfTables(vMaj)
  local effMaj
  if vMaj >= 4 then
    effMaj = 4
  elseif vMaj == 3 then
    effMaj = 3
  end
  if ElrsInfo._rfMaj == effMaj then
    return
  end
  ElrsInfo._rfMaj = effMaj

  local info = ElrsInfo.deviceInfo
  if effMaj == 4 then
    -- selene: allow(mixed_table)
    info.RFMOD = {
      "25Hz",
      "50Hz",
      "100Hz",
      "100HzFull",
      "150Hz",
      "200Hz",
      "200HzFull",
      "250Hz",
      "333HzFull",
      "500Hz",
      "D50",
      "K1000Full",
      [21] = "25Hz",
      [22] = "50Hz",
      [23] = "100Hz",
      [24] = "100HzFull",
      [25] = "150Hz",
      [26] = "200Hz",
      [27] = "200HzFull",
      [28] = "250Hz",
      [29] = "333HzFull",
      [30] = "500Hz",
      [31] = "D250",
      [32] = "D500",
      [33] = "F500",
      [34] = "F1000",
      [35] = "DK250",
      [36] = "DK500",
      [37] = "K1000",
      [101] = "X100Full",
      [102] = "X150",
    }
    -- selene: allow(mixed_table)
    info.RFRSSI = {
      -123,
      -120,
      -117,
      -112,
      0,
      -112,
      -111,
      -111,
      0,
      0,
      -112,
      -101,
      [21] = 0,
      [22] = -115,
      [23] = 0,
      [24] = -112,
      [25] = -112,
      [26] = 0,
      [27] = 0,
      [28] = -108,
      [29] = -105,
      [30] = -105,
      [31] = -104,
      [32] = -104,
      [33] = -104,
      [34] = -104,
      [35] = -103,
      [36] = -103,
      [37] = -103,
      [101] = -112,
      [102] = -112,
    }
  elseif effMaj == 3 then
    info.RFMOD = {
      "",
      "25Hz",
      "50Hz",
      "100Hz",
      "100HzFull",
      "150Hz",
      "200Hz",
      "250Hz",
      "333HzFull",
      "500Hz",
      "D250",
      "D500",
      "F500",
      "F1000",
      "D50",
      "200HzFull",
      "DK500",
      "K1000",
      "9K1000",
      "K1000Full",
    }
    info.RFRSSI = {
      0,
      -123,
      -115,
      -117,
      -112,
      -112,
      -112,
      -108,
      -105,
      -105,
      -104,
      -104,
      -104,
      -104,
      -112,
      -111,
      -103,
      -103,
      0,
      -101,
    }
  else
    info.RFMOD = nil
    info.RFRSSI = nil
  end
end

-- DEVICE_INFO handler: caches module name/identity and selects the RF tables
local function onDeviceInfo(data)
  local info = crsf:decodeDeviceInfo(data)
  if info == nil or info.id ~= crsf.CONST.ADDRESS_TX then
    return -- short frame (the ping retries) or not the TX module
  end
  ElrsInfo.deviceInfo.name = info.name
  ElrsInfo.deviceInfo.isElrs = info.isElrs
  selectRfTables(info.vMaj)
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
