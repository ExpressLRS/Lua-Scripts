---- #########################################################################
---- # LVGL UI: Color LCD rendering for the bind phrase manager             #
---- # For color LCD radios with EdgeTX 2.11.6+/2.12.1+ LVGL support        #
---- #########################################################################

local deps = ...

local App = deps.App
local crsf = deps.crsf
local msp = deps.msp

local SharedDialogs = loadScript("/SCRIPTS/ELRS/ui/lvgl/dialogs.lua")()

-- ============================================================================
-- UI state
-- ============================================================================

local UI = {
  -- App.rev the current page was built for; nil forces the first build.
  builtRev = nil,
  -- Guards the one-shot version/no-module dialogs.
  dialogBuilt = false,
}

-- Same split the config tool uses: label column, value column.
local IS_NARROW = LCD_W < 400
local LABEL_PCT = lvgl.PERCENT_SIZE + (IS_NARROW and 42 or 50)
local VALUE_PCT = lvgl.PERCENT_SIZE + (IS_NARROW and 58 or 50)
local FULL_PCT = lvgl.PERCENT_SIZE + 100

local TARGET_VALUES = { "Transmitter", "Receiver", "Both" }

-- ============================================================================
-- Main page
-- ============================================================================

local function exitTool()
  App.shouldExit = true
end

local function hasLink()
  return crsf.hasTelemetry
end

-- Own wrappers: lvgl calls a text getter with no arguments, and both
-- getters take a compact-format flag as their first parameter.
local function uidText()
  return App.uidText()
end

local function setLabel()
  return App.setLabel()
end

--- Bind is not an event that completes, it is a mode the module enters --
-- and the other half of the pairing is the user's to do, so the advice
-- belongs before the press rather than after it.
local function pressBind()
  lvgl.confirm({
    title = "Bind transmitter?",
    message = "The link drops while the transmitter binds. The receiver must be in bind mode too.",
    confirm = App.sendBind,
  })
end

local function pressUnbind()
  lvgl.confirm({
    title = "Unbind receiver?",
    message = "The link drops and the receiver waits for a bind. Put the transmitter in bind mode to re-pair.",
    confirm = App.sendUnbind,
  })
end

--- One label-and-value row, matching the config tool's info rows.
local function infoRow(parent, title, text)
  parent:setting({
    w = FULL_PCT,
    title = title,
    children = {
      { type = lvgl.LABEL, x = LABEL_PCT, text = text },
    },
  })
end

local function buildUi()
  lvgl.clear()

  -- The subtitle says what the tool is, not what it is doing: a header
  -- that changes meaning is what made the old UID line so hard to read.
  local pg = lvgl.page({
    title = "ExpressLRS",
    subtitle = "Bind phrase manager",
    back = exitTool,
  })

  local body = pg:box({
    w = FULL_PCT,
    flexFlow = lvgl.FLOW_COLUMN,
  })

  -- ***** What to send, and where *****
  body:setting({
    w = FULL_PCT,
    title = "Bind phrase",
    children = {
      {
        type = lvgl.TEXT_EDIT,
        x = LABEL_PCT,
        w = VALUE_PCT,
        value = App.phrase,
        -- A phrase must fit one un-chunked MSP_WRITE frame
        length = msp.CONST.PHRASE_MAX,
        set = function(v)
          App.phrase = v
        end,
      },
    },
  })

  body:setting({
    w = FULL_PCT,
    title = "Apply to",
    children = {
      {
        type = lvgl.CHOICE,
        x = LABEL_PCT,
        title = "Apply to",
        values = TARGET_VALUES,
        get = function()
          return App.target
        end,
        set = App.setTarget,
      },
    },
  })

  -- A row of its own: the write is the one action here that changes a
  -- device, and its label carries the sequence's progress.
  body:button({
    w = FULL_PCT,
    text = setLabel,
    press = App.sendSet,
    active = App.isSetEnabled,
  })

  -- ***** What the devices report back *****
  infoRow(body, "Transmitter", uidText)
  infoRow(body, "Receiver", App.receiverText)

  -- ***** Link actions *****
  local actions = body:box({
    w = FULL_PCT,
    flexFlow = lvgl.FLOW_ROW,
    flexPad = lvgl.PAD_MEDIUM,
  })
  actions:button({
    w = lvgl.PERCENT_SIZE + 49,
    text = "Bind",
    press = pressBind,
  })
  actions:button({
    w = lvgl.PERCENT_SIZE + 49,
    text = "Unbind",
    press = pressUnbind,
    active = hasLink,
  })

  -- ***** History, last: it grows and the page scrolls *****
  local histSection = body:box({
    w = FULL_PCT,
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = 0,
    visible = function()
      return App.history.items[1] ~= nil
    end,
  })
  histSection:label({
    text = "Bind phrase history",
    w = FULL_PCT,
    align = CENTER,
  })
  for i = 1, App.history.MAX do
    local row = histSection:box({
      w = FULL_PCT,
      flexFlow = lvgl.FLOW_ROW,
      flexPad = lvgl.PAD_SMALL,
      visible = function()
        return App.history.items[i] ~= nil
      end,
    })
    -- Fills the phrase field; sending stays with the Set button
    row:button({
      w = lvgl.PERCENT_SIZE + 80,
      text = function()
        return App.history.items[i] or ""
      end,
      press = function()
        App.useHistory(i)
      end,
    })
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

function UI.init() end

-- ============================================================================
-- Interface: preCheck (version gate)
-- ============================================================================

function UI.preCheck(_event)
  if not deps.versionOk then
    if not UI.dialogBuilt then
      SharedDialogs.showVersionRequired(exitTool)
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
    SharedDialogs.showNoModule(exitTool)
    UI.dialogBuilt = true
  end
end

-- ============================================================================
-- Interface: render
-- ============================================================================

-- Rebuild whenever App.rev moved: TEXT_EDIT's value is a build-time
-- snapshot, so a history fill only shows through a fresh build. The UID
-- rows, status line and button states are live getters and never need one.
function UI.render(_event, _touchState)
  if UI.builtRev ~= App.rev then
    buildUi()
    UI.builtRev = App.rev
  end
end

return UI
