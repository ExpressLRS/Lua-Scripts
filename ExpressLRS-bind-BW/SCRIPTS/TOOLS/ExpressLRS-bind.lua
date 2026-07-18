-- TNS|ExpressLRS-bind|TNE

-------------------------------------------------------------------------------
-- ExpressLRS-bind                                                           --
--                                                                           --
-- Original LVGL bindphrase tool: CapnBry                                    --
-- Black-and-white LCD compatibility port: prepared with ChatGPT (OpenAI)    --
--                                                                           --
-- This adaptation preserves the original color/LVGL interface and adds a    --
-- classic EdgeTX lcd API interface for radios where lvgl is unavailable.    --
-- Upstream ownership and licensing remain unchanged.                        --
--                                                                           --
-- Install as: /SCRIPTS/TOOLS/ExpressLRS-bind.lua                            --
-------------------------------------------------------------------------------

-- B&W compatibility adaptation generated with ChatGPT (OpenAI)
-- Based on the original ELRS Bind Manager and EdgeTX/ExpressLRS code
-- Requested and tested by: [Bartosz Pracz / bartoszp1992]

local CRSF = loadScript("/SCRIPTS/ELRS/crsf.lua")()
local shimLoader = loadScript("/SCRIPTS/ELRS/shim.lua")
local shim = shimLoader and shimLoader() or {}

local tableConcat = shim.tableConcat or function(t, sep, first, last)
  first = first or 1
  last = last or #t
  local out = ""
  for i = first, last do
    if i > first and sep then out = out .. sep end
    out = out .. (t[i] or "")
  end
  return out
end

local tableRemove = shim.tableRemove or function(t, pos)
  local n = #t
  if n == 0 then return nil end
  pos = pos or n
  local old = t[pos]
  for i = pos, n - 1 do t[i] = t[i + 1] end
  t[n] = nil
  return old
end

local targetIdx   = 1                 -- 1 = Transmitter, 2 = Receiver
local bindPhrase  = ""
local uidText     = ""

local MSP_ELRS_RXTX_CONFIG = 45
local ELRS_RXTX_SUBCMD_UID = 0
local ELRS_RXTX_SUBCMD_BIND_PHRASE = 1
local MAX_PHRASE_LEN = 52

local Defer = { _deferCb = nil }

function Defer.setTimeout(interval, fn, ctx)
  Defer._deferCb = {
    start = getTime(),
    interval = interval,
    fn = fn,
    ctx = ctx,
  }
end

function Defer.clear()
  Defer._deferCb = nil
end

function Defer.poll()
  if Defer._deferCb == nil then return end

  if getTime() - Defer._deferCb.start < Defer._deferCb.interval then
    return
  end

  -- Clear first, because the callback may schedule another call.
  local oldcb = Defer._deferCb
  Defer._deferCb = nil
  oldcb.fn(oldcb.ctx)
end

local History = {
  MAX = 5,
  FNAME = "/SCRIPTS/ELRS/elrs-bind.txt",
  LEGACY_FNAME = "elrs-bind.txt",
  vals = {},
}

function History.save()
  local f = io.open(History.FNAME, "w")
  if f == nil then
    -- Fall back to the location used by the original script.
    f = io.open(History.LEGACY_FNAME, "w")
  end
  if f == nil then return false end
  io.write(f, tableConcat(History.vals, '\n'))
  io.close(f)
  return true
end

function History.add(s)
  if s == nil or s == "" then return false end

  -- Remove duplicate first.
  for idx = #History.vals, 1, -1 do
    if History.vals[idx] == s then
      tableRemove(History.vals, idx)
    end
  end

  -- Insert at the front without table.insert (missing on some B&W radios).
  local limit = #History.vals + 1
  if limit > History.MAX then limit = History.MAX end
  for idx = limit, 2, -1 do
    History.vals[idx] = History.vals[idx - 1]
  end
  History.vals[1] = s
  History.vals[History.MAX + 1] = nil

  return History.save()
end

function History.load()
  local f = io.open(History.FNAME, "r")
  if f == nil then
    f = io.open(History.LEGACY_FNAME, "r")
  end
  if f == nil then return nil end

  History.vals = {}
  local all = io.read(f, 64 * History.MAX)
  io.close(f)

  if all == nil or all == "" then return nil end

  for line in string.gmatch(all, "[^\r\n]+") do
    if #History.vals >= History.MAX then break end
    if #line > MAX_PHRASE_LEN then
      line = string.sub(line, 1, MAX_PHRASE_LEN)
    end
    History.vals[#History.vals + 1] = line
  end

  return History.vals[1]
end

local function onMspResponse(data)
  if data[1] == CRSF.CONST.ADDRESS_RADIO_TRANSMITTER
    and (data[2] == CRSF.CONST.ADDRESS_RX or data[2] == CRSF.CONST.ADDRESS_TX_MODULE) then
    local mspCmd = data[5]

    if mspCmd == MSP_ELRS_RXTX_CONFIG and data[6] == ELRS_RXTX_SUBCMD_UID then
      Defer.clear()
      local rxTx = (data[2] == CRSF.CONST.ADDRESS_RX) and "RX" or "TX"
      uidText = string.format("%s: %d, %d, %d, %d, %d, %d",
          rxTx, data[7], data[8], data[9], data[10], data[11], data[12])
    end
  end
end

local function isTargetReachable()
  return targetIdx == 1 or CRSF.isConnected
end

local function requestUid()
  if not isTargetReachable() then
    uidText = "Receiver not connected"
    return
  end

  uidText = "Updating UID..."

  CRSF.push(CRSF.CONST.FRAMETYPE_MSP_REQ, {
    (targetIdx == 1) and CRSF.CONST.ADDRESS_TX_MODULE or CRSF.CONST.ADDRESS_RX,
    CRSF.CONST.ADDRESS_RADIO_TRANSMITTER,
    0x30,
    0x01,
    MSP_ELRS_RXTX_CONFIG,
    ELRS_RXTX_SUBCMD_UID,
  })

  -- Retry if no response.
  Defer.setTimeout(50, requestUid)
end

local function sendBindphrase()
  if bindPhrase == "" then
    uidText = "Bind phrase is empty"
    return
  end
  if not isTargetReachable() then
    uidText = "Receiver not connected"
    return
  end

  local rxTx = (targetIdx == 1) and "Transmitter" or "Receiver"
  uidText = "Setting " .. rxTx .. "..."

  local data = {
    (targetIdx == 1) and CRSF.CONST.ADDRESS_TX_MODULE or CRSF.CONST.ADDRESS_RX,
    CRSF.CONST.ADDRESS_RADIO_TRANSMITTER,
    0x30,
    0x01 + #bindPhrase,
    MSP_ELRS_RXTX_CONFIG,
    ELRS_RXTX_SUBCMD_BIND_PHRASE,
  }

  for i = 1, #bindPhrase do
    data[#data + 1] = string.byte(bindPhrase, i)
  end

  CRSF.push(CRSF.CONST.FRAMETYPE_MSP_WRITE, data)
  History.add(bindPhrase)

  -- Refresh UID after one second (getTime() ticks are 10 ms).
  Defer.setTimeout(100, requestUid)
end

local function sendBindTx()
  uidText = "Sending bind command..."
  CRSF.sendBind(CRSF.CONST.ADDRESS_TX_MODULE)
  Defer.setTimeout(100, function() uidText = "Bind command sent" end)
end

local function sendBindRx()
  uidText = "Sending unbind to RX..."
  CRSF.sendBind(CRSF.CONST.ADDRESS_RX)
  Defer.setTimeout(100, function() uidText = "Unbind command sent" end)
end

-- ============================================================================
-- Color/LVGL UI (keeps the original interface)
-- ============================================================================

local rebuildUi
local function history_text(id)
  return History.vals[id]
end

local function history_visible(id)
  return history_text(id) ~= nil
end

local function history_press(id)
  bindPhrase = History.vals[id] or ""
  rebuildUi()
end

rebuildUi = function()
  lvgl.clear()

  local pg = lvgl.page({
    title    = "ExpressLRS Bind Phrase",
    subtitle = function() return uidText end,
  })

  local tbox = pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    flexFlow = lvgl.FLOW_COLUMN,
  })

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
            value = bindPhrase,
            length = MAX_PHRASE_LEN,
            set = function(v) bindPhrase = v end,
            active = isTargetReachable,
          },
          {
            type = lvgl.BUTTON,
            text = "Set",
            press = sendBindphrase,
            active = isTargetReachable,
          },
          {
            type = lvgl.BUTTON,
            text = "Save",
            press = function()
              if bindPhrase ~= "" then
                History.add(bindPhrase)
                rebuildUi()
              end
            end,
          },
        },
      },
    },
  })

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
            values = {"Transmitter", "Receiver"},
            get = function() return targetIdx end,
            set = function(n) targetIdx = n end,
          },
          {
            type = lvgl.BUTTON,
            text = "Request UID",
            press = requestUid,
            active = isTargetReachable,
          },
          {
            type = lvgl.BUTTON,
            text = "Unbind",
            press = sendBindRx,
            visible = function() return targetIdx == 2 end,
            active = function() return targetIdx == 2 and CRSF.isConnected end,
          },
        },
      },
    },
  })

  pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    y = 2 * lvgl.UI_ELEMENT_HEIGHT + 4 * lvgl.PAD_MEDIUM,
    flexFlow = lvgl.FLOW_ROW,
    flexPad = lvgl.PAD_MEDIUM,
    align = LEFT,
    visible = function() return targetIdx == 2 and not CRSF.isConnected end,
    children = {
      {
        type = lvgl.LABEL,
        w = 4 + lvgl.LCD_SCALE * (120 + 250),
        text = " No receiver connected.\n Use Bind to set bindphrase if RX in bind mode",
      },
      {
        type = lvgl.BUTTON,
        text = "Bind",
        press = sendBindTx,
      },
    },
  })

  local row = pg:box({
    w = lvgl.PERCENT_SIZE + 100,
    y = 2 * lvgl.UI_ELEMENT_HEIGHT + 4 * lvgl.PAD_MEDIUM,
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = lvgl.PAD_MEDIUM,
    visible = function() return #History.vals > 0 and isTargetReachable() end,
  })
  row:label({text = "Bind Phrase History"})
  for i = 1, History.MAX do
    row:button({
      w = lvgl.PERCENT_SIZE + 80,
      text = function() return history_text(i) end,
      visible = function() return history_visible(i) end,
      press = function() return history_press(i) end,
    })
  end
end

-- ============================================================================
-- Black-and-white LCD UI
-- ============================================================================

local BW = {
  screen = "main",
  line = 1,
  offset = 0,
  shouldExit = false,
  editor = {
    cursor = 1,
    changing = false,
    charIndex = 1,
    original = "",
  },
}

-- First value is a normal space. A separate index 0 is used for DELETE.
local CHARSET = " abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.@+!#$%&*"

local function fitText(s, chars)
  s = s or ""
  if #s <= chars then return s end
  if chars <= 3 then return string.sub(s, 1, chars) end
  return string.sub(s, 1, chars - 3) .. "..."
end

local function trimTrailingSpaces(s)
  return string.gsub(s or "", "%s+$", "")
end

local function replaceChar(s, pos, c)
  if pos < 1 or pos > MAX_PHRASE_LEN then return s end
  if pos <= #s then
    return string.sub(s, 1, pos - 1) .. c .. string.sub(s, pos + 1)
  end
  if pos == #s + 1 then
    return s .. c
  end
  return s
end

local function deleteChar(s, pos)
  if pos < 1 or pos > #s then return s end
  return string.sub(s, 1, pos - 1) .. string.sub(s, pos + 1)
end

local function findCharIndex(c)
  if c == nil or c == "" then return 1 end
  local idx = string.find(CHARSET, c, 1, true)
  return idx or 1
end

local function drawTitle(title)
  lcd.drawFilledRectangle(0, 0, LCD_W, 9, GREY_DEFAULT)
  lcd.drawText(1, 1, fitText(title, LCD_W >= 200 and 25 or 15), INVERS)
  lcd.drawText(LCD_W - 1, 1, targetIdx == 1 and "TX" or "RX", RIGHT + INVERS)
end

local function maxRows()
  if LCD_H >= 96 then return 10 end
  return 6
end

local function selectLine(step, count)
  if count < 1 then
    BW.line = 1
    BW.offset = 0
    return
  end

  BW.line = BW.line + step
  if BW.line < 1 then BW.line = count end
  if BW.line > count then BW.line = 1 end

  local rows = maxRows()
  if BW.line <= BW.offset then
    BW.offset = BW.line - 1
  elseif BW.line > BW.offset + rows then
    BW.offset = BW.line - rows
  end
end

local function drawList(title, items)
  lcd.clear()
  drawTitle(title)

  local rows = maxRows()
  local count = #items
  if BW.line > count then BW.line = count end
  if BW.line < 1 then BW.line = 1 end
  if BW.offset > math.max(0, count - rows) then
    BW.offset = math.max(0, count - rows)
  end

  local col2 = LCD_W >= 200 and 110 or 64
  local maxValueChars = LCD_W >= 200 and 16 or 10

  for row = 1, rows do
    local idx = BW.offset + row
    local item = items[idx]
    if item == nil then break end

    local y = 3 + row * 8
    local attr = (idx == BW.line) and INVERS or 0
    if item.disabled and idx ~= BW.line then attr = BLINK end

    lcd.drawText(1, y, item.label or "", attr)
    if item.value and item.value ~= "" then
      lcd.drawText(LCD_W - 1, y, fitText(item.value, maxValueChars), RIGHT + attr)
    end
  end
end

local function buildMainItems()
  local items = {}

  items[#items + 1] = {
    label = "Target",
    value = targetIdx == 1 and "Transmitter" or "Receiver",
    action = "target",
  }
  items[#items + 1] = {
    label = "Phrase",
    value = bindPhrase ~= "" and bindPhrase or "(empty)",
    action = "edit",
  }
  items[#items + 1] = {
    label = "Set phrase",
    action = "set",
    disabled = bindPhrase == "" or not isTargetReachable(),
  }
  items[#items + 1] = {
    label = "Save preset",
    action = "save",
    disabled = bindPhrase == "",
  }
  items[#items + 1] = {
    label = "Saved phrases",
    value = tostring(#History.vals),
    action = "history",
  }
  items[#items + 1] = {
    label = "Request UID",
    action = "uid",
    disabled = not isTargetReachable(),
  }

  if targetIdx == 2 then
    items[#items + 1] = {
      label = CRSF.isConnected and "Unbind receiver" or "Send bind command",
      action = CRSF.isConnected and "unbind" or "bind",
    }
  end

  items[#items + 1] = {
    label = "Status",
    value = fitText(uidText, 10),
    action = "status",
  }
  items[#items + 1] = {
    label = "Exit",
    action = "exit",
  }

  return items
end

local function openStatus(message)
  if message then uidText = message end
  BW.screen = "status"
end

local function beginEditor()
  BW.editor.original = bindPhrase
  BW.editor.cursor = 1
  BW.editor.changing = false
  BW.editor.charIndex = findCharIndex(string.sub(bindPhrase, 1, 1))
  BW.screen = "edit"
end

local function handleMain(event)
  local items = buildMainItems()

  if event == EVT_VIRTUAL_NEXT then
    selectLine(1, #items)
  elseif event == EVT_VIRTUAL_PREV then
    selectLine(-1, #items)
  elseif event == EVT_VIRTUAL_EXIT then
    BW.shouldExit = true
  elseif event == EVT_VIRTUAL_ENTER then
    local item = items[BW.line]
    if not item then return end

    if item.disabled then
      if item.action == "set" and bindPhrase == "" then
        openStatus("Bind phrase is empty")
      elseif targetIdx == 2 and not CRSF.isConnected then
        openStatus("Receiver not connected")
      else
        openStatus("Action unavailable")
      end
      return
    end

    if item.action == "target" then
      targetIdx = targetIdx == 1 and 2 or 1
      uidText = targetIdx == 1 and "Target: transmitter" or "Target: receiver"
    elseif item.action == "edit" then
      beginEditor()
    elseif item.action == "set" then
      sendBindphrase()
      openStatus()
    elseif item.action == "save" then
      if History.add(bindPhrase) then
        uidText = "Preset saved"
      else
        uidText = "Could not save preset"
      end
      openStatus()
    elseif item.action == "history" then
      if #History.vals == 0 then
        openStatus("No saved phrases")
      else
        BW.screen = "history"
        BW.line = 1
        BW.offset = 0
      end
    elseif item.action == "uid" then
      requestUid()
      openStatus()
    elseif item.action == "bind" then
      sendBindTx()
      openStatus()
    elseif item.action == "unbind" then
      sendBindRx()
      openStatus()
    elseif item.action == "status" then
      openStatus()
    elseif item.action == "exit" then
      BW.shouldExit = true
    end
  end
end

local function drawMain()
  drawList("ExpressLRS-bind", buildMainItems())
end

local function historyItems()
  local items = {}
  for i = 1, #History.vals do
    items[#items + 1] = {
      label = tostring(i) .. ". " .. History.vals[i],
      action = "load",
      historyIndex = i,
    }
  end
  items[#items + 1] = { label = "Back", action = "back" }
  return items
end

local function handleHistory(event)
  local items = historyItems()

  if event == EVT_VIRTUAL_NEXT then
    selectLine(1, #items)
  elseif event == EVT_VIRTUAL_PREV then
    selectLine(-1, #items)
  elseif event == EVT_VIRTUAL_EXIT then
    BW.screen = "main"
    BW.line = 1
    BW.offset = 0
  elseif event == EVT_VIRTUAL_ENTER then
    local item = items[BW.line]
    if not item then return end
    if item.action == "load" then
      bindPhrase = History.vals[item.historyIndex] or ""
      uidText = "Preset loaded"
      BW.screen = "main"
      BW.line = 2
      BW.offset = 0
    else
      BW.screen = "main"
      BW.line = 1
      BW.offset = 0
    end
  end
end

local function drawHistory()
  drawList("Saved phrases", historyItems())
end

local function currentEditorLimit()
  local limit = #bindPhrase + 1
  if limit < 1 then limit = 1 end
  if limit > MAX_PHRASE_LEN then limit = MAX_PHRASE_LEN end
  return limit
end

local function handleEditor(event)
  local ed = BW.editor

  -- Optional long-return cancellation where the radio exposes this event.
  if EVT_VIRTUAL_EXIT_LONG and event == EVT_VIRTUAL_EXIT_LONG then
    bindPhrase = ed.original
    ed.changing = false
    BW.screen = "main"
    BW.line = 2
    BW.offset = 0
    uidText = "Edit cancelled"
    return
  end

  if event == EVT_VIRTUAL_EXIT then
    if ed.changing then
      ed.changing = false
    else
      bindPhrase = trimTrailingSpaces(bindPhrase)
      BW.screen = "main"
      BW.line = 2
      BW.offset = 0
      uidText = "Phrase edited"
    end
    return
  end

  if event == EVT_VIRTUAL_ENTER then
    if not ed.changing then
      local c = string.sub(bindPhrase, ed.cursor, ed.cursor)
      ed.charIndex = findCharIndex(c)
      ed.changing = true
    else
      if ed.charIndex == 0 then
        bindPhrase = deleteChar(bindPhrase, ed.cursor)
        local limit = currentEditorLimit()
        if ed.cursor > limit then ed.cursor = limit end
      else
        local c = string.sub(CHARSET, ed.charIndex, ed.charIndex)
        bindPhrase = replaceChar(bindPhrase, ed.cursor, c)
        if ed.cursor < currentEditorLimit() then
          ed.cursor = ed.cursor + 1
        end
      end
      ed.changing = false
    end
    return
  end

  if ed.changing then
    if event == EVT_VIRTUAL_NEXT then
      ed.charIndex = ed.charIndex + 1
      if ed.charIndex > #CHARSET then ed.charIndex = 0 end
    elseif event == EVT_VIRTUAL_PREV then
      ed.charIndex = ed.charIndex - 1
      if ed.charIndex < 0 then ed.charIndex = #CHARSET end
    end
  else
    local limit = currentEditorLimit()
    if event == EVT_VIRTUAL_NEXT then
      ed.cursor = ed.cursor + 1
      if ed.cursor > limit then ed.cursor = 1 end
    elseif event == EVT_VIRTUAL_PREV then
      ed.cursor = ed.cursor - 1
      if ed.cursor < 1 then ed.cursor = limit end
    end
  end
end

local function drawEditor()
  lcd.clear()
  drawTitle("Edit bind phrase")

  local ed = BW.editor
  local charsPerLine = LCD_W >= 200 and 32 or 20
  local charWidth = 6
  local lines = math.ceil(MAX_PHRASE_LEN / charsPerLine)
  if lines > 3 then lines = 3 end

  local displayPhrase = bindPhrase
  local candidate = nil
  if ed.changing then
    if ed.charIndex == 0 then
      candidate = "_"
    else
      candidate = string.sub(CHARSET, ed.charIndex, ed.charIndex)
    end
  end

  for line = 1, lines do
    local first = (line - 1) * charsPerLine + 1
    local last = first + charsPerLine - 1
    if last > MAX_PHRASE_LEN then last = MAX_PHRASE_LEN end
    local y = 11 + (line - 1) * 10

    for pos = first, last do
      local c = string.sub(displayPhrase, pos, pos)
      if c == "" or c == " " then c = "_" end
      if pos == ed.cursor and candidate then c = candidate end

      local col = pos - first
      local attr = 0
      if pos == ed.cursor then
        attr = INVERS + (ed.changing and BLINK or 0)
      end
      lcd.drawText(col * charWidth, y, c, attr)
    end
  end

  local modeText
  if ed.changing then
    modeText = ed.charIndex == 0 and "Character: DELETE" or "Character: " .. string.sub(CHARSET, ed.charIndex, ed.charIndex)
  else
    modeText = "Position: " .. tostring(ed.cursor) .. "/" .. tostring(MAX_PHRASE_LEN)
  end
  lcd.drawText(1, LCD_H - 17, fitText(modeText, LCD_W >= 200 and 32 or 20), 0)
  lcd.drawText(1, LCD_H - 9, ed.changing and "Dial=char ENT=OK" or "Dial=pos ENT=edit", 0)
  lcd.drawText(LCD_W - 1, LCD_H - 9, "RTN", RIGHT)
end

local function wrapText(text, charsPerLine, maxLines)
  local lines = {}
  local pos = 1
  text = text or ""

  while pos <= #text and #lines < maxLines do
    local chunk = string.sub(text, pos, pos + charsPerLine - 1)
    lines[#lines + 1] = chunk
    pos = pos + charsPerLine
  end

  if #lines == 0 then lines[1] = "No status yet" end
  return lines
end

local function handleStatus(event)
  if event == EVT_VIRTUAL_EXIT or event == EVT_VIRTUAL_ENTER then
    BW.screen = "main"
    BW.line = 1
    BW.offset = 0
  end
end

local function drawStatus()
  lcd.clear()
  drawTitle("Status / UID")
  local chars = LCD_W >= 200 and 32 or 20
  local lines = wrapText(uidText, chars, LCD_H >= 96 and 8 or 5)
  for i = 1, #lines do
    lcd.drawText(1, 3 + i * 9, lines[i], 0)
  end
  lcd.drawText(LCD_W - 1, LCD_H - 9, "[ENT/RTN] Back", RIGHT)
end

local function runBw(event)
  if BW.screen == "main" then
    handleMain(event)
    drawMain()
  elseif BW.screen == "history" then
    handleHistory(event)
    drawHistory()
  elseif BW.screen == "edit" then
    handleEditor(event)
    drawEditor()
  elseif BW.screen == "status" then
    handleStatus(event)
    drawStatus()
  end

  if BW.shouldExit then return 2 end
  return 0
end

-- ============================================================================
-- EdgeTX entry points
-- ============================================================================

local function init()
  bindPhrase = History.load() or ""
  CRSF:registerHandler(CRSF.CONST.FRAMETYPE_MSP_RESP, onMspResponse)
  Defer.setTimeout(1, requestUid)

  if lvgl ~= nil then
    rebuildUi()
  else
    BW.screen = "main"
    BW.line = 1
    BW.offset = 0
    BW.shouldExit = false
  end
end

local function run(event, touchState)
  CRSF:poll()
  -- Must come after poll so a telemetry queue is established.
  Defer.poll()

  if lvgl ~= nil then
    return 0
  end

  return runBw(event or 0)
end

return { init = init, run = run, useLvgl = (lvgl ~= nil) }
