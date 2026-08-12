---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Shared Top Bar UI                             --
-- Used by all screen-specific UI files for the top bar layout.          --
---------------------------------------------------------------------------

local ctx = ...
local crsf = ctx.crsf
local Telemetry = ctx.Telemetry

local TopBarUI = {}

--- Top bar sits on the dark header, so it needs PRIMARY2 rather than Telemetry.heroColor's PRIMARY1.
local function mismatchColor()
  if Telemetry.isMismatch() then
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
            if not crsf.hasTelemetry then
              return "--"
            end
            if Telemetry.isMismatch() then
              return "Model"
            end
            return table.concat({ "LQ ", tostring(Telemetry.link.rqly or 0), "%" })
          end,
        },
        {
          type = lvgl.LABEL,
          align = CENTER,
          font = SMLSIZE,
          color = mismatchColor,
          text = function()
            if not crsf.hasTelemetry then
              return "--"
            end
            if Telemetry.isMismatch() then
              return "Mismatch"
            end
            local rssi = Telemetry.getRssi(Telemetry.link)
            if rssi == nil then
              return ""
            end
            return table.concat({ tostring(rssi), "dBm" })
          end,
        },
      },
    },
  })
end

return TopBarUI
