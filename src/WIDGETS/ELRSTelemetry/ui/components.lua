---------------------------------------------------------------------------
-- ELRS Telemetry Widget - Drawing Components                            --
-- Loaded via loadScript() from ELRSTelemetry/loadable.lua with          --
-- (Display); returns the Components table.                              --
--                                                                       --
-- Two layers. Elements are the shapes -- panel, bar, led, antenna,      --
-- label. Blocks are what a tier actually places: the header row, the    --
-- LQ hero, a captioned value row, the reading grid. Keeping the blocks  --
-- here is what makes five per-screen files affordable: a tier builder   --
-- stays a short vertical composition instead of eight inlined element   --
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
-- Written the way ExpressLRS writes it rather than uppercased like the
-- captions further down: this is a name, not a caption, and the same reason
-- keeps the mixed case in TQly and TRSS.
local BRAND = "ExpressLRS"
local BRAND_SHORT = "ELRS"

-- The mismatch banner, and the short form for a header that cannot carry the
-- long one. Caps either way: this is the one thing on the header worth
-- interrupting for.
local MISMATCH = "MODEL MISMATCH!"
local MISMATCH_SHORT = "MISMATCH!"

--- Side of one antenna cell. Half the row, so the pair sits at the status
--- dot's weight rather than the text's.
local function antCell(m)
  return math.floor(m.sml / 2) + 1
end

--- Radius of the status dot. Deliberately smaller than the row: an indicator
--- only has to be seen, and at half the row height it stops reading as a dot
--- and starts competing with the text beside it.
local function dotRadius(m)
  return math.floor(m.sml / 4) + 1
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
    lines = {},
  }
  m.sml = Components.lineHeight(m, SMLSIZE)
  m.bold = Components.lineHeight(m, BOLD)
  m.mid = Components.lineHeight(m, MIDSIZE)
  return m
end

--- Line height of a font, measured once per font and cached on the metrics
--- table. This is what lets a screen file declare its hero ladder as font
--- names alone: the height half of the pair is always the measured truth.
function Components.lineHeight(m, font)
  local h = m.lines[font]
  if h == nil then
    h = select(2, lcd.sizeText("0", font))
    m.lines[font] = h
  end
  return h
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
--- A ladder rather than a per-radio breakpoint: what fits is a measured width
--- in this screen's font.
function Components.brandText(availW)
  if availW >= Components.textWidth(BRAND, SMLSIZE) then
    return BRAND
  end
  if availW >= Components.textWidth(BRAND_SHORT, SMLSIZE) then
    return BRAND_SHORT
  end
  return nil
end

--- The largest hero font whose line box fits the budget, with its measured
--- height. The ladder exists because one tier builder serves more than one
--- zone height -- on 480x272 the 1/1 composition draws both the 227px full
--- zone and the 113px half zone -- so the hero has to be picked from what the
--- zone can afford, not declared per tier. The last rung is the floor: it is
--- taken even when over budget, because a panel with no hero is not this
--- widget.
function Components.heroFromLadder(m, ladder, budget)
  for i = 1, #ladder do
    local font = ladder[i]
    local fh = Components.lineHeight(m, font)
    if fh <= budget then
      return font, fh
    end
  end
  local last = ladder[#ladder]
  return last, Components.lineHeight(m, last)
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
--- spec.rounded is the card's corner radius, on the fill alone: the container
--- draws nothing, so its square corners cannot show.
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
    rounded = spec.rounded,
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
  -- Pill ends. rounded is a build-time corner radius, which is fine here: the
  -- bar's height is fixed per build, and LVGL clamps the radius itself when
  -- the fill's live width drops below the pill's diameter.
  local r = math.floor(h / 2)
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
    rounded = r,
  }
  dst[#dst + 1] = {
    type = lvgl.RECTANGLE,
    x = rect.x,
    y = y,
    w = w,
    h = h,
    color = spec.color,
    filled = true,
    rounded = r,
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

--- Two antenna cells, the active one lit.
--- The best pixels-per-bit element either reference widget has: it says which
--- RF path is carrying the link in 20px, where a text row costs a whole line.
--- The second cell hides on a single-path receiver rather than sitting dark,
--- which would imply an antenna that is not there.
--- The whole group hides on a mismatch, along with everything else the banner
--- displaces: the header is not wide enough to hold both, and cells left
--- behind are what "MODEL MISMATCH!" ends up printed across.
--- Sized off the status dot beside them rather than off the row: at row
--- height the two cells are solid blocks that take the eye before any reading
--- does, which is backwards for a qualifier. As a pair of small marks they
--- read as the same class of thing the dot is.
function Components.antenna(dst, rect, y, m)
  local cell = antCell(m)
  local gap = m.gap
  local cx = rect.x
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

--- The header row: the name and the RF mode on the left, the antenna cells
--- and the status dot pinned to the right corner. Returns the next free y.
--- The name belongs here because the header is the module row -- what it is
--- transmitting at, on which antenna -- so "ExpressLRS 250Hz" reads as a
--- header and its value, the same grammar the grid's captioned cells use.
--- spec.detail swaps the RF mode for the mode-plus-power form, for tiers with
--- no grid row left to carry the power reading.
--- A model mismatch takes the row. The binding is wrong, which is worth it --
--- and the elements the banner displaces take the inverse visible rather than
--- being left out, so the banner lands in the same rect and nothing below it
--- moves. The dot stays: it is the blink saying the same thing.
--- Only a mismatch gets a banner. "No telemetry" is what the widget shows on
--- the bench with the quad switched off; shouting about a resting state
--- teaches the eye to ignore the banner that matters.
function Components.headerRow(dst, rect, y, m, spec)
  local h = m.sml + 4
  local dotR = dotRadius(m)
  local antW = 2 * antCell(m) + m.gap
  local dotX = rect.x + rect.w - dotR
  local antX = rect.x + rect.w - dotR * 2 - m.pad - antW

  -- The mode's x is reserved against the widest rate name the tables carry,
  -- so switching from 25Hz to K1000Full never pushes what follows sideways.
  local modeW = Components.textWidth(spec.detail and "K1000Full 2000mW" or "K1000Full", SMLSIZE)
  -- Wider than the header's other gaps. At one size, with only colour telling
  -- the name from the reading, a tight gap leaves "ExpressLRS 250Hz" reading
  -- as one run-together word.
  local nameGap = m.pad * 2
  local brand = Components.brandText(antX - m.pad - rect.x - modeW - nameGap)
  local textX = rect.x
  if brand then
    textX = rect.x + Components.textWidth(brand, SMLSIZE) + nameGap
  end

  -- The banner runs from wherever the readings start to the dot, because the
  -- cells it displaces hide with it. Shortened rather than squeezed: a banner
  -- is no use clipped, and "MISMATCH!" is unambiguous under a name that has
  -- just said which link it is about.
  local bannerLimit = rect.x + rect.w - dotR * 2 - m.pad
  local banner = MISMATCH
  if Components.textWidth(banner, BOLD) > bannerLimit - textX then
    banner = MISMATCH_SHORT
  end
  -- Nothing left that fits, so the name yields the row for as long as the
  -- mismatch stands. Last resort, and in the other direction from everywhere
  -- else here: the binding being wrong outranks even saying whose binding.
  local nameHides = Components.textWidth(banner, BOLD) > bannerLimit - textX
  local bannerX = textX
  if nameHides then
    bannerX = rect.x
  end

  if brand then
    Components.label(dst, {
      x = rect.x,
      y = y,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      -- A constant, so it costs no closure and no per-frame string hash --
      -- except in the one case where the banner needs its width.
      text = brand,
      visible = nameHides and Display.isNotMismatch or nil,
    })
  end
  Components.label(dst, {
    x = textX,
    y = y,
    font = SMLSIZE,
    color = COLOR_THEME_PRIMARY1,
    text = spec.detail and Display.rfDetailText or Display.rfModeText,
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

  Components.antenna(dst, { x = antX }, y, m)
  Components.led(dst, {
    x = dotX,
    -- Centred on the text's line box, not on the row. The row is the line box
    -- plus padding, so centring in it drops the dot below the text it sits
    -- beside -- close enough to look like a mistake rather than a choice.
    y = y + math.floor(m.sml / 2),
    radius = dotR,
    color = Display.ledColor,
  })
  return y + h
end

--- The hero figure: the bare LQ number in the tier's display font, with the
--- "LQ %" caption dropped to its baseline beside it. The caption's x is
--- reserved against the widest reading, so the caption never moves when the
--- number loses a digit.
--- spec.right puts a small reading on the same baseline at the right edge,
--- for a tier that merges the hero and the RSSI row into one.
function Components.hero(dst, rect, y, m, spec)
  Components.label(dst, {
    x = rect.x,
    y = y,
    font = spec.font,
    color = Display.lqTextColor,
    text = Display.lqHeroText,
  })
  -- Small type beside a large number sits on its baseline, not its top:
  -- labels position from the top, so the caption drops by the difference.
  local drop = math.max(0, spec.h - m.sml)
  Components.label(dst, {
    x = rect.x + Components.textWidth("100", spec.font) + m.pad,
    y = y + drop,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = "LQ %",
  })
  if spec.right then
    Components.label(dst, {
      x = rect.x,
      y = y + drop,
      w = rect.w,
      align = RIGHT,
      font = SMLSIZE,
      color = Display.detailColor,
      text = spec.right,
    })
  end
  return y + spec.h
end

--- A captioned value row: muted caption on the left, the reading right-aligned
--- on the same line. The bar a tier draws under it is its own call, so the row
--- reads the same with or without one.
function Components.valueRow(dst, rect, y, m, spec)
  Components.label(dst, {
    x = rect.x,
    y = y,
    font = SMLSIZE,
    color = COLOR_THEME_SECONDARY1,
    text = spec.caption,
  })
  Components.label(dst, {
    x = rect.x,
    y = y,
    w = rect.w,
    align = RIGHT,
    font = SMLSIZE,
    color = spec.color or COLOR_THEME_PRIMARY1,
    text = spec.text,
  })
  return y + m.sml
end

--- The reading grid: two equal columns of caption-value cells, in rows.
--- The captions are the sensor names EdgeTX itself puts in the model's
--- telemetry list, mixed case and all, so the grid reads straight across to
--- that list and to the module's own screen.
--- Values sit a fixed gap after their caption, left-aligned, so a reading
--- gaining a digit grows into its own column's slack and nothing reflows.
--- rows is a list of rows, each a list of { caption, text } cells.
function Components.grid(dst, rect, y, m, rows)
  local colW = math.floor((rect.w - m.pad) / 2)
  for i = 1, #rows do
    local row = rows[i]
    for j = 1, #row do
      local cell = row[j]
      local cx = rect.x + (j - 1) * (colW + m.pad)
      Components.label(dst, {
        x = cx,
        y = y,
        font = SMLSIZE,
        color = COLOR_THEME_SECONDARY1,
        text = cell.caption,
      })
      Components.label(dst, {
        x = cx + Components.textWidth(cell.caption, SMLSIZE) + m.pad,
        y = y,
        font = SMLSIZE,
        color = COLOR_THEME_PRIMARY1,
        text = cell.text,
      })
    end
    y = y + m.sml
    if i < #rows then
      y = y + m.gap
    end
  end
  return y
end

--- The downlink-and-battery grid rows the 1/1 tier shows in full and the 1/2
--- tier appends the second of when it has the height. PWR leads because it is
--- what the module is transmitting at, where the rest is what came back from
--- the aircraft. TRSS always carries dBm: a bare -94 beside a percentage
--- invites reading it as one.
local function gridRows()
  return {
    {
      { caption = "PWR", text = Display.powerText },
      { caption = "TQly", text = Display.tqlyText },
    },
    {
      { caption = "BATT", text = Display.cellText },
      { caption = "TRSS", text = Display.trssText },
    },
  }
end

-- ============================================================================
-- Tiers
-- ============================================================================

--- The whole 1/1 tier: header, hero, the two bar rows, the reading grid.
--- Lives here rather than in each screen file because after the components
--- carry the drawing there is nothing screen-specific left in it but the
--- fonts -- and five copies of the vertical arithmetic is exactly the drift
--- the per-screen split is supposed to avoid.
--- Height left over after the fixed rows goes into the bars and the air
--- between blocks, never to the bottom: a panel with a hole in it is what
--- "looks basic" means.
--- LQ gets the hero and the first bar because the uplink is what you fly on;
--- the RSSI row under it keeps the rated floor in the text and draws its bar
--- against that floor, so a full LQ bar over a half-full RSSI bar still reads
--- as "perfect right now, less margin than there could be".
function Components.fullTier(w, h, opa, m, spec)
  local f = Components.frame(w, h, m)
  local pad, inner = f.pad, f.inner

  -- Everything except the hero, the two bars and the air between blocks. This
  -- has to match what the blocks below actually consume, AIR_GAPS included,
  -- or the last row walks off the bottom of the panel.
  local AIR_GAPS = 3
  local MIN_BAR = 4
  local fixedNoHero = pad * 2
    + (m.sml + 4) -- header row
    + m.gap -- hero to LQ bar
    + m.sml -- RSSI row
    + m.gap -- RSSI row to its bar
    + (m.sml * 2 + m.gap) -- grid
  local heroFont, heroH =
    Components.heroFromLadder(m, spec.heroLadder, f.h - fixedNoHero - MIN_BAR * 2 - AIR_GAPS * m.gap)

  local slack = f.h - fixedNoHero - heroH
  -- A gentle fraction of the slack: the tier also serves zones barely over
  -- the 1/2 breakpoint, where a generous cut of a small slack makes the bars
  -- thicker than the rows they sit under. The tall 1/1 still reaches the cap.
  local barH = math.max(MIN_BAR, math.min(math.floor(slack * 0.12), spec.barH))
  local air = math.max(m.gap, math.floor((slack - barH * 2) / AIR_GAPS))

  local root = {}
  local panel = Components.panel(root, f.panel, { opacity = opa, rounded = spec.rounded })

  local y = Components.headerRow(panel, inner, pad, m, {})
  y = Components.hero(panel, inner, y + air, m, { font = heroFont, h = heroH })
  y = Components.bar(panel, inner, y + m.gap, {
    h = barH,
    pct = Display.lqPct,
    color = Display.lqBarColor,
  })
  y = Components.valueRow(panel, inner, y + air, m, {
    caption = "RSSI",
    text = Display.signalText,
    color = Display.detailColor,
  })
  y = Components.bar(panel, inner, y + m.gap, {
    h = barH,
    pct = Display.headroomPct,
    color = Display.headroomBarColor,
    -- No rated floor means no scale, and a bar drawn against a guessed one
    -- is worse than no bar. The track stays so the row keeps its height.
    visible = Display.hasHeadroom,
  })
  Components.grid(panel, inner, y + air, m, gridRows())

  lvgl.build(root)
end

--- The 1/2 tier (a 1/3-height zone): the same card with the grid cut to what
--- fits. The header takes the power reading, the hero drops to the tier's own
--- font, and both bars survive -- they are what the widget is for. The
--- BATT/TRSS row comes back the moment the zone can hold it over bars still
--- thick enough to read, which is the rung the halfH breakpoint exists for.
function Components.halfTier(w, h, opa, m, spec)
  local f = Components.frame(w, h, m)
  local pad, inner = f.pad, f.inner
  local heroH = Components.lineHeight(m, spec.heroFont)
  local AIR_GAPS = 2
  -- Thinner than this and a bar is a line, not a meter.
  local MIN_BAR = 3
  local fixed = pad * 2
    + (m.sml + 4) -- header row
    + heroH
    + m.gap -- hero to LQ bar
    + m.sml -- RSSI row
    + m.gap -- RSSI row to its bar

  -- The grid row is whole or absent, and it goes before either bar is
  -- squeezed below the height at which it stops reading as a bar. That is
  -- the degradation order the whole layout follows: lose a row, keep the
  -- instruments.
  local showGrid = (f.h - fixed - (m.sml + m.gap)) >= MIN_BAR * 2
  if showGrid then
    fixed = fixed + m.sml + m.gap
  end

  local slack = f.h - fixed
  local barH = math.max(MIN_BAR, math.min(math.floor(slack * 0.28), spec.barH))
  local air = math.max(0, math.floor((slack - barH * 2) / AIR_GAPS))

  local root = {}
  local panel = Components.panel(root, f.panel, { opacity = opa, rounded = spec.rounded })

  local y = Components.headerRow(panel, inner, pad, m, { detail = true })
  y = Components.hero(panel, inner, y + air, m, { font = spec.heroFont, h = heroH })
  y = Components.bar(panel, inner, y + m.gap, {
    h = barH,
    pct = Display.lqPct,
    color = Display.lqBarColor,
  })
  y = Components.valueRow(panel, inner, y + air, m, {
    caption = "RSSI",
    text = Display.signalText,
    color = Display.detailColor,
  })
  y = Components.bar(panel, inner, y + m.gap, {
    h = barH,
    pct = Display.headroomPct,
    color = Display.headroomBarColor,
    visible = Display.hasHeadroom,
  })
  if showGrid then
    local rows = gridRows()
    Components.grid(panel, inner, y + m.gap, m, { rows[2] })
  end

  lvgl.build(root)
end

--- The 1/3 tier (a 1/4-height zone): header, the hero sharing its baseline
--- with the RSSI pair, one bar.
--- Losing the RSSI caption costs nothing: "-85 / -108 dBm" carries its own
--- unit, and with one bar left there is no second reading it could be
--- mistaken for. The bar is the RSSI one. Between the two, it is the one that
--- says something the number beside it does not -- it recalibrates with the
--- packet rate -- where an LQ bar plots a percentage that is already legible
--- as a percentage.
function Components.thirdTier(w, h, opa, m, spec)
  local f = Components.frame(w, h, m)
  local pad, inner = f.pad, f.inner
  local heroH = Components.lineHeight(m, spec.heroFont)
  local AIR_GAPS = 2
  -- Thinner than this and a bar is a line, not a meter.
  local MIN_BAR = 3
  local fixed = pad * 2
    + (m.sml + 4) -- header row
    + heroH
  local slack = f.h - fixed
  local barH = math.max(MIN_BAR, math.min(math.floor(slack * 0.45), spec.barH))
  local air = math.max(0, math.floor((slack - barH) / AIR_GAPS))

  local root = {}
  local panel = Components.panel(root, f.panel, { opacity = opa, rounded = spec.rounded })

  local y = Components.headerRow(panel, inner, pad, m, { detail = true })
  y = Components.hero(panel, inner, y + air, m, {
    font = spec.heroFont,
    h = heroH,
    right = Display.signalText,
  })
  Components.bar(panel, inner, y + air, {
    h = barH,
    pct = Display.headroomPct,
    color = Display.headroomBarColor,
    visible = Display.hasHeadroom,
  })

  lvgl.build(root)
end

--- The short tiers -- 1/4 and 1/6 -- as one composition: a row of readings
--- over the RSSI bar, with the bar thinning and the row shedding cells as the
--- zone shrinks.
--- One function for both because the difference between them turned out to be
--- a bar height and a cell count, both of which are measured here anyway. Two
--- builders differing only in that were two places to fix the same bug.
--- The header is what goes at this height, and the mode, power and antenna
--- cells go with it. Two rows cannot hold a header and a bar, and the bar is
--- what this widget is: below the header the choice is between a row of
--- numbers any telemetry screen could show and the one instrument only this
--- widget has.
--- The name and the mode cell read as one phrase from the left -- the same
--- grammar as the header's "ExpressLRS 250Hz", in one font and one colour --
--- and the link readings pack the right margin: LQ, then the dBm pair, then
--- the status dot in the corner, where every taller tier puts it.
--- The hero label falls back to the status text: there is no header here to
--- carry a banner.
function Components.compactTier(w, h, opa, m, spec)
  local f = Components.frame(w, h, m)
  local pad, inner = f.pad, f.inner
  local heroH = Components.lineHeight(m, spec.heroFont)
  -- Thinner than this and a bar is a line, not a meter. Below it the row takes
  -- the whole panel and centres in it, rather than sitting above a smear.
  local MIN_BAR = 3
  local vpad = pad
  local slack = f.h - (vpad * 2 + heroH)
  if slack < MIN_BAR then
    -- A 1/6 zone is 28px on 480x272, which is the row and its padding and
    -- nothing else. So the padding gives: the left and right edges keep theirs,
    -- because that is what a widget in the zone above lines its text up
    -- against, and the top and bottom drop to the smallest gap the theme has.
    -- Worth it for 3px of bar, because the bar is the reading that no other
    -- widget on the screen offers -- and losing it here is losing it at the
    -- size the widget is most often squeezed into.
    vpad = m.gap
    slack = f.h - (vpad * 2 + heroH)
  end
  -- Capped where the taller tiers' fractions land in practice, so a widget
  -- resized across the ladder keeps one bar weight: a roomy 1/4 zone used to
  -- fill toward this cap's double while every other size drew ~6px.
  local barH = slack >= MIN_BAR and math.max(MIN_BAR, math.min(math.floor(slack * 0.3), spec.barH)) or 0
  local air = math.max(0, slack - barH)
  -- Small type beside a large number sits on its baseline, not its top.
  local drop = math.max(0, heroH - m.sml)

  local root = {}
  local panel = Components.panel(root, f.panel, { opacity = opa, rounded = spec.rounded })
  -- With no bar the row has the panel to itself, so it centres; with one it
  -- keeps the top and the bar takes the slack.
  local y = vpad + (barH > 0 and 0 or math.floor(air / 2))

  -- The status dot holds the right corner, as it does on every taller tier.
  local dotR = dotRadius(m)
  local right = inner.x + inner.w
  Components.led(panel, {
    x = right - dotR,
    -- Centred on the dropped small-text line the readings beside it sit on.
    y = y + drop + math.floor(m.sml / 2),
    radius = dotR,
    color = Display.ledColor,
  })
  local textRight = right - dotR * 2 - m.pad

  local textX = inner.x
  local signalW = Components.textWidth("-105 / -105 dBm", SMLSIZE)
  local detailW = Components.textWidth("K1000Full 2000mW", SMLSIZE)
  -- The hero box is reserved against the widest string the label can ever
  -- carry -- the statuses, not just the reading. A fixed-width box that the
  -- live text can outgrow would wrap rather than clip, and take the row with
  -- it; "Model Mismatch" wrapping over the bar is exactly what this pays for.
  local heroW = math.max(
    Components.textWidth("LQ 100%", spec.heroFont),
    Components.textWidth("No CRSF module", spec.heroFont),
    Components.textWidth("Model Mismatch", spec.heroFont)
  )
  -- Six pads: the name and the detail advance by two each, and the signal box
  -- keeps two off the hero. Reserving fewer lets the advances eat into the
  -- hero's own reserve.
  local avail = textRight - textX - signalW - heroW - m.pad * 6
  local showDetail = avail >= detailW + m.pad
  if showDetail then
    avail = avail - detailW - m.pad
  end
  local brand = Components.brandText(avail)

  if brand then
    -- The name leads the row, the same grammar as the header -- so the line
    -- ends on a reading, not on the mark. The readings shift right by the
    -- name's width and the gap is the header's name gap, wide enough that
    -- name and reading do not run together.
    Components.label(panel, {
      x = textX,
      y = y + drop,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = brand,
    })
    textX = textX + Components.textWidth(brand, SMLSIZE) + m.pad * 2
  end
  if showDetail then
    Components.label(panel, {
      x = textX,
      y = y + drop,
      font = SMLSIZE,
      color = COLOR_THEME_SECONDARY1,
      text = Display.rfDetailText,
      -- Hidden with the other readings while the hero carries a status.
      visible = Display.isNotMismatch,
    })
    textX = textX + detailW + m.pad * 2
  end
  -- LQ's box spans the middle, right-aligned against the dBm pair: normally
  -- only the reserved right end of it is inked, and a status -- the one long
  -- string this label ever carries -- grows leftward across the row the
  -- hidden readings have just emptied.
  local heroRight = textRight - signalW - m.pad * 2
  Components.label(panel, {
    x = textX,
    y = y,
    w = math.max(1, heroRight - textX),
    align = RIGHT,
    font = spec.heroFont,
    color = Display.heroColor,
    text = Display.heroText,
  })
  Components.label(panel, {
    x = textRight - signalW,
    y = y + drop,
    w = signalW,
    align = RIGHT,
    font = SMLSIZE,
    color = Display.detailColor,
    text = Display.signalShortText,
    visible = Display.isNotMismatch,
  })

  if barH > 0 then
    Components.bar(panel, inner, vpad + heroH + air, {
      h = barH,
      pct = Display.headroomPct,
      color = Display.headroomBarColor,
      visible = Display.hasHeadroom,
    })
  end

  lvgl.build(root)
end

return Components
