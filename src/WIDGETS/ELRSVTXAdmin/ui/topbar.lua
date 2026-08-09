---------------------------------------------------------------------------
-- VTX Administrator Widget - Shared Top Bar UI                          --
-- Used by all screen-specific UI files for the top bar layout.          --
---------------------------------------------------------------------------

local ctx = ...
local VTXDisplay = ctx.VTXDisplay

local TopBarUI = {}

--- Top bar: label over value, matching EdgeTX's stock status bar widgets.
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
          color = COLOR_THEME_PRIMARY2,
          text = "VTX",
        },
        {
          type = lvgl.LABEL,
          align = CENTER,
          font = SMLSIZE,
          color = COLOR_THEME_PRIMARY2,
          text = function()
            if VTXDisplay.showStatus() then
              return "--"
            end
            return VTXDisplay.bandChannel()
          end,
        },
      },
    },
  })
end

return TopBarUI
