---------------------------------------------------------------------------
-- Color LCD Startup Dialogs                                             --
-- Loaded via loadScript() with no arguments; returns the Dialogs table. --
-- Shared by every tool's LVGL UI.                                       --
--                                                                       --
-- The two dialogs a tool can raise before it has a page: the EdgeTX     --
-- version gate and the missing-module notice. Both are terminal -- the  --
-- only way out is exiting the tool -- so each takes the caller's        --
-- onExit and wires it to both the dialog's close box and its Exit       --
-- button.                                                               --
---------------------------------------------------------------------------

local Dialogs = {}

--- Build a full-screen dialog: a column of text lines over a single Exit
-- button. lines are label descriptors ({ text = ..., font = ... }), used
-- verbatim as children.
local function buildExitDialog(title, lines, onExit)
  lvgl.clear()

  local dg = lvgl.dialog({
    title = title,
    flexFlow = lvgl.FLOW_COLUMN,
    flexPad = lvgl.PAD_SMALL,
    close = onExit,
  })

  dg:build({
    {
      type = lvgl.BOX,
      x = 10,
      flexFlow = lvgl.FLOW_COLUMN,
      flexPad = lvgl.PAD_SMALL,
      children = lines,
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
            onExit()
          end,
        },
      },
    },
  })

  return dg
end

--- The EdgeTX version gate. Keep the versions in step with the ladder in
-- SCRIPTS/ELRS/edgetx_version.lua, which decides when this is shown.
function Dialogs.showVersionRequired(onExit)
  return buildExitDialog("EdgeTX Version Not Supported", {
    { type = lvgl.LABEL, text = "Requires EdgeTX:" },
    { type = lvgl.LABEL, text = "- 2.11.6 or later" },
    { type = lvgl.LABEL, text = "- 2.12.1 or later" },
    { type = lvgl.LABEL, text = "- 3.0 or later" },
  }, onExit)
end

--- No CRSF module configured on the model.
function Dialogs.showNoModule(onExit)
  return buildExitDialog("No Module Found: Check Model Settings", {
    { type = lvgl.LABEL, text = "- Internal/External module enabled" },
    { type = lvgl.LABEL, text = "- Protocol set to CRSF" },
    { type = lvgl.LABEL, text = "- Minimum Baud rate (depends on packet rate):" },
    { type = lvgl.LABEL, font = SMLSIZE, text = "  400k for 250Hz" },
    { type = lvgl.LABEL, font = SMLSIZE, text = "  921k for 500Hz" },
    { type = lvgl.LABEL, font = SMLSIZE, text = "  1.87M for F1000" },
  }, onExit)
end

return Dialogs
