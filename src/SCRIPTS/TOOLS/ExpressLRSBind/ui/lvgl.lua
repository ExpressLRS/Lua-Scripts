---- #########################################################################
---- # LVGL UI: Color LCD rendering for the bind phrase manager             #
---- # For color LCD radios with EdgeTX 2.11.6+/2.12.1+ LVGL support        #
---- #########################################################################

local deps = ...

local App = deps.App
local crsf = deps.crsf
local msp = deps.msp

-- ============================================================================
-- UI state
-- ============================================================================

local UI = {
  -- App.rev the current page was built for; nil forces the first build.
  builtRev = nil,
  -- Guards the one-shot version/no-module dialogs.
  dialogBuilt = false,
}

-- ============================================================================
-- EdgeTX version gate
-- ============================================================================

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

local function showVersionRequired()
  lvgl.clear()

  local dg = lvgl.dialog({
    title = "EdgeTX Version Not Supported",
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = lvgl.PAD_SMALL,
    close = function()
      App.shouldExit = true
    end,
  })

  dg:build({
    {
      type = "box",
      x = 10,
      flexFlow = lvgl.FLOW_COLUMN,
      flexPad = lvgl.PAD_SMALL,
      children = {
        { type = "label", text = "Requires EdgeTX:" },
        { type = "label", text = "- 2.11.6 or later" },
        { type = "label", text = "- 2.12.1 or later" },
        { type = "label", text = "- 3.0 or later" },
      },
    },
    {
      type = "box",
      flexFlow = lvgl.FLOW_ROW,
      w = lvgl.PERCENT_SIZE + 100,
      align = CENTER,
      children = {
        {
          type = "button",
          text = "Exit",
          w = lvgl.PERCENT_SIZE + 98,
          press = function()
            dg:close()
            App.shouldExit = true
          end,
        },
      },
    },
  })
end

local function showNoModule()
  lvgl.clear()

  local dg = lvgl.dialog({
    title = "No Module Found: Check Model Settings",
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = lvgl.PAD_SMALL,
    close = function()
      App.shouldExit = true
    end,
  })

  dg:build({
    {
      type = lvgl.BOX,
      x = 10,
      flexFlow = lvgl.FLOW_COLUMN,
      flexPad = lvgl.PAD_SMALL,
      children = {
        { type = lvgl.LABEL, text = "- Internal/External module enabled" },
        { type = lvgl.LABEL, text = "- Protocol set to CRSF" },
      },
    },
    {
      type = lvgl.BOX,
      w = lvgl.PERCENT_SIZE + 100,
      align = CENTER,
      flexFlow = lvgl.FLOW_ROW,
      children = {
        {
          type = lvgl.BUTTON,
          w = lvgl.PERCENT_SIZE + 98,
          text = "Exit",
          press = function()
            dg:close()
            App.shouldExit = true
          end,
        },
      },
    },
  })
end

-- ============================================================================
-- Main page
-- ============================================================================

local function exitTool()
  App.shouldExit = true
end

local function isSetEnabled()
  return App.isTargetReachableOrBoth() and App.phrase ~= ""
end

local function isRxSelected()
  return App.target == App.TARGET_RX
end

local function isRxSelectedConnected()
  return App.target == App.TARGET_RX and crsf.hasTelemetry
end

local function isRxSelectedDisconnected()
  return App.target == App.TARGET_RX and not crsf.hasTelemetry
end

local function buildUi()
  lvgl.clear()

  local pg = lvgl.page({
    title = "ExpressLRS Bind Phrase",
    subtitle = App.uidLine,
    back = exitTool,
  })

  local tbox = pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    flexFlow = lvgl.FLOW_COLUMN,
  })

  -- ***** Bind Phrase label + text edit + Set button *****
  tbox:setting({
    w = lvgl.PERCENT_SIZE + 100,
    title = "Bind phrase",
    children = {
      {
        type = lvgl.BOX,
        x = 120 * lvgl.LCD_SCALE,
        flexFlow = lvgl.FLOW_ROW,
        flexPad = lvgl.PAD_MEDIUM,
        children = {
          {
            type = lvgl.TEXT_EDIT,
            w = 250 * lvgl.LCD_SCALE,
            value = App.phrase,
            -- A phrase must fit one un-chunked MSP_WRITE frame
            length = msp.CONST.PHRASE_MAX,
            set = function(v)
              App.phrase = v
            end,
            active = App.isTargetReachableOrBoth,
          },
          {
            type = lvgl.BUTTON,
            text = "Set",
            press = App.sendSet,
            active = isSetEnabled,
          },
        },
      },
    },
  })

  -- ***** Target label + dropdown + Request UID button *****
  tbox:setting({
    w = lvgl.PERCENT_SIZE + 100,
    title = "Target",
    children = {
      {
        type = lvgl.BOX,
        x = 120 * lvgl.LCD_SCALE,
        flexFlow = lvgl.FLOW_ROW,
        flexPad = lvgl.PAD_MEDIUM,
        children = {
          {
            type = lvgl.CHOICE,
            title = "Select Target",
            values = { "Transmitter", "Receiver", "Both" },
            get = function()
              return App.target
            end,
            set = function(n)
              App.target = n
            end,
          },
          {
            type = lvgl.BUTTON,
            text = "Request UID",
            press = App.startUidRequest,
            active = App.isTargetReachable,
          },
          {
            type = lvgl.BUTTON,
            text = "Unbind",
            press = App.sendUnbind,
            visible = isRxSelected,
            active = isRxSelectedConnected,
          },
        },
      },
    },
  })

  -- ***** Show Bind button if RX target selected and no RX connected *****
  pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    y = 2 * lvgl.UI_ELEMENT_HEIGHT + 4 * lvgl.PAD_MEDIUM,
    flexFlow = lvgl.FLOW_ROW,
    flexPad = lvgl.PAD_MEDIUM,
    align = LEFT,
    visible = isRxSelectedDisconnected,
    children = {
      {
        type = lvgl.LABEL,
        w = 4 + lvgl.LCD_SCALE * (120 + 250),
        text = " No receiver connected.\n Use Bind to set bindphrase if RX in bind mode",
      },
      {
        type = lvgl.BUTTON,
        text = "Bind",
        press = App.sendBind,
      },
    },
  })

  -- ***** Bind Phrase History *****
  local histSection = pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    y = 2 * lvgl.UI_ELEMENT_HEIGHT + 4 * lvgl.PAD_MEDIUM,
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = 0,
    visible = function()
      return App.history.items[1] ~= nil and App.isTargetReachableOrBoth()
    end,
  })
  histSection:label({
    text = "Bind Phrase History",
    w = lvgl.PERCENT_SIZE + 100,
    align = CENTER,
  })
  for i = 1, App.history.MAX do
    local row = histSection:box({
      w = lvgl.PERCENT_SIZE + 100,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_SMALL,
      visible = function()
        return App.history.items[i] ~= nil
      end,
    })
    -- Button containing a history item with its value
    row:button({
      w = lvgl.PERCENT_SIZE + 80,
      text = function()
        return App.history.items[i] or ""
      end,
      press = function()
        App.useHistory(i)
      end,
    })
    -- Button X to delete an item
    row:button({
      text = "X",
      textColor = COLOR_THEME_WARNING,
      press = function()
        App.removeHistory(i)
      end,
    })
  end
end

-- ============================================================================
-- Interface: init
-- ============================================================================

function UI.init()
  versionCheckResult = checkEdgeTxVersion()
end

-- ============================================================================
-- Interface: preCheck (version gate)
-- ============================================================================

function UI.preCheck(_event)
  if not versionCheckResult then
    if not UI.dialogBuilt then
      showVersionRequired()
      UI.dialogBuilt = true
    end
    if App.shouldExit then
      return 2
    end
    return 0
  end

  return nil
end

-- ============================================================================
-- Interface: handleNoModule
-- ============================================================================

function UI.handleNoModule()
  if not UI.dialogBuilt then
    showNoModule()
    UI.dialogBuilt = true
  end
end

-- ============================================================================
-- Interface: render
-- ============================================================================

-- Rebuild whenever App.rev moved: TEXT_EDIT's value is a build-time
-- snapshot, so a history fill or the Both flow's target flip only shows
-- through a fresh build.
function UI.render(_event, _touchState)
  if UI.builtRev ~= App.rev then
    buildUi()
    UI.builtRev = App.rev
  end
end

return UI
