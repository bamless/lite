local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local View = require "core.view"


local TabBar = View:extend()


function TabBar:new(node)
  TabBar.super.new(self)
  self.node = node
  self.scrollable = true
end


function TabBar:get_name()
  return "Tabs"
end


function TabBar:get_height()
  return style.font:get_height() + style.padding.y * 2.5
end


-- the close button sits at the right end of the tab; this is its rect for a
-- tab occupying the given rect
local function close_rect(x, y, w, h)
  local s = style.icon_font:get_height()
  local pad = style.padding.x / 2
  return x + w - s - pad * 2, y + (h - s) / 2 - pad / 2, s + pad, s + pad
end


-- a tab is as wide as its name plus the close button, but never wider than
-- `style.tab_width`; longer names get truncated when drawn. The name lives
-- between the left padding and the close button (see `TabBar:draw`), so the
-- fitting width is those parts added up, plus a half padding gap before the
-- button so the name doesn't touch it.
function TabBar:get_tab_width(idx)
  local s = style.icon_font:get_height()
  local pad = style.padding.x / 2
  local name_w = style.font:get_width(self.node.views[idx]:get_name())
  local w = style.padding.x + name_w + pad + s + pad * 2
  return math.min(math.ceil(w), style.tab_width)
end


function TabBar:get_scrollable_size()
  return self.size.y
end


function TabBar:get_h_scrollable_size()
  local total = 0
  for i = 1, #self.node.views do
    total = total + self:get_tab_width(i)
  end
  return total
end


function TabBar:get_tab_offset(idx)
  local offset = 0
  for i = 1, idx - 1 do
    offset = offset + self:get_tab_width(i)
  end
  return offset
end


function TabBar:get_tab_rect(idx)
  return self.position.x - self.scroll.x + self:get_tab_offset(idx),
         self.position.y,
         self:get_tab_width(idx),
         self.size.y
end


function TabBar:get_close_rect(idx)
  return close_rect(self:get_tab_rect(idx))
end


local function rect_overlaps(px, py, x, y, w, h)
  return px >= x and px < x + w and py >= y and py < y + h
end


function TabBar:overlaps_point(x, y)
  return rect_overlaps(x, y, self.position.x, self.position.y,
    self.size.x, self.size.y)
end


function TabBar:get_tab_overlapping_point(px, py)
  if not self:overlaps_point(px, py) then return nil end
  local x = self.position.x - self.scroll.x
  for i = 1, #self.node.views do
    local w = self:get_tab_width(i)
    if px >= x and px < x + w then
      return i
    end
    x = x + w
  end
end


function TabBar:close_overlaps_point(idx, px, py)
  return rect_overlaps(px, py, self:get_close_rect(idx))
end


function TabBar:scroll_to_tab(idx)
  if not idx then return end
  local w = self:get_tab_width(idx)
  local left = self:get_tab_offset(idx)
  self.scroll.to.x = math.min(self.scroll.to.x, left)
  self.scroll.to.x = math.max(self.scroll.to.x, left + w - self.size.x)
end


function TabBar:update()
  TabBar.super.update(self)
  -- following the active view has to happen here rather than in
  -- `Node:set_active_view`, because opening a document also changes it
  if self.node.active_view ~= self.last_active_view then
    self.last_active_view = self.node.active_view
    self:scroll_to_tab(self.node:get_view_idx(self.node.active_view))
  end

  if self.tooltip_tab then
    local now = system.get_time()
    if now < self.tooltip_shown_at then
      core.request_wakeup(self.tooltip_shown_at)
    elseif now < self.tooltip_shown_at + config.tooltip_fade_time then
      core.request_redraw()
    end
  end
end


function TabBar:on_mouse_wheel(y, x)
  local delta = (x ~= 0) and x or -y
  self.scroll.to.x = self.scroll.to.x + delta * config.mouse_wheel_scroll * style.scale
  self.tooltip_tab = nil
end


function TabBar:on_mouse_moved(x, y, dx, dy)
  TabBar.super.on_mouse_moved(self, x, y, dx, dy)
  if self:pointer_on_scrollbar() then
    self.hovered_tab, self.hovered_close = nil, nil
    return
  end
  self.hovered_tab = self:get_tab_overlapping_point(x, y)
  self.hovered_close = self.hovered_tab
    and self:close_overlaps_point(self.hovered_tab, x, y)
end


function TabBar:on_mouse_pressed(button, x, y, clicks)
  if TabBar.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true -- a scrollbar drag
  end

  local node = self.node
  local idx = self:get_tab_overlapping_point(x, y)
  if not idx then
    -- clicking past the last tab still focuses the node
    core.set_active_view(node.active_view)
    return true
  end

  node:set_active_view(node.views[idx])
  if button == "middle" or self:close_overlaps_point(idx, x, y) then
    node:close_active_view(core.root_view.root_node)
  end
  return true
end


function TabBar:draw()
  local ds = style.divider_size
  self:draw_background(style.background2)

  core.push_clip_rect(self.position.x, self.position.y, self.size.x, self.size.y)
  -- walk the tabs left to right, so each one's position is the previous one's
  -- end rather than a fresh sum over all the tabs before it
  local x, y, h = self.position.x - self.scroll.x, self.position.y, self.size.y
  for i, view in ipairs(self.node.views) do
    local w = self:get_tab_width(i)
    -- tabs scrolled off either edge, skip it
    if x + w > self.position.x and x < self.position.x + self.size.x then
      local color = style.dim
      if view == self.node.active_view then
        color = style.text
        renderer.draw_rect(x, y, w, h, style.background)
        renderer.draw_rect(x + w, y, ds, h, style.divider)
        renderer.draw_rect(x - ds, y, ds, h, style.divider)
      end
      if i == self.hovered_tab then
        color = style.text
      end

      local cx, cy, cw, ch = close_rect(x, y, w, h)
      core.push_clip_rect(x, y, w, h)
      -- the name stops where the close button starts
      local tx = x + style.padding.x
      local tw = cx - tx
      local text = view:get_name()

      local align = "center"
      if style.font:get_width(text) > tw then
        local chars = {}
        for char in common.utf8_chars(text) do
          table.insert(chars, char)
        end
        repeat
          table.remove(chars, 1)
          text = "…" .. table.concat(chars)
        until #chars == 0 or style.font:get_width(text) <= tw
        align = "left"
      end
      common.draw_text(style.font, color, text, align, tx, y, tw, h)

      local close_color = style.dim
      if i == self.hovered_tab then
        close_color = self.hovered_close and style.accent or style.text
      end
      common.draw_text(style.icon_font, close_color, "x", "center",
        cx, cy, cw, ch)
      core.pop_clip_rect()
    end
    x = x + w
  end
  core.pop_clip_rect()

  renderer.draw_rect(self.position.x, self.position.y + self.size.y - ds,
    self.size.x, ds, style.divider)
  self:draw_scrollbar()

  local tooltip_tab = not self.hovered_close and self.hovered_tab or nil
  if tooltip_tab ~= self.tooltip_tab then
    self.tooltip_tab = tooltip_tab
    self.tooltip_shown_at = system.get_time() + config.tooltip_delay
  end

  if tooltip_tab and system.get_time() >= self.tooltip_shown_at then
    core.root_view:defer_draw(self.draw_tooltip, self, tooltip_tab)
  end
end


function TabBar:draw_tooltip(idx)
  local view = self.node.views[idx]
  if not view then return end

  local fade = (system.get_time() - self.tooltip_shown_at) / config.tooltip_fade_time
  local alpha = common.clamp(fade, 0, 1)

  local function faded(color)
    return { color[1], color[2], color[3], (color[4] or 255) * alpha }
  end

  local text = view.doc and view.doc.filename or view:get_name()

  local font = style.font
  local pad_x, pad_y = style.padding.x / 2, style.padding.y / 2
  local w = font:get_width(text) + pad_x * 2
  local h = font:get_height() + pad_y * 2

  local tab_x = self:get_tab_rect(idx)
  local root = core.root_view
  local x = math.min(tab_x, root.position.x + root.size.x - w)
  x = math.max(x, root.position.x)
  local y = self.position.y + self.size.y

  local ds = style.divider_size
  renderer.draw_rect(x - ds, y - ds, w + ds * 2, h + ds * 2, faded(style.divider))
  renderer.draw_rect(x, y, w, h, faded(style.background3))
  common.draw_text(font, faded(style.text), text, "left", x + pad_x, y, w, h)
end


return TabBar
