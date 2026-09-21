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


function TabBar:get_tab_width()
  return style.tab_width
end


function TabBar:get_scrollable_size()
  return self.size.y
end


function TabBar:get_h_scrollable_size()
  return #self.node.views * self:get_tab_width()
end


function TabBar:get_tab_rect(idx)
  local w = self:get_tab_width()
  return self.position.x - self.scroll.x + (idx - 1) * w,
         self.position.y,
         w,
         self.size.y
end


function TabBar:get_close_rect(idx)
  local x, y, w, h = self:get_tab_rect(idx)
  local s = style.icon_font:get_height()
  local pad = style.padding.x / 2
  return x + w - s - pad * 2, y + (h - s) / 2 - pad / 2, s + pad, s + pad
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
  local w = self:get_tab_width()
  local idx = math.floor((px - self.position.x + self.scroll.x) / w) + 1
  if idx >= 1 and idx <= #self.node.views then
    return idx
  end
end


function TabBar:close_overlaps_point(idx, px, py)
  return rect_overlaps(px, py, self:get_close_rect(idx))
end


function TabBar:scroll_to_tab(idx)
  if not idx then return end
  local w = self:get_tab_width()
  local left = (idx - 1) * w
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
end


function TabBar:on_mouse_wheel(y, x)
  local delta = (x ~= 0) and x or -y
  self.scroll.to.x = self.scroll.to.x + delta * config.mouse_wheel_scroll
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
  for i, view in ipairs(self.node.views) do
    local x, y, w, h = self:get_tab_rect(i)
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

      local cx, cy, cw, ch = self:get_close_rect(i)
      core.push_clip_rect(x, y, w, h)
      -- the name stops where the close button starts
      local tx = x + style.padding.x
      local tw = cx - tx
      local text = view:get_name()
      local align = style.font:get_width(text) > tw and "left" or "center"
      common.draw_text(style.font, color, text, align, tx, y, tw, h)

      local close_color = style.dim
      if i == self.hovered_tab then
        close_color = self.hovered_close and style.accent or style.text
      end
      common.draw_text(style.icon_font, close_color, "x", "center",
        cx, cy, cw, ch)
      core.pop_clip_rect()
    end
  end
  core.pop_clip_rect()

  renderer.draw_rect(self.position.x, self.position.y + self.size.y - ds,
    self.size.x, ds, style.divider)
  self:draw_scrollbar()
end


return TabBar
