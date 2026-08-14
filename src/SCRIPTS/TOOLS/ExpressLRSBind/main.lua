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

local App = {
  -- Target selector positions (order matches the UIs' choice lists)
  TARGET_TX = 1,
  TARGET_RX = 2,
  TARGET_BOTH = 3,

  target = 1,
  phrase = "",
  bothStep = nil, -- TARGET_RX while the Both sequence's RX leg is in flight
  uid = {}, -- reused 6-slot byte table, filled by msp.decodeUid
  uidFrom = nil, -- source address of the last UID answer; nil until one lands
  statusText = "Idle", -- transient status line; nil shows the UID bytes
  uidAttempts = 0,
  -- Bumped only when a build-time snapshot must refresh (the TEXT_EDIT
  -- value, the CHOICE selection). Everything else on the LVGL page reads
  -- live getters, and a rebuild resets rotary focus -- so status and UID
  -- updates must NOT bump this.
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

--- Status line for the UIs: transient status while an exchange is in
-- flight, then the last UID answer.
function App.uidLine()
  if App.statusText then
    return App.statusText
  end
  local u = App.uid
  local prefix = (App.uidFrom == crsf.CONST.ADDRESS_RX) and "RX" or "TX"
  return string.format("%s: %d, %d, %d, %d, %d, %d", prefix, u[1], u[2], u[3], u[4], u[5], u[6])
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

--- Request the target's UID, retrying on silence. Bounded: an ELRS device
-- without MSP config support (pre-4.1) never answers, and the retry must
-- not spam the wire forever.
function App.requestUid()
  if not App.isTargetReachable() then
    App.statusText = "Idle"
    return
  end
  if App.uidAttempts >= UID_MAX_ATTEMPTS then
    App.statusText = "No response (needs ELRS 4.1+)"
    return
  end
  App.uidAttempts = App.uidAttempts + 1
  App.statusText = "Updating..."
  local dest = (App.target == App.TARGET_TX) and crsf.CONST.ADDRESS_TX or crsf.CONST.ADDRESS_RX
  crsf.push(msp.encodeUidRead(dest, crsf.CONST.ADDRESS_HANDSET))
  defer.setTimeout(UID_RETRY_TICKS, App.requestUid)
end

--- User-facing entry point: start a fresh UID request cycle.
function App.startUidRequest()
  App.uidAttempts = 0
  App.requestUid()
end

--- Send the phrase (or raw UID) to the selected target. "Both" is a
-- two-step sequence: the RX first -- writing its phrase drops it off the
-- link -- then the TX, after which the selector rests on Transmitter.
function App.sendSet()
  if App.phrase == "" then
    return
  end
  if App.target == App.TARGET_BOTH then
    if App.bothStep == nil then
      App.bothStep = App.TARGET_RX
    else
      App.bothStep = nil
      -- The selector visibly rests on Transmitter after the sequence; the
      -- CHOICE renders its build-time selection, so this needs a rebuild.
      App.target = App.TARGET_TX
      App.rev = App.rev + 1
    end
  end
  local effective = App.bothStep or App.target
  if App.bothStep == nil then
    App.statusText = (App.target == App.TARGET_TX) and "Setting transmitter..." or "Setting receiver..."
  else
    App.statusText = "Setting RX and disconnecting..."
  end
  local dest = (effective == App.TARGET_TX) and crsf.CONST.ADDRESS_TX or crsf.CONST.ADDRESS_RX
  local uid = App.parseUidText(App.phrase)
  if uid then
    crsf.push(msp.encodeUidWrite(dest, crsf.CONST.ADDRESS_HANDSET, uid))
  else
    crsf.push(msp.encodePhraseWrite(dest, crsf.CONST.ADDRESS_HANDSET, App.phrase))
  end
  History.add(App.phrase)
  if App.bothStep == nil then
    defer.setTimeout(FOLLOWUP_TICKS, App.startUidRequest)
  else
    defer.setTimeout(FOLLOWUP_TICKS, App.sendSet)
  end
end

local function markSent()
  App.statusText = "Sent"
end

--- Put the TX module in bind mode, catching an RX waiting in bind mode.
function App.sendBind()
  App.statusText = "Sending bind command..."
  crsf:sendBindCommand(crsf.CONST.ADDRESS_TX)
  defer.setTimeout(FOLLOWUP_TICKS, markSent)
end

--- Unbind the connected receiver.
function App.sendUnbind()
  App.statusText = "Sending unbind to RX..."
  crsf:sendBindCommand(crsf.CONST.ADDRESS_RX)
  defer.setTimeout(FOLLOWUP_TICKS, markSent)
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
-- state, and the only traffic it consumes is the MSP UID answer.
function App.onFrame(_consumer, command, data)
  if command ~= crsf.CONST.FRAMETYPE_MSP_RESP then
    return
  end
  local srcId = msp.decodeUid(data, App.uid)
  if srcId == nil then
    return
  end
  defer.clear()
  App.uidFrom = srcId
  App.statusText = nil
  App.uidAttempts = 0
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
  -- before the request's answer can land.
  defer.setTimeout(1, App.startUidRequest)
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
