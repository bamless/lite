local core = require "core"
local common = require "core.common"
local command = require "core.command"
local config = require "core.config"
local keymap = require "core.keymap"
local style = require "core.style"
local View = require "core.view"

config.treeview_size = 200

local function get_depth(filename)
  local n = 0
  for _ in filename:gmatch("[\\/]") do
    n = n + 1
  end
  return n
end


local TreeView = View:extend()

function TreeView:new()
  TreeView.super.new(self)
  self.scrollable = true
  self.visible = true
  self.init_size = true
  self.resizable = true
  self.cache = {}
end


function TreeView:set_target_size(axis, value)
  if axis ~= "x" then return end
  local max = core.root_view.size.x / 2
  -- the drag is in real pixels, the setting is not
  config.treeview_size = common.clamp(value, style.padding.x * 3, max) / style.scale
  -- Take the width immediately instead of animating towards it on mouse resize
  self.size.x = config.treeview_size * style.scale
end


function TreeView:on_scale_change()
  for _, item in pairs(self.cache) do
    item.width = nil
  end
  self.metrics = nil
end


function TreeView:get_cached(item)
  local t = self.cache[item.filename]
  if not t then
    t = {}
    t.filename = item.filename
    t.abs_filename = system.absolute_path(item.filename)
    t.name = t.filename:match("[^\\/]+$")
    t.depth = get_depth(t.filename)
    t.type = item.type
    self.cache[t.filename] = t
  end
  return t
end


function TreeView:get_name()
  return "Project"
end


function TreeView:get_item_height()
  return style.font:get_height() + style.padding.y
end


function TreeView:check_cache()
  -- invalidate cache's skip values if project_files has changed
  if core.project_files ~= self.last_project_files then
    for _, v in pairs(self.cache) do
      v.skip = nil
    end
    self.last_project_files = core.project_files
    self.metrics = nil
  end
end


function TreeView:get_item_width(item)
  if not item.width then
    local icon_width = style.icon_font:get_width("D")
    local spacing = style.font:get_width(" ") * 2
    item.width = item.depth * style.padding.x + style.padding.x * 2 + icon_width
      + spacing + style.font:get_width(item.name) + style.padding.x
  end
  return item.width
end


function TreeView:get_metrics()
  if not self.metrics then
    local count, width = 0, 0
    for item in self:each_item() do
      count = count + 1
      width = math.max(width, self:get_item_width(item))
    end
    self.metrics = { count = count, width = width }
  end
  return self.metrics
end


function TreeView:get_scrollable_size()
  return self:get_metrics().count * self:get_item_height() + style.padding.y * 2
end


function TreeView:get_h_scrollable_size()
  return self:get_metrics().width
end


function TreeView:each_item()
  return coroutine.wrap(function()
    self:check_cache()
    local ox, oy = self:get_content_offset()
    local y = oy + style.padding.y
    local w = self.size.x
    local h = self:get_item_height()

    local i = 1
    while i <= #core.project_files do
      local item = core.project_files[i]
      local cached = self:get_cached(item)

      coroutine.yield(cached, ox, y, w, h)
      y = y + h
      i = i + 1

      if not cached.expanded then
        if cached.skip then
          i = cached.skip
        else
          local depth = cached.depth
          while i <= #core.project_files do
            local filename = core.project_files[i].filename
            if get_depth(filename) <= depth then break end
            i = i + 1
          end
          cached.skip = i
        end
      end
    end
  end)
end


function TreeView:on_mouse_moved(px, py, ...)
  TreeView.super.on_mouse_moved(self, px, py, ...)
  self.hovered_item = nil
  if self:pointer_on_scrollbar() then return end
  for item, x,y,w,h in self:each_item() do
    if px > x and py > y and px <= x + w and py <= y + h then
      self.hovered_item = item
      break
    end
  end
end


function TreeView:on_mouse_pressed(button, x, y, clicks)
  if TreeView.super.on_mouse_pressed(self, button, x, y, clicks) then
    return true -- a scrollbar drag
  end

  if button ~= "left" or not self.hovered_item then
    return
  elseif self.hovered_item.type == "dir" then
    self.hovered_item.expanded = not self.hovered_item.expanded
    self.metrics = nil
  else
    core.try(function()
      core.root_view:open_doc(core.open_doc(self.hovered_item.filename))
    end)
  end
end


-- -----------------------------------------------------------------------------
-- Filesystem helpers
-- -----------------------------------------------------------------------------


local function parent_dir(path)
  return path:match("^(.+)[\\/][^\\/]+$") or "."
end


local function each_ancestor(path)
  return coroutine.wrap(function()
    local i = 1
    while true do
      local j = path:find("[\\/]", i)
      if not j then break end
      if j > 1 then coroutine.yield(path:sub(1, j - 1)) end
      i = j + 1
    end
    coroutine.yield(path)
  end)
end


-- Like `mkdir -p`
local function mkdir_parent(path)
  if path == "." or path == "" then return true end
  local info = system.get_file_info(path)
  if info then
    if info.type == "dir" then return true end
    return nil, string.format("\"%s\" exists and is not a directory", path)
  end
  local ok, err = mkdir_parent(parent_dir(path))
  if not ok then return nil, err end
  ok, err = system.mkdir(path)
  if not ok then return nil, string.format("%s: %s", path, err) end
  return true
end


local function is_real_dir(info)
  return info and info.type == "dir" and not info.symlink
end


local function remove_recursive(path)
  local info = system.get_file_info(path)
  if is_real_dir(info) then
    for _, name in ipairs(system.list_dir(path) or {}) do
      local ok, err = remove_recursive(path .. PATHSEP .. name)
      if not ok then return nil, err end
    end
    return system.rmdir(path)
  end
  return os.remove(path)
end


local function count_entries(path)
  local n = 0
  for _, name in ipairs(system.list_dir(path) or {}) do
    local child = path .. PATHSEP .. name
    n = n + 1
    if is_real_dir(system.get_file_info(child)) then
      n = n + count_entries(child)
    end
  end
  return n
end


local function docs_under(path)
  local abs = system.absolute_path(path)
  local res = {}
  if not abs then return res end
  for _, doc in ipairs(core.docs) do
    local doc_abs = doc.filename and system.absolute_path(doc.filename)
    if doc_abs and (doc_abs == abs or doc_abs:sub(1, #abs + 1) == abs .. PATHSEP) then
      table.insert(res, { doc = doc, suffix = doc_abs:sub(#abs + 1) })
    end
  end
  return res
end


local function shell_quote(str)
  return "'" .. str:gsub("'", "'\\''") .. "'"
end


-- -----------------------------------------------------------------------------
-- File operations
-- -----------------------------------------------------------------------------


function TreeView:expand_to(path)
  for dir in each_ancestor(path) do
    self:get_cached({ filename = dir, type = "dir" }).expanded = true
  end
  self.metrics = nil
end


local function prompt_new_entry(label, dir, create)
  core.command_view:set_text(dir == "." and "" or dir .. PATHSEP)
  core.command_view:enter(label, function(path)
    path = path:gsub("[\\/]+$", "")
    if path == "" then return end
    if system.get_file_info(path) then
      core.error("\"%s\" already exists", path)
      return
    end
    create(path)
    core.rescan_project()
  end, common.path_suggest)
end


function TreeView:new_file(dir)
  prompt_new_entry("New File", dir, function(path)
    local ok, err = mkdir_parent(parent_dir(path))
    if not ok then core.error("Could not create \"%s\": %s", path, err) return end
    local doc = core.open_doc()
    core.root_view:open_doc(doc)
    doc:save(path)
    self:expand_to(parent_dir(path))
    core.log("Created \"%s\"", path)
  end)
end


function TreeView:new_folder(dir)
  prompt_new_entry("New Folder", dir, function(path)
    local ok, err = mkdir_parent(path)
    if not ok then core.error("Could not create \"%s\": %s", path, err) return end
    self:expand_to(parent_dir(path))
    core.log("Created folder \"%s\"", path)
  end)
end


function TreeView:rename(item)
  local old = item.filename
  core.command_view:set_text(old, true)
  core.command_view:enter("Rename", function(new)
    new = new:gsub("[\\/]+$", "")
    if new == "" or new == old then return end
    if system.get_file_info(new) then
      core.error("\"%s\" already exists", new)
      return
    end

    local docs = docs_under(old)

    local ok, err = mkdir_parent(parent_dir(new))
    if ok then ok, err = os.rename(old, new) end
    if not ok then
      core.error("Could not rename \"%s\": %s", old, err)
      return
    end

    for _, entry in ipairs(docs) do
      entry.doc.filename = new .. entry.suffix
      entry.doc:reset_syntax()
    end

    -- carry over openness under the filetree being renamed
    local expanded = {}
    for filename, cached in pairs(self.cache) do
      if cached.expanded
      and (filename == old or filename:sub(1, #old + 1) == old .. PATHSEP) then
        table.insert(expanded, new .. filename:sub(#old + 1))
      end
    end
    for _, filename in ipairs(expanded) do
      self:expand_to(filename)
    end
    self:expand_to(parent_dir(new))

    core.rescan_project()
    core.log("Renamed \"%s\" to \"%s\"", old, new)
  end, common.path_suggest)
end


-- TODO: ask about the dirty docs one after the other instead of leaving them
--       open (?)
function TreeView:delete(item)
  local path = item.filename
  local msg
  if item.type == "dir" then
    local n = count_entries(path)
    msg = n == 0 and string.format("Delete the empty folder \"%s\"?", path)
      or string.format("Delete the folder \"%s\" and the %d entr%s inside it?",
        path, n, n == 1 and "y" or "ies")
  else
    msg = string.format("Delete \"%s\"?", path)
  end
  if not system.show_confirm_dialog("Delete", msg) then return end

  -- close the views of what is about to go, but don't throw away unsaved
  -- changes: those docs stay open and can still be saved somewhere
  local root = core.root_view.root_node
  local kept = 0
  for _, entry in ipairs(docs_under(path)) do
    if entry.doc:is_dirty() then
      kept = kept + 1
    else
      for _, view in ipairs(core.get_views_referencing_doc(entry.doc)) do
        local node = root:get_node_for_view(view)
        if node then node:close_view(root, view) end
      end
    end
  end

  local ok, err = remove_recursive(path)
  core.rescan_project()
  if not ok then
    core.error("Could not delete \"%s\": %s", path, err)
    return
  end
  core.log("Deleted \"%s\"", path)
  if kept > 0 then
    core.log("Left %d tab%s with unsaved changes open", kept,
      kept == 1 and "" or "s")
  end
end


local function open_item(path)
  local abs = system.absolute_path(path)
  if not abs then return end
  if PLATFORM == "Windows" then
    system.exec(string.format('explorer /select,"%s"', abs))
  elseif PLATFORM == "Mac OS X" then
    system.exec("open -R " .. shell_quote(abs))
  else
    local info = system.get_file_info(abs)
    local dir = info and info.type == "dir" and abs or parent_dir(abs)
    system.exec("xdg-open " .. shell_quote(dir))
  end
end


-- -----------------------------------------------------------------------------
-- Context menu
-- -----------------------------------------------------------------------------


function TreeView:get_item_overlapping_point(px, py)
  for item, x, y, w, h in self:each_item() do
    if px > x and py > y and px <= x + w and py <= y + h then
      return item
    end
  end
end


function TreeView:get_context_menu(x, y)
  if self:pointer_on_scrollbar() then return nil end
  local item = self:get_item_overlapping_point(x, y)

  -- a click below the last entry is about the project root
  local dir = not item and "."
    or item.type == "dir" and item.filename
    or parent_dir(item.filename)

  local items = {
    { text = "New File",   fn = function() self:new_file(dir) end },
    { text = "New Folder", fn = function() self:new_folder(dir) end },
  }
  if item then
    table.insert(items, { divider = true })
    table.insert(items, { text = "Rename", fn = function() self:rename(item) end })
    table.insert(items, { text = "Delete", fn = function() self:delete(item) end })
    table.insert(items, { divider = true })
    table.insert(items, { text = "Copy Path",
      fn = function() system.set_clipboard(item.abs_filename) end })
    table.insert(items, { text = "Copy Relative Path",
      fn = function() system.set_clipboard(item.filename) end })
  end
  table.insert(items, { divider = true })

  local open_label = (not item or item.type == "dir")
    and "Open in File Manager" or "Open Containing Folder"
  table.insert(items, { text = open_label,
    fn = function() open_item(item and item.filename or ".") end })
  return items
end


function TreeView:update()
  -- update width
  local dest = self.visible and config.treeview_size * style.scale or 0
  if self.init_size then
    self.size.x = dest
    self.init_size = false
  else
    self:move_towards(self.size, "x", dest)
  end

  TreeView.super.update(self)
end


function TreeView:draw()
  self:draw_background(style.background2)

  local icon_width = style.icon_font:get_width("D")
  local spacing = style.font:get_width(" ") * 2

  local doc = core.active_view.doc
  local active_filename = doc and system.absolute_path(doc.filename or "")

  for item, x,y,w,h in self:each_item() do
    local color = style.text

    -- highlight active_view doc
    if item.abs_filename == active_filename then
      color = style.accent
    end

    -- hovered item background
    if item == self.hovered_item then
      renderer.draw_rect(x, y, w, h, style.line_highlight)
      color = style.accent
    end

    -- icons
    x = x + item.depth * style.padding.x + style.padding.x
    if item.type == "dir" then
      local icon1 = item.expanded and "-" or "+"
      local icon2 = item.expanded and "D" or "d"
      common.draw_text(style.icon_font, color, icon1, nil, x, y, 0, h)
      x = x + style.padding.x
      common.draw_text(style.icon_font, color, icon2, nil, x, y, 0, h)
      x = x + icon_width
    else
      x = x + style.padding.x
      common.draw_text(style.icon_font, color, "f", nil, x, y, 0, h)
      x = x + icon_width
    end

    -- text
    x = x + spacing
    x = common.draw_text(style.font, color, item.name, nil, x, y, 0, h)
  end

  self:draw_scrollbar()
end


-- init
local view = TreeView()
local node = core.root_view:get_active_node()
node:split("left", view, true)

-- register commands and keymap
command.add(nil, {
  ["treeview:toggle"] = function()
    view.visible = not view.visible
  end,
})

keymap.add { ["ctrl+\\"] = "treeview:toggle" }
