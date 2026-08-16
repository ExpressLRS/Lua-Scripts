---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Shared Top Bar UI                             --
-- Loaded via loadScript() from each per-screen ui/ file with            --
-- ({ Display }); returns the TopBarUI table.                            --
--                                                                       --
-- Two stacked lines and no background, so it composes onto the dark     --
-- header. Everything it shows is abbreviated to fit a top-bar slot,     --
-- which is why it spells out its own text ladder rather than reusing    --
-- the hero label's.                                                     --
---------------------------------------------------------------------------

local ctx = ...
local Display = ctx.Display

local TopBarUI = {}

--- The top bar sits on the dark header, so it needs PRIMARY2 where
--- Display.heroColor uses PRIMARY1.
local function mismatchColor()
  if Display.isMismatch() then
    return RED
  end
  return COLOR_THEME_PRIMARY2
end

--- Top bar: two lines stacked, no background.
function TopBarUI.build(w, h)
  lvgl.build({
    {
      type = lvgl.BOX,
      x = 0,
      y = 0,
      w = w,
      h = h,
      align = CENTER,
      flexFlow = lvgl.FLOW_COLUMN,
      flexPad = 0,
      children = {
        {
          type = lvgl.LABEL,
          align = CENTER,
          font = SMLSIZE,
          color = mismatchColor,
          text = function()
            if not Display.isConnected() then
              return "--"
            end
            if Display.isMismatch() then
              return "Model"
            end
            return Display.lqText()
          end,
        },
        {
          type = lvgl.LABEL,
          align = CENTER,
          font = SMLSIZE,
          color = mismatchColor,
          text = function()
            if not Display.isConnected() then
              return "--"
            end
            if Display.isMismatch() then
              return "Mismatch"
            end
            return Display.rssiText()
          end,
        },
      },
    },
  })
end

return TopBarUI
