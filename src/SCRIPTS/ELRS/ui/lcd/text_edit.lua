---------------------------------------------------------------------------
-- B&W Text Editor                                                       --
-- Loaded via loadScript() with no arguments; returns the TextEdit       --
-- table. Construct one instance per editable field: TextEdit.new().     --
--                                                                       --
-- A Lua port of the firmware's editName() (gui/common/stdlcd/           --
-- draw_functions.cpp:178), so editing a string in a tool feels exactly  --
-- like editing a model name: the cursor starts on the first char,       --
-- rotary cycles that char through the name charset (clamped at the      --
-- ends, case preserved), ENTER advances the cursor, ENTER on the last   --
-- cell or long ENTER on a space commits, and long ENTER on a letter     --
-- toggles its case. EXIT also commits -- edits are applied to the       --
-- value as they are made, never reverted. Trailing spaces are stripped  --
-- on commit; deletion is overwriting with spaces.                       --
---------------------------------------------------------------------------

local TextEdit = {}
TextEdit.__index = TextEdit

-- The firmware's nameChars. Digits and the comma are in it, so a raw UID
-- ("0,1,2,3,4,5") can be entered with the same editor.
local CHARS = " abcdefghijklmnopqrstuvwxyz0123456789_-,."

--- Index of a char in CHARS, upper-case letters mapping like their
-- lower-case form (nameCharIdx in the firmware). Unknown chars map to
-- the leading space.
local function charIdx(c)
  local b = string.byte(c)
  if b >= 65 and b <= 90 then
    c = string.char(b + 32)
  end
  local idx = string.find(CHARS, c, 1, true)
  -- "." is no pattern here thanks to the plain flag; the charset has no
  -- other metachars.
  return idx or 1
end

local function isUpper(c)
  local b = string.byte(c)
  return b ~= nil and b >= 65 and b <= 90
end

local function isLower(c)
  local b = string.byte(c)
  return b ~= nil and b >= 97 and b <= 122
end

--- Construct an editor instance.
-- @param maxLen   maximum value length in chars
-- @param visible  chars that fit the row; longer values draw a window
--                 ending at the cursor
function TextEdit.new(maxLen, visible)
  return setmetatable({
    maxLen = maxLen,
    visible = visible,
    value = "",
    editing = nil,
    cur = 1,
  }, TextEdit)
end

--- Enter edit mode with the cursor on the first char.
function TextEdit:start()
  self.editing = true
  self.cur = 1
end

--- Replace the char under the cursor, padding with spaces when the
-- cursor sits past the end of the value.
function TextEdit:_setChar(c)
  local v = self.value
  while #v < self.cur - 1 do
    v = v .. " "
  end
  self.value = string.sub(v, 1, self.cur - 1) .. c .. string.sub(v, self.cur + 1)
end

function TextEdit:_charAt(pos)
  local c = string.sub(self.value, pos, pos)
  if c == "" then
    return " "
  end
  return c
end

function TextEdit:_commit()
  self.editing = nil
  local v = self.value
  local last = #v
  while last > 0 and string.byte(v, last) == 32 do
    last = last - 1
  end
  self.value = string.sub(v, 1, last)
end

--- Handle one event while editing. Returns true when the edit committed
-- on this event, nil while it continues.
function TextEdit:handleEvent(event)
  local c = self:_charAt(self.cur)

  if event == EVT_VIRTUAL_NEXT or event == EVT_VIRTUAL_PREV then
    local idx = charIdx(c)
    if event == EVT_VIRTUAL_NEXT then
      idx = math.min(idx + 1, #CHARS)
    else
      idx = math.max(idx - 1, 1)
    end
    local nc = string.sub(CHARS, idx, idx)
    if isUpper(c) and isLower(nc) then
      nc = string.char(string.byte(nc) - 32)
    end
    self:_setChar(nc)
    return nil
  end

  if event == EVT_VIRTUAL_ENTER then
    if self.cur < self.maxLen then
      self.cur = self.cur + 1
    else
      self:_commit()
      return true
    end
    return nil
  end

  if event == EVT_VIRTUAL_ENTER_LONG then
    killEvents(event)
    if c == " " then
      self:_commit()
      return true
    elseif isUpper(c) then
      self:_setChar(string.char(string.byte(c) + 32))
    elseif isLower(c) then
      self:_setChar(string.char(string.byte(c) - 32))
    end
    return nil
  end

  if event == EVT_VIRTUAL_EXIT then
    self:_commit()
    return true
  end

  return nil
end

--- Draw the value at (x, y). attr is the row's base attribute (INVERS on
-- the selected row); while editing, only the cursor cell is inverted,
-- like the firmware's edit rendering.
function TextEdit:draw(x, y, attr)
  if not self.editing then
    local shown = self.value
    if shown == "" then
      shown = "---"
    elseif self.visible and #shown > self.visible then
      shown = string.sub(shown, 1, self.visible)
    end
    lcd.drawText(x, y, shown, attr)
    return
  end

  -- Window the value so the cursor is always on screen
  local first = 1
  if self.visible and self.cur > self.visible then
    first = self.cur - self.visible + 1
  end
  local prefix = string.sub(self.value, first, self.cur - 1)
  local suffix = ""
  if self.visible then
    suffix = string.sub(self.value, self.cur + 1, first + self.visible - 1)
  else
    suffix = string.sub(self.value, self.cur + 1)
  end

  lcd.drawText(x, y, prefix)
  lcd.drawText(lcd.getLastPos(), y, self:_charAt(self.cur), INVERS)
  if suffix ~= "" then
    lcd.drawText(lcd.getLastPos(), y, suffix)
  end
end

return TextEdit
