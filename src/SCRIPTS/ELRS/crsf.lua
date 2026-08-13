---------------------------------------------------------------------------
-- CRSF Protocol Singleton                                               --
--                                                                       --
-- Shared CRSF transport: protocol constants, pop/push wrappers (and     --
-- their simulator mock seam) and link-layer decoders. Frames are        --
-- consumed pull-style: every consumer drains its own script instance's  --
-- queue through CRSF.drain() (the firmware replicates incoming frames   --
-- into each widget instance's private queue on color radios; on B&W the --
-- standalone tool is the only consumer). Derived link state             --
-- (hasTelemetry) refreshes as a drain empties the queue.                --
--                                                                       --
-- Loaded once via loadScript() from /SCRIPTS/ELRS/crsf.lua.             --
---------------------------------------------------------------------------

local shim = loadScript("/SCRIPTS/ELRS/shim.lua")()
local sensors = loadScript("/SCRIPTS/ELRS/sensors.lua")()

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

-- Link state: derived from RQly as a drain empties the queue
CRSF.hasTelemetry = false

-- ============================================================================
-- Default telemetry wrappers: delegate to real EdgeTX functions
-- When mocking is active, setMock() replaces the underlying implementations
-- ============================================================================

--- Pop one frame from the calling script instance's queue.
-- consumer identifies the caller to the simulator mock, which emulates the
-- firmware's per-widget queue replication with per-consumer cursors; real
-- hardware ignores it. An empty-queue return is the end of a drain, so the
-- derived link state refreshes here: frames are always ingested before
-- consumers can observe a hasTelemetry flip. The ELRS TX zeroes RQly on
-- disconnect, so a present, positive value is the truth about the link.
function CRSF.pop(consumer)
  local command, data = CRSF._popImpl(consumer)
  if command == nil then
    CRSF.hasTelemetry = (CRSF.getSensorValue("RQly") or 0) > 0
  end
  return command, data
end

function CRSF._popImpl(_consumer)
  return crossfireTelemetryPop()
end

--- Drain the calling script instance's queue, routing every frame through
-- onFrame(consumer, command, data). consumer is both the queue identity
-- handed to pop() and the receiver onFrame is invoked on, so consumers
-- pass their routing method directly: CRSF.drain(self, self._onFrame).
function CRSF.drain(consumer, onFrame)
  local command, data
  repeat
    command, data = CRSF.pop(consumer)
    if command then
      onFrame(consumer, command, data)
    end
  until command == nil
end

function CRSF.push(command, data)
  return crossfireTelemetryPush(command, data)
end

-- Read a telemetry sensor value by name (/SCRIPTS/ELRS/sensors.lua)
CRSF.getSensorValue = sensors.getSensorValue

function CRSF.hasCrsfModule()
  for modIdx = 0, 1 do
    local mod = model.getModule(modIdx)
    if mod and (mod.Type == nil or mod.Type == CRSF.CONST.MODULE_TYPE_CROSSFIRE) then
      return true
    end
  end
  return false
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
  CRSF._popImpl = mock.pop
  CRSF.push = mock.push
  CRSF.getSensorValue = mock.getSensorValue
  CRSF.hasCrsfModule = function()
    return mock.moduleFound
  end
end

setMock()
---@diagnostic disable-next-line: cast-local-type
setMock = nil

-- ============================================================================
-- Shared helpers
-- ============================================================================

--- Read a null-terminated string from a CRSF data array, converting the
-- bytes to chars in place and concatenating the slice. The frame table is
-- freshly allocated by every pop, and each frame type has exactly one
-- string-decoding consumer (DEVICE_INFO and ELRS_STATUS decode only here),
-- so mutating it is safe and saves a parts table per string. A second
-- decode of the same frame would raise (string.char on a string) rather
-- than corrupt silently.
-- @param data   array of byte values
-- @param off    1-based start offset
-- @return string, nextOffset
local function readString(data, off)
  local startOff = off
  local b = data[off]
  while b and b ~= 0 do
    data[off] = string.char(b)
    off = off + 1
    b = data[off]
  end
  return shim.tableConcat(data, nil, startOff, off - 1), off + 1
end

--- Decode a DEVICE_INFO (0x29) frame.
-- Payload after [dest, src]: name (null-terminated), serial (4B BE),
-- hwVer (4B), swVer (4B, low three bytes are maj.min.rev), fieldCount (1B),
-- parameter protocol version (1B). No address gate: callers gate on the
-- returned id.
-- @param data  array of byte values
-- @return table with id (source address), name, isElrs (true/nil), fieldCount,
--         vMaj, vMin, vRev -- or nil if the frame is shorter than the layout
function CRSF:decodeDeviceInfo(data)
  local id = data[2]
  local name, off = readString(data, 3)
  if data[off + 12] == nil then
    return nil -- shorter than the fixed layout; the caller's ping retries
  end
  local serial = ((data[off] * 256 + data[off + 1]) * 256 + data[off + 2]) * 256 + data[off + 3]
  return {
    id = id,
    name = name,
    isElrs = (serial == CRSF.CONST.ELRS_SERIAL_ID) or nil,
    fieldCount = data[off + 12],
    vMaj = data[off + 9],
    vMin = data[off + 10],
    vRev = data[off + 11],
  }
end

--- Decode an ELRS_STATUS (0x2E) frame (the answer to requestElrsStatus()).
-- No address gate: callers gate on the returned id.
-- @param data  array of byte values
-- @return table with id (source address), lostPackets, receivedPackets, flags
--         (raw byte, for threshold checks), connected / modelMismatch /
--         criticalError (true/nil), warning (always a string, "" when the
--         module sends none) -- or nil if the frame is shorter than the
--         flags byte
function CRSF:decodeElrsStatus(data)
  if data[6] == nil then
    return nil
  end
  local flags = data[6]
  local warning = readString(data, 7)
  return {
    id = data[2],
    lostPackets = data[3],
    receivedPackets = data[4] * 256 + data[5],
    flags = flags,
    connected = bit32.btest(flags, 1) or nil,
    modelMismatch = bit32.btest(flags, 4) or nil,
    criticalError = (flags > CRSF.CONST.ELRS_FLAGS_WARNING_THRESHOLD) or nil,
    warning = warning,
  }
end

--- ELRS 1.x signature: an inbound PARAMETER_WRITE addressed to the official
-- handset address from the TX module. 3.x+ answers on ADDRESS_HANDSET_ELRS and
-- never writes to the handset. Reads data[1] (the destination) deliberately --
-- unlike the decoders above, which leave gating on the source to the caller.
-- @param data  array of byte values
-- @return true when the frame matches the 1.x signature, nil otherwise
function CRSF:isElrsV1Frame(data)
  return (data[1] == CRSF.CONST.ADDRESS_HANDSET and data[2] == CRSF.CONST.ADDRESS_TX) or nil
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
