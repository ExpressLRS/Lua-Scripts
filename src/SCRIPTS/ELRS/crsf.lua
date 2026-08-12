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
-- Returns a table with protocol constants, handler registry, and        --
-- pop queue dispatcher.                                                 --
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

-- Link state: derived from RQly in poll()
CRSF.hasTelemetry = false

-- Tick guard for poll()
CRSF._lastPollTick = 0

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
  -- about the link. Derived after the drain so a frame from a dying connection
  -- is dispatched before consumers observe the flip; handlers that keep
  -- per-connection state key their resets off that ordering (see
  -- ELRSTelemetry/txinfo.lua).
  self.hasTelemetry = (CRSF.getSensorValue("RQly") or 0) > 0
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

--- Request ELRS status from the TX module (PARAMETER_WRITE with fieldId=0).
-- The module answers with an ELRS_STATUS frame carrying its warning flags.
function CRSF:requestElrsStatus()
  CRSF.push(CRSF.CONST.FRAMETYPE_PARAMETER_WRITE, { CRSF.CONST.ADDRESS_TX, CRSF.CONST.ADDRESS_HANDSET_ELRS, 0, 0 })
end

-- ============================================================================
-- Return singleton
-- ============================================================================

return CRSF
