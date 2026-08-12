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
-- Return codec table
-- ============================================================================

return Fields
