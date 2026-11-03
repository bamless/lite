local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local syntax = require "core.syntax"
local tokenizer = require "core.tokenizer"
local View = require "core.view"
local DocView = require "core.docview"
local CommandView = require "core.commandview"
local Tooltip = require "core.tooltip"

local font_files = {
  regular = EXEDIR .. "/data/fonts/font.ttf",
  bold = EXEDIR .. "/data/fonts/font_bold.ttf",
  italic = EXEDIR .. "/data/fonts/font_italic.ttf",
  bold_italic = EXEDIR .. "/data/fonts/font_bold_italic.ttf",
}

local md_fonts = {
  md_bold = { "bold", 1 },
  md_italic = { "italic", 1 },
  md_bold_italic = { "bold_italic", 1 },
  md_h1 = { "bold", 1.85 },
  md_h1_italic = { "bold_italic", 1.85 },
  md_h2 = { "bold", 1.5 },
  md_h2_italic = { "bold_italic", 1.5 },
  md_h3 = { "bold", 1.2 },
  md_h3_italic = { "bold_italic", 1.2 },
}

local set_scale = style.set_scale
function style.set_scale(scale)
  local size = style.fonts.font[2]
  for name, font in pairs(md_fonts) do
    style.fonts[name] = { font_files[font[1]], size * font[2] }
  end
  set_scale(scale)
end

local body_family = {
  regular = "font", bold = "md_bold", italic = "md_italic", bold_italic = "md_bold_italic",
}

local heading_families = {
  { regular = "md_h1",   italic = "md_h1_italic" },
  { regular = "md_h2",   italic = "md_h2_italic" },
  { regular = "md_h3",   italic = "md_h3_italic" },
  { regular = "md_bold", italic = "md_bold_italic" },
}

local lang_extensions = {
  python = "py",
  javascript = "js",
  jstar = "jsr",
  ["c++"] = "cpp",
}


-- -----------------------------------------------------------------------------
-- Layout
-- -----------------------------------------------------------------------------


-- TODO: move into the theme once the preview's colours settle.
local link_color = { common.color "#6cb6ff" }

local function span_style(span, family, base_color)
  local color = span.link and link_color or base_color
  if span.code then
    return style.code_font, color
  end
  local face = span.bold and (span.italic and "bold_italic" or "bold")
      or (span.italic and "italic" or "regular")
  return style[family[face] or family.regular], color
end


local function get_image_size(entry, max_width)
  local w = math.max(1, common.round(entry.width * style.scale))
  local h = math.max(1, common.round(entry.height * style.scale))
  if w > max_width then
    w, h = math.max(1, math.floor(max_width)), math.max(1, math.floor(h * max_width / w))
  end
  return w, h
end


local function get_scaled_image(entry, w, h)
  if w == entry.width and h == entry.height then return entry.image end
  local key = w .. "x" .. h
  local image = entry.sizes[key] or entry.previous_sizes[key] or entry.image:resized(w, h)
  entry.sizes[key] = image
  return image
end


-- Word-wraps `spans` into the column from `x` to `x + width`, appending runs to `items`.
-- Returns the y below the last line.
-- TODO: break words wider than the column, instead of letting them overflow.
-- TODO: Knuth-Plass line breaking for more even lines (?).
local function wrap_spans(spans, x, width, y, family, base_color, items, align)
  local line_runs = {}
  local cx = x
  local pending_space
  local underline = math.max(1, common.round(style.scale))

  -- whether the next line starts after a hard break rather than a wrap
  local hard = true

  local function flush_line()
    if #line_runs == 0 then return y end
    local text_h, image_h = 0, 0
    for _, run in ipairs(line_runs) do
      if run.image then
        image_h = math.max(image_h, run.h)
      else
        text_h = math.max(text_h, run.font:get_height())
      end
    end
    local lh = math.max(math.floor(text_h * config.line_height), image_h)
    local line = { y = y, h = lh, hard = hard }
    hard = false
    if align == "center" or align == "right" then
      local last = line_runs[#line_runs]
      local shift = x + width - (last.x + last.w)
      if align == "center" then shift = math.floor(shift / 2) end
      for _, run in ipairs(line_runs) do run.x = run.x + shift end
    end
    for _, run in ipairs(line_runs) do
      if run.code then
        table.insert(items, {
          x = run.x - 2,
          y = y,
          w = run.w + 4,
          h = lh,
          color = style.background2
        })
      end
    end
    for _, run in ipairs(line_runs) do
      if not run.image then
        run.h = run.font:get_height()
        run.line = line
      end
      run.y = y + common.round((lh - run.h) / 2)
      table.insert(items, run)
      if run.link and not run.image then
        table.insert(items, {
          x = run.x,
          y = run.y + run.h - underline,
          w = run.w,
          h = underline,
          color = run.color
        })
      end
      if run.strike then
        table.insert(items, {
          x = run.x,
          y = run.y + math.floor(run.h * 0.55),
          w = run.w,
          h = underline,
          color = run.color
        })
      end
    end
    line_runs = {}
    y = y + lh
    return y
  end

  local function place_image(span)
    local w, h = get_image_size(span.loaded, width)
    local sw = (pending_space and #line_runs > 0) and pending_space.font:get_width(" ") or 0
    if cx + sw + w > x + width and #line_runs > 0 then
      flush_line()
      cx, sw = x, 0
    end
    table.insert(line_runs, {
      x = cx + sw,
      w = w,
      h = h,
      link = span.link,
      span = span,
      image = get_scaled_image(span.loaded, w, h)
    })
    cx = cx + sw + w
    pending_space = nil
  end

  for _, span in ipairs(spans) do
    local font, color = span_style(span, family, base_color)
    if span.loaded then
      place_image(span)
      goto next_span
    end
    for space, word in span.text:gmatch("(%s*)(%S*)") do
      if space:find("\n", 1, true) then
        flush_line()
        cx, pending_space, hard = x, nil, true
      elseif space ~= "" then
        pending_space = { font = font, text = " " }
      end
      if word ~= "" then
        local w = font:get_width(word)
        local sw = (pending_space and #line_runs > 0)
            and pending_space.font:get_width(" ") or 0
        if cx + sw + w > x + width and #line_runs > 0 then
          flush_line()
          cx, sw = x, 0
        end
        local last = line_runs[#line_runs]
        if last and last.font == font and last.color == color
            and last.code == span.code and last.link == span.link and last.strike == span.strike
            and (last.span == span or not (span.link or span.code)) then
          last.text = last.text .. (sw > 0 and " " or "") .. word
          last.w = last.w + sw + w
        else
          table.insert(line_runs, {
            x = cx + sw,
            w = w,
            font = font,
            color = color,
            text = word,
            code = span.code,
            link = span.link,
            strike = span.strike,
            span = span,
            space_before = sw > 0
          })
        end
        cx = cx + sw + w
        pending_space = nil
      end
    end
    ::next_span::
  end

  return flush_line()
end


local function get_code_syntax(lang)
  if not lang or lang == "" then return nil end
  lang = lang:lower()
  local syn = syntax.get("code." .. (lang_extensions[lang] or lang), "")
  if #syn.patterns > 0 then return syn end
end


local function highlight_code_line(syn, text, state)
  if not syn then return { { text, style.syntax["normal"] } }, state end
  local tokens
  tokens, state = tokenizer.tokenize(syn, text .. "\n", state)
  local runs = {}
  for _, type, token in tokenizer.each_token(tokens) do
    token = token:gsub("\n$", "")
    if token ~= "" then
      local color = style.syntax[type] or style.syntax["normal"]
      local last = runs[#runs]
      if last and last[2] == color then
        last[1] = last[1] .. token
      else
        table.insert(runs, { token, color })
      end
    end
  end
  return runs, state
end


-- The widths a cell needs on one line, and at its longest word.
local function measure_cell(spans, family)
  local scratch = {}
  wrap_spans(spans, 0, math.huge, 0, family, style.syntax["normal"], scratch)
  local natural = 0
  for _, item in ipairs(scratch) do
    if item.text or item.image then natural = math.max(natural, item.x + item.w) end
  end

  local min = 0
  for _, span in ipairs(spans) do
    if span.loaded then
      -- images shrink to fit, down to a small thumbnail
      local w = get_image_size(span.loaded, math.huge)
      min = math.max(min, math.min(w, common.round(48 * style.scale)))
      goto next_span
    end
    local span_font = span_style(span, family, style.syntax["normal"])
    for word in span.text:gmatch("%S+") do
      min = math.max(min, span_font:get_width(word))
    end
    ::next_span::
  end
  return natural, math.min(min, natural)
end


-- TODO: horizontal scrolling for tables wider than the view.
local function get_column_widths(natural, min, available)
  local total_natural, total_min = 0, 0
  for i = 1, #natural do
    total_natural = total_natural + natural[i]
    total_min = total_min + min[i]
  end
  if total_natural <= available then return natural end
  if total_min >= available then return min end

  local widths = {}
  local extra = available - total_min
  for i = 1, #natural do
    local want = natural[i] - min[i]
    widths[i] = min[i] + math.floor(extra * want / (total_natural - total_min))
  end
  return widths
end


-- -----------------------------------------------------------------------------
-- Inline content
-- -----------------------------------------------------------------------------


local block_types = {
  doc = true,
  quote = true,
  ul = true,
  ol = true,
  li = true,
  hr = true,
  h = true,
  code_block = true,
  html_block = true,
  p = true,
  table = true,
  footnotes = true,
  footnote = true,
  admonition = true,
  blank = true,
}

local function is_block(node)
  return type(node) == "table" and block_types[node.type]
end


local function plain_text(node, out)
  out = out or {}
  for _, child in ipairs(node) do
    if type(child) == "string" then table.insert(out, child) else plain_text(child, out) end
  end
  return table.concat(out)
end


local function with(state, key, value)
  local copy = {}
  for k, v in pairs(state) do copy[k] = v end
  copy[key] = value
  return copy
end


-- TODO: superscript, subscript, highlight and the other spans md4c's
-- extensions can produce, should they ever be enabled.
local function collect_spans(ctx, node, spans, state)
  for _, child in ipairs(node) do
    if type(child) == "string" then
      table.insert(spans, {
        text = child,
        bold = state.bold,
        italic = state.italic,
        code = state.code,
        strike = state.strike,
        link = state.link
      })
    elseif child.type == "em" then
      collect_spans(ctx, child, spans, with(state, "italic", true))
    elseif child.type == "strong" then
      collect_spans(ctx, child, spans, with(state, "bold", true))
    elseif child.type == "del" then
      collect_spans(ctx, child, spans, with(state, "strike", true))
    elseif child.type == "code" then
      collect_spans(ctx, child, spans, with(state, "code", true))
    elseif child.type == "a" then
      collect_spans(ctx, child, spans, with(state, "link", child.href or ""))
    elseif child.type == "img" then
      -- the alt text is shown in its place if the image can't be
      table.insert(spans, {
        text = plain_text(child),
        bold = state.bold,
        italic = state.italic,
        link = state.link,
        image = child.src,
        loaded = child.src and ctx.load_image(child.src)
      })
    elseif child.type == "footnote_ref" then
      -- TODO: jump to the footnote when clicked
      table.insert(spans, { text = "[" .. child.id .. "]", link = "#fn" .. child.id })
    elseif child.type == "html" then
      -- TODO: render the few inline HTML tags documents commonly use (for example: <br>,
      -- <kbd>, <img>).
      -- For now, HTML is simply not shown
    else
      collect_spans(ctx, child, spans, state)
    end
  end
  return spans
end


-- -----------------------------------------------------------------------------
-- Blocks
-- -----------------------------------------------------------------------------


local function tag_leaf(ctx, first_item)
  ctx.block = ctx.block + 1
  local gap = ctx.next_gap or "\n\n"
  ctx.next_gap = nil
  for k = first_item, #ctx.items do
    local line = ctx.items[k].line
    if line then line.block, line.gap = ctx.block, gap end
  end
end


-- TODO: horizontal scrolling for wide code blocks.
local function layout_code(ctx, node, x, width, y)
  local text = plain_text(node):gsub("\n$", ""):gsub("\t", (" "):rep(config.indent_size))
  local font = style.code_font
  local lh = math.floor(font:get_height() * config.line_height)
  local pad = common.round(style.padding.y * 0.75)
  local lines = {}
  for line in (text .. "\n"):gmatch("(.-)\n") do table.insert(lines, line) end

  local h = #lines * lh + pad * 2
  table.insert(ctx.items, { x = x, y = y, w = width, h = h, color = style.background2 })
  local ty = y + pad + common.round((lh - font:get_height()) / 2)
  local syn, state = get_code_syntax(node.lang), nil
  for _, line_text in ipairs(lines) do
    local runs
    runs, state = highlight_code_line(syn, line_text, state)
    if #runs == 0 then runs = { { "", style.syntax["normal"] } } end
    local line = { y = ty - common.round((lh - font:get_height()) / 2), h = lh, hard = true }
    local tx = x + math.floor(style.padding.x / 2)
    for _, run in ipairs(runs) do
      local w = font:get_width(run[1])
      table.insert(ctx.items, {
        x = tx,
        y = ty,
        w = w,
        h = font:get_height(),
        font = font,
        color = run[2],
        text = run[1],
        line = line
      })
      tx = tx + w
    end
    ty = ty + lh
  end
  return y + h
end


local function layout_table(ctx, node, x, y, column)
  local px, py = style.padding.x, style.padding.y
  local rule = math.max(1, common.round(style.scale))
  local pad_x, pad_y = math.floor(px / 2), math.floor(py / 2)

  local rows, align, ncols, header_rows = {}, {}, 0, 0
  for _, section in ipairs(node) do
    for _, tr in ipairs(section) do
      local row = {}
      for c, cell in ipairs(tr) do
        row[c] = collect_spans(ctx, cell, {}, { bold = section.type == "thead" })
        align[c] = align[c] or cell.align
      end
      ncols = math.max(ncols, #row)
      table.insert(rows, row)
      if section.type == "thead" then header_rows = header_rows + 1 end
    end
  end
  for _, row in ipairs(rows) do
    for c = #row + 1, ncols do row[c] = {} end
  end

  local natural, min = {}, {}
  for c = 1, ncols do
    natural[c], min[c] = 0, 0
    for _, row in ipairs(rows) do
      local n, m = measure_cell(row[c], body_family)
      natural[c], min[c] = math.max(natural[c], n), math.max(min[c], m)
    end
  end
  local chrome = ncols * pad_x * 2 + (ncols + 1) * rule
  local widths = get_column_widths(natural, min, column - chrome)

  local col_x = {}
  local table_w = rule
  for c = 1, ncols do
    col_x[c] = x + table_w + pad_x
    table_w = table_w + widths[c] + pad_x * 2 + rule
  end

  local items = ctx.items
  local top = y
  table.insert(items, { x = x, y = y, w = table_w, h = rule, color = style.dim })
  y = y + rule

  for r, row in ipairs(rows) do
    local cell_items = {}
    local bottom = y + pad_y
    for c = 1, ncols do
      local first = #cell_items + 1
      bottom = math.max(bottom, wrap_spans(row[c], col_x[c], widths[c], y + pad_y,
        body_family, style.syntax["normal"], cell_items, align[c]))
      for k = first, #cell_items do
        local line = cell_items[k].line
        if line then line.row, line.cell = r, c end
      end
    end
    local h = bottom + pad_y - y
    if r <= header_rows then
      table.insert(items, { x = x, y = y, w = table_w, h = h, color = style.background2 })
    end
    for _, item in ipairs(cell_items) do table.insert(items, item) end
    y = y + h
    table.insert(items, { x = x, y = y, w = table_w, h = rule, color = style.dim })
    y = y + rule
  end

  local line_x = x + rule
  table.insert(items, { x = x, y = top, w = rule, h = y - top, color = style.dim })
  for c = 1, ncols do
    line_x = line_x + widths[c] + pad_x * 2 + rule
    table.insert(items, { x = line_x - rule, y = top, w = rule, h = y - top, color = style.dim })
  end

  return y
end


-- TODO: move into the theme along with the link colour.
local admonition_colors = {
  note = { common.color "#6cb6ff" },
  tip = { common.color "#57ab5a" },
  important = { common.color "#986ee2" },
  warning = { common.color "#c69026" },
  caution = { common.color "#e5534b" },
}


local layout_flow

local function layout_marked(ctx, node, marker, x, width, y, opts)
  local items = ctx.items
  local font = style.font
  local em = font:get_height()
  local lh = math.floor(em * config.line_height)
  local marker_w = math.max(ctx.list_indent, font:get_width(marker or "") + font:get_width(" "))

  if node.checked ~= nil then
    -- a task: draw a checkbox rather than rely on the font having one
    local size = common.round(em * 0.75)
    local bx, by = x, y + common.round((lh - size) / 2)
    local rule = math.max(1, common.round(style.scale))
    table.insert(items, { x = bx, y = by, w = size, h = size, color = style.dim })
    table.insert(items, {
      x = bx + rule,
      y = by + rule,
      w = size - rule * 2,
      h = size - rule * 2,
      color = style.background
    })
    if node.checked then
      local inset = rule * 3
      table.insert(items, {
        x = bx + inset,
        y = by + inset,
        w = size - inset * 2,
        h = size - inset * 2,
        color = style.syntax["normal"]
      })
    end
  elseif marker then
    table.insert(items, {
      x = x,
      y = y + common.round((lh - em) / 2),
      w = font:get_width(marker),
      h = em,
      font = font,
      color = style.dim,
      text = marker
    })
  end
  return layout_flow(ctx, node, x + marker_w, width - marker_w, y, opts)
end


local function layout_list(ctx, node, x, width, y, opts)
  local item_opts = with(opts, "tight", node.tight)
  local gap = common.round(style.font:get_height() * (node.tight and 0.15 or 0.7))
  for i, li in ipairs(node) do
    if i > 1 then
      y = y + gap
      ctx.next_gap = node.tight and "\n" or "\n\n"
    end
    local marker = node.type == "ol" and ((node.start + i - 1) .. node.delimiter) or "•"
    y = layout_marked(ctx, li, marker, x, width, y, item_opts)
  end
  return y
end


local function layout_block(ctx, node, x, width, y, opts)
  local items = ctx.items
  local em = style.font:get_height()
  local rule = math.max(1, common.round(style.scale))
  local first_item = #items + 1

  if node.type == "p" then
    y = wrap_spans(collect_spans(ctx, node, {}, {}), x, width, y, body_family,
      opts.color, items)
    tag_leaf(ctx, first_item)
  elseif node.type == "h" then
    local family = heading_families[math.min(node.level, #heading_families)]
    if node.level <= 2 then y = y + common.round(em * 0.4) end
    y = wrap_spans(collect_spans(ctx, node, {}, {}), x, width, y, family, opts.color, items)
    tag_leaf(ctx, first_item)
    if node.level <= 2 then
      y = y + common.round(em * 0.2)
      table.insert(items, { x = x, y = y, w = width, h = rule, color = style.dim })
      y = y + rule
    end
  elseif node.type == "code_block" then
    y = layout_code(ctx, node, x, width, y)
    tag_leaf(ctx, first_item)
  elseif node.type == "table" then
    y = layout_table(ctx, node, x, y, width)
    tag_leaf(ctx, first_item)
  elseif node.type == "quote" or node.type == "admonition" then
    local color = admonition_colors[node.kind] or style.dim
    local bar = math.max(2, common.round(3 * style.scale))
    local inset = bar + style.padding.x
    local bar_item = { x = x, y = y, w = bar, h = 0, color = color }
    table.insert(items, bar_item)
    local top = y
    local inner = with(opts, "tight", false)
    if node.type == "admonition" then
      local title = (node.kind or "note"):gsub("^%l", string.upper)
      y = wrap_spans({ { text = title, bold = true } }, x + inset, width - inset, y,
        body_family, color, items)
      tag_leaf(ctx, first_item)
      ctx.next_gap = "\n"
      y = y + common.round(em * 0.3)
    else
      inner.color = style.text
    end
    y = layout_flow(ctx, node, x + inset, width - inset, y, inner)
    bar_item.h = y - top
  elseif node.type == "ul" or node.type == "ol" then
    y = layout_list(ctx, node, x, width, y, opts)
  elseif node.type == "footnotes" then
    table.insert(items, { x = x, y = y, w = math.floor(width / 3), h = rule, color = style.dim })
    y = y + rule + common.round(em * 0.5)
    for i, footnote in ipairs(node) do
      if i > 1 then
        y = y + common.round(em * 0.15)
        ctx.next_gap = "\n"
      end
      y = layout_marked(ctx, footnote, footnote.id .. ".", x, width, y,
        with(opts, "tight", true))
    end
  elseif node.type == "hr" then
    y = y + common.round(em * 0.3)
    table.insert(items, { x = x, y = y, w = width, h = rule, color = style.dim })
    y = y + rule + common.round(em * 0.3)
  else
    -- TODO: render HTML blocks, for now they're just skipped.
    return y, false
  end
  return y, true
end


function layout_flow(ctx, node, x, width, y, opts)
  local gap = common.round(style.font:get_height() * (opts.tight and 0.15 or 0.7))
  local placed_any = false
  local pending = {}

  local function place(block)
    local before = y
    if placed_any then
      y = y + gap
      ctx.next_gap = opts.tight and "\n" or "\n\n"
    end
    local placed
    y, placed = layout_block(ctx, block, x, width, y, opts)
    if placed then placed_any = true else y = before end
  end

  local function flush_inline()
    if #pending > 0 then
      pending.type = "p"
      place(pending)
      pending = {}
    end
  end

  for _, child in ipairs(node) do
    if is_block(child) then
      flush_inline()
      place(child)
    else
      table.insert(pending, child)
    end
  end
  flush_inline()
  return y
end

local function layout(doc, width, load_image)
  local px, py = style.padding.x, style.padding.y
  local ctx = {
    items = {},
    load_image = load_image,
    block = 0,
    list_indent = style.font:get_width("00. "),
  }
  local column = math.max(width - px * 2, style.font:get_height())
  local y = layout_flow(ctx, doc, px, column, py, { color = style.syntax["normal"] })

  local runs = {}
  for _, item in ipairs(ctx.items) do
    if item.line then
      table.insert(runs, item)
      item.index = #runs
    end
  end

  return { items = ctx.items, runs = runs, height = y + py }
end


-- -----------------------------------------------------------------------------
-- View
-- -----------------------------------------------------------------------------

local MarkdownView = View:extend()


function MarkdownView:new(doc)
  MarkdownView.super.new(self)
  self.doc = assert(doc)
  self.scrollable = true
  self.tooltip = Tooltip()
  self.images = {}
end

function MarkdownView:get_name()
  return self.doc:get_name():match("[^/%\\]*$") .. " (preview)"
end

function MarkdownView:try_close(do_close)
  do_close()
end

function MarkdownView:on_scale_change()
  self.cache = nil
end

function MarkdownView:get_layout()
  local version = self.doc:get_content_version()
  local width = self.size.x
  local cache = self.cache
  if cache and cache.version == version and cache.width == width
      and cache.scale == style.scale then
    return cache.layout
  end

  for _, entry in pairs(self.images) do
    entry.previous_sizes, entry.sizes, entry.used = entry.sizes, {}, false
  end
  local doc, err = markdown.parse(table.concat(self.doc.lines))
  if not doc then
    core.log_quiet("Can't render %s: %s", self.doc:get_name(), err)
    doc = { type = "doc", { type = "p", "This document can't be rendered: " .. err } }
  end
  local result = layout(doc, width, function(target)
    return self:load_image(target)
  end)
  for path, entry in pairs(self.images) do
    entry.previous_sizes = {}
    -- Let the GC be able to collect unused images
    if not entry.used then
      self.images[path] = nil
    end
  end

  self.cache = { version = version, width = width, scale = style.scale, layout = result }
  self.selection, self.selecting = nil, nil

  return result
end

function MarkdownView:get_scrollable_size()
  return self:get_layout().height
end

function MarkdownView:draw()
  self:draw_background(style.background)

  local result = self:get_layout()
  local ox, oy = self:get_content_offset()
  local _, top, _, bottom = self:get_content_bounds()

  local first, last = self:get_selection()

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  for _, item in ipairs(result.items) do
    if item.y + item.h >= top and item.y <= bottom then
      if first and last and item.index and item.index >= first.index and item.index <= last.index then
        self:draw_run_selection(item, first, last, ox, oy)
      end
      if item.image then
        renderer.draw_image(item.image, ox + item.x, oy + item.y)
      elseif item.text then
        renderer.draw_text(item.font, item.text, ox + item.x, oy + item.y, item.color)
      else
        renderer.draw_rect(ox + item.x, oy + item.y, item.w, item.h, item.color)
      end
    end
  end
  core.pop_clip_rect()

  self:draw_scrollbar()

  local link = self.hovered_link
  if link then
    local gap = math.floor(style.padding.y / 2)
    self.tooltip:draw(link.link, ox + link.x, oy + link.y + link.h + gap,
      oy + link.y - gap)
  end
end


-- -----------------------------------------------------------------------------
-- Selection
-- -----------------------------------------------------------------------------


local function is_before(a, b)
  return a.index < b.index or (a.index == b.index and a.offset < b.offset)
end


function MarkdownView:get_selection()
  local current = self.selection
  if not current then return nil, nil end
  local first, last = current.anchor, current.focus
  if is_before(last, first) then
    first, last = last, first
  end
  if first.index == last.index and first.offset == last.offset then
    return nil, nil
  end
  return first, last
end

function MarkdownView:draw_run_selection(run, first, last, ox, oy)
  local from = run.index == first.index and first.offset or 0
  local to = run.index == last.index and last.offset or #run.text
  local x1 = run.x + run.font:get_width(run.text:sub(1, from))
  local x2 = run.x + run.font:get_width(run.text:sub(1, to))
  -- cover the space between this run and a selected one before it
  local prev = self:get_layout().runs[run.index - 1]
  if from == 0 and run.index > first.index and prev.line == run.line then
    x1 = prev.x + prev.w
  end
  renderer.draw_rect(ox + x1, oy + run.line.y, x2 - x1, run.line.h, style.selection)
end

local function offset_at(run, x)
  local offset, width = 0, 0
  for char in common.utf8_chars(run.text) do
    local w = run.font:get_width(char)
    if width + w / 2 > x then break end
    width, offset = width + w, offset + #char
  end
  return offset
end


function MarkdownView:get_position_at(x, y)
  local ox, oy = self:get_content_offset()
  x, y = x - ox, y - oy
  local best, best_dy, best_dx
  for _, run in ipairs(self:get_layout().runs) do
    local line = run.line
    local dy = math.max(line.y - y, y - (line.y + line.h), 0)
    local dx = math.max(run.x - x, x - (run.x + run.w), 0)
    if not best or dy < best_dy or (dy == best_dy and dx < best_dx) then
      best, best_dy, best_dx = run, dy, dx
    end
  end
  if not best then return nil end
  return { index = best.index, offset = offset_at(best, x - best.x) },
      best_dy == 0 and best_dx == 0
end

local function is_word_char(char)
  return not config.non_word_chars:find(char, 1, true)
end


function MarkdownView:select_from_mouse(pos)
  local runs = self:get_layout().runs
  local press = self.press
  local first, last = press.pos, pos
  local swap = is_before(last, first)
  if swap then first, last = last, first end
  local s, e = first.offset, last.offset

  if press.clicks == 2 then
    local text = runs[first.index].text
    while s > 0 and is_word_char(text:sub(s, s)) do s = s - 1 end
    text = runs[last.index].text
    while e < #text and is_word_char(text:sub(e + 1, e + 1)) do e = e + 1 end
  elseif press.clicks == 3 then
    local block = runs[first.index].line.block
    while runs[first.index - 1] and runs[first.index - 1].line.block == block do
      first = { index = first.index - 1 }
    end
    block = runs[last.index].line.block
    while runs[last.index + 1] and runs[last.index + 1].line.block == block do
      last = { index = last.index + 1 }
    end
    s, e = 0, #runs[last.index].text
  end

  first = { index = first.index, offset = s }
  last = { index = last.index, offset = e }
  if swap then first, last = last, first end
  self.selection = { anchor = first, focus = last }
end

function MarkdownView:select_all()
  local runs = self:get_layout().runs
  if #runs == 0 then return end
  self.selection = {
    anchor = { index = 1, offset = 0 },
    focus = { index = #runs, offset = #runs[#runs].text },
  }
end

local function separator(prev, run)
  local a, b = prev.line, run.line
  if a == b then return run.space_before and " " or "" end
  if a.block ~= b.block then return b.gap end
  if b.row then
    if a.row ~= b.row then return "\n" end
    if a.cell ~= b.cell then return "\t" end
  end
  return b.hard and "\n" or " "
end


function MarkdownView:get_selected_text()
  local first, last = self:get_selection()
  if not first or not last then return end
  if not first then return nil end
  local runs = self:get_layout().runs
  local parts = {}
  for i = first.index, last.index do
    local run = runs[i]
    if i > first.index then table.insert(parts, separator(runs[i - 1], run)) end
    local from = i == first.index and first.offset + 1 or 1
    local to = i == last.index and last.offset or #run.text
    table.insert(parts, run.text:sub(from, to))
  end
  return table.concat(parts)
end


-- -----------------------------------------------------------------------------
-- Links
-- -----------------------------------------------------------------------------


local external_schemes = { http = true, https = true, mailto = true }

local function open_external(url)
  if PLATFORM == "Windows" then
    -- TODO: support opening links on windows, using
    -- `ShellExecuteW()` to avoid injection.
  else
    local opener = PLATFORM == "Mac OS X" and "open" or "xdg-open"
    system.exec(opener .. " '" .. url:gsub("'", "'\\''") .. "'")
  end
end


local function resolve_path(doc, target)
  local path = target:gsub("[#?].*$", ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
  if path == "" then return nil end
  if not path:match("^/") and not path:match("^%a:[/\\]") then
    local dir = doc.filename and doc.filename:match("^(.*)[/\\]")
    if dir then path = dir .. PATHSEP .. path end
  end
  return path
end


local function open_relative(doc, target)
  -- TODO: scroll to `#fragment` in the opened doc
  local path = resolve_path(doc, target)
  if not path then
    -- TODO: scroll to anchors within this doc
    core.log("Links to anchors aren't supported yet: %s", target)
    return
  end
  local info = system.get_file_info(path)
  if not info or info.type ~= "file" then
    core.error("Can't open link target: %s", target)
    return
  end
  core.root_view:open_doc(core.open_doc(path))
end


-- TODO: notice changed image files, like `autoreload` does for docs.
function MarkdownView:load_image(target)
  if target:match("^%a[%w+.-]*:") then
    -- TODO: fetch http(s) images off the main thread (coroutine) with a cache
    return nil
  end

  local path = resolve_path(self.doc, target)
  if not path then return end

  local info = path and system.get_file_info(path)
  if not info or info.type ~= "file" then return nil end

  local entry = self.images[path]
  if not entry or entry.modified ~= info.modified then
    local image, err = renderer.image.load(path)
    if not image then core.log_quiet("Can't load image %s: %s", path, err) end
    local width, height = 0, 0
    if image then width, height = image:get_size() end
    entry = {
      image = image,
      width = width,
      height = height,
      modified = info.modified,
      sizes = {},
      previous_sizes = {}
    }
    self.images[path] = entry
  end
  entry.used = true
  return entry.image and entry
end

function MarkdownView:open_link(url)
  local scheme = url:match("^(%a[%w+.-]*):")
  if not scheme then
    open_relative(self.doc, url)
  elseif external_schemes[scheme:lower()] then
    open_external(url)
  else
    core.error("Not opening link with unsupported scheme: %s", url)
  end
end

function MarkdownView:get_link_at(x, y)
  local pos, size = self.position, self.size
  if x < pos.x or y < pos.y or x >= pos.x + size.x or y >= pos.y + size.y then
    return nil
  end
  local ox, oy = self:get_content_offset()
  x, y = x - ox, y - oy
  for _, item in ipairs(self:get_layout().items) do
    if item.link and x >= item.x and x < item.x + item.w
        and y >= item.y and y < item.y + item.h then
      return item.link, item
    end
  end
end

function MarkdownView:update()
  MarkdownView.super.update(self)

  local root = core.root_view
  local mouse = root.mouse
  local node = root.root_node:get_child_overlapping_point(mouse.x, mouse.y)
  local link
  if node and node.active_view == self and not root.context_menu.visible
      and not self:pointer_on_scrollbar() then
    link = select(2, self:get_link_at(mouse.x, mouse.y))
  end
  if link ~= self.hovered_link then
    self.hovered_link = link
    core.request_redraw()
  end
  -- a wrapped link is several runs of the same span; moving between them
  -- shouldn't restart the delay
  self.tooltip:set_target(link and link.span)
  self.tooltip:update()
end

function MarkdownView:on_mouse_pressed(button, x, y, clicks)
  if MarkdownView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true
  end
  if button ~= "left" then return end

  local pos = self:get_position_at(x, y)
  self.press = {
    x = x,
    y = y,
    link = self:get_link_at(x, y),
    pos = pos,
    clicks = math.min(clicks, 3)
  }
  if not pos then
    self.selection = nil
  else
    if clicks == 1 and keymap.modkeys["shift"] and self.selection then
      self.press.pos = self.selection.anchor
    end
    self:select_from_mouse(pos)
    self.selecting = true
  end
  core.request_redraw()
  return true
end

function MarkdownView:on_mouse_moved(x, y, ...)
  MarkdownView.super.on_mouse_moved(self, x, y, ...)

  local press = self.press
  if press and math.abs(x - press.x) + math.abs(y - press.y) > 4 * style.scale then
    press.link = nil
  end
  if self.selecting then
    local pos = self:get_position_at(x, y)
    if pos then
      self:select_from_mouse(pos)
      core.request_redraw()
    end
  end

  if self:pointer_on_scrollbar() then
    self.cursor = "arrow"
  elseif not self.selecting and self:get_link_at(x, y) then
    self.cursor = "hand"
  else
    local _, on_text = self:get_position_at(x, y)
    self.cursor = (self.selecting or on_text) and "ibeam" or "arrow"
  end
end

function MarkdownView:on_mouse_released(button, x, y)
  MarkdownView.super.on_mouse_released(self, button, x, y)
  local press = self.press
  self.press, self.selecting = nil, nil
  if button == "left" and press and press.link and not self:get_selection() then
    self:open_link(press.link)
  end
end

function MarkdownView:get_context_menu(x, y)
  local items = {
    { command = "markdown:copy",       text = "Copy" },
    { command = "markdown:select-all", text = "Select All" },
  }
  local link = self:get_link_at(x, y)
  if link then
    table.insert(items, { divider = true })
    table.insert(items, { text = "Open Link", fn = function() self:open_link(link) end })
    table.insert(items, { text = "Copy Link Address", fn = function() system.set_clipboard(link) end })
  end
  table.insert(items, { divider = true })
  table.insert(items, { command = "markdown:toggle-preview", text = "Edit Source" })
  return items
end


-- -----------------------------------------------------------------------------
-- Commands
-- -----------------------------------------------------------------------------


local function find_in_node(node, doc, class)
  for _, view in ipairs(node.views) do
    if view.doc == doc and view:is(class) then return view end
  end
end


local function can_toggle()
  local av = core.active_view
  return av:is(MarkdownView) or (av:is(DocView) and not av:is(CommandView))
end


command.add(can_toggle, {
  ["markdown:toggle-preview"] = function()
    local av = core.active_view
    local node = core.root_view:get_active_node()
    if av:is(MarkdownView) then
      local dv = find_in_node(node, av.doc, DocView)
      if dv then
        node:set_active_view(dv)
      else
        core.root_view:open_doc(av.doc)
      end
    else
      local mv = find_in_node(node, av.doc, MarkdownView)
      if mv then
        node:set_active_view(mv)
      else
        node:add_view(MarkdownView(av.doc))
      end
    end
  end,
})


command.add(function()
  local av = core.active_view
  return av:is(MarkdownView) and av:get_selection() ~= nil
end, {
  ["markdown:copy"] = function()
    system.set_clipboard(core.active_view:get_selected_text())
  end,
})


command.add(MarkdownView, {
  ["markdown:select-all"] = function()
    core.active_view:select_all()
  end,

  ["markdown:select-none"] = function()
    core.active_view.selection = nil
  end,
})


keymap.add {
  ["ctrl+shift+m"] = "markdown:toggle-preview",
  ["ctrl+c"] = "markdown:copy",
  ["ctrl+shift+a"] = "markdown:select-all",
  ["escape"] = "markdown:select-none",
}


return MarkdownView
