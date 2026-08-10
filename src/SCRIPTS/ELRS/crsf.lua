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
-- Loaded once via loadScript() from /SCRIPTS/ELRSLib/crsf.lua.          --
-- Returns a table with protocol constants, handler registry,            --
-- pop queue dispatcher, and device info cache.                          --
---------------------------------------------------------------------------

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
  FIELD_FLOAT = 8,
  FIELD_TEXT_SELECTION = 9,
  FIELD_STRING = 10,
  FIELD_FOLDER = 11,
  FIELD_INFO = 12,
  FIELD_COMMAND = 13,

  -- Command states
  CMD_IDLE = 0,
  CMD_CLICK = 1,
  CMD_EXECUTING = 2,
  CMD_CONFIRMED = 3,

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

-- Telemetry state (populated by built-in ELRS_STATUS handler)
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
-- Caches the getFieldInfo string->ID lookup; getValue is called every time.
-- setMock() replaces this function with the simulator's mock telemetry.
function CRSF.getSensorValue(id)
  local cid = CRSF._vCache[id]
  if cid == nil then
    local info = getFieldInfo(id)
    cid = info and info.id or 0
    CRSF._vCache[id] = cid
  end
  return cid ~= 0 and getValue(cid) or nil
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
  -- Avoid duplicate registration
  for _, cb in ipairs(self._handlers[frameType]) do
    if cb == callback then
      return
    end
  end
  self._handlers[frameType][#self._handlers[frameType] + 1] = callback
end

--- Remove a previously registered callback.
-- @param frameType  numeric frame type
-- @param callback   the exact function reference to remove
function CRSF:unregisterHandler(frameType, callback)
  local handlers = self._handlers[frameType]
  if not handlers then
    return
  end
  for i = #handlers, 1, -1 do
    if handlers[i] == callback then
      table.remove(handlers, i)
      return
    end
  end
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
  return table.concat(data, nil, startOff, off - 1), off + 1
end

--- Send a DEVICE_PING if device info is not yet available.
-- Rate-limited to at most once per second.
function CRSF:requestDeviceInfo()
  if self.deviceInfo.name then
    return
  end
  local now = getTime()
  if now - self._lastDevPoll < 100 then
    return
  end
  self._lastDevPoll = now
  CRSF.push(CRSF.CONST.FRAMETYPE_DEVICE_PING, { CRSF.CONST.ADDRESS_BROADCAST, CRSF.CONST.ADDRESS_HANDSET })
end

--- Request ELRS status from the TX module (PARAMETER_WRITE with fieldId=0).
-- Updates hasTelemetry via the ELRS_STATUS handler on the next poll().
-- Rate-limited to at most once per second.
function CRSF:requestElrsStatus()
  local now = getTime()
  if now - (self._lastStatusPoll or 0) < 100 then
    return
  end
  self._lastStatusPoll = now
  CRSF.push(CRSF.CONST.FRAMETYPE_PARAMETER_WRITE, { CRSF.CONST.ADDRESS_TX, CRSF.CONST.ADDRESS_HANDSET_ELRS, 0, 0 })
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
  info.vStr = string.format("%s (%d.%d.%d)", name, vMaj, vMin, vRev)

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

-- ELRS_STATUS handler: updates hasTelemetry, modelMismatch, elrsFlagsInfo
local function onElrsStatus(data)
  if data[2] ~= CRSF.CONST.ADDRESS_TX then
    return
  end

  CRSF.elrsFlags = data[6] or 0
  CRSF.hasTelemetry = bit32.btest(CRSF.elrsFlags, 1)
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
