---------------------------------------------------------------------------
-- CRSF Parameter-Field Codec                                            --
--                                                                       --
-- Stateless codecs for CRSF parameter fields: byte getters and the      --
-- per-type PARAMETER_SETTINGS_ENTRY (0x2B) payload decoders. Opt-in:    --
-- only consumers that read or write parameter fields load it, so        --
-- telemetry-only widgets never pay for it. Policy -- load queues,       --
-- command popups, reload decisions -- stays with the caller.            --
--                                                                       --
-- Purity rule: nothing in this file mutates a frame data table.         --
-- crsf:poll() hands the same table to every registered handler, so an   --
-- in-place decode here would corrupt the frame for sibling handlers     --
-- (the hazard crsf.lua's fieldGetString documents).                     --
--                                                                       --
-- Loaded via loadScript("/SCRIPTS/ELRS/crsf_fields.lua")(crsf).         --
-- Returns the codec table directly.                                     --
---------------------------------------------------------------------------

local crsf = ...

local shim = loadScript("/SCRIPTS/ELRS/shim.lua")()

local Fields = {}

-- ============================================================================
-- Byte getters
-- ============================================================================

--- Read a big-endian unsigned integer from a byte array.
-- @param data    array of byte values
-- @param offset  1-based start offset
-- @param size    width in bytes
-- @return number
function Fields.readValue(data, offset, size)
  local result = 0
  for i = 0, size - 1 do
    result = bit32.lshift(result, 8) + data[offset + i]
  end
  return result
end

--- Read a null-terminated string, or a semicolon-separated option list, from
-- a byte array without mutating it. Translates the legacy ELRS arrow bytes
-- (0xC0/0xC1) to the EdgeTX CHAR_UP/CHAR_DOWN glyphs.
-- @param data    array of byte values
-- @param offset  1-based start offset
-- @param last    cached previous result: when given, decoding is skipped and
--                it is returned as-is (the offset still advances past the
--                terminator). Only safe while no reload has flagged the
--                content as possibly changed.
-- @param isOpts  truthy to split on ';' and return a table of options
-- @return string|table result, number nextOffset, number optCount (count of
--         non-empty options; 0 when cached or not isOpts)
function Fields.readStringOrOpts(data, offset, last, isOpts)
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

-- ============================================================================
-- Per-type field loaders
-- ============================================================================

local function fieldUnsignedLoad(field, data, offset, size, unitoffset)
  field.value = Fields.readValue(data, offset, size)
  field.min = Fields.readValue(data, offset + size, size)
  field.max = Fields.readValue(data, offset + 2 * size, size)
  local unit = Fields.readStringOrOpts(data, offset + (unitoffset or (4 * size)), field.unit)
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

local function fieldIntLoad(field, data, offset)
  local loadFn = (field.type % 2 == 0) and fieldUnsignedLoad or fieldSignedLoad
  return loadFn(field, data, offset, math.floor(field.type / 2) + 1)
end

local function fieldFloatLoad(field, data, offset)
  fieldSignedLoad(field, data, offset, 4, 21)
  field.prec = data[offset + 16]
  if field.prec > 3 then
    field.prec = 3
  end
  field.step = Fields.readValue(data, offset + 17, 4)
  field.fmt = shim.tableConcat({ "%.", tostring(field.prec), "f" })
  field.prec = 10 ^ field.prec
end

local function fieldTextSelLoad(field, data, offset)
  local vcnt
  local oldValues = field.values
  local cached = field.dirty == nil and oldValues
  field.values, offset, vcnt = Fields.readStringOrOpts(data, offset, cached, true)
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
  local unit = Fields.readStringOrOpts(data, offset + 4)
  field.unit = (unit ~= "") and unit or nil
  field.dirty = nil
end

local function fieldStringLoad(field, data, offset)
  field.value, offset = Fields.readStringOrOpts(data, offset)
  if #data >= offset then
    field.maxlen = data[offset]
  end
end

local function fieldCommandLoad(field, data, offset)
  field.status = data[offset]
  field.timeout = data[offset + 1]
  local info = Fields.readStringOrOpts(data, offset + 2)
  field.info = (info ~= "") and info or nil
end

local function fieldFolderLoad(field, data, offset)
  field.children = {}
  while data[offset] and data[offset] ~= crsf.CONST.FIELD_LIST_END do
    field.children[#field.children + 1] = data[offset]
    offset = offset + 1
  end
end

-- Per-type load dispatch, keyed by wire type id + 1.
-- UINT32..INT64 are unsupported (nil slots), as in the ELRS firmware.
local handlers = {
  [crsf.CONST.FIELD_UINT8 + 1] = fieldIntLoad,
  [crsf.CONST.FIELD_INT8 + 1] = fieldIntLoad,
  [crsf.CONST.FIELD_UINT16 + 1] = fieldIntLoad,
  [crsf.CONST.FIELD_INT16 + 1] = fieldIntLoad,
  [crsf.CONST.FIELD_FLOAT + 1] = fieldFloatLoad,
  [crsf.CONST.FIELD_TEXT_SELECTION + 1] = fieldTextSelLoad,
  [crsf.CONST.FIELD_STRING + 1] = fieldStringLoad,
  [crsf.CONST.FIELD_FOLDER + 1] = fieldFolderLoad,
  [crsf.CONST.FIELD_INFO + 1] = fieldStringLoad,
  [crsf.CONST.FIELD_COMMAND + 1] = fieldCommandLoad,
}

-- ============================================================================
-- Chunk reassembly
--
-- PARAMETER_SETTINGS_ENTRY payloads larger than the handset link's frame
-- limit arrive in chunks (CRSFEndpoint::sendParameter). Reassembly state
-- lives in a caller-owned session table; the library manages these keys:
--   fieldChunk         next chunk index to request (readable; do not write)
--   fieldData          reassembly buffer for the in-flight entry
--   fieldDataId        the field id the buffer belongs to
--   expectChunksRemain duplicate-frame guard
--   fieldDone          field whose multi-chunk entry just completed, to
--                      swallow the other consumers' trailing final chunks
-- Consumers initialize fieldChunk = 0 and expectChunksRemain = -1 alongside
-- their deviceId/handsetId addressing bytes.
-- ============================================================================

--- Abandon any in-flight reassembly.
-- @param session  the session table
function Fields.resetChunks(session)
  session.fieldChunk = 0
  session.fieldData = nil
  session.fieldDataId = nil
  session.fieldDone = nil
end

--- Feed one PARAMETER_SETTINGS_ENTRY frame into the session.
-- expectedFieldId selects the consumption model: a caller waiting on one
-- specific field passes its id (nil while idle drops everything), a caller
-- listening passively under the poll() fan-out passes data[3] to accept any
-- field from session.deviceId -- the fieldDataId gate then keeps a
-- sibling-elicited entry for another field out of an in-flight buffer.
-- Never mutates data, and never retains it: the single-frame fast path
-- returns data itself as the buffer, valid only for the current call.
-- @param session          the session table
-- @param data             the frame's byte array
-- @param expectedFieldId  the field id to accept
-- @return fieldId, buffer, offset  entry complete; buffer[offset] is the
--         parent byte, ready for decodeEntry
-- @return fieldId                  chunk consumed, more expected -- send the
--         next read, which carries the updated session.fieldChunk
-- @return nil                      frame dropped (wrong device or field,
--         cross-field continuation, duplicate chunk)
function Fields.reassemble(session, data, expectedFieldId)
  -- Another device answered, or this is not the awaited field: drop any
  -- partial data
  if data[2] ~= session.deviceId or data[3] ~= expectedFieldId then
    Fields.resetChunks(session)
    return nil
  end
  -- An in-flight buffer only accepts continuation frames for its own field
  if session.fieldData and session.fieldDataId ~= data[3] then
    return nil
  end
  local chunksRemain = data[4]
  -- Trailing duplicates of a multi-chunk entry: when several consumers each
  -- request the same field, every session sees every answer, and the extra
  -- copies of the final chunk arrive back to back after this session already
  -- completed the entry. Their header is indistinguishable from a fresh
  -- single-frame entry, so they would decode as garbage. Swallow them until
  -- a new request cycle starts -- traffic for another field, or our own
  -- sendRead, both of which clear fieldDone.
  if session.fieldDone then
    if session.fieldDone == data[3] then
      if chunksRemain == 0 and not session.fieldData then
        return nil
      end
    else
      session.fieldDone = nil
    end
  end
  -- chunksRemain changed while data is buffered: duplicate frame, drop it
  if session.fieldData and chunksRemain ~= session.expectChunksRemain then
    return nil
  end

  local buffer
  local offset
  -- If data is chunked, copy it to the persistent buffer
  if chunksRemain > 0 or session.fieldChunk > 0 then
    session.fieldData = session.fieldData or {}
    session.fieldDataId = data[3]
    buffer = session.fieldData
    for i = 5, #data do
      buffer[#buffer + 1] = data[i]
    end
    offset = 1
  else
    -- All data arrived in one chunk, hand the frame back directly
    buffer = data
    offset = 5
  end

  if chunksRemain > 0 then
    session.fieldChunk = session.fieldChunk + 1
    session.expectChunksRemain = chunksRemain - 1
    return data[3]
  end

  local wasChunked = session.fieldChunk > 0
  Fields.resetChunks(session)
  if wasChunked then
    session.fieldDone = data[3]
  end
  return data[3], buffer, offset
end

-- ============================================================================
-- Entry decode
-- ============================================================================

--- Decode a complete PARAMETER_SETTINGS_ENTRY payload into the caller-owned
-- field table. Sets field.id, parent (0 -> nil), type (0x7F-masked), hidden
-- (0x80 bit, true/nil), name, and dispatches the per-type loader, which fills
-- value/min/max/unit (ints, floats), prec/step/fmt (floats), values/disabled
-- (text selections), maxlen (strings), status/timeout/info (commands) or
-- children (folders). min/max of 0 are normalized to nil.
-- @param field       the caller-owned field table to decode into
-- @param fieldId     the field id the payload belongs to
-- @param buffer      byte array holding the payload
-- @param offset      1-based offset of the parent byte within buffer
-- @param cachedName  pass the previous name to skip its decode (see
--                    readStringOrOpts); nil decodes it fresh
-- @return field, or nil when the entry is shorter than parent + type + one
--         name byte (the caller should still drop it from its queue)
function Fields.decodeEntry(field, fieldId, buffer, offset, cachedName)
  -- Need at least parent + type + one name byte for the entry to be usable
  if #buffer <= offset + 2 then
    return nil
  end
  field.id = fieldId
  field.parent = (buffer[offset] ~= 0) and buffer[offset] or nil
  field.type = bit32.band(buffer[offset + 1], 0x7f)
  field.hidden = bit32.btest(buffer[offset + 1], 0x80) or nil
  field.name, offset = Fields.readStringOrOpts(buffer, offset + 2, cachedName)
  local load = handlers[field.type + 1]
  if load then
    load(field, buffer, offset)
  end
  if field.min == 0 then
    field.min = nil
  end
  if field.max == 0 then
    field.max = nil
  end
  return field
end

-- ============================================================================
-- Frame senders
--
-- Every sender takes a caller-owned session table and reads its addressing
-- bytes: session.deviceId (the target device) and session.handsetId (the
-- reply-to address). Wire layouts match the tables in CRSFParameters.h.
-- ============================================================================

--- Request one chunk of a field's PARAMETER_SETTINGS_ENTRY. The chunk index
-- rides in session.fieldChunk, so follow-up reads of a chunked entry continue
-- where reassemble() left off (0 requests a fresh entry).
-- @param session  table with deviceId/handsetId and fieldChunk
-- @param fieldId  the field id to read
function Fields.sendRead(session, fieldId)
  session.fieldDone = nil
  crsf.push(crsf.CONST.FRAMETYPE_PARAMETER_READ, { session.deviceId, session.handsetId, fieldId, session.fieldChunk })
end

--- Send a PARAMETER_WRITE carrying a field's integer value, big-endian at the
-- field's width. field.size < 0 marks a signed field |size| bytes wide
-- (decodeEntry's convention); negative values are re-encoded as two's
-- complement. A missing size means 1 byte.
-- @param session  table with deviceId/handsetId
-- @param field    table with id, value and optional size
function Fields.sendWriteInt(session, field)
  local value = field.value
  local size = field.size or 1
  if size < 0 then
    size = -size
    if value < 0 then
      value = bit32.lshift(0x100, (size - 1) * 8) + value
    end
  end

  local frame = { session.deviceId, session.handsetId, field.id }
  for i = size - 1, 0, -1 do
    frame[#frame + 1] = bit32.rshift(value, 8 * i) % 256
  end
  crsf.push(crsf.CONST.FRAMETYPE_PARAMETER_WRITE, frame)
end

--- Send a PARAMETER_WRITE carrying a field's string value, clamped to
-- field.maxlen (default 32), inner NULs stripped, null-terminated.
-- @param session  table with deviceId/handsetId
-- @param field    table with id, value and optional maxlen
function Fields.sendWriteString(session, field)
  local frame = { session.deviceId, session.handsetId, field.id }
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
  crsf.push(crsf.CONST.FRAMETYPE_PARAMETER_WRITE, frame)
end

--- Send a command-step PARAMETER_WRITE: one byte from the commandStep_e
-- machine (crsf.CONST.CMD_CLICK / CMD_CONFIRMED / CMD_CANCEL / CMD_QUERY).
-- @param session  table with deviceId/handsetId
-- @param fieldId  the command field's id
-- @param step     the command step byte
function Fields.sendCommandStep(session, fieldId, step)
  crsf.push(crsf.CONST.FRAMETYPE_PARAMETER_WRITE, { session.deviceId, session.handsetId, fieldId, step })
end

-- Pseudo-field id: a PARAMETER_WRITE to this id calls supressCriticalErrors()
-- in TXModuleEndpoint.cpp (the firmware matches the bare 0x2E literal).
local FIELD_ID_SUPPRESS_CRITICAL_ERRORS = 0x2E

--- Ask the module to stop reporting its critical error flags (the bits above
-- crsf.CONST.ELRS_FLAGS_WARNING_THRESHOLD in the ELRS status byte).
-- @param session  table with deviceId/handsetId
function Fields.sendSuppressCriticalErrors(session)
  crsf.push(
    crsf.CONST.FRAMETYPE_PARAMETER_WRITE,
    { session.deviceId, session.handsetId, FIELD_ID_SUPPRESS_CRITICAL_ERRORS, 0 }
  )
end

-- ============================================================================
-- Return codec table
-- ============================================================================

return Fields
