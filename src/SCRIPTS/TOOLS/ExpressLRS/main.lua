-- TNS|ExpressLRS|TNE
---- #########################################################################
---- #                                                                       #
---- # Copyright (C) OpenTX, adapted for ExpressLRS                          #
---- #                                                                       #
---- # License GPLv2: http://www.gnu.org/licenses/gpl-2.0.html               #
---- #                                                                       #
---- # Unified tool for BW and color LCD radios (EdgeTX 2.11.6+/2.12.1+)     #
---- #########################################################################

local VERSION = "r2"
local useLvgl = (lvgl ~= nil)

-- ============================================================================
-- Load shared modules
-- ============================================================================

local shim = loadScript("/SCRIPTS/ELRS/shim.lua")()
local crsf = loadScript("/SCRIPTS/ELRS/crsf.lua")()
local Protocol = loadScript("/SCRIPTS/TOOLS/ExpressLRS/protocol.lua")(crsf, shim)
local Navigation = loadScript("/SCRIPTS/TOOLS/ExpressLRS/navigation.lua")()

-- ============================================================================
-- App Module: Pure business logic (zero UI references)
-- ============================================================================

local App = {
  crsfModuleChecked = false,
  crsfModuleFound = false,
  shouldExit = false,
}

function App.reset()
  App.crsfModuleChecked = false
  App.crsfModuleFound = false
  App.shouldExit = false
  Protocol.reset()
end

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
  if Protocol.setDevice(device) then
    Navigation.reset()
    return true
  end
  return false
end

-- Returns true if device was switched.
function App.switchDevice(deviceId, viewState)
  local device = Protocol.getDevice(deviceId)
  if not device then
    return false
  end
  local prevDeviceId = Protocol.deviceId
  if Protocol.setDevice(device) then
    Navigation.openDevice(device.name, prevDeviceId, viewState)
    return true
  end
  return false
end

-- Navigate into folder.
function App.enterFolder(folderId, folderName, viewState)
  Navigation.openFolder(folderId, folderName, viewState)
  Protocol.loadFolderChildren(folderId)
end

-- Returns navigation entry (or nil).
function App.goBack()
  return Navigation.goBack()
end

-- Reload at root: switch back to TX device or reload fields + ping.
function App.reloadAtRoot()
  if Protocol.deviceId ~= crsf.CONST.ADDRESS_TX then
    local txDevice = Protocol.getDevice(crsf.CONST.ADDRESS_TX)
    if txDevice then
      App.loadDevice(txDevice)
    end
  else
    Protocol.allocateFields()
    Protocol.reloadAllFields()
  end
  crsf:pingDevices()
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
    Navigation = Navigation,
    Protocol = Protocol,
    crsf = crsf,
    VERSION = VERSION,
  }
  if useLvgl then
    UI = loadScript("/SCRIPTS/TOOLS/ExpressLRS/ui/lvgl.lua")(deps)
  else
    UI = loadScript("/SCRIPTS/TOOLS/ExpressLRS/ui/lcd.lua")(deps)
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

  local targetDevice, anyNewDevice = Protocol.poll()
  Protocol.tick()

  if Protocol.elrsV1Detected then
    UI.handleUnsupported()
    return 0
  end

  if targetDevice then
    if App.loadDevice(targetDevice) then
      UI.onDeviceLoaded()
    end
  end
  if anyNewDevice then
    UI.onNewDevice()
  end

  local currentFolder = Navigation.getCurrent()
  local folderReady = Protocol.isFolderLoaded(currentFolder)
  if folderReady and not UI.folderWasReady then
    collectgarbage("collect")
    UI.invalidate()
    if currentFolder == nil and not Protocol.backgroundLoading then
      Protocol.startBackgroundLoad()
    end
  end
  UI.folderWasReady = folderReady

  if Protocol.fieldHiddenChanged then
    Protocol.fieldHiddenChanged = nil
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
