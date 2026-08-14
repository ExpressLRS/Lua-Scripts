---------------------------------------------------------------------------
-- B&W Alert Screen                                                      --
-- Loaded via loadScript() with no arguments; returns the drawAlert      --
-- function. Shared by every tool's B&W UI.                              --
--                                                                       --
-- Full-screen alert: MIDSIZE title, body lines, and an optional row of  --
-- action labels along the bottom.                                       --
---------------------------------------------------------------------------

-- B&W text row height
local TEXT_H = 8

--- Clear the screen and draw the alert.
-- @param title    heading, drawn MIDSIZE
-- @param msgs     array of body lines
-- @param actions  optional { left, right } action labels for the bottom row
local function drawAlert(title, msgs, actions)
  lcd.clear()
  local y = 0
  lcd.drawText(2, y, title, MIDSIZE)
  y = y + (TEXT_H * 2) - 2
  for _, msg in ipairs(msgs) do
    lcd.drawText(2, y, msg)
    y = y + TEXT_H
  end
  if actions then
    y = y + TEXT_H
    if actions.left then
      lcd.drawText(2, y, actions.left, 0)
    end
    if actions.right then
      lcd.drawText(LCD_W - 2, y, actions.right, RIGHT)
    end
  end
end

return drawAlert
