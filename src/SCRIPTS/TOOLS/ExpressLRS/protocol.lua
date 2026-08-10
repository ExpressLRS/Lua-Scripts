---- #########################################################################
---- # Protocol Module: CRSF constants, parsing, and field operations     #
---- # Shared between BW and LVGL UI implementations                      #
---- #########################################################################

local shim = ...

local Protocol = {
  -- EdgeTX module type for CRSF/ELRS
  MODULE_TYPE_CROSSFIRE = 5,

  -- CRSF Field Type Constants
  CRSF = {
    UINT8 = 0,
    INT8 = 1,
    UINT16 = 2,
    INT16 = 3,
    UINT32 = 4,
    INT32 = 5,
    UINT64 = 6,
    INT64 = 7,
    FLOAT = 8,
    TEXT_SELECTION = 9,
    STRING = 10,
    FOLDER = 11,
    INFO = 12,
    COMMAND = 13,
    -- Internal/extended types (not in official CRSF protocol)
    BACK_EXIT = 14,
    DEVICE = 15,
    DEVICE_FOLDER = 16,

    -- Frame types
    FRAMETYPE_DEVICE_PING = 0x28,
    FRAMETYPE_DEVICE_INFO = 0x29,
    FRAMETYPE_PARAMETER_SETTINGS_ENTRY = 0x2B,
    FRAMETYPE_PARAMETER_READ = 0x2C,
    FRAMETYPE_PARAMETER_WRITE = 0x2D,
    FRAMETYPE_ELRS_STATUS = 0x2E,

    -- Addresses
    ADDRESS_BROADCAST = 0x00,
    ADDRESS_HANDSET = 0xEA, -- EdgeTX's official handset address
    ADDRESS_RX = 0xEC,
    ADDRESS_TX = 0xEE,
    ADDRESS_HANDSET_ELRS = 0xEF, -- ELRS-custom Lua device address, not standard CRSF

    -- ELRS identification
    ELRS_SERIAL_ID = 0x454C5253,

    -- ELRS flags: bits 0-1 are status (connected, status1),
    -- bits 2-4 are warnings (model match, armed, warning1),
    -- bits 5-7 are critical errors (error connected, error baudrate, critical2)
    ELRS_FLAGS_STATUS_MASK = 0x03, -- bits 0-1: status flags only
    ELRS_FLAGS_WARNING_THRESHOLD = 0x1F, -- bits 5+: critical error flags

    -- Command steps (sent as last byte in PARAMETER_WRITE for COMMAND fields)
    CMD_IDLE = 0,
    CMD_CLICK = 1,
    CMD_EXECUTING = 2,
    CMD_ASKCONFIRM = 3,
    CMD_CONFIRMED = 4,
    CMD_CANCEL = 5,
    CMD_QUERY = 6,
  },

  -- Handlers dispatch table (populated after function definitions)
  handlers = {},

  -- Device identity (used in every CRSF frame)
  deviceId = 0xEE, -- ADDRESS_TX (can't self-ref before table is created)
  handsetId = 0xEF, -- ADDRESS_HANDSET_ELRS
  deviceName = nil,
  deviceIsELRS_TX = nil,

  -- Fields collection
  fields = {},
  fieldsCount = 0,
  fieldPopup = nil,

  -- Devices collection
  devices = {},

  -- Status/flags (parsed from ELRS info messages)
  elrsFlags = 0,
  elrsFlagsInfo = "",
  elrsV1Detected = false,
  receivedPackets = nil,
  lostPackets = nil,

  -- Protocol timing
  linkstatTimeout = 100,
  pingTimeout = 0,

  -- Communication state
  fieldTimeout = 0,
  fieldChunk = 0,
  fieldData = nil,
  loadQueue = {},
  expectChunksRemain = -1,
  backgroundLoading = false,

  -- Telemetry transition tracking (for auto-discovery on reconnect)
  hadTelemetry = false,
}

-- ============================================================================
-- Reset
-- ============================================================================

function Protocol.reset()
  Protocol.deviceId = Protocol.CRSF.ADDRESS_TX
  Protocol.handsetId = Protocol.CRSF.ADDRESS_HANDSET_ELRS
  Protocol.deviceName = nil
  Protocol.deviceIsELRS_TX = nil

  Protocol.fields = {}
  Protocol.fieldsCount = 0
  Protocol.fieldPopup = nil

  Protocol.devices = {}

  Protocol.elrsFlags = 0
  Protocol.elrsFlagsInfo = ""
  Protocol.elrsV1Detected = false
  Protocol.receivedPackets = nil
  Protocol.lostPackets = nil

  Protocol.linkstatTimeout = 100
  Protocol.pingTimeout = 0

  Protocol.fieldTimeout = 0
  Protocol.fieldChunk = 0
  Protocol.fieldData = nil
  Protocol.loadQueue = {}
  Protocol.expectChunksRemain = -1
  Protocol.backgroundLoading = false
  Protocol.hadTelemetry = false
end

-- ============================================================================
-- Telemetry wrappers (replaced by setMock in simulator)
-- ============================================================================

function Protocol.pop()
  return crossfireTelemetryPop()
end

function Protocol.push(command, data)
  return crossfireTelemetryPush(command, data)
end

function Protocol.pingDevices()
  Protocol.push(Protocol.CRSF.FRAMETYPE_DEVICE_PING, { Protocol.CRSF.ADDRESS_BROADCAST, Protocol.CRSF.ADDRESS_HANDSET })
end

-- Check if telemetry is being received from the RX (elrsFlags bit 1)
function Protocol.hasTelemetry()
  return bit32.btest(Protocol.elrsFlags, 1)
end

function Protocol.isModelMismatch()
  return bit32.btest(Protocol.elrsFlags, 0x04)
end

function Protocol.hasCriticalError()
  return Protocol.elrsFlags > Protocol.CRSF.ELRS_FLAGS_WARNING_THRESHOLD
end

-- Response timeout for PARAMETER_READ:
-- 0.5s for local TX module, 5s for remote devices relayed over air link.
function Protocol.fieldResponseTimeout()
  return Protocol.deviceIsELRS_TX and 50 or 500
end

-- Check if a CRSF-compatible module is available
function Protocol.hasCrsfModule()
  for modIdx = 0, 1 do
    local mod = model.getModule(modIdx)
    if mod and (mod.Type == nil or mod.Type == Protocol.MODULE_TYPE_CROSSFIRE) then
      return true
    end
  end
  return false
end

-- Set active device and prepare fields
-- Returns true if device changed, false if no change needed
function Protocol.setDevice(device)
  if not device then
    return false
  end
  if Protocol.deviceId == device.id and Protocol.fieldsCount == device.fieldCount then
    return false
  end

  Protocol.deviceId = device.id
  Protocol.elrsFlags = 0
  Protocol.deviceName = device.name
  Protocol.fieldsCount = device.fieldCount
  Protocol.deviceIsELRS_TX = device.isElrs and device.id == Protocol.CRSF.ADDRESS_TX or nil
  Protocol.handsetId = Protocol.deviceIsELRS_TX and Protocol.CRSF.ADDRESS_HANDSET_ELRS or Protocol.CRSF.ADDRESS_HANDSET

  Protocol.allocateFields()
  Protocol.reloadAllFields()
  return true
end

-- ============================================================================
-- Field management functions
-- ============================================================================

function Protocol.allocateFields()
  Protocol.fields = {}
  Protocol.fields[0] = {} -- root folder (field 0)
  for i = 1, Protocol.fieldsCount do
    Protocol.fields[i] = {}
  end
end

-- Check if all children of a folder have been loaded (have names).
-- folderId: the folder's field ID, or nil for root (uses field 0).
function Protocol.isFolderLoaded(folderId)
  local folder = Protocol.fields[folderId or 0]
  if not folder or not folder.children then
    return false
  end
  for _, childId in ipairs(folder.children) do
    local child = Protocol.fields[childId]
    if not child or not child.name or child.nameStale then
      return false
    end
  end
  return true
end

-- Return load progress for a folder's children as (loaded, total).
-- Returns nil if the folder or its children list is unknown yet.
function Protocol.getFolderLoadProgress(folderId)
  local folder = Protocol.fields[folderId or 0]
  if not folder or not folder.children then
    return nil
  end
  local total = #folder.children
  local loaded = 0
  for _, childId in ipairs(folder.children) do
    local child = Protocol.fields[childId]
    if child and child.name and not child.reloading then
      loaded = loaded + 1
    end
  end
  return loaded, total
end

function Protocol.reloadAllFields()
  Protocol.fieldTimeout = 0
  Protocol.fieldChunk = 0
  Protocol.fieldData = nil
  Protocol.loadQueue = {}
  -- Start by loading only field 0 (root folder).
  -- Its response contains child IDs; only root children are auto-queued.
  -- Subfolder children are loaded on-demand via loadFolderChildren().
  Protocol.loadQueue[1] = 0
end

-- Parameterized: takes folderId instead of accessing Navigation
function Protocol.getFieldsInFolder(folderId)
  local folder = Protocol.fields[folderId or 0]
  if not folder or not folder.children then
    return {}
  end
  local result = {}
  for _, childId in ipairs(folder.children) do
    local child = Protocol.fields[childId]
    if child and child.name then
      result[#result + 1] = child
    end
  end
  return result
end

function Protocol.getDevice(id)
  for _, device in ipairs(Protocol.devices) do
    if device.id == id then
      return device
    end
  end
end

function Protocol.reloadCurField(field)
  Protocol.fieldTimeout = 0
  Protocol.fieldChunk = 0
  Protocol.fieldData = nil
  Protocol.loadQueue[#Protocol.loadQueue + 1] = field.id
end

-- Queue unloaded children of a folder for on-demand loading.
function Protocol.loadFolderChildren(folderId)
  local folder = Protocol.fields[folderId]
  if not folder or not folder.children then
    return
  end
  for i = #folder.children, 1, -1 do
    local childId = folder.children[i]
    local child = Protocol.fields[childId]
    if child and not child.name then
      Protocol.loadQueue[#Protocol.loadQueue + 1] = childId
    end
  end
  if #Protocol.loadQueue > 0 then
    Protocol.fieldTimeout = 0
  end
end

-- Queue all unloaded subfolder children for background preloading.
function Protocol.startBackgroundLoad()
  Protocol.backgroundLoading = true
  for i = 1, #Protocol.fields do
    local field = Protocol.fields[i]
    if field.type == Protocol.CRSF.FOLDER and field.children then
      for j = #field.children, 1, -1 do
        local childId = field.children[j]
        local child = Protocol.fields[childId]
        if child and not child.name then
          Protocol.loadQueue[#Protocol.loadQueue + 1] = childId
        end
      end
    end
  end
  if #Protocol.loadQueue > 0 then
    Protocol.fieldTimeout = 0
  end
end

-- ============================================================================
-- Field data helpers
-- ============================================================================

function Protocol.fieldGetStrOrOpts(data, offset, last, isOpts)
  local r = last or (isOpts and {})
  local optParts = {}
  local vcnt = 0
  repeat
    local b = data[offset]
    offset = offset + 1

    if not last then
      if r and (b == 59 or b == 0) then
        r[#r + 1] = shim.tableConcat(optParts)
        if #optParts > 0 then
          vcnt = vcnt + 1
          optParts = {}
        end
      elseif b ~= 0 then
        -- Translate legacy arrow bytes (0xC0/0xC1) from ELRS firmware
        -- to EdgeTX CHAR_UP/CHAR_DOWN glyphs
        if b == 192 and CHAR_UP then
          optParts[#optParts + 1] = CHAR_UP
        elseif b == 193 and CHAR_DOWN then
          optParts[#optParts + 1] = CHAR_DOWN
        else
          optParts[#optParts + 1] = string.char(b)
        end
      end
    end
  until b == 0

  return (r or shim.tableConcat(optParts)), offset, vcnt
end

function Protocol.fieldGetValue(data, offset, size)
  local result = 0
  for i = 0, size - 1 do
    result = bit32.lshift(result, 8) + data[offset + i]
  end
  return result
end

-- ============================================================================
-- Field load functions
-- ============================================================================

local function fieldUnsignedLoad(field, data, offset, size, unitoffset)
  field.value = Protocol.fieldGetValue(data, offset, size)
  field.min = Protocol.fieldGetValue(data, offset + size, size)
  field.max = Protocol.fieldGetValue(data, offset + 2 * size, size)
  local unit = Protocol.fieldGetStrOrOpts(data, offset + (unitoffset or (4 * size)), field.unit)
  field.unit = (unit ~= "") and unit or nil
  if size ~= 1 then
    field.size = size
  end
end

local function fieldUnsignedToSigned(field, size)
  local bandval = bit32.lshift(0x80, (size - 1) * 8)
  field.value = field.value - bit32.band(field.value, bandval) * 2
  field.min = field.min - bit32.band(field.min, bandval) * 2
  field.max = field.max - bit32.band(field.max, bandval) * 2
end

local function fieldSignedLoad(field, data, offset, size, unitoffset)
  fieldUnsignedLoad(field, data, offset, size, unitoffset)
  fieldUnsignedToSigned(field, size)
  field.size = -size
end

function Protocol.fieldIntLoad(field, data, offset)
  local loadFn = (field.type % 2 == 0) and fieldUnsignedLoad or fieldSignedLoad
  return loadFn(field, data, offset, math.floor(field.type / 2) + 1)
end

function Protocol.fieldFloatLoad(field, data, offset)
  fieldSignedLoad(field, data, offset, 4, 21)
  field.prec = data[offset + 16]
  if field.prec > 3 then
    field.prec = 3
  end
  field.step = Protocol.fieldGetValue(data, offset + 17, 4)
  field.fmt = shim.tableConcat({ "%.", tostring(field.prec), "f" })
  field.prec = 10 ^ field.prec
end

function Protocol.fieldTextSelLoad(field, data, offset)
  local vcnt
  local oldValues = field.values
  local cached = field.dirty == nil and oldValues
  field.values, offset, vcnt = Protocol.fieldGetStrOrOpts(data, offset, cached, true)
  if not cached then
    field.disabled = (vcnt <= 1) or nil
    -- Preserve table identity if contents unchanged (avoids redundant Choice widget updates)
    if oldValues and #oldValues == #field.values then
      local same = true
      for i = 1, #field.values do
        if oldValues[i] ~= field.values[i] then
          same = false
          break
        end
      end
      if same then
        field.values = oldValues
      end
    end
  end
  field.value = data[offset]
  local unit = Protocol.fieldGetStrOrOpts(data, offset + 4)
  field.unit = (unit ~= "") and unit or nil
  field.dirty = nil
end

function Protocol.fieldStringLoad(field, data, offset)
  field.value, offset = Protocol.fieldGetStrOrOpts(data, offset)
  if #data >= offset then
    field.maxlen = data[offset]
  end
end

function Protocol.fieldCommandLoad(field, data, offset)
  field.status = data[offset]
  field.timeout = data[offset + 1]
  local info = Protocol.fieldGetStrOrOpts(data, offset + 2)
  field.info = (info ~= "") and info or nil
  if field.status == Protocol.CRSF.CMD_IDLE then
    -- A command that was actively running just finished (or was cancelled):
    -- re-read its same-level fields so the current page reflects any values the
    -- command changed. The guard limits this to the active command -- routine
    -- loads of idle command fields while browsing (fieldPopup is nil) must not
    -- trigger a reload.
    if Protocol.fieldPopup == field then
      Protocol.reloadRelatedFields(field)
    end
    Protocol.fieldPopup = nil
  end
end

function Protocol.fieldFolderLoad(field, data, offset)
  field.children = {}
  while data[offset] and data[offset] ~= 0xFF do
    field.children[#field.children + 1] = data[offset]
    offset = offset + 1
  end
end

-- ============================================================================
-- Field save functions
-- ============================================================================

function Protocol.fieldIntSave(field)
  local value = field.value
  local size = field.size or 1
  if size < 0 then
    size = -size
    if value < 0 then
      value = bit32.lshift(0x100, (size - 1) * 8) + value
    end
  end

  local frame = { Protocol.deviceId, Protocol.handsetId, field.id }
  for i = size - 1, 0, -1 do
    frame[#frame + 1] = bit32.rshift(value, 8 * i) % 256
  end
  Protocol.push(Protocol.CRSF.FRAMETYPE_PARAMETER_WRITE, frame)
end

function Protocol.fieldStringSave(field)
  local frame = { Protocol.deviceId, Protocol.handsetId, field.id }
  local val = field.value or ""
  local maxlen = field.maxlen or 32
  if #val > maxlen then
    val = string.sub(val, 1, maxlen)
  end
  for i = 1, #val do
    local b = string.byte(val, i)
    if b ~= 0 then
      frame[#frame + 1] = b
    end
  end
  frame[#frame + 1] = 0
  Protocol.push(Protocol.CRSF.FRAMETYPE_PARAMETER_WRITE, frame)
end

-- ============================================================================
-- Related fields reload (for value changes)
-- ============================================================================

function Protocol.reloadParentFolder(field)
  if field.parent and Protocol.fields[field.parent] then
    Protocol.fields[field.parent].nameStale = true
    Protocol.loadQueue[#Protocol.loadQueue + 1] = field.parent
    local minTimeout = getTime() + Protocol.fieldResponseTimeout()
    if Protocol.fieldTimeout < minTimeout then
      Protocol.fieldTimeout = minTimeout
    end
  end
end

function Protocol.reloadRelatedFields(field)
  Protocol.reloadParentFolder(field)

  for fieldId = Protocol.fieldsCount, 1, -1 do
    local sibling = Protocol.fields[fieldId]
    local siblingType = sibling.type or 99
    if
      fieldId ~= field.id
      and sibling.parent == field.parent
      and (siblingType < Protocol.CRSF.FOLDER or siblingType == Protocol.CRSF.INFO)
    then
      sibling.dirty = true
      sibling.reloading = true
      Protocol.loadQueue[#Protocol.loadQueue + 1] = fieldId
    end
  end

  field.dirty = true
  field.reloading = true
  Protocol.loadQueue[#Protocol.loadQueue + 1] = field.id
  Protocol.fieldTimeout = getTime() + 20
  Protocol.linkstatTimeout = Protocol.fieldTimeout + 100
end

function Protocol.handleCommandSave(field)
  Protocol.reloadCurField(field)

  if field.status ~= nil then
    if field.status < Protocol.CRSF.CMD_CONFIRMED then
      field.status = Protocol.CRSF.CMD_CLICK
      Protocol.push(
        Protocol.CRSF.FRAMETYPE_PARAMETER_WRITE,
        { Protocol.deviceId, Protocol.handsetId, field.id, field.status }
      )
      Protocol.fieldPopup = field
      Protocol.fieldPopup.lastStatus = Protocol.CRSF.CMD_IDLE
      Protocol.fieldTimeout = getTime() + field.timeout
    end
  end
end

function Protocol.commandConfirm()
  if Protocol.fieldPopup then
    Protocol.push(
      Protocol.CRSF.FRAMETYPE_PARAMETER_WRITE,
      { Protocol.deviceId, Protocol.handsetId, Protocol.fieldPopup.id, Protocol.CRSF.CMD_CONFIRMED }
    )
    Protocol.fieldTimeout = getTime() + Protocol.fieldPopup.timeout
    Protocol.fieldPopup.status = Protocol.CRSF.CMD_CONFIRMED
  end
end

function Protocol.commandCancel()
  if Protocol.fieldPopup then
    Protocol.push(
      Protocol.CRSF.FRAMETYPE_PARAMETER_WRITE,
      { Protocol.deviceId, Protocol.handsetId, Protocol.fieldPopup.id, Protocol.CRSF.CMD_CANCEL }
    )
    Protocol.fieldPopup = nil
  end
end

-- ============================================================================
-- Handlers dispatch table
-- ============================================================================

Protocol.handlers = {
  [Protocol.CRSF.UINT8 + 1] = { load = Protocol.fieldIntLoad, save = Protocol.fieldIntSave },
  [Protocol.CRSF.INT8 + 1] = { load = Protocol.fieldIntLoad, save = Protocol.fieldIntSave },
  [Protocol.CRSF.UINT16 + 1] = { load = Protocol.fieldIntLoad, save = Protocol.fieldIntSave },
  [Protocol.CRSF.INT16 + 1] = { load = Protocol.fieldIntLoad, save = Protocol.fieldIntSave },
  [Protocol.CRSF.UINT32 + 1] = nil,
  [Protocol.CRSF.INT32 + 1] = nil,
  [Protocol.CRSF.UINT64 + 1] = nil,
  [Protocol.CRSF.INT64 + 1] = nil,
  [Protocol.CRSF.FLOAT + 1] = { load = Protocol.fieldFloatLoad, save = Protocol.fieldIntSave },
  [Protocol.CRSF.TEXT_SELECTION + 1] = { load = Protocol.fieldTextSelLoad, save = Protocol.fieldIntSave },
  [Protocol.CRSF.STRING + 1] = { load = Protocol.fieldStringLoad, save = Protocol.fieldStringSave },
  [Protocol.CRSF.FOLDER + 1] = { load = Protocol.fieldFolderLoad, save = nil },
  [Protocol.CRSF.INFO + 1] = { load = Protocol.fieldStringLoad, save = nil },
  [Protocol.CRSF.COMMAND + 1] = { load = Protocol.fieldCommandLoad, save = Protocol.handleCommandSave },
}

-- ============================================================================
-- CRSF message parsing
-- ============================================================================

function Protocol.parseDeviceInfoMessage(data)
  local id = data[2]
  local newName, offset = Protocol.fieldGetStrOrOpts(data, 3)
  local device = Protocol.getDevice(id)
  local isNew = (device == nil)
  if isNew then
    device = { id = id }
    Protocol.devices[#Protocol.devices + 1] = device
  end
  device.name = newName
  device.fieldCount = data[offset + 12]
  device.isElrs = Protocol.fieldGetValue(data, offset, 4) == Protocol.CRSF.ELRS_SERIAL_ID
  return device, isNew
end

-- Handle a parameter settings entry (0x2B) frame. Field data can span several frames,
-- so this reassembles the chunks before decoding one field.
function Protocol.parseParameterInfoMessage(data)
  local fieldId = (Protocol.fieldPopup and Protocol.fieldPopup.id) or Protocol.loadQueue[#Protocol.loadQueue]
  -- Another device answered, or this is not the field we are waiting for: drop any partial data
  if data[2] ~= Protocol.deviceId or data[3] ~= fieldId then
    Protocol.fieldData = nil
    Protocol.fieldChunk = 0
    return
  end
  local field = Protocol.fields[fieldId]
  local chunksRemain = data[4]
  -- If no field or the chunksremain changed when we have data, don't continue
  if not field or (Protocol.fieldData and chunksRemain ~= Protocol.expectChunksRemain) then
    return
  end

  local offset
  -- If data is chunked, copy it to persistent buffer
  if chunksRemain > 0 or Protocol.fieldChunk > 0 then
    Protocol.fieldData = Protocol.fieldData or {}
    for i = 5, #data do
      Protocol.fieldData[#Protocol.fieldData + 1] = data[i]
      data[i] = nil
    end
    offset = 1
  else
    -- All data arrived in one chunk, operate directly on data
    Protocol.fieldData = data
    offset = 5
  end

  if chunksRemain > 0 then
    Protocol.fieldChunk = Protocol.fieldChunk + 1
    Protocol.expectChunksRemain = chunksRemain - 1
  else
    -- Field data stream is now complete, process into a field
    Protocol.loadQueue[#Protocol.loadQueue] = nil

    -- Need at least parent + type + one name byte for the entry to be usable
    if #Protocol.fieldData > (offset + 2) then
      field.id = fieldId
      field.parent = (Protocol.fieldData[offset] ~= 0) and Protocol.fieldData[offset] or nil
      field.type = bit32.band(Protocol.fieldData[offset + 1], 0x7f)
      -- Hidden bit flipped, so the UI's cached list of visible fields has to be rebuilt
      local wasHidden = field.hidden
      field.hidden = bit32.btest(Protocol.fieldData[offset + 1], 0x80) or nil
      if field.hidden ~= wasHidden then
        Protocol.fieldHiddenChanged = true
      end
      -- Passing the old name makes fieldGetStrOrOpts skip the decode and reuse that string,
      -- which is only safe while no reload has flagged the name as possibly changed
      local cachedName = (not field.nameStale and not field.reloading) and field.name or nil
      field.name, offset = Protocol.fieldGetStrOrOpts(Protocol.fieldData, offset + 2, cachedName)
      field.nameStale = nil
      field.reloading = nil
      local handler = Protocol.handlers[field.type + 1]
      if handler and handler.load then
        handler.load(field, Protocol.fieldData, offset)
      end
      if field.min == 0 then
        field.min = nil
      end
      if field.max == 0 then
        field.max = nil
      end

      -- Auto-queue children for root folder (field 0) and during background preloading.
      if field.type == Protocol.CRSF.FOLDER and field.children and (fieldId == 0 or Protocol.backgroundLoading) then
        for i = #field.children, 1, -1 do
          Protocol.loadQueue[#Protocol.loadQueue + 1] = field.children[i]
        end
      end
    end

    Protocol.fieldChunk = 0
    Protocol.fieldData = nil
  end
end

function Protocol.parseElrsInfoMessage(data)
  if data[2] ~= Protocol.deviceId then
    Protocol.fieldData = nil
    Protocol.fieldChunk = 0
    return
  end

  Protocol.lostPackets = data[3]
  Protocol.receivedPackets = (data[4] * 256) + data[5]
  local newFlags = data[6]
  Protocol.elrsFlags = newFlags
  Protocol.elrsFlagsInfo = Protocol.fieldGetStrOrOpts(data, 7)
end

function Protocol.parseElrsV1Message(data)
  if (data[1] ~= Protocol.CRSF.ADDRESS_HANDSET) or (data[2] ~= Protocol.CRSF.ADDRESS_TX) then
    return
  end
  Protocol.elrsV1Detected = true
end

-- ============================================================================
-- Main CRSF communication loop
-- ============================================================================

function Protocol.poll()
  local command, data
  local targetDevice = nil
  local anyNewDevice = false

  repeat
    command, data = Protocol.pop()
    if command == Protocol.CRSF.FRAMETYPE_DEVICE_INFO then
      local device, isNew = Protocol.parseDeviceInfoMessage(data)
      if device.id == Protocol.deviceId then
        targetDevice = device
      end
      if isNew then
        anyNewDevice = true
      end
    elseif command == Protocol.CRSF.FRAMETYPE_PARAMETER_SETTINGS_ENTRY then
      Protocol.parseParameterInfoMessage(data)
      if #Protocol.loadQueue > 0 then
        Protocol.fieldTimeout = 0
      elseif Protocol.fieldPopup then
        Protocol.fieldTimeout = getTime() + Protocol.fieldPopup.timeout
      end
    elseif command == Protocol.CRSF.FRAMETYPE_PARAMETER_WRITE then
      Protocol.parseElrsV1Message(data)
    elseif command == Protocol.CRSF.FRAMETYPE_ELRS_STATUS then
      Protocol.parseElrsInfoMessage(data)
    end
  until command == nil

  return targetDevice, anyNewDevice
end

function Protocol.tick()
  -- Ping on telemetry transition (device may have changed)
  local hasTelemetry = Protocol.hasTelemetry()
  if hasTelemetry and not Protocol.hadTelemetry then
    Protocol.pingDevices()
  end
  Protocol.hadTelemetry = hasTelemetry

  local time = getTime()
  -- Periodic ping for initial device discovery
  if #Protocol.devices == 0 and time > Protocol.pingTimeout then
    Protocol.pingDevices()
    Protocol.pingTimeout = time + 100 -- 1s
  end

  if Protocol.fieldPopup then
    if time > Protocol.fieldTimeout and Protocol.fieldPopup.status ~= Protocol.CRSF.CMD_ASKCONFIRM then
      Protocol.push(
        Protocol.CRSF.FRAMETYPE_PARAMETER_WRITE,
        { Protocol.deviceId, Protocol.handsetId, Protocol.fieldPopup.id, Protocol.CRSF.CMD_QUERY }
      )
      Protocol.fieldTimeout = time + Protocol.fieldPopup.timeout
    end
  elseif time > Protocol.linkstatTimeout then
    if Protocol.deviceIsELRS_TX then
      Protocol.push(Protocol.CRSF.FRAMETYPE_PARAMETER_WRITE, { Protocol.deviceId, Protocol.handsetId, 0x0, 0x0 })
    else
      Protocol.receivedPackets = nil
      Protocol.lostPackets = nil
    end
    Protocol.linkstatTimeout = time + 100
  elseif time > Protocol.fieldTimeout and Protocol.fieldsCount ~= 0 then
    if #Protocol.loadQueue > 0 then
      Protocol.push(
        Protocol.CRSF.FRAMETYPE_PARAMETER_READ,
        { Protocol.deviceId, Protocol.handsetId, Protocol.loadQueue[#Protocol.loadQueue], Protocol.fieldChunk }
      )
      Protocol.fieldTimeout = time + Protocol.fieldResponseTimeout()
    else
      Protocol.backgroundLoading = false
    end
  end
end

return Protocol
