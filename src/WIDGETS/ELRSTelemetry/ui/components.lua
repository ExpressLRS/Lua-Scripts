---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Drawing Components                            --
-- Loaded via loadScript() from ELRSTelemetry/loadable.lua with          --
-- (Display); returns the Components table.                              --
--                                                                       --
-- Two layers. Elements are the shapes -- panel, bar, led, segments,     --
-- rule, label. Blocks are what a tier actually places: a status strip,  --
-- the uplink panel, a row of captioned groups. Keeping the blocks here  --
-- is what makes five per-screen files affordable: a tier builder stays  --
-- a short vertical composition instead of eight inlined element         --
-- definitions copied five times.                                        --
--                                                                       --
-- Nothing here calls lvgl.build(). Every function appends descriptor    --
-- tables to a list its caller owns, and the tier builds once at the     --
-- end: one C traversal, no retained handles, and no giant nested        --
-- literal for the .luac precompiler to choke on.                        --
--                                                                       --
-- Every block returns the next free y, so a tier reads top to bottom.   --
--                                                                       --
-- Only label, rectangle and circle appear below. The others lvgl offers --
-- are either fullscreen-only -- silently skipped in a widget zone, and  --
-- lvgl.build() fails without a word when that happens -- or, like       --
-- hline, have no thickness and so cannot draw a rule.                   --
---------------------------------------------------------------------------

local Display = ...

local Components = {}

-- How solid a bar's unfilled track is. Enough to read the bar's full
-- extent, not so much that the empty half draws the eye before the fill.
local TRACK_OPACITY = 90

-- The widget's own name, and the short form for a zone too narrow for it.
-- Written the way ExpressLRS writes it rather than uppercased like the inline
-- headers further down: this is a name, not a caption, and the same reason
-- keeps the mixed case in TQly and TRSS.
local BRAND = "ExpressLRS"
local BRAND_SHORT = "ELRS"

-- The mismatch banner, and the form for a strip that carries the name as well.
-- Caps either way: this is the one thing on the strip worth interrupting for.
local MISMATCH = "MODEL MISMATCH!"
local MISMATCH_SHORT = "MISMATCH!"

--- Side of one antenna cell. Half the row, so the pair sits at the LED's
--- weight rather than the text's.
local function antCell(m)
  return math.floor(m.sml / 2) + 1
end

-- ============================================================================
-- Metrics
-- ============================================================================

--- Measure the font line heights a layout needs.
-- Measured rather than tabulated because the 800x480 target ships different
-- font files: a height taken on 480x272 and scaled by lvgl.LCD_SCALE would be
-- confidently wrong there. lcd.sizeText has no LCD-buffer guard, so it is one
-- of the few lcd.* calls that still works under LVGL.
-- "0" is measured rather than the real strings: line height is a property of
-- the font, and using content would make the metric move with the data.
function Components.measure()
  local m = {
    pad = lvgl.PAD_SMALL,
    gap = lvgl.PAD_TINY,
  }
  m.sml = select(2, lcd.sizeText("0", SMLSIZE))
  m.bold = select(2, lcd.sizeText("0", BOLD))
  m.mid = select(2, lcd.sizeText("0", MIDSIZE))
  return m
end

--- Width of a string in a font, for reserving a column.
function Components.textWidth(s, font)
  return (lcd.sizeText(s, font))
end

--- Split a widget zone into the panel rect and the content rect inside it.
--- The panel fills the zone and the breathing room is padding inside it. A
--- widget that inset its panel instead would sit a couple of pixels in from
--- every neighbour on the screen, and the gap reads as a misalignment rather
--- than as space -- the zone boundaries are the screen's grid, and they are not
--- this widget's to redraw.
--- The padding is lvgl.PAD_SMALL because that is the borderPad the ELRS VTX
--- Admin widget's container uses (ELRSVTXAdmin/ui/display.lua:19-44), so the
--- two stack with their text on one left edge. It also comes off the theme's
--- own scale rather than being 4px on a 480 and 4px on an 800.
--- panel is absolute; inner is relative to the panel, because lvgl positions
--- children against their parent's origin.
function Components.frame(w, h, m)
  return {
    panel = { x = 0, y = 0, w = w, h = h },
    inner = { x = m.pad, w = w - m.pad * 2 },
    pad = m.pad,
    h = h,
  }
end

--- The widget's name in the longest form that fits availW, or nil when even
--- the short one does not.
--- A ladder rather than a per-radio breakpoint, for the same reason the group
--- row has one: what fits is a measured width in this screen's font.
function Components.brandText(availW)
  if availW >= Components.textWidth(BRAND, SMLSIZE) then
    return BRAND
  end
  if availW >= Components.textWidth(BRAND_SHORT, SMLSIZE) then
    return BRAND_SHORT
  end
  return nil
end

--- The name in the form the panel's top row can carry beside the LQ reading.
--- Measured against the widest reading rather than the current one, so the
--- mark does not move when the number gains a digit.
function Components.panelBrand(w, m, lqFont)
  return Components.brandText(w - Components.textWidth("LQ 100%", lqFont) - m.pad * 3)
end

-- ============================================================================
-- Elements
-- ============================================================================

--- Background panel. Returns the child list to compose into, so everything
--- placed afterwards is positioned relative to the panel's own origin.
--- A fill and a separate container, the same shape the VTX Admin widget's
--- WidgetLayout uses, and for the same two reasons: opacity applies to the
--- object rather than only its background, so the content cannot live inside
--- the translucent rectangle, and a borderless container puts the content
--- origin exactly on the zone corner. An outlined panel was tried and reads as
--- a card glued over the background while every widget beside it is painted on
--- -- and a border also eats a pixel off each side of the content box, which is
--- enough to make symmetric padding come out lopsided.
function Components.panel(dst, rect, spec)
  local children = {}
  dst[#dst + 1] = {
    type = lvgl.RECTANGLE,
    x = rect.x,
    y = rect.y,
    w = rect.w,
    h = rect.h,
    color = COLOR_THEME_PRIMARY2,
    opacity = spec.opacity,
    filled = true,
  }
  dst[#dst + 1] = {
    type = lvgl.RECTANGLE,
    x = rect.x,
    y = rect.y,
    w = rect.w,
    h = rect.h,
    thickness = 0,
    children = children,
  }
  return children
end

--- A 1px horizontal rule.
--- A filled rectangle, not an hline: hline has no thickness property, an
--- unknown key raises, and lvgl.build() swallows the error along with the
--- whole tree.
--- COLOR_THEME_SECONDARY2 is the obvious choice for a divider and the wrong
--- one: against COLOR_THEME_PRIMARY2, at 1px, it simply does not appear.
function Components.rule(dst, rect, y)
  dst[#dst + 1] = {
    type = lvgl.RECTANGLE,
    x = rect.x,
    y = y,
    w = rect.w,
    h = 1,
    color = COLOR_THEME_DISABLED,
    filled = true,
  }
  return y + 1
end

--- A text label. Thin wrapper, so a tier never hand-writes a descriptor.
function Components.label(dst, spec)
  dst[#dst + 1] = {
    type = lvgl.LABEL,
    x = spec.x,
    y = spec.y,
    w = spec.w,
    align = spec.align or LEFT,
    font = spec.font,
    color = spec.color or COLOR_THEME_PRIMARY1,
    text = spec.text,
    visible = spec.visible,
  }
end

--- A horizontal meter: a track with a fill that grows from the left.
--- spec.pct returns 0-100; spec.color is the fill colour; spec.visible, when
--- given, hides the fill so the bare track shows through.
function Components.bar(dst, rect, y, spec)
  local h = spec.h
  local w = rect.w
  dst[#dst + 1] = {
    type = lvgl.RECTANGLE,
    x = rect.x,
    y = y,
    w = w,
    h = h,
    -- A track has to be soft enough not to compete with the fill and solid
    -- enough to show how far the fill has to go -- an invisible track makes
    -- the bar a floating stub with no scale. COLOR_THEME_SECONDARY2 vanishes
    -- into the panel and COLOR_THEME_DISABLED reads as a second bar, so it is
    -- the disabled grey at part opacity.
    color = COLOR_THEME_DISABLED,
    opacity = TRACK_OPACITY,
    filled = true,
  }
  dst[#dst + 1] = {
    type = lvgl.RECTANGLE,
    x = rect.x,
    y = y,
    w = w,
    h = h,
    color = spec.color,
    filled = true,
    -- Size closures go through luaL_checkunsigned, so this must never return
    -- a negative, and never 0 either: 0 is a literal zero-pixel object rather
    -- than "no width". An empty bar hides via spec.visible instead.
    size = function()
      local fill = math.floor(w * (spec.pct() or 0) / 100)
      if fill < 1 then
        fill = 1
      elseif fill > w then
        fill = w
      end
      return fill, h
    end,
    visible = spec.visible,
  }
  return y + h
end

--- The status LED. x and y are the centre, not a corner.
function Components.led(dst, spec)
  dst[#dst + 1] = {
    type = lvgl.CIRCLE,
    x = spec.x,
    y = spec.y,
    radius = spec.radius,
    filled = true,
    color = spec.color,
  }
end

--- A stepped meter: a continuous track and fill, cut into cells by separators
--- drawn on top in the panel colour.
--- One size closure for the whole meter rather than one per cell, which is
--- the difference between 1 and 8 pcalls a frame. The separators are static,
--- so the fill reads as discrete steps without any cell knowing the value.
--- Outlining the unlit cells instead was tried and is not visible: a
--- COLOR_THEME_SECONDARY2 hairline disappears into COLOR_THEME_PRIMARY2 on
--- the light themes, which took the meter's scale with it -- and a meter
--- whose empty half cannot be seen is just a short bar.
--- spec.visible hides the whole meter, cells and separators included. Every
--- piece needs it: a track left behind while its header and reading hide is
--- what a banner drawn over the strip runs into.
function Components.segments(dst, rect, y, spec)
  local n = spec.count
  local cw = math.floor(rect.w / n)
  local h = spec.h
  local total = cw * n
  dst[#dst + 1] = {
    type = lvgl.RECTANGLE,
    x = rect.x,
    y = y,
    w = total,
    h = h,
    color = COLOR_THEME_DISABLED,
    opacity = TRACK_OPACITY,
    filled = true,
    visible = spec.visible,
  }
  dst[#dst + 1] = {
    type = lvgl.RECTANGLE,
    x = rect.x,
    y = y,
    w = total,
    h = h,
    color = spec.color,
    filled = true,
    size = function()
      local lit = spec.steps()
      if lit > n then
        lit = n
      end
      return math.max(1, lit * cw), h
    end,
    -- At zero steps the size closure would still have to return 1px, so the
    -- meter empties by hiding the fill rather than by shrinking it.
    visible = function()
      if spec.visible and not spec.visible() then
        return false
      end
      return spec.steps() > 0
    end,
  }
  for i = 1, n - 1 do
    dst[#dst + 1] = {
      type = lvgl.RECTANGLE,
      x = rect.x + i * cw - 1,
      y = y,
      w = 1,
      h = h,
      color = COLOR_THEME_PRIMARY2,
      filled = true,
      visible = spec.visible,
    }
  end
  return y + h
end

--- Two antenna cells, the active one lit.
--- The best pixels-per-bit element either reference widget has: it says which
--- RF path is carrying the link in 20px, where a text row costs a whole line.
--- The second cell hides on a single-path receiver rather than sitting dark,
--- which would imply an antenna that is not there.
--- The whole group hides on a mismatch, along with everything else the banner
--- displaces: the strip is not wide enough to hold both, and cells left behind
--- are what "MODEL MISMATCH!" ends up printed across.
--- Sized off the LED beside them rather than off the row: at row height the two
--- cells are solid blocks that take the eye before any reading on the strip
--- does, which is backwards for a qualifier. As a pair of small marks they read
--- as the same class of thing the LED is, and they cost the strip less width.
function Components.antenna(dst, rect, y, m, labelled)
  local cell = antCell(m)
  local gap = m.gap
  local cx = rect.x
  if labelled then
    Components.label(dst, {
      x = rect.x,
      y = y,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = "ANT",
      visible = Display.isNotMismatch,
    })
    cx = rect.x + Components.textWidth("ANT ", SMLSIZE)
  end
  for i = 1, 2 do
    dst[#dst + 1] = {
      type = lvgl.RECTANGLE,
      x = cx + (i - 1) * (cell + gap),
      -- Centred on the text line rather than pinned near its top, which is
      -- where a cell shorter than the row would otherwise sit.
      y = y + math.floor((m.sml - cell) / 2),
      w = cell,
      h = cell,
      color = Display.antColor(i),
      filled = true,
      visible = (i == 2) and function()
        return Display.isNotMismatch() and Display.hasDiversity()
      end or Display.isNotMismatch,
    }
  end
  return cx + 2 * cell + gap
end

-- ============================================================================
-- Blocks
-- ============================================================================

--- The status strip: LED, the name, RF mode, optionally the power meter,
--- antenna cells. Returns the next free y and whether it took the name, so a
--- tier with no name on its strip can put one on the panel instead.
--- The name belongs here because the strip is the module row -- what it is
--- transmitting at, on which antenna -- so "ExpressLRS 150Hz" reads as a
--- header and its value, which is the grammar the captioned groups already
--- use. It stays through a mismatch: knowing which widget is shouting is
--- worth more then than at any other time.
--- A model mismatch takes the rest of the strip. The binding is wrong, which
--- is worth the row -- and the elements it displaces take the inverse visible
--- rather than being left out, so the banner lands in the same rect and
--- nothing below it moves.
--- Only a mismatch gets a banner. "No telemetry" is what the widget shows on
--- the bench with the quad switched off; shouting about a resting state
--- teaches the eye to ignore the banner that matters.
function Components.statusStrip(dst, rect, y, m, spec)
  local h = m.sml + 4
  -- The LED gets a fixed lane sized off the row, and sits centred in it. The
  -- lane is what the text after it measures from, so the dot's radius can be
  -- tuned without the RF mode shifting sideways.
  local lane = math.floor(m.sml / 2) + 2
  -- Deliberately smaller than the lane. An indicator only has to be seen, and
  -- at half the row height it stops reading as a dot and starts competing with
  -- the text it sits beside.
  local r = math.floor(m.sml / 4) + 1
  Components.led(dst, {
    x = rect.x + math.floor(lane / 2),
    -- Centred on the text's line box, not on the strip. The strip is the line
    -- box plus padding, so centring in it drops the dot below the RF mode it
    -- sits beside -- close enough to look like a mistake rather than a choice.
    y = y + math.floor(m.sml / 2),
    radius = r,
    color = Display.ledColor,
  })
  local textX = rect.x + lane + m.pad

  -- Right-hand end, laid out from the right edge inward. Measured before the
  -- name because it is what the name has to fit inside of.
  local antW = Components.textWidth("ANT ", SMLSIZE) + 2 * antCell(m) + m.gap
  local antX = rect.x + rect.w - antW
  -- The mode's x is reserved against the widest rate name the tables carry, so
  -- switching from 25Hz to K1000Full never pushes what follows sideways.
  local modeW = Components.textWidth("K1000Full", SMLSIZE)
  -- Measured against the power reading rather than the whole meter, so the
  -- name outranks the meter's cells but never its number. The cells only
  -- illustrate a figure that stays on the strip either way, and where they go
  -- the existing fallback below puts "50 mW" in the gap instead -- so the strip
  -- keeps everything it was saying and gains the name. A widget that says whose
  -- readings these are is worth more than a lit-cell count of one of them.
  local powerW = 0
  if spec.power or spec.powerText then
    powerW = Components.textWidth("2000 mW", SMLSIZE) + m.pad * 2
  end
  -- The mode-to-power gap is only reserved when there is a power element to
  -- separate the mode from. On a tier that gives TX power its own row this was
  -- holding 12px open for nothing, and the name is what it held them from.
  local gapToPower = powerW > 0 and m.pad * 3 or m.pad
  -- Wider than the strip's other gaps. At one size, with only colour telling
  -- the name from the reading, a tight gap leaves "ExpressLRS 150Hz" reading
  -- as one run-together word.
  local nameGap = m.pad * 2
  local slack = antX - (textX + modeW + gapToPower + powerW)
  local antLabelled = true
  -- Only the full name goes on the strip. Here it is a header to the value
  -- beside it, and an abbreviated header reads as a strip that ran out of
  -- room; the same abbreviation on the panel row still reads as a mark. So a
  -- strip with space for the short form only passes the name down instead.
  local named = Components.brandText(slack - nameGap) == BRAND
  if not named then
    -- Short by less than the antenna caption is wide, so the caption is what
    -- the name is standing behind. The cells are the reading -- which path is
    -- carrying the link -- and "ANT" only says what they are, so on a strip
    -- that has to choose, the word goes and the widget gets its name. A
    -- half-width 480x272 zone misses the full name by a single pixel with the
    -- word in place, which is not a margin worth an anonymous widget.
    local bareW = 2 * antCell(m) + m.gap
    local bareSlack = slack + (antW - bareW)
    if Components.brandText(bareSlack - nameGap) == BRAND then
      named, antLabelled, antW, slack = true, false, bareW, bareSlack
      antX = rect.x + rect.w - antW
    end
  end
  local nameX = textX
  if named then
    textX = textX + Components.textWidth(BRAND, SMLSIZE) + nameGap
  end

  -- The banner runs from wherever the readings start to the end of the strip,
  -- so putting the name first takes width off it. Shortened rather than
  -- squeezed: a banner is no use clipped, and "MISMATCH!" is unambiguous under
  -- a name that has just said which link it is about.
  local banner = MISMATCH
  local bannerX = textX
  if Components.textWidth(banner, BOLD) > rect.x + rect.w - bannerX then
    banner = MISMATCH_SHORT
  end
  -- Nothing left that fits, so the name yields the strip for as long as the
  -- mismatch stands. Last resort, and in the other direction from everywhere
  -- else here: the binding being wrong outranks even saying whose binding.
  local nameHides = Components.textWidth(banner, BOLD) > rect.x + rect.w - bannerX
  if nameHides then
    bannerX = nameX
  end

  if named then
    Components.label(dst, {
      x = nameX,
      y = y,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      -- A constant, so it costs no closure and no per-frame string hash --
      -- except in the one case where the banner needs its width.
      text = BRAND,
      visible = nameHides and Display.isNotMismatch or nil,
    })
  end

  Components.label(dst, {
    x = textX,
    y = y,
    font = SMLSIZE,
    color = COLOR_THEME_PRIMARY1,
    text = Display.rfModeText,
    visible = Display.isNotMismatch,
  })
  Components.label(dst, {
    x = bannerX,
    y = y,
    font = BOLD,
    color = COLOR_THEME_WARNING,
    -- A constant label plus a bool closure, not a formatter: statusText()
    -- keeps title case for the full-screen subtitle it also feeds, and a
    -- string closure would be hashed every frame to say the same thing.
    text = banner,
    visible = Display.isMismatch,
  })

  Components.antenna(dst, { x = antX }, y, m, antLabelled)

  -- The meter goes in the gap between the RF mode and the antenna cells, at
  -- its natural width and only when it genuinely fits there.
  local powerX = textX + modeW + gapToPower
  local meterFits = powerX + Components.powerGroupWidth(m) <= antX
  if spec.power and meterFits then
    Components.powerGroup(dst, { x = powerX }, y, m)
  elseif spec.power or spec.powerText then
    -- No room for the meter, so the reading itself takes the gap. The meter is
    -- the first thing to go and the number is the last, because "50 mW" still
    -- answers the question a lit cell count only illustrates.
    -- Anchored to the antenna cells, not left-aligned off the RF mode. Left
    -- aligned it lands wherever the reserved width of "K1000Full" happens to
    -- end, which on a half-width strip is hard against the cells -- and
    -- "50 mW ANT" reads as one phrase. From the right the gap is the same at
    -- every width, and the box still starts no earlier than the RF mode allows.
    local right = antX - m.pad * 2
    local px = math.max(rect.x, math.min(powerX, right - Components.textWidth("2000 mW", SMLSIZE)))
    Components.label(dst, {
      x = px,
      y = y,
      w = math.max(1, right - px),
      align = RIGHT,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = Display.powerText,
      visible = Display.isNotMismatch,
    })
  end
  return y + h, named
end

--- Width of the TX POWER group, so a caller can place it without stretching
--- it. The meter is sized off the row height rather than off the space
--- available: a meter that grows to fill its container drags its own reading
--- away from it, which leaves "50 mW" stranded at the far side of the strip
--- with no visible tie to the cells it belongs to.
function Components.powerGroupWidth(m)
  return Components.textWidth("TX POWER ", SMLSIZE)
    + Display.powerStepCount() * math.floor(m.sml / 2)
    + m.pad
    + Components.textWidth("2000 mW", SMLSIZE)
end

--- TX POWER as an inline group: header, stepped meter, value.
--- Laid out left to right at its natural width, so the reading sits right
--- after the cells it describes. Any slack in the strip stays to its right.
function Components.powerGroup(dst, rect, y, m)
  local headW = Components.textWidth("TX POWER ", SMLSIZE)
  local valW = Components.textWidth("2000 mW", SMLSIZE)
  local meterW = Display.powerStepCount() * math.floor(m.sml / 2)
  Components.label(dst, {
    x = rect.x,
    y = y,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = "TX POWER",
    visible = Display.isNotMismatch,
  })
  Components.segments(dst, { x = rect.x + headW, w = meterW }, y + 2, {
    count = Display.powerStepCount(),
    h = m.sml - 4,
    visible = Display.isNotMismatch,
    -- Accent, not COLOR_THEME_PRIMARY1. The lit cells are a filled area, and
    -- the text colour used as a fill is a black bar sitting on a blue panel.
    -- Power is also not a health reading -- 500 mW is not worse than 50 -- so
    -- it deliberately stays off the green/amber/red ramp.
    color = COLOR_THEME_FOCUS,
    steps = Display.powerSteps,
  })
  Components.label(dst, {
    x = rect.x + headW + meterW + m.pad,
    y = y,
    w = valW,
    -- Left, so the reading starts a fixed gap from the meter. Right-aligning
    -- it in a box wide enough for "2000 mW" would push "50 mW" away from the
    -- cells again, which is the thing being fixed.
    align = LEFT,
    font = SMLSIZE,
    text = Display.powerText,
    visible = Display.isNotMismatch,
  })
  return y + m.sml
end

--- The uplink panel: the widget's identity.
--- Unheadered on purpose. The uplink is what you fly on -- if it degrades you
--- lose control, where a degraded downlink only makes the numbers stale -- so
--- it takes the whole upper body in a visual register nothing else competes
--- with. Naming it would imply a peer that does not exist here; the downlink
--- is a single captioned row further down.
--- LQ and RSSI each get a full-width bar under their own caption. The two
--- scales differ -- LQ is a fixed 0-100, the headroom track recalibrates with
--- the packet rate -- and comparing their lengths is the useful part: a full
--- LQ bar over a half-full headroom bar reads as "perfect right now, less
--- margin than there could be", which is exactly what is worth seeing early.
--- spec.lqBar and spec.headroomBar drop either bar for the smaller tiers;
--- spec.endpoints adds the headroom scale's numbers where width allows.
--- spec.brand puts the widget's name at the right end of the LQ row, for a
--- tier whose strip had no room for it. That is a mark, not a header: it names
--- the widget, in the one place on the panel nothing else uses, and it does not
--- claim the block below it is "the uplink" as a caption there would.
function Components.uplinkPanel(dst, rect, y, m, spec)
  Components.label(dst, {
    x = rect.x,
    y = y,
    font = spec.lqFont,
    color = Display.lqTextColor,
    text = Display.lqText,
  })
  if spec.brand then
    Components.label(dst, {
      x = rect.x,
      -- Sat on the reading's baseline rather than its top. Labels position from
      -- the top, so small type beside a large number has to be dropped by the
      -- difference or it floats above the digits it sits beside.
      y = y + math.max(0, spec.lqH - m.sml),
      w = rect.w,
      align = RIGHT,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = spec.brand,
    })
  end
  y = y + spec.lqH
  if spec.lqBar then
    y = Components.bar(dst, rect, y, {
      h = spec.barH,
      pct = Display.lqPct,
      color = Display.lqBarColor,
    }) + m.gap
  end

  Components.label(dst, {
    x = rect.x,
    y = y,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = "RSSI",
  })
  Components.label(dst, {
    x = rect.x,
    y = y,
    w = rect.w,
    align = RIGHT,
    font = SMLSIZE,
    color = Display.detailColor,
    text = Display.signalText,
  })
  y = y + m.sml

  if spec.headroomBar then
    y = Components.bar(dst, rect, y, {
      h = spec.barH,
      pct = Display.headroomPct,
      color = Display.headroomBarColor,
      -- No rated floor means no scale, and a bar drawn against a guessed one
      -- is worse than no bar. The track stays so the row keeps its height.
      visible = Display.hasHeadroom,
    })
    if spec.endpoints then
      Components.label(dst, {
        x = rect.x,
        y = y,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = Display.sensText,
      })
      Components.label(dst, {
        x = rect.x,
        y = y,
        w = rect.w,
        align = RIGHT,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = Display.ceilingText,
      })
      y = y + m.sml
    end
  end
  return y
end

--- One row of `HEADER value value ...` groups laid side by side.
--- The inline header is what makes two groups share a row readably: a value
--- always belongs to the nearest header on its left. Groups get measured
--- widths, so a value gaining a digit never reflows the row.
--- groups is a list of { header = "DOWNLINK", w = n, values = { ... } }, where
--- each value is { text = fn, caption = "TQly" } and the caption is optional.
--- The downlink's captions are the sensor names EdgeTX itself puts in the
--- model's telemetry list, mixed case and all, so the row can be read straight
--- across to that list and to the module's own screen.
--- Width one group needs, measured against the widest string each of its
--- values can ever show. Columns sized this way never move when a reading
--- gains a digit, and a tier can ask before committing to a row.
function Components.groupWidth(m, group)
  local w = 0
  if group.header ~= "" then
    w = Components.textWidth(table.concat({ group.header, "  " }), SMLSIZE)
  end
  for i = 1, #group.values do
    local v = group.values[i]
    if v.caption then
      w = w + Components.textWidth(v.caption, SMLSIZE) + m.pad
    end
    w = w + Components.textWidth(v.sample, SMLSIZE) + m.pad * 2
  end
  return w
end

function Components.groupRow(dst, rect, y, m, groups)
  -- Lay out on measured widths and hand the leftover to the gaps between
  -- groups. Splitting the row evenly instead would give a captioned group the
  -- same space as a bare one and overlap its caption with its own value.
  local natural = 0
  for i = 1, #groups do
    natural = natural + Components.groupWidth(m, groups[i])
  end
  local spare = math.max(0, math.floor((rect.w - natural) / math.max(1, #groups)))

  local x = rect.x
  for i = 1, #groups do
    local g = groups[i]
    local cx = x
    -- An empty header drops the group name and lets the captions carry it.
    -- Only the downlink may do that, and only because TQly and TRSS are
    -- self-qualifying: the T prefix already means the transmitter end.
    if g.header ~= "" then
      Components.label(dst, {
        x = x,
        y = y,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = g.header,
      })
      cx = x + Components.textWidth(table.concat({ g.header, "  " }), SMLSIZE)
    end
    for j = 1, #g.values do
      local v = g.values[j]
      local capW = 0
      if v.caption then
        Components.label(dst, {
          x = cx,
          y = y,
          font = SMLSIZE,
          color = COLOR_THEME_SECONDARY1,
          text = v.caption,
        })
        capW = Components.textWidth(v.caption, SMLSIZE) + m.pad
      end
      local cellW = capW + Components.textWidth(v.sample, SMLSIZE) + m.pad * 2
      Components.label(dst, {
        x = cx,
        y = y,
        w = cellW - m.pad,
        align = RIGHT,
        font = SMLSIZE,
        color = COLOR_THEME_PRIMARY1,
        text = v.text,
      })
      cx = cx + cellW
    end
    x = cx + spare
  end
  return y + m.sml
end

-- ============================================================================
-- The 1/1 tier
-- ============================================================================

--- The downlink pair. TRSS always carries dBm: a bare -94 beside a
--- percentage invites reading it as one, and the two numbers on this row are
--- in different units. The unit is not something the width ladder may trade
--- away, so what gives instead is the pack total, then the row, then the
--- header.
local function downlinkGroup(headed)
  return {
    header = headed and "DOWNLINK" or "",
    values = {
      { caption = "TQly", text = Display.tqlyText, sample = "100 %" },
      { caption = "TRSS", text = Display.trssText, sample = "-105 dBm" },
    },
  }
end

local function batteryGroup(compact)
  local g = {
    header = "BATTERY",
    values = {
      { text = Display.cellText, sample = "4S 3.75 V" },
      { text = Display.packText, sample = "15.20 V" },
    },
  }
  if compact then
    g.values[2] = nil
  end
  return g
end

--- Fit the downlink and battery groups into the width there is.
--- A ladder, not a breakpoint: what fits depends on the header and column
--- widths in this screen's font, and the answer already differs between a
--- 396px zone and a 198px one on the same radio.
--- Whole values come off, never half a group -- a lone TQly with no TRSS
--- beside it reads as a downlink with no signal rather than as a row that ran
--- out of room. The DOWNLINK header is the last thing to go, and it can go at
--- all only because TQly and TRSS name themselves.
local function groupRows(w, m)
  local function fits(a, b)
    local total = Components.groupWidth(m, a)
    if b then
      total = total + Components.groupWidth(m, b)
    end
    return total <= w
  end

  if fits(downlinkGroup(true), batteryGroup(false)) then
    return { { downlinkGroup(true), batteryGroup(false) } }
  end
  if fits(downlinkGroup(true), batteryGroup(true)) then
    return { { downlinkGroup(true), batteryGroup(true) } }
  end
  if fits(downlinkGroup(true)) then
    return { { downlinkGroup(true) }, { batteryGroup(true) } }
  end
  return { { downlinkGroup(false) }, { batteryGroup(true) } }
end

--- The whole 1/1 tier: status strip, uplink panel, group rows.
--- Lives here rather than in each screen file because after the components
--- carry the drawing there is nothing screen-specific left in it but the
--- fonts -- and five copies of the vertical arithmetic is exactly the drift
--- the per-screen split is supposed to avoid.
--- Height left over after the fixed rows goes into the bars and the air
--- around the rules, never to the bottom: a panel with a hole in it is what
--- "looks basic" means.
function Components.fullTier(w, h, opa, m, spec)
  local wide = spec.wide
  local f = Components.frame(w, h, m)
  local pad, inner = f.pad, f.inner
  local rows = groupRows(inner.w, m)

  -- Everything except the two bars and the air between blocks. This has to
  -- match what the blocks below actually consume, AIR_GAPS included, or the
  -- last row walks off the bottom of the panel.
  local AIR_GAPS = 4
  local fixed = pad * 2 -- top and bottom
    + (m.sml + 4) -- status strip
    + 2 -- two rules
    + spec.lqH -- LQ
    + m.gap -- LQ bar to RSSI row
    + m.sml -- RSSI row
    + (wide and m.sml or 0) -- headroom endpoints
    + m.sml * #rows
    + (wide and 0 or m.sml + m.gap) -- narrow puts TX POWER on its own row
  local slack = f.h - fixed
  local barH = math.max(4, math.min(math.floor(slack * 0.3), 26))
  local air = math.max(m.gap, math.floor((slack - barH * 2) / AIR_GAPS))

  local root = {}
  local panel = Components.panel(root, f.panel, { opacity = opa })

  local y, named = Components.statusStrip(panel, inner, pad, m, { power = wide })
  y = Components.rule(panel, inner, y + air)
  y = Components.uplinkPanel(panel, inner, y + air, m, {
    lqFont = spec.lqFont,
    lqH = spec.lqH,
    barH = barH,
    lqBar = true,
    headroomBar = true,
    endpoints = wide,
    -- A narrow strip has nothing to spare between the RF mode and the antenna
    -- cells, and the LQ row has a whole empty right half.
    brand = not named and Components.panelBrand(inner.w, m, spec.lqFont) or nil,
  })
  y = Components.rule(panel, inner, y + air) + air
  if not wide then
    -- Half width has no gap in the strip wide enough for the meter, so TX power
    -- takes its own row at the head of the captioned groups. Header, meter,
    -- reading is the same shape DOWNLINK and BATTERY have, so it reads as one of
    -- them rather than as something wedged under the strip -- and it leads them
    -- because it is what the module is transmitting at, where the rows below it
    -- are what came back from the aircraft.
    y = Components.powerGroup(panel, inner, y, m) + m.gap
  end
  for i = 1, #rows do
    y = Components.groupRow(panel, inner, y, m, rows[i])
  end

  lvgl.build(root)
end

--- The 1/2 tier: the same panel with the group rows and the rules taken out.
--- Both bars survive here, and that is the point of the whole layout. This is
--- the size the widget is most often placed at, and it is where an earlier
--- draft -- uplink and downlink as mirrored blocks -- could not keep even one
--- of them. The downlink row goes first because it is a whole group, and the
--- bars are what the widget is for.
--- TX power stays as the text in the strip; only the meter goes.
function Components.halfTier(w, h, opa, m, spec)
  local f = Components.frame(w, h, m)
  local pad, inner = f.pad, f.inner
  local battery = {
    header = "BATTERY",
    values = { { text = Display.cellText, sample = "4S 3.75 V" } },
  }
  local AIR_GAPS = 2
  -- Thinner than this and a bar is a line, not a meter.
  local MIN_BAR = 3
  local fixed = pad * 2
    + (m.sml + 4) -- status strip
    + spec.lqH
    + m.gap
    + m.sml -- RSSI row

  -- Battery is a whole group, so it goes before either bar is squeezed below
  -- the height at which it stops reading as a bar. That is the degradation
  -- order the whole layout follows: lose a row, keep the instruments.
  local showBattery = Components.groupWidth(m, battery) <= inner.w and (f.h - fixed - m.sml) >= MIN_BAR * 2
  if showBattery then
    fixed = fixed + m.sml
  end

  local slack = f.h - fixed
  local barH = math.max(MIN_BAR, math.min(math.floor(slack * 0.35), 20))
  local air = math.max(0, math.floor((slack - barH * 2) / AIR_GAPS))

  local root = {}
  local panel = Components.panel(root, f.panel, { opacity = opa })

  local y, named = Components.statusStrip(panel, inner, pad, m, { powerText = true })
  y = Components.uplinkPanel(panel, inner, y + air, m, {
    lqFont = spec.lqFont,
    lqH = spec.lqH,
    barH = barH,
    lqBar = true,
    headroomBar = true,
    brand = not named and Components.panelBrand(inner.w, m, spec.lqFont) or nil,
  })
  if showBattery then
    Components.groupRow(panel, inner, y + air, m, { battery })
  end

  lvgl.build(root)
end

-- ============================================================================
-- Return components
-- ============================================================================

return Components
