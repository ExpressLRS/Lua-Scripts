---------------------------------------------------------------------------
-- CRSF Parameter Session                                                --
--                                                                       --
-- A stateful CRSF parameter client: owns the field store, the load      --
-- queue and its retry scheduler, the write queue and its pacing, the    --
-- command state machine, and optionally device discovery, link status   --
-- and ELRS 1.x detection. Mechanism lives here; policy -- what to load, --
-- when to write, how to render -- stays with the caller, which reacts   --
-- through the store queries and the onFieldUpdate / onDeviceUpdate      --
-- callbacks.                                                            --
--                                                                       --
-- Multiple instances are real: the config tool and every VTX Admin      --
-- widget instance each own one. Methods live on the shared metatable,   --
-- so an instance costs one table plus its opts callbacks.               --
--                                                                       --
-- Frames arrive through drain(): every consumer pops its own script     --
-- instance's queue (the firmware replicates incoming frames per widget  --
-- instance on color radios) and _onFrame routes them internally.        --
--                                                                       --
-- Loaded via loadScript("/SCRIPTS/ELRS/crsf_session.lua")(crsf,params). --
-- Returns the CRSFSession class; construct with CRSFSession.new(opts).  --
---------------------------------------------------------------------------

local crsf, params = ...

-- Scheduler constants (ticks, 10 ms each)
local STATUS_PERIOD = 100 -- link-status cadence (1 s)
local PING_PERIOD = 100 -- discovery ping cadence while no device answered
local WRITE_SPACING = 5 -- minimum gap between parameter writes (50 ms)
local WRITE_SETTLE = 20 -- post-write quiet time before the next read
local CANCEL_GRACE = 200 -- wait for CMD_IDLE after a requested cancel (2 s)

local CRSFSession = {}
CRSFSession.__index = CRSFSession

--- Create a session.
-- @param opts  table with:
--   deviceId          target device address (default ADDRESS_TX)
--   handsetId         reply-to address (default ADDRESS_HANDSET_ELRS)
--   responseTimeout   fixed read-retry deadline in ticks; when omitted it is
--                     derived per device: 50 for the local ELRS TX, 500 for
--                     remote devices relayed over the air link
--   acceptUnsolicited true accepts any field from deviceId (passive fan-out:
--                     sibling instances see every response); default strict,
--                     accepting only the answer the session is waiting for
--   discovery         maintain .devices from DEVICE_INFO + ping cadence
--   trackStatus       keep .status current from ELRS_STATUS (1 Hz cadence)
--   detectV1          watch inbound PARAMETER_WRITE for the ELRS 1.x
--                     signature, latching .v1Detected
--   preload           once the root load completes, queue every unloaded
--                     subfolder child for background loading
--   onFieldUpdate     function(field) called after each decoded entry
--   onDeviceUpdate    function(device, isNew) called after each DEVICE_INFO
function CRSFSession.new(opts)
  opts = opts or {}
  return setmetatable({
    -- Public facts
    deviceId = opts.deviceId or crsf.CONST.ADDRESS_TX,
    handsetId = opts.handsetId or crsf.CONST.ADDRESS_HANDSET_ELRS,
    deviceName = nil,
    isElrsTx = nil,
    fieldsCount = 0,
    devices = {},
    command = nil, -- the command field driving the active popup
    -- Link status; table identity is stable, only keys change
    status = { flags = 0, warning = "" },
    -- Read-and-clear flags for the app
    fieldHiddenChanged = nil,
    v1Detected = nil,
    -- Reassembly state (crsf_params.lua manages it; rx.chunk is readable)
    rx = { chunk = 0, expect = -1 },

    -- Options
    _acceptUnsolicited = opts.acceptUnsolicited,
    _discovery = opts.discovery,
    _trackStatus = opts.trackStatus,
    _detectV1 = opts.detectV1,
    _preload = opts.preload,
    _respTimeout = opts.responseTimeout,
    _onFieldUpdate = opts.onFieldUpdate,
    _onDeviceUpdate = opts.onDeviceUpdate,

    -- Field store: id -> field table, get-or-create on first entry so a
    -- field's table identity is stable across reloads (UI closures hold it)
    _fields = {},

    -- Load queue (LIFO) and the five scheduler deadlines
    _loadQueue = {},
    _nextReadAt = 0,
    _nextQueryAt = 0,
    _nextStatusAt = 0,
    _nextPingAt = 0,
    _lastWriteAt = 0,

    -- Write queue: encoded frames between head and tail, paced by tick()
    _writeQueue = {},
    _writeHead = 1,
    _writeTail = 0,

    -- Bounded best-effort refresh slot (refreshField)
    _refreshId = nil,
    _refreshAt = 0,
    _refreshLeft = 0,
    _refreshAttempts = 0,

    _hadTelemetry = false,
    _preloadArmed = nil,
    _preloading = nil,
  }, CRSFSession)
end

-- Read-retry deadline for PARAMETER_READ: a fixed opts.responseTimeout wins,
-- otherwise 0.5 s for the local TX module, 5 s for remote devices relayed
-- over the air link.
function CRSFSession:_responseTimeout()
  if self._respTimeout then
    return self._respTimeout
  end
  return self.isElrsTx and 50 or 500
end

-- ============================================================================
-- Lifecycle
-- ============================================================================

--- Point the session at a device (a .devices entry) and reload its fields.
-- @return true when the device changed, false when nothing needed doing
function CRSFSession:setDevice(device)
  if not device then
    return false
  end
  if self.deviceId == device.id and self.fieldsCount == device.fieldCount then
    return false
  end

  self.deviceId = device.id
  self.deviceName = device.name
  self.fieldsCount = device.fieldCount
  self.isElrsTx = device.isElrs and device.id == crsf.CONST.ADDRESS_TX or nil
  self.handsetId = self.isElrsTx and crsf.CONST.ADDRESS_HANDSET_ELRS or crsf.CONST.ADDRESS_HANDSET
  local st = self.status
  st.flags = 0
  st.connected = nil
  st.modelMismatch = nil
  st.criticalError = nil

  self:reloadAll()
  return true
end

--- Drain the destructive pop queue into the session: the one receive path
-- for every consumer. The queue popped is the calling script instance's
-- own, so a session drains exactly the frames delivered to its owner.
function CRSFSession:drain()
  crsf.drain(self, self._onFrame)
end

--- Ask every reachable device to announce itself (broadcast DEVICE_PING).
-- Answers land in .devices through the discovery routing, so this is the
-- policy-facing "refresh the device list now" -- the scheduler's own
-- cadence only pings while the list is still empty. Meaningful only with
-- opts.discovery.
function CRSFSession:discoverDevices()
  crsf:pingDevices()
end

-- ============================================================================
-- Frame handlers
-- ============================================================================

function CRSFSession:_onFrame(command, data)
  if command == crsf.CONST.FRAMETYPE_PARAMETER_SETTINGS_ENTRY then
    self:_onEntry(data)
  elseif command == crsf.CONST.FRAMETYPE_DEVICE_INFO then
    if self._discovery then
      self:_onDeviceInfo(data)
    end
  elseif command == crsf.CONST.FRAMETYPE_ELRS_STATUS then
    if self._trackStatus then
      self:_onStatus(data)
    end
  elseif command == crsf.CONST.FRAMETYPE_PARAMETER_WRITE then
    if self._detectV1 then
      self:_onWrite(data)
    end
  end
end

function CRSFSession:_onDeviceInfo(data)
  local info = crsf:decodeDeviceInfo(data)
  if not info then
    return
  end
  local device = self:getDevice(info.id)
  local isNew = device == nil
  if isNew then
    device = { id = info.id }
    self.devices[#self.devices + 1] = device
  end
  device.name = info.name
  device.fieldCount = info.fieldCount
  device.isElrs = info.isElrs
  if self._onDeviceUpdate then
    self._onDeviceUpdate(device, isNew)
  end
end

function CRSFSession:_onStatus(data)
  local status = crsf:decodeElrsStatus(data)
  if not status then
    return
  end
  if status.id ~= self.deviceId then
    -- A foreign device's status while we buffer chunks means our entry
    -- stream was interrupted: abandon it
    params.resetChunks(self.rx)
    return
  end
  local st = self.status
  st.lostPackets = status.lostPackets
  st.receivedPackets = status.receivedPackets
  st.flags = status.flags
  st.connected = status.connected
  st.modelMismatch = status.modelMismatch
  st.criticalError = status.criticalError
  st.warning = status.warning
end

function CRSFSession:_onWrite(data)
  if crsf:isElrsV1Frame(data) then
    self.v1Detected = true
  end
end

function CRSFSession:_onEntry(data)
  local expectedId
  if self._acceptUnsolicited then
    expectedId = data[3]
  else
    expectedId = (self.command and self.command.id) or self._loadQueue[#self._loadQueue] or self._refreshId
  end
  local fieldId, buffer, offset = params.reassemble(self.rx, self.deviceId, data, expectedId)
  if not fieldId then
    return
  end
  local now = getTime()
  if not buffer then
    -- Chunk consumed: hurry the follow-up read, which carries the updated
    -- chunk index. A refresh slot answering mid-entry burns no attempt.
    if self._loadQueue[#self._loadQueue] == fieldId then
      self._nextReadAt = 0
    elseif self._refreshId == fieldId then
      self._refreshAt = now
      self._refreshLeft = self._refreshAttempts
    elseif self.command then
      self._nextQueryAt = now + (self.command.timeout or 100)
    end
    return
  end

  -- Entry complete: it settles the queue head only when it answers it -- a
  -- command status elicited while loads are pending must not pop an
  -- unrelated field
  local answeredHead = self._loadQueue[#self._loadQueue] == fieldId
  if answeredHead then
    self._loadQueue[#self._loadQueue] = nil
  end
  if self._refreshId == fieldId then
    self._refreshId = nil
  end

  local field = self._fields[fieldId]
  if not field then
    field = {}
    self._fields[fieldId] = field
  end

  -- Hidden-bit changes rebuild the UI's cached list of visible fields, so
  -- track it across the decode.
  local wasHidden = field.hidden
  -- Passing the old name makes the decoder skip its read and reuse that
  -- string. In strict mode any name change is flagged first
  -- (nameStale/reloading). A passive fan-out session also decodes entries
  -- it never asked for, so no flag can cover a change -- but only folder
  -- names embed values (ExpressLRS rewrites them on writes); every other
  -- name is static, and caching it keeps the fan-out path cheap enough for
  -- many sessions sharing one bus.
  local cachedName
  if not self._acceptUnsolicited then
    cachedName = (not field.nameStale and not field.reloading) and field.name or nil
  elseif field.type ~= crsf.CONST.FIELD_FOLDER then
    cachedName = field.name
  end
  if params.decodeEntry(field, fieldId, buffer, offset, cachedName) then
    field.nameStale = nil
    field.reloading = nil
    if field.hidden ~= wasHidden then
      self.fieldHiddenChanged = true
    end

    if field.type == crsf.CONST.FIELD_COMMAND and field.status == crsf.CONST.CMD_IDLE and self.command == field then
      -- The active command just finished (or was cancelled): re-read its
      -- same-level fields so the current page reflects any values the
      -- command changed, and dismiss the popup. The guard limits both to
      -- the active command -- routine loads of idle command fields while
      -- browsing must not trigger either.
      self:_reloadRelated(field)
      self.command = nil
    end

    -- Auto-queue children for the root folder and during preloading -- but
    -- only off the answer to our own read: under the fan-out, sessions also
    -- see every sibling's root answers, and re-queueing the children each
    -- time would multiply the load traffic by the instance count
    if
      answeredHead
      and field.type == crsf.CONST.FIELD_FOLDER
      and field.children
      and (fieldId == 0 or self._preloading)
    then
      for i = #field.children, 1, -1 do
        self._loadQueue[#self._loadQueue + 1] = field.children[i]
      end
    end

    if self._onFieldUpdate then
      self._onFieldUpdate(field)
    end
  end

  if self._loadQueue[1] then
    self._nextReadAt = 0
  else
    if self.command then
      self._nextQueryAt = now + (self.command.timeout or 100)
    end
    if self._preloadArmed and self:isFolderLoaded(nil) then
      self._preloadArmed = nil
      self:preloadAll()
    end
  end
end

-- ============================================================================
-- Store queries
-- ============================================================================

--- The device table for an address, or nil (opts.discovery fills .devices).
function CRSFSession:getDevice(id)
  for _, device in ipairs(self.devices) do
    if device.id == id then
      return device
    end
  end
end

--- Loaded children of a folder, in wire order. folderId nil means root.
function CRSFSession:fieldsInFolder(folderId)
  local folder = self._fields[folderId or 0]
  if not folder or not folder.children then
    return {}
  end
  local result = {}
  for _, childId in ipairs(folder.children) do
    local child = self._fields[childId]
    if child and child.name then
      result[#result + 1] = child
    end
  end
  return result
end

--- True when every child of a folder is loaded. folderId nil means root.
function CRSFSession:isFolderLoaded(folderId)
  local folder = self._fields[folderId or 0]
  if not folder or not folder.children then
    return false
  end
  for _, childId in ipairs(folder.children) do
    local child = self._fields[childId]
    if not child or not child.name or child.nameStale then
      return false
    end
  end
  return true
end

--- Load progress for a folder's children as (loaded, total), or nil while
-- the folder or its children list is unknown. folderId nil means root.
function CRSFSession:folderLoadProgress(folderId)
  local folder = self._fields[folderId or 0]
  if not folder or not folder.children then
    return nil
  end
  local total = #folder.children
  local loaded = 0
  for _, childId in ipairs(folder.children) do
    local child = self._fields[childId]
    if child and child.name and not child.reloading then
      loaded = loaded + 1
    end
  end
  return loaded, total
end

--- True while reads are queued.
function CRSFSession:isLoading()
  return self._loadQueue[1] ~= nil
end

--- True while a multi-chunk entry is mid-reassembly.
function CRSFSession:isReceivingChunks()
  return self.rx.chunk > 0
end

--- True while writes are waiting in the paced write queue.
function CRSFSession:isWriting()
  return self._writeHead <= self._writeTail
end

-- ============================================================================
-- Loading
-- ============================================================================

--- Forget every field and reload from the root folder. Its response carries
-- the child ids, which auto-queue; subfolder children load on demand via
-- loadFolder() or in the background via opts.preload.
function CRSFSession:reloadAll()
  self._fields = {}
  self._loadQueue = { 0 }
  self._nextReadAt = 0
  self._preloadArmed = self._preload
  self._preloading = nil
  params.resetChunks(self.rx)
end

--- Re-read one field now.
function CRSFSession:reloadField(field)
  self._nextReadAt = 0
  params.resetChunks(self.rx)
  self._loadQueue[#self._loadQueue + 1] = field.id
end

--- Queue a folder's unloaded children.
function CRSFSession:loadFolder(folderId)
  local folder = self._fields[folderId]
  if not folder or not folder.children then
    return
  end
  for i = #folder.children, 1, -1 do
    local childId = folder.children[i]
    local child = self._fields[childId]
    if not (child and child.name) then
      self._loadQueue[#self._loadQueue + 1] = childId
    end
  end
  if self._loadQueue[1] then
    self._nextReadAt = 0
  end
end

--- Queue every unloaded subfolder child for background loading.
function CRSFSession:preloadAll()
  self._preloading = true
  for id = 1, self.fieldsCount do
    local field = self._fields[id]
    if field and field.type == crsf.CONST.FIELD_FOLDER and field.children then
      for j = #field.children, 1, -1 do
        local childId = field.children[j]
        local child = self._fields[childId]
        if not (child and child.name) then
          self._loadQueue[#self._loadQueue + 1] = childId
        end
      end
    end
  end
  if self._loadQueue[1] then
    self._nextReadAt = 0
  end
end

--- Arm the bounded best-effort refresh slot: read fieldId `delay` ticks from
-- now, retrying at most `attempts` times if unanswered. Event-driven, never
-- periodic -- use it when something else can have changed the device (our
-- own writes, resume from suspension), not as a poll.
function CRSFSession:refreshField(fieldId, delay, attempts)
  self._refreshId = fieldId
  self._refreshAt = getTime() + (delay or 0)
  self._refreshAttempts = attempts or 3
  self._refreshLeft = self._refreshAttempts
  -- A fresh read must not inherit chunk state from an interrupted one
  params.resetChunks(self.rx)
end

-- ============================================================================
-- Writing
-- ============================================================================

-- Re-read what a value change can have altered: the parent folder (its name
-- may embed values) and every non-folder sibling (CRSF parameters on one
-- level are routinely interdependent -- option lists shrink, fields hide).
function CRSFSession:_reloadRelated(field)
  if field.parent and self._fields[field.parent] then
    self._fields[field.parent].nameStale = true
    self._loadQueue[#self._loadQueue + 1] = field.parent
  end

  for fieldId = self.fieldsCount, 1, -1 do
    local sibling = self._fields[fieldId]
    if sibling and fieldId ~= field.id and sibling.parent == field.parent then
      local siblingType = sibling.type or 99
      if siblingType < crsf.CONST.FIELD_FOLDER or siblingType == crsf.CONST.FIELD_INFO then
        sibling.dirty = true
        sibling.reloading = true
        self._loadQueue[#self._loadQueue + 1] = fieldId
      end
    end
  end

  field.dirty = true
  field.reloading = true
  self._loadQueue[#self._loadQueue + 1] = field.id
  self:_afterWrite()
end

-- Post-write settle: give the device WRITE_SETTLE to apply the change
-- before the re-reads go out, and keep the next link-status request from
-- landing inside that window.
function CRSFSession:_afterWrite()
  local now = getTime()
  self._nextReadAt = now + WRITE_SETTLE
  local statusAt = now + WRITE_SETTLE + STATUS_PERIOD
  if self._nextStatusAt < statusAt then
    self._nextStatusAt = statusAt
  end
end

--- Write a field's current value to the device: encodes by field type,
-- sends immediately when the wire is idle (every push replaces one
-- RC-channels frame, so bursts are paced by tick()). In strict mode the
-- write also re-reads its related fields; a passive fan-out session owns
-- its read-back policy (refreshField).
function CRSFSession:writeField(field)
  local frameType, payload
  if field.type == crsf.CONST.FIELD_STRING then
    frameType, payload = params.encodeWriteString(self.deviceId, self.handsetId, field)
  else
    frameType, payload = params.encodeWriteInt(self.deviceId, self.handsetId, field)
  end

  local now = getTime()
  if self._writeHead > self._writeTail and now - self._lastWriteAt >= WRITE_SPACING then
    crsf.push(frameType, payload)
    self._lastWriteAt = now
  else
    self._writeTail = self._writeTail + 1
    self._writeQueue[self._writeTail] = { frameType, payload }
  end

  if not self._acceptUnsolicited then
    self:_reloadRelated(field)
  end
end

-- ============================================================================
-- Commands
-- ============================================================================

--- Click a command field. When the device accepts, session.command holds the
-- field until it reports CMD_IDLE (or the command is cancelled); the UI
-- renders its popup from session.command.status/info.
function CRSFSession:execCommand(field)
  self:reloadField(field)
  if field.status ~= nil and field.status < crsf.CONST.CMD_CONFIRMED then
    field.status = crsf.CONST.CMD_CLICK
    crsf.push(params.encodeCommandStep(self.deviceId, self.handsetId, field.id, crsf.CONST.CMD_CLICK))
    self.command = field
    self._nextQueryAt = getTime() + (field.timeout or 100)
  end
end

--- Answer the device's CMD_ASKCONFIRM.
function CRSFSession:confirmCommand()
  if self.command then
    crsf.push(params.encodeCommandStep(self.deviceId, self.handsetId, self.command.id, crsf.CONST.CMD_CONFIRMED))
    self._nextQueryAt = getTime() + (self.command.timeout or 100)
    self.command.status = crsf.CONST.CMD_CONFIRMED
  end
end

--- Cancel and dismiss: sends CMD_CANCEL and drops the popup immediately.
function CRSFSession:cancelCommand()
  if self.command then
    crsf.push(params.encodeCommandStep(self.deviceId, self.handsetId, self.command.id, crsf.CONST.CMD_CANCEL))
    self.command = nil
  end
end

--- Cancel but keep the popup: sends CMD_CANCEL and waits CANCEL_GRACE for
-- the device to report CMD_IDLE, which dismisses the popup through the
-- entry decode. Used while no dialog is on screen yet (e.g. right after
-- CMD_CLICK), so the UI keeps tracking the device's actual command state.
function CRSFSession:requestCancelCommand()
  if self.command then
    crsf.push(params.encodeCommandStep(self.deviceId, self.handsetId, self.command.id, crsf.CONST.CMD_CANCEL))
    self._nextQueryAt = getTime() + CANCEL_GRACE
  end
end

-- ============================================================================
-- Status
-- ============================================================================

--- Clear the ELRS critical-error banner: optimistic local clear plus the
-- suppress write the module acts on.
function CRSFSession:suppressCriticalErrors()
  self.status.flags = 0
  crsf.push(params.encodeSuppressCriticalErrors(self.deviceId, self.handsetId))
end

-- ============================================================================
-- Scheduler
-- ============================================================================

--- Send what is due. At most one parameter frame per call, strict priority:
-- command keep-alive > write drain > link-status > reads (refresh slot,
-- then load-queue head). While a command runs it owns the wire -- reads
-- starve by design, and the field data rides its CMD_QUERY answers.
-- Discovery pings sit outside that chain: they cost no parameter traffic.
function CRSFSession:tick()
  local now = getTime()

  if self._discovery then
    -- Ping on telemetry transition (the answering device may have changed)
    local connected = self.status.connected
    if connected and not self._hadTelemetry then
      crsf:pingDevices()
    end
    self._hadTelemetry = connected
    -- Periodic ping for initial device discovery
    if #self.devices == 0 and now > self._nextPingAt then
      crsf:pingDevices()
      self._nextPingAt = now + PING_PERIOD
    end
  end

  if self.command then
    if now > self._nextQueryAt and self.command.status ~= crsf.CONST.CMD_ASKCONFIRM then
      crsf.push(params.encodeCommandStep(self.deviceId, self.handsetId, self.command.id, crsf.CONST.CMD_QUERY))
      self._nextQueryAt = now + (self.command.timeout or 100)
    end
    return
  end

  if self._writeHead <= self._writeTail then
    if now - self._lastWriteAt >= WRITE_SPACING then
      local write = self._writeQueue[self._writeHead]
      self._writeQueue[self._writeHead] = nil
      self._writeHead = self._writeHead + 1
      if self._writeHead > self._writeTail then
        self._writeHead = 1
        self._writeTail = 0
      end
      crsf.push(write[1], write[2])
      self._lastWriteAt = now
    end
    return
  end

  if self._trackStatus and now > self._nextStatusAt then
    if self.isElrsTx then
      -- isElrsTx guarantees deviceId/handsetId are ADDRESS_TX and
      -- ADDRESS_HANDSET_ELRS here (see setDevice), the addressing
      -- requestElrsStatus() hardcodes.
      crsf:requestElrsStatus()
    else
      self.status.receivedPackets = nil
      self.status.lostPackets = nil
    end
    self._nextStatusAt = now + STATUS_PERIOD
    return
  end

  if self._refreshId then
    if now >= self._refreshAt then
      if self._refreshLeft > 0 then
        self._refreshLeft = self._refreshLeft - 1
        self._refreshAt = now + self:_responseTimeout()
        crsf.push(params.encodeRead(self.rx, self.deviceId, self.handsetId, self._refreshId))
      else
        self._refreshId = nil
      end
    end
    return
  end

  if now > self._nextReadAt then
    if self._loadQueue[1] then
      crsf.push(params.encodeRead(self.rx, self.deviceId, self.handsetId, self._loadQueue[#self._loadQueue]))
      self._nextReadAt = now + self:_responseTimeout()
    else
      self._preloading = nil
    end
  end
end

-- ============================================================================
-- Return class
-- ============================================================================

return CRSFSession
