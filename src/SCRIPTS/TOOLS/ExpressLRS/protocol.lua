---- #########################################################################
---- # Protocol Module: CRSF constants, parsing, and field operations     #
---- # Shared between BW and LVGL UI implementations                      #
---- #########################################################################

local crsf, fields = ...

local Protocol = {
  -- Tool-internal pseudo field types for the synthetic device rows in the
  -- "Other Devices" list. Values sit above the wire range: the type byte is
  -- masked with 0x7f at parse, so a real field type can never exceed 127 --
  -- unlike 15/16, which the previous numbering used and which shadow
  -- CRSF_VTX (0x0F) on the wire.
  DEVICE = 128,
  DEVICE_FOLDER = 129,

  -- Device identity (used in every CRSF frame)
  deviceId = crsf.CONST.ADDRESS_TX,
  handsetId = crsf.CONST.ADDRESS_HANDSET_ELRS,
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
  connected = nil,
  modelMismatch = nil,
  criticalError = nil,

  -- Protocol timing
  linkstatTimeout = 100,
  pingTimeout = 0,

  -- Communication state. rx is the crsf_params.lua reassembly state -- the
  -- codec manages it; rx.chunk stays readable (the BW UI's popup spinner
  -- ticks on it).
  fieldTimeout = 0,
  rx = { chunk = 0, expect = -1 },
  loadQueue = {},
  backgroundLoading = false,

  -- Telemetry transition tracking (for auto-discovery on reconnect)
  hadTelemetry = false,
}

-- Response timeout for PARAMETER_READ:
-- 0.5s for local TX module, 5s for remote devices relayed over air link.
function Protocol.fieldResponseTimeout()
  return Protocol.deviceIsELRS_TX and 50 or 500
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
  Protocol.connected = nil
  Protocol.modelMismatch = nil
  Protocol.criticalError = nil
  Protocol.deviceName = device.name
  Protocol.fieldsCount = device.fieldCount
  Protocol.deviceIsELRS_TX = device.isElrs and device.id == crsf.CONST.ADDRESS_TX or nil
  Protocol.handsetId = Protocol.deviceIsELRS_TX and crsf.CONST.ADDRESS_HANDSET_ELRS or crsf.CONST.ADDRESS_HANDSET

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
  fields.resetChunks(Protocol.rx)
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
  fields.resetChunks(Protocol.rx)
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
    if field.type == crsf.CONST.FIELD_FOLDER and field.children then
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
      and (siblingType < crsf.CONST.FIELD_FOLDER or siblingType == crsf.CONST.FIELD_INFO)
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
    if field.status < crsf.CONST.CMD_CONFIRMED then
      field.status = crsf.CONST.CMD_CLICK
      crsf.push(fields.encodeCommandStep(Protocol.deviceId, Protocol.handsetId, field.id, crsf.CONST.CMD_CLICK))
      Protocol.fieldPopup = field
      Protocol.fieldPopup.lastStatus = crsf.CONST.CMD_IDLE
      Protocol.fieldTimeout = getTime() + field.timeout
    end
  end
end

function Protocol.commandConfirm()
  if Protocol.fieldPopup then
    crsf.push(
      fields.encodeCommandStep(Protocol.deviceId, Protocol.handsetId, Protocol.fieldPopup.id, crsf.CONST.CMD_CONFIRMED)
    )
    Protocol.fieldTimeout = getTime() + Protocol.fieldPopup.timeout
    Protocol.fieldPopup.status = crsf.CONST.CMD_CONFIRMED
  end
end

-- Cancel and dismiss: sends CMD_CANCEL and drops the popup immediately.
function Protocol.commandCancel()
  if Protocol.fieldPopup then
    crsf.push(
      fields.encodeCommandStep(Protocol.deviceId, Protocol.handsetId, Protocol.fieldPopup.id, crsf.CONST.CMD_CANCEL)
    )
    Protocol.fieldPopup = nil
  end
end

-- Cancel but keep the popup: sends CMD_CANCEL and waits for the device to
-- report CMD_IDLE, which dismisses the popup through the entry decode. Used
-- while no dialog is on screen yet (e.g. right after CMD_CLICK), so the UI
-- keeps tracking the device's actual command state.
function Protocol.commandRequestCancel()
  if Protocol.fieldPopup then
    crsf.push(
      fields.encodeCommandStep(Protocol.deviceId, Protocol.handsetId, Protocol.fieldPopup.id, crsf.CONST.CMD_CANCEL)
    )
    Protocol.fieldTimeout = getTime() + 200
  end
end

-- Clear the ELRS critical-error banner: optimistic local clear plus the
-- suppress write the module acts on.
function Protocol.suppressCriticalErrors()
  Protocol.elrsFlags = 0
  crsf.push(fields.encodeSuppressCriticalErrors(Protocol.deviceId, Protocol.handsetId))
end

-- ============================================================================
-- CRSF message parsing
-- ============================================================================

function Protocol.parseDeviceInfoMessage(data)
  local info = crsf:decodeDeviceInfo(data)
  if not info then
    return nil
  end
  local device = Protocol.getDevice(info.id)
  local isNew = (device == nil)
  if isNew then
    device = { id = info.id }
    Protocol.devices[#Protocol.devices + 1] = device
  end
  device.name = info.name
  device.fieldCount = info.fieldCount
  device.isElrs = info.isElrs
  return device, isNew
end

-- Handle a parameter settings entry (0x2B) frame. Field data can span several
-- frames; the library reassembles the chunks before this decodes one field.
function Protocol.parseParameterInfoMessage(data)
  local expectedId = (Protocol.fieldPopup and Protocol.fieldPopup.id) or Protocol.loadQueue[#Protocol.loadQueue]
  local fieldId, buffer, offset = fields.reassemble(Protocol.rx, Protocol.deviceId, data, expectedId)
  if not fieldId then
    return
  end
  local field = Protocol.fields[fieldId]
  if not field then
    return
  end
  if not buffer then
    -- Chunk consumed; the next read goes out with the updated chunk index
    return
  end

  -- Field data stream is now complete, process into a field
  Protocol.loadQueue[#Protocol.loadQueue] = nil

  -- Hidden-bit changes rebuild the UI's cached list of visible fields, so
  -- track it across the decode.
  local wasHidden = field.hidden
  -- Passing the old name makes the decoder skip its read and reuse that string,
  -- which is only safe while no reload has flagged the name as possibly changed
  local cachedName = (not field.nameStale and not field.reloading) and field.name or nil
  if fields.decodeEntry(field, fieldId, buffer, offset, cachedName) then
    field.nameStale = nil
    field.reloading = nil
    if field.hidden ~= wasHidden then
      Protocol.fieldHiddenChanged = true
    end

    if field.type == crsf.CONST.FIELD_COMMAND and field.status == crsf.CONST.CMD_IDLE then
      -- A command that was actively running just finished (or was cancelled):
      -- re-read its same-level fields so the current page reflects any values
      -- the command changed. The guard limits this to the active command --
      -- routine loads of idle command fields while browsing (fieldPopup is
      -- nil) must not trigger a reload.
      if Protocol.fieldPopup == field then
        Protocol.reloadRelatedFields(field)
      end
      Protocol.fieldPopup = nil
    end

    -- Auto-queue children for root folder (field 0) and during background preloading.
    if field.type == crsf.CONST.FIELD_FOLDER and field.children and (fieldId == 0 or Protocol.backgroundLoading) then
      for i = #field.children, 1, -1 do
        Protocol.loadQueue[#Protocol.loadQueue + 1] = field.children[i]
      end
    end
  end
end

function Protocol.parseElrsInfoMessage(data)
  local status = crsf:decodeElrsStatus(data)
  if not status then
    return
  end
  if status.id ~= Protocol.deviceId then
    fields.resetChunks(Protocol.rx)
    return
  end

  Protocol.lostPackets = status.lostPackets
  Protocol.receivedPackets = status.receivedPackets
  Protocol.elrsFlags = status.flags
  Protocol.connected = status.connected
  Protocol.modelMismatch = status.modelMismatch
  Protocol.criticalError = status.criticalError
  Protocol.elrsFlagsInfo = status.warning
end

-- ============================================================================
-- Main CRSF communication loop
-- ============================================================================

function Protocol.poll()
  local command, data
  local targetDevice = nil
  local anyNewDevice = false

  repeat
    command, data = crsf.pop()
    if command == crsf.CONST.FRAMETYPE_DEVICE_INFO then
      local device, isNew = Protocol.parseDeviceInfoMessage(data)
      if device then
        if device.id == Protocol.deviceId then
          targetDevice = device
        end
        if isNew then
          anyNewDevice = true
        end
      end
    elseif command == crsf.CONST.FRAMETYPE_PARAMETER_SETTINGS_ENTRY then
      Protocol.parseParameterInfoMessage(data)
      if #Protocol.loadQueue > 0 then
        Protocol.fieldTimeout = 0
      elseif Protocol.fieldPopup then
        Protocol.fieldTimeout = getTime() + Protocol.fieldPopup.timeout
      end
    elseif command == crsf.CONST.FRAMETYPE_PARAMETER_WRITE then
      if crsf:isElrsV1Frame(data) then
        Protocol.elrsV1Detected = true
      end
    elseif command == crsf.CONST.FRAMETYPE_ELRS_STATUS then
      Protocol.parseElrsInfoMessage(data)
    end
  until command == nil

  return targetDevice, anyNewDevice
end

function Protocol.tick()
  -- Ping on telemetry transition (device may have changed)
  local connected = Protocol.connected
  if connected and not Protocol.hadTelemetry then
    crsf:pingDevices()
  end
  Protocol.hadTelemetry = connected

  local time = getTime()
  -- Periodic ping for initial device discovery
  if #Protocol.devices == 0 and time > Protocol.pingTimeout then
    crsf:pingDevices()
    Protocol.pingTimeout = time + 100 -- 1s
  end

  if Protocol.fieldPopup then
    if time > Protocol.fieldTimeout and Protocol.fieldPopup.status ~= crsf.CONST.CMD_ASKCONFIRM then
      crsf.push(
        fields.encodeCommandStep(Protocol.deviceId, Protocol.handsetId, Protocol.fieldPopup.id, crsf.CONST.CMD_QUERY)
      )
      Protocol.fieldTimeout = time + Protocol.fieldPopup.timeout
    end
  elseif time > Protocol.linkstatTimeout then
    if Protocol.deviceIsELRS_TX then
      -- deviceIsELRS_TX guarantees deviceId/handsetId are ADDRESS_TX and
      -- ADDRESS_HANDSET_ELRS here (see setDevice), the addressing
      -- requestElrsStatus() hardcodes.
      crsf:requestElrsStatus()
    else
      Protocol.receivedPackets = nil
      Protocol.lostPackets = nil
    end
    Protocol.linkstatTimeout = time + 100
  elseif time > Protocol.fieldTimeout and Protocol.fieldsCount ~= 0 then
    if #Protocol.loadQueue > 0 then
      crsf.push(
        fields.encodeRead(Protocol.rx, Protocol.deviceId, Protocol.handsetId, Protocol.loadQueue[#Protocol.loadQueue])
      )
      Protocol.fieldTimeout = time + Protocol.fieldResponseTimeout()
    else
      Protocol.backgroundLoading = false
    end
  end
end

return Protocol
