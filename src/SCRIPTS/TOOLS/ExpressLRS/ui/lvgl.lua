---- #########################################################################
---- # LVGL UI: Color LCD rendering, dialogs, command pages               #
---- # For color LCD radios with EdgeTX 2.12.1+ LVGL support              #
---- #########################################################################

local deps = ...

local App = deps.App
local Navigation = deps.Navigation
local session = deps.session
local crsf = deps.crsf
local VERSION = deps.VERSION

local SharedDialogs = loadScript("/SCRIPTS/ELRS/ui/lvgl/dialogs.lua")()

-- ============================================================================
-- UI state
-- ============================================================================

local UI = {
  currentPage = nil,
  uiBuilt = false,
  folderWasReady = false,

  -- Warning/command state (LVGL-specific). cmdLastStatus remembers which
  -- command status the current dialog was built for, so a status change
  -- swaps the dialog exactly once.
  warningDismissedAt = nil,
  warningDialog = nil,
  commandDialog = nil,
  cmdLastStatus = nil,
}

-- ============================================================================
-- Dialogs Module: Generic LVGL wrappers
-- ============================================================================

local Dialogs = {}

function Dialogs.showConfirm(options)
  return lvgl.confirm({
    title = options.title,
    message = options.message,
    confirm = options.onConfirm,
    cancel = options.onCancel,
  })
end

function Dialogs.showMessage(options)
  return lvgl.message({
    title = options.title,
    message = options.message,
  })
end

-- ============================================================================
-- ModelMismatchDialog
-- ============================================================================

local ModelMismatchDialog = {}

function ModelMismatchDialog.show(onContinue, onExit)
  local dg = lvgl.dialog({
    title = "Model Mismatch",
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = lvgl.PAD_SMALL,
  })

  dg:build({
    {
      type = lvgl.BOX,
      x = 10,
      flexFlow = lvgl.FLOW_COLUMN,
      flexPad = lvgl.PAD_SMALL,
      children = {
        { type = lvgl.LABEL, text = "Receiver connected but Model ID doesn't match." },
        { type = lvgl.LABEL, text = "RC commands are blocked until resolved." },
        { type = lvgl.LABEL, text = "Toggle the Model Match setting to" },
        { type = lvgl.LABEL, text = "re-sync, or change the EdgeTX model." },
      },
    },
    {
      type = lvgl.BOX,
      w = lvgl.PERCENT_SIZE + 100,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_SMALL,
      children = {
        {
          type = lvgl.BUTTON,
          w = lvgl.PERCENT_SIZE + 48,
          text = "Continue",
          press = function()
            dg:close()
            onContinue()
          end,
        },
        {
          type = lvgl.BUTTON,
          w = lvgl.PERCENT_SIZE + 48,
          text = "Exit to Change Model",
          press = function()
            dg:close()
            onExit()
          end,
        },
      },
    },
  })

  return dg
end

-- ============================================================================
-- Startup dialogs (version gate, no module): SCRIPTS/ELRS/ui/lvgl/dialogs.lua
-- ============================================================================

local function exitTool()
  App.shouldExit = true
end

-- ============================================================================
-- CommandPage: Non-modal pages for command confirm/executing states
-- ============================================================================

local CommandPage = {}
local spinnerAngle = 0

local function createSpinner(parent)
  local r = 20
  local wrapper = parent:box({
    flexFlow = lvgl.FLOW_ROW,
    flexPad = lvgl.PAD_MEDIUM,
    color = COLOR_THEME_PRIMARY2,
    w = lvgl.PERCENT_SIZE + 100,
    align = CENTER,
  })
  wrapper:arc({
    radius = r,
    thickness = 4,
    rounded = true,
    color = COLOR_THEME_PRIMARY1,
    startAngle = function()
      spinnerAngle = (spinnerAngle + 8) % 360
      return spinnerAngle
    end,
    endAngle = function()
      return spinnerAngle + 120
    end,
  })
end

function CommandPage.showConfirm(name, getInfo, onConfirm, onCancel)
  lvgl.clear()
  local pg = lvgl.page({
    title = "ExpressLRS",
    subtitle = "Send command",
    back = onCancel,
  })

  local container = pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = lvgl.PAD_MEDIUM,
    align = CENTER,
    borderPad = { left = lvgl.PAD_TINY, right = lvgl.PAD_TINY },
  })

  container:build({
    {
      type = lvgl.RECTANGLE,
      w = lvgl.PERCENT_SIZE + 100,
      h = lvgl.PAD_LARGE,
      thickness = 0,
    },
    {
      type = lvgl.LABEL,
      w = lvgl.PERCENT_SIZE + 100,
      align = CENTER,
      font = BOLD,
      text = name or "Command",
    },
    {
      type = lvgl.LABEL,
      w = lvgl.PERCENT_SIZE + 100,
      align = CENTER,
      color = COLOR_THEME_DISABLED,
      -- Prompt supplied by the caller as a getter so it refreshes each frame
      text = getInfo,
    },
    {
      type = lvgl.RECTANGLE,
      w = lvgl.PERCENT_SIZE + 100,
      h = lvgl.PAD_LARGE,
      thickness = 0,
    },
    {
      type = lvgl.BOX,
      w = lvgl.PERCENT_SIZE + 100,
      align = CENTER,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_SMALL,
      borderPad = lvgl.PAD_OUTLINE,
      children = {
        {
          type = lvgl.BUTTON,
          w = lvgl.PERCENT_SIZE + 49,
          text = "Confirm",
          press = onConfirm,
        },
        {
          type = lvgl.BUTTON,
          w = lvgl.PERCENT_SIZE + 49,
          text = "Cancel",
          press = onCancel,
        },
      },
    },
  })

  return pg
end

function CommandPage.showExecuting(title, getInfo, onCancel)
  lvgl.clear()
  local pg = lvgl.page({
    title = "ExpressLRS",
    subtitle = title or "Executing...",
    back = onCancel,
  })

  local container = pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = lvgl.PAD_MEDIUM,
    align = CENTER,
    borderPad = { left = lvgl.PAD_TINY, right = lvgl.PAD_TINY },
  })

  container:build({
    {
      type = lvgl.RECTANGLE,
      w = lvgl.PERCENT_SIZE + 100,
      h = lvgl.PAD_LARGE,
      thickness = 0,
    },
  })
  createSpinner(container)
  container:build({
    {
      type = lvgl.RECTANGLE,
      w = lvgl.PERCENT_SIZE + 100,
      h = lvgl.PAD_LARGE,
      thickness = 0,
    },
    {
      -- Live status text the device sends back while the command runs.
      -- Supplied by the caller as a getter so each CMD_QUERY poll response is shown.
      type = lvgl.LABEL,
      w = lvgl.PERCENT_SIZE + 100,
      align = CENTER,
      font = BOLD,
      text = getInfo,
    },
    {
      type = lvgl.RECTANGLE,
      w = lvgl.PERCENT_SIZE + 100,
      h = lvgl.PAD_LARGE,
      thickness = 0,
    },
    {
      type = lvgl.LABEL,
      w = lvgl.PERCENT_SIZE + 100,
      align = CENTER,
      color = COLOR_THEME_DISABLED,
      text = "Hold [RTN] to exit and keep running",
    },
    {
      type = lvgl.RECTANGLE,
      w = lvgl.PERCENT_SIZE + 100,
      h = lvgl.PAD_LARGE,
      thickness = 0,
    },
    {
      type = lvgl.BOX,
      w = lvgl.PERCENT_SIZE + 100,
      align = CENTER,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_SMALL,
      borderPad = lvgl.PAD_OUTLINE,
      children = {
        {
          type = lvgl.BUTTON,
          w = lvgl.PERCENT_SIZE + 100,
          text = "Cancel command",
          press = onCancel,
        },
      },
    },
  })

  return pg
end

-- ============================================================================
-- Interface: init
-- ============================================================================

function UI.init() end

-- ============================================================================
-- Interface: preCheck (version gate)
-- ============================================================================

function UI.preCheck(_event)
  if not deps.versionOk then
    if not UI.uiBuilt then
      SharedDialogs.showVersionRequired(exitTool)
      UI.uiBuilt = true
    end
    if App.shouldExit then
      return 2
    end
    return 0
  end

  return nil
end

-- ============================================================================
-- Interface: invalidate
-- ============================================================================

function UI.invalidate()
  UI.uiBuilt = false
end

-- ============================================================================
-- Interface: onDeviceLoaded
-- ============================================================================

function UI.onDeviceLoaded()
  UI.invalidate()
end

-- ============================================================================
-- Interface: onNewDevice
-- ============================================================================

function UI.onNewDevice()
  if Navigation.getCurrent() == Navigation.FOLDER_OTHER_DEVICES or UI.folderWasReady then
    UI.invalidate()
  end
end

-- ============================================================================
-- Interface: handleNoModule
-- ============================================================================

function UI.handleNoModule()
  if not UI.uiBuilt then
    SharedDialogs.showNoModule(exitTool)
    UI.uiBuilt = true
  end
end

-- ============================================================================
-- Interface: handleUnsupported
-- ============================================================================

function UI.handleUnsupported()
  if not UI.uiBuilt then
    Dialogs.showMessage({
      title = "Unsupported Firmware",
      message = "ELRS 1.x firmware detected. Please update to 3.x.",
    })
    UI.uiBuilt = true
  end
end

-- ============================================================================
-- User action handlers (call App for business logic)
-- ============================================================================

function UI.openFolder(folderId, folderName)
  -- The subtitle shows the folder name without the dynamic value suffix
  -- ExpressLRS embeds in it (e.g. "VTX Admin (R:4:2:P)").
  if folderName then
    local par = string.find(folderName, " (", 1, true)
    if par then
      folderName = string.sub(folderName, 1, par - 1)
    end
  end
  App.enterFolder(folderId, folderName)
  UI.invalidate()
end

function UI.switchDevice(deviceId)
  if App.switchDevice(deviceId) then
    UI.invalidate()
  end
end

function UI.handleBack()
  if Navigation.isAtRoot() then
    Dialogs.showConfirm({
      title = "Exit",
      message = "Exit ExpressLRS Lua script?",
      onConfirm = function()
        App.shouldExit = true
      end,
    })
  else
    local entry = App.goBack()
    if entry and entry.type == Navigation.TYPE_DEVICE and entry.prevDeviceId then
      local prevDevice = session:getDevice(entry.prevDeviceId)
      if prevDevice then
        session:setDevice(prevDevice)
      end
    end
    UI.invalidate()
  end
end

-- ============================================================================
-- Command popup handling
-- ============================================================================

local function onCommandCancel()
  session:cancelCommand()
  UI.commandDialog = nil
  UI.invalidate()
end

local function handleCommandPopup()
  local command = session.command
  if not command then
    if UI.commandDialog then
      UI.commandDialog = nil
      UI.invalidate()
    end
    UI.cmdLastStatus = nil
    return
  end

  if command.status == crsf.CONST.CMD_ASKCONFIRM then
    if not UI.commandDialog or UI.cmdLastStatus ~= crsf.CONST.CMD_ASKCONFIRM then
      UI.commandDialog = CommandPage.showConfirm(command.name, function()
        return command.info or ""
      end, function()
        session:confirmCommand()
      end, onCommandCancel)
    end
  elseif command.status == crsf.CONST.CMD_EXECUTING then
    if not UI.commandDialog or UI.cmdLastStatus ~= crsf.CONST.CMD_EXECUTING then
      UI.commandDialog = CommandPage.showExecuting(command.name, function()
        return command.info or ""
      end, onCommandCancel)
    end
  end
  UI.cmdLastStatus = command.status
end

-- ============================================================================
-- Warning handling
-- ============================================================================

local function handleWarning()
  if App.shouldExit then
    return
  end
  if session.status.flags > crsf.CONST.ELRS_FLAGS_STATUS_MASK then
    if not UI.warningDialog and not UI.warningDismissedAt then
      if session.status.modelMismatch then
        UI.warningDialog = ModelMismatchDialog.show(function()
          UI.warningDismissedAt = getTime()
          UI.invalidate()
        end, function()
          App.shouldExit = true
        end)
      elseif session.status.criticalError then
        Dialogs.showMessage({
          title = "Warning",
          message = session.status.warning,
        })
        UI.warningDialog = true
        UI.warningDismissedAt = getTime()
      end
    end
    if UI.warningDismissedAt and getTime() - UI.warningDismissedAt > 6000 then
      UI.warningDismissedAt = nil
      UI.warningDialog = nil
    end
  else
    UI.warningDialog = nil
    if UI.warningDismissedAt and getTime() - UI.warningDismissedAt > 6000 then
      UI.warningDismissedAt = nil
    end
  end
end

-- ============================================================================
-- Interface: render
-- ============================================================================

function UI.render(_event, _touchState)
  handleCommandPopup()

  if not UI.commandDialog then
    handleWarning()

    if not UI.uiBuilt and session.fieldsCount > 0 then
      UI.build()
    end
  end
end

-- ============================================================================
-- Subtitle builder
-- ============================================================================

function UI.getSubtitle()
  if not Navigation.isAtRoot() then
    local top = Navigation.stack[#Navigation.stack]
    local subtitleParts = { top.name or "" }

    local loaded, total = session:folderLoadProgress(Navigation.getCurrent())
    if loaded and loaded < total then
      subtitleParts[#subtitleParts + 1] = string.format(" • Loading %d%%", math.floor(loaded / total * 100))
    end

    return table.concat(subtitleParts)
  end

  local loaded, total = session:folderLoadProgress(nil)
  if loaded and loaded < total and session.fieldsCount > 0 then
    return string.format("Loading %d%%", math.floor(loaded / total * 100))
  end

  local status = session.status
  local subtitle = ""
  if status.receivedPackets then
    local state = status.connected and "Telemetry OK" or "No telemetry"
    subtitle = string.format("%u/%u • %s", status.lostPackets, status.receivedPackets, state)
  end

  if status.flags > crsf.CONST.ELRS_FLAGS_STATUS_MASK and status.warning and status.warning ~= "" then
    if subtitle ~= "" then
      subtitle = table.concat({ subtitle, " • ", status.warning })
    else
      subtitle = status.warning
    end
  end

  return subtitle
end

-- ============================================================================
-- Field value increment
-- ============================================================================

function UI.isBooleanField(field)
  if not field.values or #field.values ~= 2 then
    return false
  end
  return field.values[1] == "Off" and field.values[2] == "On"
end

-- ============================================================================
-- Widget creators
-- ============================================================================

local IS_NARROW = LCD_W < 400
local LABEL_PCT = lvgl.PERCENT_SIZE + (IS_NARROW and 42 or 50)
local VALUE_PCT = lvgl.PERCENT_SIZE + (IS_NARROW and 58 or 50)

function UI.createToggleRow(pg, field)
  pg:setting({
    w = lvgl.PERCENT_SIZE + 100,
    title = field.name,
    visible = function()
      return not field.hidden
    end,
    children = {
      {
        type = lvgl.BOX,
        x = LABEL_PCT,
        flexFlow = lvgl.FLOW_ROW,
        flexPad = lvgl.PAD_MEDIUM,
        align = LEFT,
        children = {
          {
            type = lvgl.TOGGLE,
            get = function()
              return field.value or 0
            end,
            set = function(val)
              field.value = val
              session:writeField(field)
            end,
            active = function()
              return not field.disabled
            end,
          },
          {
            type = lvgl.BOX,
            h = lvgl.UI_ELEMENT_HEIGHT,
            children = {
              {
                type = lvgl.LABEL,
                y = lvgl.PAD_MEDIUM,
                text = function()
                  return field.unit or ""
                end,
              },
            },
          },
        },
      },
    },
  })
end

function UI.createChoiceRow(pg, field)
  local valuesRef = field.valuesRev
  local choiceWidget

  local setting = pg:setting({
    w = lvgl.PERCENT_SIZE + 100,
    title = field.name,
    visible = function()
      if field.hidden then
        return false
      end
      -- The values table is refilled in place (identity is stable); the
      -- codec bumps valuesRev when the contents change.
      if field.valuesRev ~= valuesRef then
        valuesRef = field.valuesRev
        if choiceWidget then
          choiceWidget:set({ values = field.values or {} })
        end
      end
      return true
    end,
  })

  local valueBox = setting:box({
    x = LABEL_PCT,
    flexFlow = lvgl.FLOW_ROW,
    flexPad = lvgl.PAD_MEDIUM,
    align = LEFT,
  })

  choiceWidget = valueBox:choice({
    title = field.name,
    values = field.values or {},
    filter = function(index)
      return (field.values and field.values[index] or "") ~= ""
    end,
    get = function()
      return (field.value or 0) + 1
    end,
    set = function(val)
      field.value = val - 1
      session:writeField(field)
    end,
    active = function()
      return not field.disabled
    end,
  })

  valueBox:build({
    {
      type = lvgl.BOX,
      h = lvgl.UI_ELEMENT_HEIGHT,
      children = {
        {
          type = lvgl.LABEL,
          y = lvgl.PAD_MEDIUM,
          text = function()
            return field.unit or ""
          end,
        },
      },
    },
  })
end

function UI.createNumberRow(pg, field)
  local isFloat = field.type == crsf.CONST.FIELD_FLOAT
  local numberEdit = {
    type = lvgl.NUMBER_EDIT,
    min = field.min or 0,
    max = field.max or 255,
    get = function()
      return field.value or 0
    end,
    set = function(val)
      field.value = val
    end,
    edited = function(val)
      field.value = val
      session:writeField(field)
    end,
    display = function(val)
      if isFloat then
        return string.format(field.fmt or "%.0f", val / (field.prec or 1))
      end
      return tostring(val)
    end,
    active = function()
      return not field.disabled
    end,
  }

  local children
  if field.unit then
    children = {
      {
        type = lvgl.BOX,
        x = LABEL_PCT,
        flexFlow = lvgl.FLOW_ROW,
        flexPad = lvgl.PAD_MEDIUM,
        align = LEFT,
        children = {
          numberEdit,
          {
            type = lvgl.BOX,
            h = lvgl.UI_ELEMENT_HEIGHT,
            children = {
              {
                type = lvgl.LABEL,
                y = lvgl.PAD_MEDIUM,
                text = function()
                  return field.unit or ""
                end,
              },
            },
          },
        },
      },
    }
  else
    numberEdit.x = LABEL_PCT
    children = { numberEdit }
  end

  pg:setting({
    w = lvgl.PERCENT_SIZE + 100,
    title = field.name,
    visible = function()
      return not field.hidden
    end,
    children = children,
  })
end

function UI.createInfoRow(pg, field)
  pg:build({
    {
      type = lvgl.SETTING,
      w = lvgl.PERCENT_SIZE + 100,
      title = field.name,
      visible = function()
        return not field.hidden
      end,
      children = {
        {
          type = lvgl.LABEL,
          x = LABEL_PCT,
          text = function()
            return field.value or ""
          end,
        },
      },
    },
  })
end

function UI.createStringRow(pg, field)
  pg:build({
    {
      type = lvgl.SETTING,
      w = lvgl.PERCENT_SIZE + 100,
      title = field.name,
      visible = function()
        return not field.hidden
      end,
      children = {
        {
          type = lvgl.TEXT_EDIT,
          x = LABEL_PCT,
          w = VALUE_PCT,
          value = field.value or "",
          length = math.min(math.max(field.maxlen or 32, 32), 128),
          set = function(val)
            field.value = val
            session:writeField(field)
          end,
          active = function()
            return not field.disabled
          end,
        },
      },
    },
  })
end

function UI.createFolderWidget(pg, field, width)
  pg:button({
    text = function()
      return field.name or ""
    end,
    visible = function()
      return not field.hidden
    end,
    w = width or (lvgl.PERCENT_SIZE + 100),
    h = lvgl.UI_ELEMENT_HEIGHT * 2,
    press = function()
      UI.openFolder(field.id, field.name)
    end,
  })
end

function UI.createCommandWidget(pg, field)
  local wrapper = pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    flexFlow = lvgl.FLOW_COLUMN,
    align = CENTER,
    borderPad = { top = lvgl.PAD_TINY, bottom = lvgl.PAD_TINY },
    visible = function()
      return not field.hidden
    end,
  })
  wrapper:button({
    text = function()
      return field.name or ""
    end,
    w = lvgl.PERCENT_SIZE + 99,
    press = function()
      session:execCommand(field)
    end,
  })
end

function UI.buildFieldWidget(pg, field)
  if not field then
    return
  end

  local fieldType = field.type

  if fieldType == crsf.CONST.FIELD_COMMAND then
    return UI.createCommandWidget(pg, field)
  end

  if fieldType <= crsf.CONST.FIELD_INT16 or fieldType == crsf.CONST.FIELD_FLOAT then
    return UI.createNumberRow(pg, field)
  end

  if fieldType == crsf.CONST.FIELD_TEXT_SELECTION then
    if UI.isBooleanField(field) then
      return UI.createToggleRow(pg, field)
    else
      return UI.createChoiceRow(pg, field)
    end
  end

  if fieldType == crsf.CONST.FIELD_STRING then
    return UI.createStringRow(pg, field)
  end

  if fieldType == crsf.CONST.FIELD_INFO then
    return UI.createInfoRow(pg, field)
  end
end

-- ============================================================================
-- Main build function
-- ============================================================================

function UI.build()
  lvgl.clear()

  local pageOptions = {
    title = "ExpressLRS",
    subtitle = UI.getSubtitle,
  }

  if not Navigation.isAtRoot() then
    pageOptions.backButton = true
    pageOptions.back = function()
      UI.handleBack()
    end
  else
    pageOptions.back = UI.handleBack
  end

  UI.currentPage = lvgl.page(pageOptions)

  local fieldContainer = UI.currentPage:box({
    w = lvgl.PERCENT_SIZE + 100,
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = lvgl.PAD_OUTLINE,
  })

  local currentFolder = Navigation.getCurrent()

  if currentFolder == Navigation.FOLDER_OTHER_DEVICES then
    local devicesBox = fieldContainer:box({
      w = lvgl.PERCENT_SIZE + 100,
      flexFlow = lvgl.FLOW_COLUMN,
      flexPad = lvgl.PAD_SMALL,
      borderPad = lvgl.PAD_TINY,
    })
    for _, device in ipairs(session.devices) do
      if device.id ~= session.deviceId then
        devicesBox:button({
          text = device.name or "Unknown",
          w = lvgl.PERCENT_SIZE + 100,
          press = function()
            UI.switchDevice(device.id)
          end,
        })
      end
    end
  else
    local fieldsInFolder = session:fieldsInFolder(currentFolder)

    if currentFolder == nil then
      UI.createInfoRow(fieldContainer, { name = "Device name", value = session.deviceName or "Searching..." })
    end

    local FOLDERS_PER_ROW = 2
    if IS_NARROW then
      FOLDERS_PER_ROW = 1
    elseif LCD_W >= 800 then
      FOLDERS_PER_ROW = 3
    end
    local folderWidth = math.floor(100 / FOLDERS_PER_ROW) - 1
    local i = 1
    while i <= #fieldsInFolder do
      local field = fieldsInFolder[i]

      if field.type == crsf.CONST.FIELD_FOLDER then
        local folderBatch = {}
        while i <= #fieldsInFolder and fieldsInFolder[i].type == crsf.CONST.FIELD_FOLDER do
          folderBatch[#folderBatch + 1] = fieldsInFolder[i]
          i = i + 1
        end

        if FOLDERS_PER_ROW == 1 then
          for j = 1, #folderBatch do
            UI.createFolderWidget(fieldContainer, folderBatch[j])
          end
        else
          for j = 1, #folderBatch, FOLDERS_PER_ROW do
            local rowContainer = fieldContainer:box({
              w = lvgl.PERCENT_SIZE + 100,
              borderPad = lvgl.PAD_OUTLINE,
              flexFlow = lvgl.FLOW_ROW,
              flexPad = lvgl.PAD_SMALL,
              align = CENTER,
              color = COLOR_THEME_PRIMARY2,
            })

            for k = 0, FOLDERS_PER_ROW - 1 do
              local folderField = folderBatch[j + k]
              if folderField then
                UI.createFolderWidget(rowContainer, folderField, lvgl.PERCENT_SIZE + folderWidth)
              end
            end
          end
        end
      else
        UI.buildFieldWidget(fieldContainer, field)
        i = i + 1
      end
    end

    if currentFolder == nil and session.isElrsTx then
      UI.createInfoRow(fieldContainer, { name = "Lua script version", value = VERSION })
    end

    if currentFolder == nil and #session.devices > 1 and not Navigation.hasDeviceEntry() then
      local wrapper = fieldContainer:box({
        w = lvgl.PERCENT_SIZE + 100,
        flexFlow = lvgl.FLOW_COLUMN,
        align = CENTER,
        borderPad = lvgl.PAD_TINY,
      })
      wrapper:button({
        text = "Other Devices",
        w = lvgl.PERCENT_SIZE + 100,
        h = lvgl.UI_ELEMENT_HEIGHT * 2,
        press = function()
          UI.openFolder(Navigation.FOLDER_OTHER_DEVICES, "Other Devices")
        end,
      })
    end
  end

  fieldContainer:rectangle({
    w = lvgl.PERCENT_SIZE + 100,
    h = lvgl.PAD_SMALL,
    thickness = 0,
  })

  UI.uiBuilt = true
end

return UI
