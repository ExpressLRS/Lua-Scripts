---------------------------------------------------------------------------
-- CRSF Protocol Singleton                                               --
--                                                                       --
-- Allows multiple widgets to share a single CRSF connection.            --
-- crossfireTelemetryPop() is a destructive queue — each frame can only  --
-- be read once. This singleton is the sole consumer: it drains the      --
-- queue in poll() and fans each frame out to every widget that          --
-- registered a handler for that frame type. Widgets never call          --
-- crossfireTelemetryPop() directly; they register callbacks via         --
-- registerHandler() and push outgoing frames through CRSF.push().       --
--                                                                       --
-- Loaded once via loadScript() from /SCRIPTS/ELRS/crsf.lua.             --
-- Returns a table with protocol constants, handler registry,            --
-- pop queue dispatcher, and device info cache.                          --
---------------------------------------------------------------------------

local shim = loadScript("/SCRIPTS/ELRS/shim.lua")()

local CRSF = {}

-- ============================================================================
-- Named protocol constants
-- ============================================================================

CRSF.CONST = {
  -- Addresses
  ADDRESS_BROADCAST = 0x00,
  ADDRESS_HANDSET = 0xEA, -- EdgeTX's official handset address
  ADDRESS_RX = 0xEC,
  ADDRESS_TX = 0xEE,
  ADDRESS_HANDSET_ELRS = 0xEF, -- ELRS-custom Lua device address, not standard CRSF

  -- Frame types
  FRAMETYPE_DEVICE_PING = 0x28,
  FRAMETYPE_DEVICE_INFO = 0x29,
  FRAMETYPE_PARAMETER_SETTINGS_ENTRY = 0x2B,
  FRAMETYPE_PARAMETER_READ = 0x2C,
  FRAMETYPE_PARAMETER_WRITE = 0x2D,
  FRAMETYPE_ELRS_STATUS = 0x2E,

  -- Field types (for parsing PARAMETER_SETTINGS_ENTRY responses)
  FIELD_UINT8 = 0,
  FIELD_INT8 = 1,
  FIELD_UINT16 = 2,
  FIELD_INT16 = 3,
  FIELD_UINT32 = 4,
  FIELD_INT32 = 5,
  FIELD_UINT64 = 6,
  FIELD_INT64 = 7,
  FIELD_FLOAT = 8,
  FIELD_TEXT_SELECTION = 9,
  FIELD_STRING = 10,
  FIELD_FOLDER = 11,
  FIELD_INFO = 12,
  FIELD_COMMAND = 13,
  FIELD_VTX = 15,

  -- Command steps (commandStep_e in ExpressLRS CRSFParameters.h)
  CMD_IDLE = 0,
  CMD_CLICK = 1, -- user has clicked the command to execute
  CMD_EXECUTING = 2, -- command is executing
  CMD_ASKCONFIRM = 3, -- command pending user OK
  CMD_CONFIRMED = 4, -- user has confirmed
  CMD_CANCEL = 5, -- user has requested cancel
  CMD_QUERY = 6, -- UI is requesting status update

  -- ELRS identification (serial number field in DEVICE_INFO)
  ELRS_SERIAL_ID = 0x454C5253,

  -- ELRS flags: bits 0-1 are status (connected, status1),
  -- bits 2-4 are warnings (model match, armed, warning1),
  -- bits 5-7 are critical errors (error connected, error baudrate, critical2)
  ELRS_FLAGS_STATUS_MASK = 0x03, -- bits 0-1: status flags only
  ELRS_FLAGS_WARNING_THRESHOLD = 0x1F, -- bits 5+: critical error flags

  -- Folder child list terminator
  FIELD_LIST_END = 0xFF,

  -- Module type for model.getModule() check
  MODULE_TYPE_CROSSFIRE = 5,
}

-- ============================================================================
-- Internal state
-- ============================================================================

-- Handler registry: frameType -> { callback1, callback2, ... }
CRSF._handlers = {}

-- Device info cache (populated by built-in DEVICE_INFO handler)
CRSF.deviceInfo = {}

-- Link state: hasTelemetry is derived from RQly in poll(); the rest comes
-- from the ELRS_STATUS answer updateModelMatch() requests once per connection.
-- elrsFlags/elrsFlagsInfo are therefore a connect-time snapshot: fine for
-- model match, which is decided at connect, but stale for anything dynamic
-- like the armed bit -- read the arm switch via getValue() for that, or poll
-- like the tool does.
CRSF.hasTelemetry = false
CRSF.modelMismatch = false
CRSF.elrsFlags = 0
CRSF.elrsFlagsInfo = ""

-- Tick guard for poll()
CRSF._lastPollTick = 0

-- Device info polling
CRSF._lastDevPoll = 0

-- ELRS status polling
CRSF._lastStatusPoll = 0

-- Set once the current connection's ELRS_STATUS answer has arrived, so each
-- connection is polled for model match at most once. Cleared with the rest of
-- the per-connection state on any hasTelemetry edge in poll().
---@type boolean?
CRSF._statusAnswered = nil

-- ============================================================================
-- Default telemetry wrappers: delegate to real EdgeTX functions
-- When mocking is active, setMock() replaces these with mock implementations
-- ============================================================================

function CRSF.pop()
  return crossfireTelemetryPop()
end

function CRSF.push(command, data)
  return crossfireTelemetryPush(command, data)
end

function CRSF.hasCrsfModule()
  for modIdx = 0, 1 do
    local mod = model.getModule(modIdx)
    if mod and (mod.Type == nil or mod.Type == CRSF.CONST.MODULE_TYPE_CROSSFIRE) then
      return true
    end
  end
  return false
end

-- Field ID cache (string sensor name -> numeric ID)
CRSF._vCache = {}

--- Read a telemetry sensor value by name.
-- Caches the getFieldInfo string->ID lookup once it succeeds; a sensor that is
-- not discovered yet is retried on every call, so it starts reading as soon as
-- EdgeTX creates it (e.g. sensor discovery running after the widget loaded).
-- getValue is called every time.
-- setMock() replaces this function with the simulator's mock telemetry.
function CRSF.getSensorValue(id)
  local cid = CRSF._vCache[id]
  if cid == nil then
    local info = getFieldInfo(id)
    if info == nil then
      return nil
    end
    cid = info.id
    CRSF._vCache[id] = cid
  end
  return getValue(cid)
end

-- ============================================================================
-- Simulator integration (mirrors expresslrs.lua setMock pattern)
-- ============================================================================

local function setMock()
  local _, rv = getVersion()
  if string.sub(rv, -5) ~= "-simu" then
    return
  end
  local mockModule = loadScript("/SCRIPTS/CRSFSimulator/csrfsimulator.lua")
  if mockModule == nil then
    return
  end
  local mock = mockModule()
  CRSF.pop = mock.pop
  CRSF.push = mock.push
  CRSF.hasCrsfModule = function()
    return mock.moduleFound
  end
  CRSF.getSensorValue = mock.getSensorValue
end

setMock()
---@diagnostic disable-next-line: cast-local-type
setMock = nil

-- ============================================================================
-- Handler registry
-- ============================================================================

--- Register a callback for a specific CRSF frame type.
-- @param frameType  numeric frame type (use CRSF.CONST.FRAMETYPE_*)
-- @param callback   function(data) called when a frame of this type is popped
function CRSF:registerHandler(frameType, callback)
  if not self._handlers[frameType] then
    self._handlers[frameType] = {}
  end
  self._handlers[frameType][#self._handlers[frameType] + 1] = callback
end

-- ============================================================================
-- Pop queue dispatcher
-- ============================================================================

--- Drain the pop queue and dispatch frames to registered handlers.
-- Guarded by a tick timestamp so only one effective poll runs per tick,
-- even if multiple widgets call this.
function CRSF:poll()
  local now = getTime()
  if now == self._lastPollTick then
    return
  end
  self._lastPollTick = now

  while true do
    local command, data = CRSF.pop()
    if command == nil then
      break
    end
    local fh = self._handlers[command]
    if fh then
      for _, cb in ipairs(fh) do
        cb(data)
      end
    end
  end

  -- Connection state is derived from link quality at zero wire cost: the ELRS
  -- TX zeroes RQly on disconnect, so a present, positive value is the truth
  -- about the link. Runs after the drain so an ELRS_STATUS frame from a dying
  -- connection is processed before the edge check, and any edge wipes the
  -- per-connection state: a stale modelMismatch can neither survive a
  -- disconnect nor suppress the next connection's status poll via a
  -- late-arriving answer.
  local connected = (CRSF.getSensorValue("RQly") or 0) > 0
  if connected ~= self.hasTelemetry then
    self.modelMismatch = false
    self.elrsFlags = 0
    self.elrsFlagsInfo = ""
    self._statusAnswered = nil
    self.hasTelemetry = connected
  end
end

-- ============================================================================
-- Shared helpers
-- ============================================================================

--- Parse a null-terminated string from a CRSF data array.
-- Modifies data in-place (bytes -> chars) for efficiency: poll() hands the
-- same data table to every handler registered for a frame type, so a handler
-- running after this one sees 1-char strings, not bytes, over
-- [off, nextOffset - 2].
-- @param data   array of byte values
-- @param off    1-based start offset
-- @return string, nextOffset
function CRSF:fieldGetString(data, off)
  local startOff = off
  local b = data[off]
  while b and b ~= 0 do
    data[off] = string.char(b)
    off = off + 1
    b = data[off]
  end
  return shim.tableConcat(data, nil, startOff, off - 1), off + 1
end

--- Send a DEVICE_PING.
-- A ping addressed to a specific device is answered on the handset UART and
-- never forwarded over the air; a broadcast ping is also forwarded to the RX
-- while the link is up, costing over-the-air round trips. Broadcast only when
-- discovering remote devices.
-- @param dest  CRSF device address (use CRSF.CONST.ADDRESS_*); nil broadcasts
function CRSF:pingDevices(dest)
  CRSF.push(CRSF.CONST.FRAMETYPE_DEVICE_PING, { dest or CRSF.CONST.ADDRESS_BROADCAST, CRSF.CONST.ADDRESS_HANDSET })
end

--- Ask the TX module for its DEVICE_INFO if it is not cached yet.
-- Addressed to the module itself, so it stays off the air. EdgeTX pings once
-- at module init, but that answer lands before any widget's Lua queue exists
-- (queues are created lazily on the first crossfireTelemetryPop), so widgets
-- must ask themselves. Rate-limited to at most once per second, permanently
-- quiet once answered.
function CRSF:requestDeviceInfo()
  if self.deviceInfo.name then
    return
  end
  local now = getTime()
  if now - self._lastDevPoll < 100 then
    return
  end
  self._lastDevPoll = now
  self:pingDevices(CRSF.CONST.ADDRESS_TX)
end

--- Request ELRS status from the TX module (PARAMETER_WRITE with fieldId=0).
-- The module answers with an ELRS_STATUS frame carrying its warning flags.
function CRSF:requestElrsStatus()
  CRSF.push(CRSF.CONST.FRAMETYPE_PARAMETER_WRITE, { CRSF.CONST.ADDRESS_TX, CRSF.CONST.ADDRESS_HANDSET_ELRS, 0, 0 })
end

--- RSSI of the antenna currently in use, or nil while unknown.
function CRSF.getActiveRssi()
  local ant = CRSF.getSensorValue("ANT")
  return (ant == 1) and CRSF.getSensorValue("2RSS") or CRSF.getSensorValue("1RSS")
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
function CRSF:updateModelMatch()
  if not (self.hasTelemetry and self.deviceInfo.isElrs) or self._statusAnswered then
    return
  end
  local rssi = CRSF.getActiveRssi()
  if rssi == nil or rssi <= MODEL_MATCH_MIN_RSSI then
    return
  end
  local now = getTime()
  if now - self._lastStatusPoll < 100 then
    return
  end
  self._lastStatusPoll = now
  self:requestElrsStatus()
end

-- ============================================================================
-- Built-in handlers
-- ============================================================================

-- DEVICE_INFO handler: parses and caches module name, version, RFMOD/RFRSSI
local function onDeviceInfo(data)
  if data[2] ~= CRSF.CONST.ADDRESS_TX then
    return
  end

  local name, off = CRSF:fieldGetString(data, 3)
  -- off is the first byte after the name's null terminator:
  -- serNo (4) + hwVer (4) + swVer (4), where swVer's low 3 bytes are maj.min.rev
  local vMaj, vMin, vRev = data[off + 9], data[off + 10], data[off + 11]
  if not vRev then
    return -- frame shorter than the layout; leave the cache so the ping retries
  end

  local info = CRSF.deviceInfo
  info.name = name
  info.vMaj = vMaj
  info.vMin = vMin
  info.vRev = vRev

  -- Serial number "ELRS" identifies an ExpressLRS module. Other CRSF modules
  -- answer DEVICE_PING too, but only ELRS answers the fieldId=0 status request.
  local serial = ((data[off] * 256 + data[off + 1]) * 256 + data[off + 2]) * 256 + data[off + 3]
  if serial == CRSF.CONST.ELRS_SERIAL_ID then
    info.isElrs = true
  end

  -- RFMOD / RFRSSI lookup tables (version-dependent)
  if info.vMaj == 4 then
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
  elseif info.vMaj == 3 then
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

-- ELRS_STATUS handler: latches the answer, updates modelMismatch and elrsFlagsInfo
local function onElrsStatus(data)
  if data[2] ~= CRSF.CONST.ADDRESS_TX then
    return
  end

  CRSF._statusAnswered = true
  CRSF.elrsFlags = data[6] or 0
  CRSF.modelMismatch = bit32.btest(CRSF.elrsFlags, 4)

  -- Null-terminated warning info string starts at data[7]
  CRSF.elrsFlagsInfo = CRSF:fieldGetString(data, 7)
end

-- Register built-in handlers
CRSF:registerHandler(CRSF.CONST.FRAMETYPE_DEVICE_INFO, onDeviceInfo)
CRSF:registerHandler(CRSF.CONST.FRAMETYPE_ELRS_STATUS, onElrsStatus)

-- ============================================================================
-- Return singleton
-- ============================================================================

return CRSF
