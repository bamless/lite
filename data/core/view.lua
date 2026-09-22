local core = require "core"
local config = require "core.config"
local style = require "core.style"
local common = require "core.common"
local Object = require "core.object"


local View = Object:extend()


function View:new()
  self.position = { x = 0, y = 0 }
  self.size = { x = 0, y = 0 }
  self.scroll = { x = 0, y = 0, to = { x = 0, y = 0 } }
  self.scrollbars = {
    v = { size = style.scrollbar_size, hovered = false, dragging = false },
    h = { size = style.scrollbar_size, hovered = false, dragging = false },
  }
  self.cursor = "arrow"
  self.scrollable = false
  self.resizable = false
end


-- Called while the divider of a split whose size this view controls is
-- dragged (see `RootView:on_mouse_moved`). `axis` is "x" or "y". The view
-- decides what to do with the value: a view whose size comes from a config
-- entry stores it there, so the change survives the view being hidden.
function View:set_target_size(axis, value)
end


-- called after `core.style` is rebuilt at a new scale; views drop whatever
-- they measured with the old fonts
function View:on_scale_change(new_scale, old_scale)
end


function View:move_towards(t, k, dest, rate)
  if type(t) ~= "table" then
    return self:move_towards(self, t, k, dest, rate)
  end
  local val = t[k]
  if math.abs(val - dest) < 0.5 then
    t[k] = dest
  else
    t[k] = common.lerp(val, dest, rate or 0.5)
  end
  if val ~= dest then
    core.request_redraw()
  end
end


function View:try_close(do_close)
  do_close()
end


function View:get_name()
  return "---"
end


function View:get_scrollable_size()
  return math.huge
end


local function thumb(extent, viewport, scroll)
  if extent <= viewport or extent == math.huge then return nil end
  local len = math.max(20, viewport * viewport / extent)
  return scroll * (viewport - len) / (extent - viewport), len
end


function View:get_scrollbar_rect()
  local offset, len = thumb(self:get_scrollable_size(), self.size.y, self.scroll.y)
  if not offset then return 0, 0, 0, 0 end
  local w = self.scrollbars.v.size
  return self.position.x + self.size.x - w, self.position.y + offset, w, len
end


function View:get_h_scrollbar_rect()
  local offset, len = thumb(self:get_h_scrollable_size(), self.size.x, self.scroll.x)
  if not offset then return 0, 0, 0, 0 end
  local h = self.scrollbars.h.size
  return self.position.x + offset, self.position.y + self.size.y - h, len, h
end


function View:scrollbar_overlaps_point(x, y)
  local sx, sy, sw, sh = self:get_scrollbar_rect()
  local grab_reach = style.scrollbar_hover_size
  return x >= sx - grab_reach and x < sx + sw
     and y >= sy and y < sy + sh
end


function View:h_scrollbar_overlaps_point(x, y)
  local sx, sy, sw, sh = self:get_h_scrollbar_rect()
  local grab_reach = style.scrollbar_hover_size
  return y >= sy - grab_reach and y < sy + sh
     and x >= sx and x < sx + sw
end


function View:pointer_on_scrollbar()
  for _, bar in pairs(self.scrollbars) do
    if bar.hovered or bar.dragging then return true end
  end
  return false
end


function View:on_mouse_pressed(button, x, y, clicks)
  if self:scrollbar_overlaps_point(x, y) then
    self.scrollbars.v.dragging = true
    return true
  elseif self:h_scrollbar_overlaps_point(x, y) then
    self.scrollbars.h.dragging = true
    return true
  end
end


function View:on_mouse_released(button, x, y)
  for _, bar in pairs(self.scrollbars) do
    bar.dragging = false
  end
end


function View:on_mouse_moved(x, y, dx, dy)
  local bars = self.scrollbars
  if bars.v.dragging then
    self.scroll.to.y = self.scroll.to.y + self:get_scrollable_size() / self.size.y * dy
  end
  if bars.h.dragging then
    self.scroll.to.x = self.scroll.to.x + self:get_h_scrollable_size() / self.size.x * dx
  end
  bars.v.hovered = self:scrollbar_overlaps_point(x, y)
  bars.h.hovered = self:h_scrollbar_overlaps_point(x, y)
end


function View:on_text_input(text)
  -- no-op
end


function View:on_mouse_wheel(y, x)
  if self.scrollable then
    self.scroll.to.y = self.scroll.to.y - y * config.mouse_wheel_scroll * style.scale
    self.scroll.to.x = self.scroll.to.x + (x or 0) * config.mouse_wheel_scroll * style.scale
  end
end


function View:get_content_bounds()
  local x = self.scroll.x
  local y = self.scroll.y
  return x, y, x + self.size.x, y + self.size.y
end


function View:get_content_offset()
  local x = common.round(self.position.x - self.scroll.x)
  local y = common.round(self.position.y - self.scroll.y)
  return x, y
end


function View:get_h_scrollable_size()
  return self.size.x
end


function View:clamp_scroll_position()
  local max = self:get_scrollable_size() - self.size.y
  self.scroll.to.y = common.clamp(self.scroll.to.y, 0, max)

  if self.scroll.to.x > 0 then
    local hmax = self:get_h_scrollable_size() - self.size.x
    self.scroll.to.x = common.clamp(self.scroll.to.x, 0, math.max(0, hmax))
  else
    self.scroll.to.x = 0
  end
end


function View:update()
  self:clamp_scroll_position()
  self:move_towards(self.scroll, "x", self.scroll.to.x, 0.3)
  self:move_towards(self.scroll, "y", self.scroll.to.y, 0.3)

  for _, bar in pairs(self.scrollbars) do
    local dest = (bar.hovered or bar.dragging)
      and style.scrollbar_hover_size or style.scrollbar_size
    self:move_towards(bar, "size", dest, 0.3)
  end
end


function View:draw_background(color)
  local x, y = self.position.x, self.position.y
  local w, h = self.size.x, self.size.y
  renderer.draw_rect(x, y, w + x % 1, h + y % 1, color)
end


local function draw_bar(bar, x, y, w, h)
  local highlight = bar.hovered or bar.dragging
  renderer.draw_rect(x, y, w, h, highlight and style.scrollbar2 or style.scrollbar)
end


function View:draw_scrollbar()
  draw_bar(self.scrollbars.v, self:get_scrollbar_rect())
  draw_bar(self.scrollbars.h, self:get_h_scrollbar_rect())
end


function View:draw()
end


return View
