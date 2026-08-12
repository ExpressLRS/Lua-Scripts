---------------------------------------------------------------------------
-- ELRS TX Module Info                                                   --
--                                                                       --
-- Opt-in stateful companion to the CRSF singleton: DEVICE_INFO cache    --
-- (module name, version-keyed RFMOD/RFRSSI lookup tables) and the       --
-- per-connection model-match status, fed by frame handlers registered   --
-- on the shared CRSF singleton. Loaded once per Lua state and shared by --
-- every widget instance; widgets that do not need this data never load  --
-- it, so they never pay for the tables.                                 --
--                                                                       --
-- update() is the per-tick pump: call it right after crsf:poll().       --
---------------------------------------------------------------------------

local crsf = ...

local ElrsInfo = {}

-- ============================================================================
-- State
-- ============================================================================

-- Device info cache (populated by the DEVICE_INFO handler):
-- name, isElrs, RFMOD, RFRSSI
ElrsInfo.deviceInfo = {}

-- Model match comes from the ELRS_STATUS answer updateModelMatch() requests
-- once per connection: a connect-time snapshot, fine for model match, which
-- is decided at connect.
---@type boolean?
ElrsInfo.modelMismatch = nil

-- Device info polling
ElrsInfo._lastDevPoll = 0

-- ELRS status polling
ElrsInfo._lastStatusPoll = 0

-- Set once the current connection's ELRS_STATUS answer has arrived, so each
-- connection is polled for model match at most once. Cleared with the rest of
-- the per-connection state on any hasTelemetry edge in update().
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

-- Weakest link updateModelMatch() will spend a frame on: a mismatch is caught
-- next to the quad, and on a marginal link every RC-channels frame matters.
local MODEL_MATCH_MIN_RSSI = -70

--- Keep modelMismatch current at about one status request per connection.
-- requestElrsStatus() is answered locally, but still replaces one RC-channels
-- frame on the handset->module UART, so it is sent only when it can matter
-- and can be afforded: while connected, from a module that identifies as
-- ExpressLRS (other CRSF modules never answer the fieldId=0 convention), on
-- a strong link, and only until the current connection's answer arrives.
-- Retries at most once per second while unanswered.
local function updateModelMatch()
  if not (crsf.hasTelemetry and ElrsInfo.deviceInfo.isElrs) or ElrsInfo._statusAnswered then
    return
  end
  local rssi = getActiveRssi()
  if rssi == nil or rssi <= MODEL_MATCH_MIN_RSSI then
    return
  end
  local now = getTime()
  if now - ElrsInfo._lastStatusPoll < 100 then
    return
  end
  ElrsInfo._lastStatusPoll = now
  crsf:requestElrsStatus()
end

--- Per-tick pump; call right after crsf:poll() so the tick's frames are
-- dispatched and hasTelemetry is current. Any hasTelemetry edge wipes the
-- per-connection state before updateModelMatch() runs: a stale modelMismatch
-- can neither survive a disconnect nor suppress the next connection's status
-- poll via a late-arriving answer. poll() dispatches frames before it derives
-- hasTelemetry, so a dying connection's ELRS_STATUS always lands before the
-- edge is observed here.
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

-- Sole byte-level consumer of these frame types in this Lua state: the
-- decoders consume string bytes in place, so a handler registered behind
-- these would see decoded chars, not bytes.
crsf:registerHandler(crsf.CONST.FRAMETYPE_DEVICE_INFO, onDeviceInfo)
crsf:registerHandler(crsf.CONST.FRAMETYPE_ELRS_STATUS, onElrsStatus)

-- ============================================================================
-- Return singleton
-- ============================================================================

return ElrsInfo
