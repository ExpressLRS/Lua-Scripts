---------------------------------------------------------------------------
-- MSP-over-CRSF Codec                                                   --
-- Loaded via loadScript() with (crsf); returns the Msp table.           --
--                                                                       --
-- Stateless encoders and decoders for MSP frames tunnelled in CRSF      --
-- (frame types MSP_REQ/MSP_RESP/MSP_WRITE). Encoders return             --
-- (frameType, payload) for the caller to crsf.push(); decoders never    --
-- mutate the frame. Single-frame v1 traffic only: every message this    --
-- repo speaks (ELRS RXTX_CONFIG) fits one CRSF frame, so the chunked    --
-- transfer protocol (sequence numbers, reassembly, XOR CRC) is not      --
-- implemented. The firmware verifies no MSP CRC on these frames         --
-- (RxTxEndpoint.cpp reads the payload by offset), so encoders append    --
-- none, and the decoder ignores anything past the declared size.       --
---------------------------------------------------------------------------

local crsf = ...

local Msp = {}

-- ============================================================================
-- Named protocol constants
-- ============================================================================

Msp.CONST = {
  -- MSP-over-CRSF status byte: bits 0-3 sequence, bit 4 start-of-frame,
  -- bits 5-6 MSP version, bit 7 error (responses only)
  MSP_STARTFLAG = 0x10,
  MSP_VERSION_V1 = 0x20,
  MSP_ERRORFLAG = 0x80,

  -- MSP function ids (ExpressLRS msptypes.h; RXTX_CONFIG needs ELRS 4.1+)
  MSP_ELRS_RXTX_CONFIG = 0x2D,

  -- MSP_ELRS_RXTX_CONFIG subcommands (first payload byte)
  RXTX_UID = 0x00,
  RXTX_BIND_PHRASE = 0x01,
  RXTX_MODEL_ID = 0x0A,

  -- A bind phrase must fit a single un-chunked MSP_WRITE frame
  PHRASE_MAX = 52,
}

-- Header of every outgoing frame: version 1, start-of-frame, sequence 0.
-- Single-frame messages never advance the sequence.
local HEADER = Msp.CONST.MSP_VERSION_V1 + Msp.CONST.MSP_STARTFLAG

-- Version bits mask within the status byte
local VERSION_MASK = 0x60

--- Build the shared MSP payload layout: extended-frame addressing, header,
-- size (bytes after fn: subcommand plus data), function id, then args.
local function encode(deviceId, handsetId, fn, args)
  local payload = { deviceId, handsetId, HEADER, #args, fn }
  for i = 1, #args do
    payload[5 + i] = args[i]
  end
  return payload
end

-- ============================================================================
-- Encoders: return (frameType, payload) for crsf.push()
-- ============================================================================

--- Encode an MSP read request.
-- @param deviceId   destination CRSF address
-- @param handsetId  source CRSF address (the handset)
-- @param fn         MSP function id
-- @param args       array of payload bytes (subcommand first)
-- @return frameType, payload
function Msp.encodeRead(deviceId, handsetId, fn, args)
  return crsf.CONST.FRAMETYPE_MSP_REQ, encode(deviceId, handsetId, fn, args)
end

--- Encode an MSP write.
-- @param deviceId   destination CRSF address
-- @param handsetId  source CRSF address (the handset)
-- @param fn         MSP function id
-- @param args       array of payload bytes (subcommand first)
-- @return frameType, payload
function Msp.encodeWrite(deviceId, handsetId, fn, args)
  return crsf.CONST.FRAMETYPE_MSP_WRITE, encode(deviceId, handsetId, fn, args)
end

--- Encode a request for the device's current bind UID.
-- @return frameType, payload
function Msp.encodeUidRead(deviceId, handsetId)
  return Msp.encodeRead(deviceId, handsetId, Msp.CONST.MSP_ELRS_RXTX_CONFIG, { Msp.CONST.RXTX_UID })
end

--- Encode a write of a raw 6-byte bind UID.
-- @param uid  array of six byte values
-- @return frameType, payload
function Msp.encodeUidWrite(deviceId, handsetId, uid)
  return Msp.encodeWrite(deviceId, handsetId, Msp.CONST.MSP_ELRS_RXTX_CONFIG, {
    Msp.CONST.RXTX_UID,
    uid[1],
    uid[2],
    uid[3],
    uid[4],
    uid[5],
    uid[6],
  })
end

--- Encode a write of a bind phrase; the device derives its UID from it.
-- @param phrase  string of at most PHRASE_MAX chars
-- @return frameType, payload
function Msp.encodePhraseWrite(deviceId, handsetId, phrase)
  local args = { Msp.CONST.RXTX_BIND_PHRASE }
  for i = 1, #phrase do
    args[i + 1] = string.byte(phrase, i)
  end
  return Msp.encodeWrite(deviceId, handsetId, Msp.CONST.MSP_ELRS_RXTX_CONFIG, args)
end

-- ============================================================================
-- Decoders
-- ============================================================================

--- Decode an MSP_RESP frame addressed to the handset. Accepts only v1
-- single-frame responses (start flag set); continuation chunks and other
-- MSP versions return nil. Source gating stays with the caller, matching
-- decodeDeviceInfo's convention.
-- @param data  array of byte values
-- @return srcId, fn, offset, len  -- payload is data[offset .. offset+len-1]
--         (subcommand first), or nil when the frame is not a complete
--         single-frame v1 response to the handset
function Msp.decodeResponse(data)
  if data[1] ~= crsf.CONST.ADDRESS_HANDSET then
    return nil
  end
  local status = data[3]
  local size = data[4]
  if status == nil or size == nil then
    return nil
  end
  if not bit32.btest(status, Msp.CONST.MSP_STARTFLAG) then
    return nil
  end
  if bit32.band(status, VERSION_MASK) ~= Msp.CONST.MSP_VERSION_V1 then
    return nil
  end
  local fn = data[5]
  if fn == nil or data[5 + size] == nil then
    return nil
  end
  return data[2], fn, 6, size
end

--- Decode an RXTX_CONFIG/UID answer into the caller-owned out[1..6]
-- (reused across frames: no per-frame table).
-- @param data  array of byte values
-- @param out   table receiving the six UID bytes
-- @return srcId (source CRSF address) or nil when the frame is not a
--         complete UID response
function Msp.decodeUid(data, out)
  local srcId, fn, offset, len = Msp.decodeResponse(data)
  if srcId == nil or fn ~= Msp.CONST.MSP_ELRS_RXTX_CONFIG then
    return nil
  end
  if data[offset] ~= Msp.CONST.RXTX_UID or len < 7 then
    return nil
  end
  for i = 1, 6 do
    out[i] = data[offset + i]
  end
  return srcId
end

return Msp
