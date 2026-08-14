-- TNS|ExpressLRS|TNE
---- #########################################################################
---- #                                                                       #
---- # Copyright (C) OpenTX, adapted for ExpressLRS                          #
---- #                                                                       #
---- # License GPLv2: http://www.gnu.org/licenses/gpl-2.0.html               #
---- #                                                                       #
---- # Unified tool for BW and color LCD radios (EdgeTX 2.11.6+/2.12.1+)     #
---- #########################################################################

local VERSION = "r3"
local useLvgl = (lvgl ~= nil)

-- ============================================================================
-- Load shared modules
-- ============================================================================

-- The loader is the one shared part that must bootstrap with a bare
-- loadScript; it owns the GC-before-load discipline.
---@diagnostic disable-next-line: need-check-nil
local loader = loadScript("/SCRIPTS/ELRS/loader.lua")()

local crsf = loader("/SCRIPTS/ELRS/crsf.lua")
local params = loader("/SCRIPTS/ELRS/crsf_params.lua", crsf)
local CRSFSession = loader("/SCRIPTS/ELRS/crsf_session.lua", crsf, params)
local Navigation = loader("/SCRIPTS/TOOLS/ExpressLRS/navigation.lua")

-- ============================================================================
-- App Module: business logic between the session and the UI
-- ============================================================================

local App = {
  -- Tool-internal pseudo field types for the synthetic device rows in the
  -- "Other Devices" list. Values sit above the wire range: the type byte is
  -- masked with 0x7f at parse, so a real field type can never exceed 127 --
  -- unlike 15/16, which the previous numbering used and which shadow
  -- CRSF_VTX (0x0F) on the wire.
  DEVICE = 128,
  DEVICE_FOLDER = 129,

  crsfModuleChecked = false,
  crsfModuleFound = false,
  shouldExit = false,
}

local UI
local session

function App.checkCrsfModule()
  if App.crsfModuleChecked then
    return App.crsfModuleFound
  end
  App.crsfModuleChecked = true
  App.crsfModuleFound = crsf.hasCrsfModule()
  return App.crsfModuleFound
end

-- Returns true if device was set, false if no change needed.
function App.loadDevice(device)
  if session:setDevice(device) then
    Navigation.reset()
    return true
  end
  return false
end

-- Returns true if device was switched.
function App.switchDevice(deviceId, viewState)
  local device = session:getDevice(deviceId)
  if not device then
    return false
  end
  local prevDeviceId = session.deviceId
  if session:setDevice(device) then
    Navigation.openDevice(device.name, prevDeviceId, viewState)
    return true
  end
  return false
end

-- Navigate into folder.
function App.enterFolder(folderId, folderName, viewState)
  Navigation.openFolder(folderId, folderName, viewState)
  session:loadFolder(folderId)
end

-- Returns navigation entry (or nil).
function App.goBack()
  return Navigation.goBack()
end

-- Reload at root: switch back to TX device or reload fields, then
-- re-discover so new devices appear.
function App.reloadAtRoot()
  if session.deviceId ~= crsf.CONST.ADDRESS_TX then
    local txDevice = session:getDevice(crsf.CONST.ADDRESS_TX)
    if txDevice then
      App.loadDevice(txDevice)
    end
  else
    session:reloadAll()
  end
  session:discoverDevices()
end

-- ============================================================================
-- Session: the tool talks to one device at a time, tracking it fully
-- ============================================================================

session = CRSFSession.new({
  discovery = true,
  trackStatus = true,
  detectV1 = true,
  preload = true,
  onDeviceUpdate = function(device, isNew)
    if device.id == session.deviceId and App.loadDevice(device) then
      UI.onDeviceLoaded()
    end
    if isNew then
      UI.onNewDevice()
    end
  end,
})

-- ============================================================================
-- UI loading (deferred to init)
-- ============================================================================

-- Module table, forward-declared so init() can drop itself once it has run.
local M = {}

local function init()
  local deps = {
    App = App,
    Navigation = Navigation,
    session = session,
    crsf = crsf,
    VERSION = VERSION,
  }
  if useLvgl then
    UI = loader("/SCRIPTS/TOOLS/ExpressLRS/ui/lvgl.lua", deps)
  else
    UI = loader("/SCRIPTS/TOOLS/ExpressLRS/ui/lcd.lua", deps)
  end
  UI.init()
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

  -- UI-specific pre-checks (version check on both LVGL and BW paths)
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

  session:drain()
  session:tick()

  if session.v1Detected then
    UI.handleUnsupported()
    return 0
  end

  local currentFolder = Navigation.getCurrent()
  local folderReady = session:isFolderLoaded(currentFolder)
  if folderReady and not UI.folderWasReady then
    collectgarbage("collect")
    UI.invalidate()
  end
  UI.folderWasReady = folderReady

  if session.fieldHiddenChanged then
    session.fieldHiddenChanged = nil
    UI.visibleFields = nil
  end

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
