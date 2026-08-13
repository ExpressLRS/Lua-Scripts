---- #########################################################################
---- # BW LCD UI: Rendering, input handling, cursor management            #
---- # For black & white radios (no LVGL required)                        #
---- #########################################################################

local deps = ...

local App = deps.App
local Navigation = deps.Navigation
local session = deps.session
local crsf = deps.crsf
local VERSION = deps.VERSION

local versionCheckResult = nil

local function checkEdgeTxVersion()
  local _ver, _radio, maj, minor, rev = getVersion()

  if maj >= 3 then
    return true
  elseif maj == 2 and minor == 12 and rev >= 1 then
    return true
  elseif maj == 2 and minor == 11 and rev >= 6 then
    return true
  end

  return false
end

-- ============================================================================
-- UI state
-- ============================================================================

-- Title warning flash half-period, in 10 ms ticks. Also paces the idle page
-- repaint (the flash tick sets forceRedraw), so halving it doubles that rate.
local WARN_FLASH_PERIOD = 100

local UI = {
  -- Cursor/selection state (owned entirely by this module)
  lineIndex = 1,
  pageOffset = 0,
  edit = nil,

  -- Visible field list (rebuilt on invalidate)
  visibleFields = nil,

  -- Layout constants for 128x64; UI.init widens COL2 at 212px wide and
  -- raises maxLineIndex at 96px tall
  COL1 = 0,
  COL2 = 70,
  maxLineIndex = 6,
  textSize = 8,
  textYoffset = 3,

  -- Redraw state
  forceRedraw = true,
  folderWasReady = false,
  wasLoading = false,

  -- Warning flashing
  titleShowWarn = nil,
  titleShowWarnTimeout = 0,
  titleWarnFlags = nil, -- last flags byte the flash phase was anchored to

  -- Warning dismissal (model mismatch)
  warningDismissedAt = nil,

  -- Command popup spinner
  commandRunningIndicator = 1,
}

-- ============================================================================
-- Interface: init
-- ============================================================================

function UI.init()
  if LCD_W == 212 then
    UI.COL2 = 110
  end
  if LCD_H == 96 then
    UI.maxLineIndex = 9
  end

  versionCheckResult = checkEdgeTxVersion()
end

-- ============================================================================
-- Interface: preCheck (version gate)
-- ============================================================================

function UI.preCheck(event)
  if not versionCheckResult then
    UI.drawAlert("Unsupported", {
      "Requires EdgeTX:",
      "- 2.11.6 or later",
      "- 2.12.1 or later",
      "- 3.0 or later",
    })
    if event == EVT_VIRTUAL_EXIT then
      App.shouldExit = true
      return 2
    end
    return 0
  end
  return nil
end

-- ============================================================================
-- Interface: invalidate (does NOT reset cursor)
-- ============================================================================

function UI.invalidate()
  UI.forceRedraw = true
  UI.visibleFields = nil
end

-- ============================================================================
-- Interface: onDeviceLoaded (resets cursor + invalidates)
-- ============================================================================

function UI.onDeviceLoaded()
  UI.lineIndex = 1
  UI.pageOffset = 0
  UI.invalidate()
end

-- ============================================================================
-- Interface: onNewDevice
-- ============================================================================

function UI.onNewDevice()
  UI.invalidate()
end

-- ============================================================================
-- Interface: handleNoModule
-- ============================================================================

function UI.handleNoModule()
  UI.drawAlert(" No ExpressLRS", {
    "Enable a CRSF Internal",
    "  or External module in",
    "      Model settings",
    " If module is internal",
    "also set Internal RF to",
    "CRSF in SYS->Hardware",
  })
end

-- ============================================================================
-- Interface: handleUnsupported
-- ============================================================================

function UI.handleUnsupported()
  UI.drawAlert("Unsupported Firmware", {
    "ELRS 1.x firmware detected.",
    "Please update to 3.x.",
  })
end

-- ============================================================================
-- Interface: render
-- ============================================================================

function UI.render(event, _touchState)
  -- Warning flash: any flags change re-anchors the phase, so a new warning
  -- starts on its visible half and a cleared one disappears at once
  local time = getTime()
  local flags = session.status.flags
  if flags ~= UI.titleWarnFlags then
    UI.titleWarnFlags = flags
    UI.titleShowWarn = (flags > crsf.CONST.ELRS_FLAGS_STATUS_MASK) or nil
    UI.titleShowWarnTimeout = time + WARN_FLASH_PERIOD
    UI.forceRedraw = true
  elseif time > UI.titleShowWarnTimeout then
    UI.titleShowWarn = (flags > crsf.CONST.ELRS_FLAGS_STATUS_MASK and not UI.titleShowWarn) or nil
    UI.titleShowWarnTimeout = time + WARN_FLASH_PERIOD
    UI.forceRedraw = true
  end

  -- Warning dismissal cooldown (60s before re-showing)
  if UI.warningDismissedAt and time - UI.warningDismissedAt > 6000 then
    UI.warningDismissedAt = nil
  end

  -- Model mismatch alert (full-screen, blocks normal rendering)
  if session.status.modelMismatch and not UI.warningDismissedAt then
    if event == EVT_VIRTUAL_ENTER then
      UI.warningDismissedAt = getTime()
      UI.forceRedraw = true
      return
    elseif event == EVT_VIRTUAL_EXIT then
      App.shouldExit = true
      return
    end
    UI.drawAlert("Model Mismatch", {
      "RX connected but",
      "Model ID doesn't match.",
      "Toggle Model Match",
      "to re-sync",
    }, { left = "[OK]", right = "[RTN] Change model" })
    return
  end

  -- Force redraw while the queue is loading, to show the progress bar, and once
  -- more on the frame it empties. poll() pops the last entry before we get here,
  -- so without the trailing edge the response that completes a reload never
  -- reaches the screen and the page waits for the next event or warn tick.
  local loading = session:isLoading()
  if loading or UI.wasLoading then
    UI.forceRedraw = true
  end
  UI.wasLoading = loading

  -- Render: command popup or normal page
  if session.command ~= nil then
    UI.drawPopup(event)
  elseif event ~= 0 or UI.forceRedraw or UI.edit then
    UI.drawPage(event)
    UI.forceRedraw = false
  end
end

-- ============================================================================
-- Alert screen (clear screen + title + body messages)
-- ============================================================================

function UI.drawAlert(title, msgs, actions)
  lcd.clear()
  local y = 0
  lcd.drawText(2, y, title, MIDSIZE)
  y = y + (UI.textSize * 2) - 2
  for _, msg in ipairs(msgs) do
    lcd.drawText(2, y, msg)
    y = y + UI.textSize
  end
  if actions then
    y = y + UI.textSize
    if actions.left then
      lcd.drawText(2, y, actions.left, 0)
    end
    if actions.right then
      lcd.drawText(LCD_W - 2, y, actions.right, RIGHT)
    end
  end
end

-- ============================================================================
-- User action handlers (call App for business logic, manage own state)
-- ============================================================================

function UI.openFolder(folderId, folderName)
  App.enterFolder(folderId, folderName, { li = UI.lineIndex, po = UI.pageOffset })
  UI.lineIndex = 1
  UI.pageOffset = 0
  UI.invalidate()
end

function UI.switchDevice(deviceId)
  if App.switchDevice(deviceId, { li = UI.lineIndex, po = UI.pageOffset }) then
    UI.lineIndex = 1
    UI.pageOffset = 0
    UI.invalidate()
  end
end

function UI.handleBack()
  if Navigation.isAtRoot() then
    App.reloadAtRoot()
  else
    local entry = App.goBack()
    if entry then
      UI.lineIndex = entry.li or 1
      UI.pageOffset = entry.po or 0
      if entry.type == Navigation.TYPE_DEVICE and entry.prevDeviceId then
        local prevDevice = session:getDevice(entry.prevDeviceId)
        if prevDevice then
          session:setDevice(prevDevice)
        end
      end
    end
  end
  UI.invalidate()
end

-- ============================================================================
-- Build visible field list for current navigation state
-- ============================================================================

function UI.buildVisibleFields()
  local currentFolder = Navigation.getCurrent()
  local vf = {}

  if currentFolder == Navigation.FOLDER_OTHER_DEVICES then
    for _, device in ipairs(session.devices) do
      if device.id ~= session.deviceId then
        vf[#vf + 1] = { id = device.id, name = device.name, type = App.DEVICE }
      end
    end
  else
    local fields = session:fieldsInFolder(currentFolder)
    for _, field in ipairs(fields) do
      if not field.hidden then
        vf[#vf + 1] = field
      end
    end

    if currentFolder == nil and #session.devices > 1 and not Navigation.hasDeviceEntry() then
      vf[#vf + 1] = { name = "Other Devices", type = App.DEVICE_FOLDER }
    end
  end

  UI.visibleFields = vf
end

function UI.getField(line)
  if not UI.visibleFields then
    UI.buildVisibleFields()
  end
  return UI.visibleFields[line]
end

function UI.getFieldCount()
  if not UI.visibleFields then
    UI.buildVisibleFields()
  end
  return #UI.visibleFields
end

function UI.getSelectableCount()
  return UI.getFieldCount() + 1
end

function UI.isOnBackExit()
  return UI.lineIndex > UI.getFieldCount()
end

function UI.getBackExitLabel()
  if Navigation.isAtRoot() then
    return "-- EXIT (" .. VERSION .. ") --"
  else
    return "----BACK----"
  end
end

-- ============================================================================
-- Field value increment
-- ============================================================================

function UI.incrField(step)
  local field = UI.getField(UI.lineIndex)
  if not field then
    return
  end
  local min, max = 0, 0
  if field.type <= crsf.CONST.FIELD_FLOAT then
    min = field.min or 0
    max = field.max or 0
    step = (field.step or 1) * step
  elseif field.type == crsf.CONST.FIELD_TEXT_SELECTION then
    min = 0
    max = #field.values - 1
  end

  local newval = field.value
  repeat
    newval = newval + step
    if newval < min then
      newval = min
    elseif newval > max then
      newval = max
    end

    if field.values == nil or #field.values[newval + 1] ~= 0 then
      field.value = newval
      return
    end
  until newval == min or newval == max
end

-- ============================================================================
-- Field selection navigation
-- ============================================================================

function UI.selectField(step)
  local count = UI.getSelectableCount()
  local fieldCount = UI.getFieldCount()
  local newLineIndex = UI.lineIndex
  repeat
    newLineIndex = newLineIndex + step
    if newLineIndex <= 0 then
      newLineIndex = count
    elseif newLineIndex > count then
      newLineIndex = 1
      UI.pageOffset = 0
    end
    if newLineIndex > fieldCount then
      break
    end
    local field = UI.getField(newLineIndex)
    if field and field.name then
      break
    end
  until newLineIndex == UI.lineIndex
  UI.lineIndex = newLineIndex
  if UI.lineIndex > UI.maxLineIndex + UI.pageOffset then
    UI.pageOffset = UI.lineIndex - UI.maxLineIndex
  elseif UI.lineIndex <= UI.pageOffset then
    UI.pageOffset = UI.lineIndex - 1
  end
end

-- ============================================================================
-- BW field display functions
-- ============================================================================

local function fieldIntDisplay(field, y, attr)
  lcd.drawText(UI.COL2, y, field.value .. (field.unit or ""), attr)
end

local function fieldFloatDisplay(field, y, attr)
  lcd.drawText(UI.COL2, y, string.format(field.fmt, field.value / field.prec) .. (field.unit or ""), attr)
end

local function fieldTextSelDisplay(field, y, attr)
  lcd.drawText(UI.COL2, y, (field.values[field.value + 1] or "ERR") .. (field.unit or ""), attr)
end

local function fieldStringDisplay(field, y, attr)
  lcd.drawText(UI.COL2, y, field.value or "", attr)
end

local function fieldFolderDisplay(field, y, attr)
  lcd.drawText(UI.COL1, y, "> " .. field.name, attr + BOLD)
end

local function fieldCommandDisplay(field, y, attr)
  lcd.drawText(10, y, "[" .. field.name .. "]", attr + BOLD)
end

local displayHandlers = {}
displayHandlers[crsf.CONST.FIELD_UINT8] = fieldIntDisplay
displayHandlers[crsf.CONST.FIELD_INT8] = fieldIntDisplay
displayHandlers[crsf.CONST.FIELD_UINT16] = fieldIntDisplay
displayHandlers[crsf.CONST.FIELD_INT16] = fieldIntDisplay
displayHandlers[crsf.CONST.FIELD_FLOAT] = fieldFloatDisplay
displayHandlers[crsf.CONST.FIELD_TEXT_SELECTION] = fieldTextSelDisplay
displayHandlers[crsf.CONST.FIELD_STRING] = fieldStringDisplay
displayHandlers[crsf.CONST.FIELD_INFO] = fieldStringDisplay
displayHandlers[crsf.CONST.FIELD_FOLDER] = fieldFolderDisplay
displayHandlers[crsf.CONST.FIELD_COMMAND] = fieldCommandDisplay
displayHandlers[App.DEVICE] = fieldCommandDisplay
displayHandlers[App.DEVICE_FOLDER] = fieldFolderDisplay

-- ============================================================================
-- Title bar drawing
-- ============================================================================

function UI.drawTitle()
  local barHeight = 9
  local goodBadPkt = ""
  local status = session.status
  if status.receivedPackets then
    local state = status.connected and "C" or "-"
    goodBadPkt = string.format("%u/%u   %s", status.lostPackets, status.receivedPackets, state)
  end

  local loaded, total = session:folderLoadProgress(Navigation.getCurrent())
  if not UI.titleShowWarn then
    lcd.drawText(LCD_W - 1, 1, goodBadPkt, RIGHT)
    lcd.drawLine(LCD_W - 10, 0, LCD_W - 10, barHeight - 1, SOLID, INVERS)
  end

  if loaded and total and total > 0 and loaded < total then
    lcd.drawFilledRectangle(UI.COL2, 0, LCD_W, barHeight, GREY_DEFAULT)
    lcd.drawGauge(0, 0, UI.COL2, barHeight, loaded, total, 0)
  else
    lcd.drawFilledRectangle(0, 0, LCD_W, barHeight, GREY_DEFAULT)
    if UI.titleShowWarn then
      lcd.drawText(UI.COL1, 1, session.status.warning, INVERS)
    else
      lcd.drawText(UI.COL1, 1, session.deviceName or "Searching...", INVERS)
    end
  end
end

-- ============================================================================
-- Warning display
-- ============================================================================

function UI.drawWarning()
  lcd.drawText(UI.COL1, UI.textSize * 2, "Error:")
  lcd.drawText(UI.COL1, UI.textSize * 3, session.status.warning)
  lcd.drawText(LCD_W / 2, UI.textSize * 5, "[OK]", BLINK + INVERS + CENTER)
end

-- ============================================================================
-- Event handling
-- ============================================================================

function UI.handleEvent(event)
  if event == EVT_VIRTUAL_EXIT then
    if UI.edit then
      UI.edit = nil
      local field = UI.getField(UI.lineIndex)
      if field and field.id then
        session:reloadField(field)
      end
    else
      UI.handleBack()
    end
  elseif event == EVT_VIRTUAL_ENTER then
    if session.status.flags > crsf.CONST.ELRS_FLAGS_WARNING_THRESHOLD then
      session:suppressCriticalErrors()
    elseif UI.isOnBackExit() then
      if Navigation.isAtRoot() then
        App.shouldExit = true
      else
        UI.handleBack()
      end
    else
      local field = UI.getField(UI.lineIndex)
      if field and field.name then
        local ft = field.type

        if ft == crsf.CONST.FIELD_FOLDER then
          UI.openFolder(field.id, field.name)
        elseif ft == App.DEVICE_FOLDER then
          UI.openFolder(Navigation.FOLDER_OTHER_DEVICES, "Other Devices")
        elseif ft == App.DEVICE then
          UI.switchDevice(field.id)
        elseif ft == crsf.CONST.FIELD_COMMAND then
          session:execCommand(field)
        elseif not field.disabled and ft <= crsf.CONST.FIELD_TEXT_SELECTION then
          UI.edit = not UI.edit
          if not UI.edit then
            session:writeField(field)
          end
        end
      end
    end
  elseif UI.edit then
    if event == EVT_VIRTUAL_NEXT then
      UI.incrField(1)
    elseif event == EVT_VIRTUAL_PREV then
      UI.incrField(-1)
    end
  else
    if event == EVT_VIRTUAL_NEXT then
      UI.selectField(1)
    elseif event == EVT_VIRTUAL_PREV then
      UI.selectField(-1)
    end
  end
end

-- ============================================================================
-- Main page rendering
-- ============================================================================

function UI.drawPage(event)
  UI.handleEvent(event)

  lcd.clear()
  UI.drawTitle()

  if session.status.flags > crsf.CONST.ELRS_FLAGS_WARNING_THRESHOLD then
    UI.drawWarning()
  else
    local totalCount = UI.getSelectableCount()
    for y = 1, UI.maxLineIndex + 1 do
      local idx = UI.pageOffset + y
      if idx > totalCount then
        break
      end
      local yPos = y * UI.textSize + UI.textYoffset
      local isSelected = (UI.lineIndex == idx)
      local attr = isSelected and ((UI.edit and BLINK or 0) + INVERS) or 0

      if idx > UI.getFieldCount() then
        lcd.drawText(10, yPos, "[" .. UI.getBackExitLabel() .. "]", attr + BOLD)
      else
        local field = UI.getField(idx)
        if field and field.name then
          local ft = field.type
          if ft < crsf.CONST.FIELD_FOLDER or ft == crsf.CONST.FIELD_INFO then
            lcd.drawText(UI.COL1, yPos, field.name, 0)
          end
          local displayFn = displayHandlers[ft]
          if displayFn then
            displayFn(field, yPos, attr)
          end
        end
      end
    end
  end
end

-- ============================================================================
-- Command popup rendering
-- ============================================================================

function UI.drawPopup(event)
  local command = session.command
  if event == EVT_VIRTUAL_EXIT then
    local status = command.status
    if status ~= crsf.CONST.CMD_ASKCONFIRM and status ~= crsf.CONST.CMD_EXECUTING then
      -- No dialog is on screen yet (e.g. CMD_CLICK just went out): request the
      -- cancel but keep the popup up until the device reports CMD_IDLE. The
      -- dialog branches below handle their own cancel via popupConfirmation.
      session:requestCancelCommand()
    end
  end

  if command.status == crsf.CONST.CMD_ASKCONFIRM then
    local result = popupConfirmation(command.info or "", "PRESS [OK] to confirm", event)
    if result == "OK" then
      session:confirmCommand()
    elseif result == "CANCEL" then
      session:cancelCommand()
    end
  elseif command.status == crsf.CONST.CMD_EXECUTING then
    if not session:isReceivingChunks() then
      UI.commandRunningIndicator = (UI.commandRunningIndicator % 4) + 1
    end
    local result = popupConfirmation(
      (command.info or "") .. " [" .. string.sub("|/-\\", UI.commandRunningIndicator, UI.commandRunningIndicator) .. "]",
      "Press [RTN] to exit",
      event
    )
    if result == "CANCEL" then
      session:cancelCommand()
    end
  end
end

return UI
