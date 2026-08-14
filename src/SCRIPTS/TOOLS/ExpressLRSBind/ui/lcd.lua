---- #########################################################################
---- # BW LCD UI: Rendering, input handling, cursor management            #
---- # For black & white radios (no LVGL required)                        #
---- #########################################################################

local deps = ...

local App = deps.App
local crsf = deps.crsf
local msp = deps.msp
local VERSION = deps.VERSION

local TextEdit = loadScript("/SCRIPTS/ELRS/ui/lcd/text_edit.lua")()
local drawAlert = loadScript("/SCRIPTS/ELRS/ui/lcd/alert.lua")()

-- ============================================================================
-- UI state
-- ============================================================================

-- Cursor stop ids (numeric to save RAM). History items are HIST_BASE + i.
local ROW_PHRASE = 1
local ROW_TARGET = 2
local ROW_SET = 3
local ROW_BIND = 4
local ROW_UNBIND = 5
local ROW_HISTORY = 6
local ROW_EXIT = 7
local ROW_CLEAR = 8
local ROW_BACK = 9
local HIST_BASE = 100

local PAGE_MAIN = 1
local PAGE_HISTORY = 2

-- Short forms: "Transmitter" would truncate at COL2 on 128 px
local TARGET_NAMES = { "TX", "RX", "Both" }

local UI = {
  -- Cursor/selection state (owned entirely by this module)
  page = PAGE_MAIN,
  lineIndex = 1,
  rows = {},
  editTarget = nil,
  ---@type table constructed in init(), needs LCD_W for the window
  phraseEdit = nil,

  -- Pending confirmation popup: { msg, info, fn }. Only msg reaches the
  -- screen: EdgeTX's Lua binding sets warningInfoText without
  -- warningInfoLength, so the BW popup draws the info line zero chars wide
  -- (api_general.cpp luaPopupConfirmation). Keep msg under 24 chars --
  -- WARNING_LINE_LEN -- and say what matters there.
  confirm = nil,

  -- Layout constants for 128x64; UI.init widens COL2 at 212 px wide
  COL1 = 0,
  COL2 = 54,
  textSize = 8,
  textYoffset = 3,
  ---@type table row baselines, filled by init() for the screen height
  y = nil,

  -- Redraw state: the page repaints on events and whenever a live part of
  -- it changes (statusKey below), tracked as a string compare per frame.
  forceRedraw = true,
  lastStatus = nil,
}

-- 128x64 has room for three normal rows, the two report lines and one
-- action row, which is why the three actions share a line at SMLSIZE.
local Y_SHORT = { phrase = 9, target = 17, set = 25, tx = 34, rx = 41, actions = 48, exit = 56 }
local Y_TALL = { phrase = 10, target = 20, set = 30, tx = 44, rx = 52, actions = 62, exit = 76 }

-- ============================================================================
-- Interface: init
-- ============================================================================

function UI.init()
  if LCD_W == 212 then
    UI.COL2 = 110
  end
  UI.y = (LCD_H >= 96) and Y_TALL or Y_SHORT

  -- The phrase window ends at the cursor; 6 px per char of the fixed BW font
  UI.phraseEdit = TextEdit.new(msp.CONST.PHRASE_MAX, math.floor((LCD_W - UI.COL2 - 2) / 6))
  UI.phraseEdit.value = App.phrase
end

-- ============================================================================
-- Interface: preCheck (version gate)
-- ============================================================================

function UI.preCheck(event)
  if not deps.versionOk then
    drawAlert("Unsupported", {
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
-- Interface: handleNoModule
-- ============================================================================

function UI.handleNoModule()
  drawAlert(" No ExpressLRS", {
    "Enable a CRSF Internal",
    "  or External module in",
    "      Model settings",
    " If module is internal",
    "also set Internal RF to",
    "CRSF in SYS->Hardware",
  })
end

-- ============================================================================
-- Cursor stops
-- ============================================================================

local function buildRows()
  local rows = UI.rows
  for i = #rows, 1, -1 do
    rows[i] = nil
  end
  if UI.page == PAGE_MAIN then
    rows[1] = ROW_PHRASE
    rows[2] = ROW_TARGET
    rows[3] = ROW_SET
    rows[4] = ROW_BIND
    -- Unbind appears only with a receiver to unbind, so the cursor never
    -- lands on a dead action -- and Bind keeps its place either way.
    if crsf.hasTelemetry then
      rows[#rows + 1] = ROW_UNBIND
    end
    rows[#rows + 1] = ROW_HISTORY
    rows[#rows + 1] = ROW_EXIT
  else
    for i = 1, #App.history.items do
      rows[#rows + 1] = HIST_BASE + i
    end
    rows[#rows + 1] = ROW_CLEAR
    rows[#rows + 1] = ROW_BACK
  end
  if UI.lineIndex > #rows then
    UI.lineIndex = #rows
  end
end

-- ============================================================================
-- Navigation and actions
-- ============================================================================

local function selectRow(step)
  local count = #UI.rows
  local idx = UI.lineIndex + step
  if idx < 1 then
    idx = count
  elseif idx > count then
    idx = 1
  end
  UI.lineIndex = idx
end

local function goToPage(page)
  UI.page = page
  UI.lineIndex = 1
  UI.forceRedraw = true
end

local function handleEnter(id)
  if id == ROW_PHRASE then
    UI.phraseEdit.value = App.phrase
    UI.phraseEdit:start()
  elseif id == ROW_TARGET then
    UI.editTarget = true
  elseif id == ROW_SET then
    App.sendSet()
  elseif id == ROW_BIND then
    -- Bind is a mode the module enters, not an event that completes, and
    -- the other half of the pairing is the user's to do -- so the advice
    -- belongs before the press, not after it.
    UI.confirm = { msg = "Bind transmitter?", info = "Also bind the RX", fn = App.sendBind }
  elseif id == ROW_UNBIND then
    UI.confirm = { msg = "Unbind receiver?", info = "Link will drop", fn = App.sendUnbind }
  elseif id == ROW_HISTORY then
    goToPage(PAGE_HISTORY)
  elseif id == ROW_EXIT then
    App.shouldExit = true
  elseif id == ROW_CLEAR then
    UI.confirm = { msg = "Clear history?", info = "[OK] to confirm", fn = App.clearHistory }
  elseif id == ROW_BACK then
    goToPage(PAGE_MAIN)
  elseif id > HIST_BASE then
    App.useHistory(id - HIST_BASE)
    UI.phraseEdit.value = App.phrase
    goToPage(PAGE_MAIN)
  end
end

local function handleEvent(event)
  -- Phrase editing captures every event until it commits
  if UI.phraseEdit.editing then
    if UI.phraseEdit:handleEvent(event) then
      App.phrase = UI.phraseEdit.value
    end
    return
  end

  -- Target edit: rotary cycles, ENTER or EXIT commits
  if UI.editTarget then
    if event == EVT_VIRTUAL_NEXT then
      App.setTarget(math.min(App.target + 1, App.TARGET_BOTH))
    elseif event == EVT_VIRTUAL_PREV then
      App.setTarget(math.max(App.target - 1, App.TARGET_TX))
    elseif event == EVT_VIRTUAL_ENTER or event == EVT_VIRTUAL_EXIT then
      UI.editTarget = nil
    end
    return
  end

  if event == EVT_VIRTUAL_EXIT then
    if UI.page == PAGE_HISTORY then
      goToPage(PAGE_MAIN)
    else
      App.shouldExit = true
    end
  elseif event == EVT_VIRTUAL_ENTER then
    handleEnter(UI.rows[UI.lineIndex])
  elseif event == EVT_VIRTUAL_ENTER_LONG then
    killEvents(event)
    local id = UI.rows[UI.lineIndex]
    if id and id > HIST_BASE then
      local i = id - HIST_BASE
      UI.confirm = {
        msg = "Delete entry?",
        info = "[OK] to confirm",
        fn = function()
          App.removeHistory(i)
        end,
      }
    end
  elseif event == EVT_VIRTUAL_NEXT then
    selectRow(1)
  elseif event == EVT_VIRTUAL_PREV then
    selectRow(-1)
  end
end

-- ============================================================================
-- Rendering
-- ============================================================================

local function drawTitle()
  lcd.drawFilledRectangle(0, 0, LCD_W, UI.textSize + 1, GREY_DEFAULT)
  lcd.drawText(UI.COL1 + 1, 1, "ELRS Bind " .. VERSION, INVERS)
  -- Link flag: C while RX telemetry is alive, - otherwise
  lcd.drawText(LCD_W - 1, 1, crsf.hasTelemetry and "C" or "-", INVERS + RIGHT)
end

local function attrFor(id)
  return (UI.rows[UI.lineIndex] == id) and INVERS or 0
end

local function drawMain()
  local y = UI.y

  lcd.drawText(UI.COL1, y.phrase, "Phrase", 0)
  UI.phraseEdit:draw(UI.COL2, y.phrase, attrFor(ROW_PHRASE))

  local targetAttr = attrFor(ROW_TARGET)
  if UI.editTarget then
    targetAttr = targetAttr + BLINK
  end
  lcd.drawText(UI.COL1, y.target, "Apply to", 0)
  lcd.drawText(UI.COL2, y.target, TARGET_NAMES[App.target], targetAttr)

  -- The one action that changes a device: its own row, and its label
  -- doubles as the write sequence's progress
  local setAttr = attrFor(ROW_SET)
  if App.isSetEnabled() then
    setAttr = setAttr + BOLD
  end
  lcd.drawText(LCD_W / 2, y.set, "[" .. App.setLabel(true) .. "]", setAttr + CENTER)

  -- What the devices report back
  lcd.drawText(UI.COL1, y.tx, "TX " .. App.uidText(true), SMLSIZE)
  lcd.drawText(UI.COL1, y.rx, "RX " .. App.receiverText(), SMLSIZE)

  lcd.drawText(UI.COL1 + 1, y.actions, "[Bind]", attrFor(ROW_BIND) + SMLSIZE)
  if crsf.hasTelemetry then
    lcd.drawText(math.floor(LCD_W * 0.3), y.actions, "[Unbind]", attrFor(ROW_UNBIND) + SMLSIZE)
  end
  lcd.drawText(LCD_W - 1, y.actions, "[History]", attrFor(ROW_HISTORY) + SMLSIZE + RIGHT)

  lcd.drawText(LCD_W / 2, y.exit, "[---- EXIT ----]", attrFor(ROW_EXIT) + BOLD + CENTER)
end

local function drawHistory()
  for i = 1, #UI.rows do
    local id = UI.rows[i]
    local yPos = i * UI.textSize + UI.textYoffset
    local attr = (UI.lineIndex == i) and INVERS or 0
    if id == ROW_CLEAR then
      lcd.drawText(10, yPos, "[Clear All]", attr + BOLD)
    elseif id == ROW_BACK then
      lcd.drawText(10, yPos, "[---- BACK ----]", attr + BOLD)
    else
      lcd.drawText(UI.COL1, yPos, App.history.items[id - HIST_BASE] or "", attr)
    end
  end
end

local function drawPage(event)
  handleEvent(event)
  buildRows()

  lcd.clear()
  drawTitle()

  if UI.page == PAGE_MAIN then
    drawMain()
  else
    drawHistory()
  end
end

-- ============================================================================
-- Interface: render
-- ============================================================================

--- Everything on the page that can change without an event: repainting on
-- a change keeps the UID rows and status live without repainting at frame
-- rate.
local function statusKey()
  return App.setLabel(true) .. App.uidText(true) .. (crsf.hasTelemetry and "C" or "-")
end

function UI.render(event, _touchState)
  -- Pending confirmation owns the screen until answered. It arms only after
  -- a quiet frame: the ENTER release that follows the press which opened it
  -- would otherwise answer it on the spot.
  if UI.confirm then
    local result = popupConfirmation(UI.confirm.msg, UI.confirm.info, event)
    if not UI.confirm.armed then
      if event == 0 then
        UI.confirm.armed = true
      end
      return
    end
    if result == "OK" then
      UI.confirm.fn()
      UI.confirm = nil
      UI.forceRedraw = true
    elseif result == "CANCEL" then
      UI.confirm = nil
      UI.forceRedraw = true
    end
    return
  end

  local status = statusKey()
  if event ~= 0 or UI.forceRedraw or UI.phraseEdit.editing or status ~= UI.lastStatus then
    drawPage(event)
    UI.lastStatus = status
    UI.forceRedraw = false
  end
end

return UI
