-- TNS|ExpressLRS Bind|TNE
---- #########################################################################
---- #                                                                       #
---- # ExpressLRS bind phrase manager for BW and color LCD radios            #
---- # (EdgeTX 2.11.6+/2.12.1+). Reads and writes the bind phrase / UID      #
---- # over MSP; the device side requires ExpressLRS 4.1+.                   #
---- #                                                                       #
---- # License GPLv2: http://www.gnu.org/licenses/gpl-2.0.html               #
---- #########################################################################

local VERSION = "r1"
local useLvgl = (lvgl ~= nil)

-- ============================================================================
-- Load shared modules
-- ============================================================================

-- The loader is the one shared part that must bootstrap with a bare
-- loadScript; it owns the GC-before-load discipline.
---@diagnostic disable-next-line: need-check-nil
local loader = loadScript("/SCRIPTS/ELRS/loader.lua")()

local crsf = loader("/SCRIPTS/ELRS/crsf.lua")
local msp = loader("/SCRIPTS/ELRS/msp.lua", crsf)
local defer = loader("/SCRIPTS/ELRS/defer.lua")
local FileStorage = loader("/SCRIPTS/ELRS/file_storage.lua")
local History = loader("/SCRIPTS/TOOLS/ExpressLRSBind/history_storage.lua", FileStorage)
local versionOk = loader("/SCRIPTS/ELRS/edgetx_version.lua")()

-- ============================================================================
-- App Module: business logic shared by both UI frontends
-- ============================================================================

-- Scheduler constants (getTime() ticks of 10 ms)
local UID_RETRY_TICKS = 50 -- resend an unanswered UID read after 500 ms
local UID_MAX_ATTEMPTS = 6 -- then give up: the device has no MSP config support
local FOLLOWUP_TICKS = 100 -- settle time before a follow-up after a write

-- How the tool formats the six-byte UID: wide for colour, tight for the
-- 128 px BW line where every pixel of the row is spoken for.
local UID_FMT_WIDE = "%d, %d, %d, %d, %d, %d"
local UID_FMT_TIGHT = "%d,%d,%d,%d,%d,%d"

local App = {
  -- Target selector positions (order matches the UIs' choice lists)
  TARGET_TX = 1,
  TARGET_RX = 2,
  TARGET_BOTH = 3,

  -- What is known about the transmitter's UID. Kept apart from the
  -- transient status line: an identity is data, an action is an event.
  UID_UNKNOWN = 0, -- never asked, or the read was interrupted
  UID_OK = 1, -- uid holds the transmitter's answer
  UID_SILENT = 2, -- asked and asked again, nothing came back

  target = 1,
  phrase = "",
  bothStep = nil, -- which side the in-flight write sequence is on

  -- Only the transmitter is read. A receiver answers over the link, and a
  -- link only exists between devices already sharing a UID, so its answer
  -- could never be anything but the number below -- while the link's mere
  -- existence, which is free, says everything asking would have.
  uid = {}, -- reused 6-slot byte table, filled by msp.decodeUid
  uidState = 0,

  probing = false, -- a UID read is outstanding
  probeAttempts = 0,
  setInFlight = false, -- a write sequence owns the defer slot
  writeSide = nil, -- side the in-flight write is addressing; drives the Set label

  -- Bumped only when a build-time snapshot must refresh (the TEXT_EDIT
  -- value). Everything else on the LVGL page reads live getters, and a
  -- rebuild resets rotary focus -- so status and UID updates must NOT bump it.
  rev = 0,
  history = History,

  shouldExit = false,
  crsfModuleChecked = false,
  crsfModuleFound = false,
}

function App.checkCrsfModule()
  if App.crsfModuleChecked then
    return App.crsfModuleFound
  end
  App.crsfModuleChecked = true
  App.crsfModuleFound = crsf.hasCrsfModule()
  return App.crsfModuleFound
end

-- The TX module answers on the handset UART; the RX only over an active link.
function App.isTargetReachable()
  return App.target == App.TARGET_TX or (App.target == App.TARGET_RX and crsf.hasTelemetry)
end

function App.isTargetReachableOrBoth()
  return App.target == App.TARGET_BOTH or App.isTargetReachable()
end

--- The transmitter's identity as the UIs display it: the bytes once they
-- land, and what is standing in the way until they do.
-- @param compact  omit the spaces between bytes (the narrow BW line)
function App.uidText(compact)
  if App.uidState == App.UID_OK then
    local u = App.uid
    return string.format(compact and UID_FMT_TIGHT or UID_FMT_WIDE, u[1], u[2], u[3], u[4], u[5], u[6])
  end
  if App.probing then
    return "Reading..."
  end
  if App.uidState == App.UID_SILENT then
    -- The transmitter answers over the handset UART whenever it is
    -- powered, so its silence is a firmware statement, not a link problem.
    return "Needs ExpressLRS 4.1+"
  end
  return "--"
end

--- Whether a receiver is bound to that identity, which is exactly what an
-- active link means.
function App.receiverText()
  return crsf.hasTelemetry and "Connected" or "Not connected"
end

--- The Set button's own label, which doubles as the write sequence's
-- progress: the report belongs on the control that caused it, so the page
-- needs no status line of its own.
-- @param compact  short forms for the narrow BW row
function App.setLabel(compact)
  if App.writeSide == App.TARGET_TX then
    return compact and "Setting TX..." or "Setting transmitter..."
  end
  if App.writeSide == App.TARGET_RX then
    return compact and "Setting RX..." or "Setting receiver..."
  end
  return "Set bind phrase"
end

--- True while a write sequence is running, which is also what disables Set.
function App.isSetEnabled()
  return App.isTargetReachableOrBoth() and App.phrase ~= "" and not App.setInFlight
end

--- Parse one comma-separated segment as a plain decimal byte (surrounding
-- spaces allowed). No patterns: B&W-friendly byte walking.
local function parseByte(part)
  local i = 1
  local j = #part
  while i <= j and string.byte(part, i) == 32 do
    i = i + 1
  end
  while j >= i and string.byte(part, j) == 32 do
    j = j - 1
  end
  if i > j or j - i > 2 then
    return nil
  end
  local n = 0
  for k = i, j do
    local b = string.byte(part, k)
    if b < 48 or b > 57 then
      return nil
    end
    n = n * 10 + (b - 48)
  end
  if n > 255 then
    return nil
  end
  return n
end

--- Interpret the phrase text as a raw UID: 4-6 comma-separated bytes,
-- left-padded with zeros to 6. Returns nil when the text is a phrase.
function App.parseUidText(text)
  local bytes = {}
  local pos = 1
  while pos <= #text do
    local comma = string.find(text, ",", pos, true)
    local part
    if comma then
      part = string.sub(text, pos, comma - 1)
      pos = comma + 1
    else
      part = string.sub(text, pos)
      pos = #text + 1
    end
    local n = parseByte(part)
    if n == nil then
      return nil
    end
    bytes[#bytes + 1] = n
  end
  local count = #bytes
  if count < 4 or count > 6 then
    return nil
  end
  local uid = { 0, 0, 0, 0, 0, 0 }
  for i = 1, count do
    uid[6 - count + i] = bytes[i]
  end
  return uid
end

-- ============================================================================
-- UID probe
-- ============================================================================

--- Ask the transmitter for its UID, retrying on silence. Bounded: an ELRS
-- module without MSP config support (pre-4.1) never answers, and the retry
-- must not spam the wire forever. The module answers over the handset UART
-- whenever it is powered, so silence here is a firmware statement rather
-- than a link problem.
function App.probeStep()
  if not App.probing then
    return
  end
  if App.probeAttempts >= UID_MAX_ATTEMPTS then
    App.uidState = App.UID_SILENT
    App.probing = false
    return
  end
  App.probeAttempts = App.probeAttempts + 1
  crsf.push(msp.encodeUidRead(crsf.CONST.ADDRESS_TX, crsf.CONST.ADDRESS_HANDSET))
  defer.setTimeout(UID_RETRY_TICKS, App.probeStep)
end

function App.startProbe()
  if App.setInFlight then
    return
  end
  App.probing = true
  App.probeAttempts = 0
  App.probeStep()
end

--- Drop an in-flight probe so a user action can take the defer slot.
local function cancelProbe()
  App.probing = false
end

-- ============================================================================
-- Actions
-- ============================================================================

--- Point the tool at a different side. Also the natural retry: a user who
-- moves the selector after a silent read gets a fresh look at the module.
function App.setTarget(n)
  if n == App.target then
    return
  end
  App.target = n
  App.startProbe()
end

--- The write sequence's last step: release the defer slot and read back
-- what the transmitter actually stored.
local function finishSet()
  App.setInFlight = false
  App.bothStep = nil
  App.writeSide = nil
  App.startProbe()
end

--- Write the phrase (or raw UID) to the side the sequence is on, then
-- either advance to the transmitter or finish.
function App.writeStep()
  local side = App.bothStep
  local isTx = side == App.TARGET_TX
  App.writeSide = side
  local dest = isTx and crsf.CONST.ADDRESS_TX or crsf.CONST.ADDRESS_RX
  local uid = App.parseUidText(App.phrase)
  if uid then
    crsf.push(msp.encodeUidWrite(dest, crsf.CONST.ADDRESS_HANDSET, uid))
  else
    crsf.push(msp.encodePhraseWrite(dest, crsf.CONST.ADDRESS_HANDSET, App.phrase))
  end
  if App.target == App.TARGET_BOTH and not isTx then
    App.bothStep = App.TARGET_TX
    defer.setTimeout(FOLLOWUP_TICKS, App.writeStep)
  else
    defer.setTimeout(FOLLOWUP_TICKS, finishSet)
  end
end

--- Send the phrase to the selected side. "Both" runs as a two-step
-- sequence: the receiver first -- writing its phrase drops it off the link
-- -- then the transmitter, which brings the link back on the new identity.
function App.sendSet()
  if not App.isSetEnabled() then
    return
  end
  cancelProbe()
  App.setInFlight = true
  App.bothStep = (App.target == App.TARGET_BOTH) and App.TARGET_RX or App.target
  History.add(App.phrase)
  App.writeStep()
end

--- Put the TX module in bind mode, meeting an RX that is in bind mode too
-- (firmware: both addresses of this command reach EnterBindingModeSafely).
-- A plain CRSF command, so unlike the phrase write it works on every ELRS
-- version -- which is what keeps the tool useful on a pre-4.1 setup.
-- Neither side reports its bind state back, so the UIs say what the user
-- still has to do rather than claiming a result.
function App.sendBind()
  crsf:sendBindCommand(crsf.CONST.ADDRESS_TX)
end

--- Send the same command to the connected receiver, which drops the link
-- and leaves it listening for a bind.
function App.sendUnbind()
  crsf:sendBindCommand(crsf.CONST.ADDRESS_RX)
end

function App.useHistory(i)
  local phrase = History.items[i]
  if phrase == nil then
    return
  end
  App.phrase = phrase
  App.rev = App.rev + 1
end

function App.removeHistory(i)
  History.remove(i)
end

function App.clearHistory()
  History.clear()
end

--- Frame router for crsf.drain(): the tool is the sole drainer in its Lua
-- state, and the only traffic it consumes is the transmitter's MSP UID
-- answer. Source gating lives here, as msp.lua leaves it to the caller.
function App.onFrame(_consumer, command, data)
  if command ~= crsf.CONST.FRAMETYPE_MSP_RESP or data[2] ~= crsf.CONST.ADDRESS_TX then
    return
  end
  if msp.decodeUid(data, App.uid) == nil then
    return
  end
  App.uidState = App.UID_OK
  -- Only an answer we are waiting for ends the retry; a late duplicate
  -- must not cancel a write sequence's follow-up.
  if App.probing then
    defer.clear()
    App.probing = false
  end
end

-- ============================================================================
-- UI loading (deferred to init)
-- ============================================================================

local UI

-- Module table, forward-declared so init() can drop itself once it has run.
local M = {}

local function init()
  local deps = {
    App = App,
    crsf = crsf,
    msp = msp,
    VERSION = VERSION,
    versionOk = versionOk,
  }
  App.phrase = History.items[1] or ""
  if useLvgl then
    UI = loader("/SCRIPTS/TOOLS/ExpressLRSBind/ui/lvgl.lua", deps)
  else
    UI = loader("/SCRIPTS/TOOLS/ExpressLRSBind/ui/lcd.lua", deps)
  end
  UI.init()
  -- One tick of delay so run()'s first drain creates the telemetry queue
  -- before the answer can land.
  defer.setTimeout(1, App.startProbe)
  -- The returned table stays on the standalone Lua stack and pins init(),
  -- which holds VERSION and useLvgl as upvalues. Drop it.
  M.init = nil
end

-- ============================================================================
-- Run (shared orchestrator)
-- ============================================================================

local function run(event, touchState)
  if event == nil then
    return 2
  end

  -- UI-specific pre-checks (version gate on both LVGL and BW paths)
  if UI.preCheck then
    local result = UI.preCheck(event)
    if result ~= nil then
      return result
    end
  end

  if not App.checkCrsfModule() then
    UI.handleNoModule()
    if App.shouldExit then
      return 2
    end
    return 0
  end

  crsf.drain(App, App.onFrame)
  -- After the drain, so a callback's push is answered before its follow-up
  defer.poll()

  UI.render(event, touchState)

  if App.shouldExit then
    return 2
  end
  return 0
end

-- ============================================================================
-- Return
-- ============================================================================

M.init = init
M.run = run
M.useLvgl = useLvgl
return M
