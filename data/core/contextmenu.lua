local core = require "core"
local common = require "core.common"
local style = require "core.style"
local command = require "core.command"
local keymap = require "core.keymap"
local Object = require "core.object"


local ContextMenu = Object:extend()

ContextMenu.DIVIDER = { divider = true }

-- -----------------------------------------------------------------------------
-- Items registered by plugins
-- -----------------------------------------------------------------------------

local extensions = {}

-- `predicate` is a view class (the items show for views of that class) or a
-- function taking the clicked view and returning whether they show. `items` is
-- a list of items, or a function `(view, x, y)` returning one (or nil) when the
-- menu opens. Returns a handle for `ContextMenu.remove`.
function ContextMenu.add(predicate, items)
  if type(predicate) == "table" then
    local class = predicate
    predicate = function(view) return view:is(class) end
  end
  local ext = { predicate = predicate, items = items }
  table.insert(extensions, ext)
  return ext
end


-- Removing a handle that was already removed does nothing.
function ContextMenu.remove(handle)
  for i, ext in ipairs(extensions) do
    if ext == handle then
      table.remove(extensions, i)
      return
    end
  end
end


-- The view's own items followed by each matching extension's, with a divider
-- between groups. Returns nil if there's nothing to show.
function ContextMenu.collect_items(view, x, y)
  local groups = {}
  local own = view:get_context_menu(x, y)
  if own then table.insert(groups, own) end
  -- a failing extension is logged and skipped, rather than taking the whole
  -- menu down with it
  for _, ext in ipairs(extensions) do
    local ok, items = core.try(function()
      if not ext.predicate(view) then return nil end
      if type(ext.items) == "function" then return ext.items(view, x, y) end
      return ext.items
    end)
    if ok and items then table.insert(groups, items) end
  end

  local res = {}
  for _, group in ipairs(groups) do
    if #res > 0 then table.insert(res, ContextMenu.DIVIDER) end
    for _, item in ipairs(group) do table.insert(res, item) end
  end
  return #res > 0 and res or nil
end


-- -----------------------------------------------------------------------------
-- Opening and closing
-- -----------------------------------------------------------------------------


function ContextMenu:new()
  self.visible = false
  self.items = {}
  self.rect = { x = 0, y = 0, w = 0, h = 0 }
end


local function resolve_items(items, view)
  local res = {}
  for _, item in ipairs(items) do
    if item.divider then
      if #res > 0 and not res[#res].divider then
        table.insert(res, ContextMenu.DIVIDER)
      end
    else
      local enabled = item.enabled
      if type(enabled) == "function" then
        enabled = enabled(view)
      end
      enabled = enabled ~= false
      if item.command then
        local cmd = command.map[item.command]
        enabled = enabled and cmd ~= nil and cmd.predicate()
      end
      table.insert(res, {
        text = item.text or command.prettify_name(item.command),
        binding = item.binding or (item.command and keymap.get_binding(item.command)),
        command = item.command,
        fn = item.fn,
        enabled = enabled,
      })
    end
  end
  if #res > 0 and res[#res].divider then
    table.remove(res)
  end
  return res
end


function ContextMenu:open(items, view, x, y)
  self.items = resolve_items(items, view)
  if #self.items == 0 then return end
  self.visible = true
  self.view = view
  self.anchor = { x = x, y = y }
  self.selected = nil
  self:layout()
end


function ContextMenu:close()
  self.visible = false
  self.items = {}
  self.view = nil
  core.request_redraw()
end


function ContextMenu:run(idx)
  local item = self.items[idx]
  if not item or item.divider or not item.enabled then return end
  local view = self.view
  self:close()
  if item.command then
    command.perform(item.command)
  else
    core.try(item.fn, view)
  end
end


-- -----------------------------------------------------------------------------
-- Layout
-- -----------------------------------------------------------------------------


function ContextMenu:layout()
  local font = style.font
  local pad = style.padding
  local item_h = font:get_height() + pad.y
  local divider_h = pad.y

  -- half a padding above the first row and below the last
  local text_w, binding_w, h = 0, 0, pad.y
  for _, item in ipairs(self.items) do
    if item.divider then
      h = h + divider_h
    else
      text_w = math.max(text_w, font:get_width(item.text))
      if item.binding then
        binding_w = math.max(binding_w, font:get_width(item.binding))
      end
      h = h + item_h
    end
  end
  local w = pad.x + text_w + pad.x + (binding_w > 0 and binding_w + pad.x or 0)

  local root = core.root_view
  local right, bottom = root.position.x + root.size.x, root.position.y + root.size.y
  local x, y = self.anchor.x, self.anchor.y
  if x + w > right then x = x - w end
  if y + h > bottom then y = y - h end
  x = math.max(root.position.x, x)
  y = math.max(root.position.y, y)

  self.rect.x, self.rect.y, self.rect.w, self.rect.h = x, y, w, h
  self.item_h, self.divider_h = item_h, divider_h
end


function ContextMenu:each_item()
  return coroutine.wrap(function()
    local y = self.rect.y + style.padding.y / 2
    for i, item in ipairs(self.items) do
      local h = item.divider and self.divider_h or self.item_h
      coroutine.yield(i, item, self.rect.x, y, self.rect.w, h)
      y = y + h
    end
  end)
end


function ContextMenu:overlaps_point(px, py)
  local r = self.rect
  return px >= r.x and px < r.x + r.w and py >= r.y and py < r.y + r.h
end


-- Returns the index of the enabled item under the point, if any.
function ContextMenu:get_item_overlapping_point(px, py)
  for i, item, x, y, w, h in self:each_item() do
    if px >= x and px < x + w and py >= y and py < y + h then
      return (not item.divider and item.enabled) and i or nil
    end
  end
end


-- -----------------------------------------------------------------------------
-- Events
-- -----------------------------------------------------------------------------


function ContextMenu:on_mouse_pressed(button, x, y)
  if not self.visible then return false end
  if self:overlaps_point(x, y) then
    return true
  end
  self:close()
  return button ~= "right"
end


function ContextMenu:on_mouse_released(button, x, y)
  if not self.visible or button ~= "left" then return end
  local idx = self:get_item_overlapping_point(x, y)
  if idx then self:run(idx) end
end


function ContextMenu:on_mouse_moved(x, y)
  self.selected = self:get_item_overlapping_point(x, y)
end


local function step_selection(self, dir)
  local n = #self.items
  local idx = self.selected or (dir > 0 and 0 or n + 1)
  for _ = 1, n do
    idx = (idx + dir - 1) % n + 1
    local item = self.items[idx]
    if not item.divider and item.enabled then
      self.selected = idx
      return
    end
  end
end


function ContextMenu:on_key_pressed(k)
  if not self.visible or keymap.is_modkey(k) then return false end
  if k == "up" then
    step_selection(self, -1)
  elseif k == "down" then
    step_selection(self, 1)
  elseif k == "return" or k == "keypad enter" then
    if self.selected then self:run(self.selected) end
  else
    self:close()
  end
  return true
end


-- -----------------------------------------------------------------------------
-- Drawing
-- -----------------------------------------------------------------------------


function ContextMenu:draw()
  if not self.visible then return end
  self:layout()

  local r, ds = self.rect, style.divider_size
  renderer.draw_rect(r.x - ds, r.y - ds, r.w + ds * 2, r.h + ds * 2, style.divider)
  renderer.draw_rect(r.x, r.y, r.w, r.h, style.background3)

  local font, pad = style.font, style.padding
  for i, item, x, y, w, h in self:each_item() do
    if item.divider then
      renderer.draw_rect(x, y + math.floor((h - ds) / 2), w, ds, style.divider)
    else
      if i == self.selected then
        renderer.draw_rect(x, y, w, h, style.line_highlight)
      end
      local color = item.enabled and style.text or style.dim
      if i == self.selected then color = style.accent end
      common.draw_text(font, color, item.text, "left", x + pad.x, y, w, h)
      if item.binding then
        common.draw_text(font, style.dim, item.binding, "right", x, y, w - pad.x, h)
      end
    end
  end
end


return ContextMenu
