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

-- Row ids (numeric to save RAM). History items are encoded as HIST_BASE + i.
local ROW_PHRASE = 1
local ROW_TARGET = 2
local ROW_UID = 3
local ROW_SET = 4
local ROW_BIND = 5 -- renders Bind or Unbind depending on the link
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

  -- Pending confirmation popup: { msg, i (history index) or nil = clear all }
  confirm = nil,

  -- Layout constants for 128x64; UI.init widens COL2 at 212px wide
  COL1 = 0,
  COL2 = 70,
  textSize = 8,
  textYoffset = 3,

  -- Redraw state: the page repaints on events and whenever the live status
  -- line changes (statusLine below), tracked as a string compare per frame.
  forceRedraw = true,
  lastStatus = nil,
}

-- Both pages fit the 8-row 128x64 grid (main 7 rows, history at most 7),
-- so there is no scrolling and no page offset in this UI.

-- ============================================================================
-- Interface: init
-- ============================================================================

function UI.init()
  if LCD_W == 212 then
    UI.COL2 = 110
  end

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
-- Row list
-- ============================================================================

local function buildRows()
  local rows = UI.rows
  for i = #rows, 1, -1 do
    rows[i] = nil
  end
  if UI.page == PAGE_MAIN then
    rows[1] = ROW_PHRASE
    rows[2] = ROW_TARGET
    rows[3] = ROW_UID
    rows[4] = ROW_SET
    if App.target == App.TARGET_RX then
      rows[5] = ROW_BIND
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

--- The UID/status row text: compact so it fits 128 px at SMLSIZE.
local function statusLine()
  if App.statusText then
    return App.statusText
  end
  local u = App.uid
  local prefix = (App.uidFrom == crsf.CONST.ADDRESS_RX) and "RX" or "TX"
  return string.format("%s: %d,%d,%d,%d,%d,%d", prefix, u[1], u[2], u[3], u[4], u[5], u[6])
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
    if App.isTargetReachableOrBoth() then
      UI.phraseEdit.value = App.phrase
      UI.phraseEdit:start()
    end
  elseif id == ROW_TARGET then
    UI.editTarget = true
  elseif id == ROW_UID then
    App.startUidRequest()
  elseif id == ROW_SET then
    if App.isTargetReachableOrBoth() and App.phrase ~= "" then
      App.sendSet()
    end
  elseif id == ROW_BIND then
    if crsf.hasTelemetry then
      App.sendUnbind()
    else
      App.sendBind()
    end
  elseif id == ROW_HISTORY then
    goToPage(PAGE_HISTORY)
  elseif id == ROW_EXIT then
    App.shouldExit = true
  elseif id == ROW_CLEAR then
    UI.confirm = { msg = "Clear history?" }
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
      App.target = math.min(App.target + 1, App.TARGET_BOTH)
    elseif event == EVT_VIRTUAL_PREV then
      App.target = math.max(App.target - 1, App.TARGET_TX)
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
      UI.confirm = { msg = "Delete entry?", i = id - HIST_BASE }
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

local function drawRow(id, yPos, isSelected)
  local attr = isSelected and INVERS or 0
  if id == ROW_PHRASE then
    lcd.drawText(UI.COL1, yPos, "Phrase", 0)
    UI.phraseEdit:draw(UI.COL2, yPos, attr)
  elseif id == ROW_TARGET then
    if UI.editTarget and isSelected then
      attr = attr + BLINK
    end
    lcd.drawText(UI.COL1, yPos, "Target", 0)
    lcd.drawText(UI.COL2, yPos, TARGET_NAMES[App.target], attr)
  elseif id == ROW_UID then
    lcd.drawText(UI.COL1, yPos, statusLine(), attr + SMLSIZE)
  elseif id == ROW_SET then
    lcd.drawText(10, yPos, "[Set]", attr + BOLD)
  elseif id == ROW_BIND then
    lcd.drawText(10, yPos, crsf.hasTelemetry and "[Unbind]" or "[Bind]", attr + BOLD)
  elseif id == ROW_HISTORY then
    lcd.drawText(UI.COL1, yPos, "> History", attr + BOLD)
  elseif id == ROW_EXIT then
    lcd.drawText(10, yPos, "[---- EXIT ----]", attr + BOLD)
  elseif id == ROW_CLEAR then
    lcd.drawText(10, yPos, "[Clear All]", attr + BOLD)
  elseif id == ROW_BACK then
    lcd.drawText(10, yPos, "[---- BACK ----]", attr + BOLD)
  elseif id > HIST_BASE then
    lcd.drawText(UI.COL1, yPos, App.history.items[id - HIST_BASE] or "", attr)
  end
end

local function drawPage(event)
  handleEvent(event)
  buildRows()

  lcd.clear()
  drawTitle()

  for i = 1, #UI.rows do
    drawRow(UI.rows[i], i * UI.textSize + UI.textYoffset, UI.lineIndex == i)
  end
end

-- ============================================================================
-- Interface: render
-- ============================================================================

function UI.render(event, _touchState)
  -- Pending confirmation owns the screen until answered. It arms only after
  -- a quiet frame: the ENTER release that follows the long press which
  -- opened it would otherwise answer it on the spot.
  if UI.confirm then
    local result = popupConfirmation(UI.confirm.msg, "PRESS [OK] to confirm", event)
    if not UI.confirm.armed then
      if event == 0 then
        UI.confirm.armed = true
      end
      return
    end
    if result == "OK" then
      if UI.confirm.i then
        App.removeHistory(UI.confirm.i)
      else
        App.clearHistory()
      end
      UI.confirm = nil
      UI.forceRedraw = true
    elseif result == "CANCEL" then
      UI.confirm = nil
      UI.forceRedraw = true
    end
    return
  end

  -- Repaint on any event, while editing, and whenever the live parts of the
  -- page (status line, link flag) changed since the last paint.
  local status = statusLine() .. (crsf.hasTelemetry and "C" or "-")
  if event ~= 0 or UI.forceRedraw or UI.phraseEdit.editing or status ~= UI.lastStatus then
    drawPage(event)
    UI.lastStatus = status
    UI.forceRedraw = false
  end
end

return UI
