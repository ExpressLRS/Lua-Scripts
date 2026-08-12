---------------------------------------------------------------------------
-- ELRS TX Module Info                                                   --
--                                                                       --
-- DEVICE_INFO cache (module name, RFMOD/RFRSSI lookup tables) and the   --
-- per-connection model-match status, fed by frame handlers registered   --
-- on the shared CRSF singleton. Loaded once per Lua state by            --
-- ELRSTelemetry/main.lua and shared by every widget instance; widgets   --
-- that do not need this data never load it.                             --
--                                                                       --
-- update() is the per-tick pump: call it right after crsf:poll().       --
---------------------------------------------------------------------------

local crsf = ...

local TxInfo = {}

-- ============================================================================
-- State
-- ============================================================================

-- Device info cache (populated by the DEVICE_INFO handler):
-- name, isElrs, RFMOD, RFRSSI
TxInfo.deviceInfo = {}

-- Model match comes from the ELRS_STATUS answer updateModelMatch() requests
-- once per connection: a connect-time snapshot, fine for model match, which
-- is decided at connect.
---@type boolean?
TxInfo.modelMismatch = nil

-- Device info polling
TxInfo._lastDevPoll = 0

-- ELRS status polling
TxInfo._lastStatusPoll = 0

-- Set once the current connection's ELRS_STATUS answer has arrived, so each
-- connection is polled for model match at most once. Cleared with the rest of
-- the per-connection state on any hasTelemetry edge in update().
---@type boolean?
TxInfo._statusAnswered = nil

-- hasTelemetry as last seen by update(), to detect connection edges.
TxInfo._wasConnected = false

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
  if TxInfo.deviceInfo.name then
    return
  end
  local now = getTime()
  if now - TxInfo._lastDevPoll < 100 then
    return
  end
  TxInfo._lastDevPoll = now
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
  if not (crsf.hasTelemetry and TxInfo.deviceInfo.isElrs) or TxInfo._statusAnswered then
    return
  end
  local rssi = getActiveRssi()
  if rssi == nil or rssi <= MODEL_MATCH_MIN_RSSI then
    return
  end
  local now = getTime()
  if now - TxInfo._lastStatusPoll < 100 then
    return
  end
  TxInfo._lastStatusPoll = now
  crsf:requestElrsStatus()
end

--- Per-tick pump; call right after crsf:poll() so the tick's frames are
-- dispatched and hasTelemetry is current. Any hasTelemetry edge wipes the
-- per-connection state before updateModelMatch() runs: a stale modelMismatch
-- can neither survive a disconnect nor suppress the next connection's status
-- poll via a late-arriving answer. poll() dispatches frames before it derives
-- hasTelemetry, so a dying connection's ELRS_STATUS always lands before the
-- edge is observed here.
function TxInfo:update()
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

-- DEVICE_INFO handler: parses and caches module name and RFMOD/RFRSSI
local function onDeviceInfo(data)
  if data[2] ~= crsf.CONST.ADDRESS_TX then
    return
  end

  local name, off = crsf:fieldGetString(data, 3)
  -- off is the first byte after the name's null terminator:
  -- serNo (4) + hwVer (4) + swVer (4), where swVer's low 3 bytes are maj.min.rev
  local vMaj, vRev = data[off + 9], data[off + 11]
  if not vRev then
    return -- frame shorter than the layout; leave the cache so the ping retries
  end

  local info = TxInfo.deviceInfo
  info.name = name

  -- Serial number "ELRS" identifies an ExpressLRS module. Other CRSF modules
  -- answer DEVICE_PING too, but only ELRS answers the fieldId=0 status request.
  local serial = ((data[off] * 256 + data[off + 1]) * 256 + data[off + 2]) * 256 + data[off + 3]
  if serial == crsf.CONST.ELRS_SERIAL_ID then
    info.isElrs = true
  end

  -- RFMOD / RFRSSI lookup tables (version-dependent)
  if vMaj == 4 then
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
  elseif vMaj == 3 then
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
  end
end

-- ELRS_STATUS handler: latches the answer and updates modelMismatch
local function onElrsStatus(data)
  if data[2] ~= crsf.CONST.ADDRESS_TX then
    return
  end

  TxInfo._statusAnswered = true
  TxInfo.modelMismatch = bit32.btest(data[6] or 0, 4) or nil
end

crsf:registerHandler(crsf.CONST.FRAMETYPE_DEVICE_INFO, onDeviceInfo)
crsf:registerHandler(crsf.CONST.FRAMETYPE_ELRS_STATUS, onElrsStatus)

-- ============================================================================
-- Return singleton
-- ============================================================================

return TxInfo
