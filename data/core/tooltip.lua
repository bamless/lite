local core = require "core"
local common = require "core.common"
local config = require "core.config"
local style = require "core.style"
local Object = require "core.object"


local Tooltip = Object:extend()


function Tooltip:new()
  self.target = nil
  self.shown_at = 0
end


function Tooltip:set_target(target)
  if target ~= self.target then
    self.target = target
    self.shown_at = system.get_time() + config.tooltip_delay
  end
end


function Tooltip:hide()
  self.target = nil
end


function Tooltip:update()
  if not self.target then return end
  local now = system.get_time()
  if now < self.shown_at then
    core.request_wakeup(self.shown_at)
  elseif now < self.shown_at + config.tooltip_fade_time then
    core.request_redraw()
  end
end


local function draw_box(self, text, x, y, flip_y)
  local fade = (system.get_time() - self.shown_at) / config.tooltip_fade_time
  local alpha = common.clamp(fade, 0, 1)
  local function faded(color)
    return { color[1], color[2], color[3], (color[4] or 255) * alpha }
  end

  local font = style.font
  local pad_x, pad_y = style.padding.x / 2, style.padding.y / 2
  local w = font:get_width(text) + pad_x * 2
  local h = font:get_height() + pad_y * 2

  local root = core.root_view
  x = math.max(math.min(x, root.position.x + root.size.x - w), root.position.x)
  if flip_y and y + h > root.position.y + root.size.y then
    y = flip_y - h
  end

  local ds = style.divider_size
  renderer.draw_rect(x - ds, y - ds, w + ds * 2, h + ds * 2, faded(style.divider))
  renderer.draw_rect(x, y, w, h, faded(style.background3))
  common.draw_text(font, faded(style.text), text, "left", x + pad_x, y, w, h)
end


function Tooltip:draw(text, x, y, flip_y)
  if not self.target or system.get_time() < self.shown_at then return end
  core.root_view:defer_draw(draw_box, self, text, x, y, flip_y)
end


return Tooltip
