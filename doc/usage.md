# lite

![screenshot](https://user-images.githubusercontent.com/3920290/81471642-6c165880-91ea-11ea-8cd1-fae7ae8f0bc4.png)

## Overview
lite is a lightweight text editor written mostly in Lua — it aims to provide
something practical, pretty, *small* and fast, implemented as simply as
possible; easy to modify and extend, or to use without doing either.


## Getting Started
When lite is started it's typically opened with a *project directory* — this
is the directory where your project's code and other data resides. The project
directory is set once when lite is started and, for the duration of the
session, cannot be changed.

To open lite with a specific project directory the directory name can be passed
as a command-line argument *(`.` can be passed to use the current directory)* or
the directory can be dragged onto either the lite executable or a running
instance of lite.

The main way of opening files in lite is through the `core:find-file` command
— this provides a fuzzy finder over all of the project's files and can be
opened using the **`ctrl+shift+p`** shortcut by default. `ctrl+p` and `ctrl+n`
move between lines, command palette suggestions and search results, following
emacs.

Commands can be run using keyboard shortcuts, or by using the `core:find-command`
command bound to **`ctrl+alt+p`** by default. For example, pressing
`ctrl+alt+p` and typing `newdoc` then pressing `return` would open a new
document. The current keyboard shortcut for a command can be seen to the right
of the command name on the command finder, thus to find the shortcut for a command
`ctrl+alt+p` can be pressed and the command name typed.


## User Module
lite can be configured through use of the user module. The user module can be
used for changing options in the config module, adding additional key bindings,
loading custom color themes, modifying the style or changing any other part of
lite to your personal preference.

The user module is loaded by lite when the application starts, after the plugins
have been loaded.

The user module can be modified by running the `core:open-user-module` command
or otherwise directly opening the `data/user/init.lua` file.


## Project Module
The project module is an optional module which is loaded from the current
project's directory when lite is started. Project modules can be useful for
things like adding custom commands for project-specific build systems, or
loading project-specific plugins.

The project module is loaded by lite when the application starts, after both the
plugins and user module have been loaded.

The project module can be edited by running the `core:open-project-module`
command — if the module does not exist for the current project when the
command is run it will be created.


## Commands
Commands in lite are used both through the command finder (`ctrl+alt+p`) and
by lite's keyboard shortcut system. Commands consist of 3 components:
* **Name** — The command name in the form of `namespace:action-name`, for
  example: `doc:select-all`
* **Predicate** — A function that returns true if the command can be ran, for
  example, for any document commands the predicate checks whether the active
  view is a document
* **Function** — The function which performs the command itself

Commands can be added using the `command.add` function provided by the
`core.command` module:
```lua
local core = require "core"
local command = require "core.command"

command.add("core.docview", {
  ["doc:save"] = function()
    core.active_view.doc:save()
    core.log("Saved '%s', core.active_view.doc.filename)
  end
})
```

Commands can be performed programatically (eg. from another command or by your
user module) by calling the `command.perform` function after requiring the
`command` module:
```lua
local command = require "core.command"
command.perform "core:quit"
```


## Keymap
All keyboard shortcuts in lite are handled by the `core.keymap` module. A key
binding in lite maps a "stroke" (eg. `ctrl+q`) to one or more commands (eg.
`core:quit`). When the shortcut is pressed lite will iterate each command
assigned to that key and run the *predicate function* for that command — if the
predicate passes it stops iterating and runs the command.

An example of where this used is the default binding of the `tab` key:
``` lua
  ["tab"] = { "command:complete", "doc:indent" },
```
When tab is pressed the `command:complete` command is attempted which will only
succeed if the command-input at the bottom of the window is active. Otherwise
the `doc:indent` command is attempted which will only succeed if we have a
document as our active view.

A new mapping can be added by your user module as follows:
```lua
local keymap = require "core.keymap"
keymap.add { ["ctrl+q"] = "core:quit" }
```


## Plugins
Plugins in lite are normal lua modules and are treated as such — no
complicated plugin manager is provided, and, once a plugin is loaded, it is never
expected be to have to unload itself.

To install a plugin simply drop it in the `data/plugins` directory — installed
plugins will be automatically loaded when lite starts. To uninstall a plugin the
plugin file can be deleted — any plugin (including those included with lite's
default installation) can be deleted to remove its functionality.

If you want to load a plugin only under a certain circumstance (for example,
only on a given project) the plugin can be placed somewhere other than the
`data/plugins` directory so that it is not automatically loaded. The plugin can
then be loaded manually as needed by using the `require` function.

Plugins can be downloaded from the [plugins repository](https://github.com/rxi/lite-plugins).

### Context Menus

Right-clicking a view or a tab opens a context menu. In the project tree, the
menu has file operations: new file or folder (missing parent folders are
created too), rename, delete, copy the absolute or project-relative path, and
reveal in the system file manager. Deleting a folder removes everything inside
it after a confirmation; symbolic links inside it are removed, never followed.
Open docs follow a rename, and the tabs of deleted files are closed unless they
have unsaved changes.

The items come from two places: the view that was clicked, and any items
plugins registered for that kind of view. Plugins add items with
`ContextMenu.add`, from the `core.contextmenu` module:
```lua
local ContextMenu = require "core.contextmenu"
local DocView = require "core.docview"

ContextMenu.add(DocView, {
  { command = "reflow:reflow" },
  { text = "Copy File Name",
    enabled = function(view) return view.doc.filename ~= nil end,
    fn = function(view) system.set_clipboard(view.doc.filename) end },
})
```

The first argument says which views the items are for. It's either a view
class, which also matches its subclasses, or a function that takes the clicked
view and returns true if the items should show.

Each item does one of two things:
* **`command`**: Runs the named command. The label defaults to the command's
  name in readable form (`reflow:reflow` shows as "Reflow: Reflow"), the
  command's shortcut is shown next to it, and the item is greyed out when the
  command's predicate fails. Right-clicking a view makes it the active view,
  so commands act on the view that was clicked. Tabs are the exception: the
  active view doesn't change, so use `fn` for items that act on the clicked
  tab.
* **`fn`**: Calls the function with the view the menu was opened on. For a
  tab, that's the node's `TabBar`.

Items can also set:
* **`text`**: The label.
* **`binding`**: The shortcut shown on the right, eg. `"ctrl+s"`.
* **`enabled`**: `false`, or a function taking the view and returning
  whether the item can be picked. Disabled items are shown greyed out.

`{ divider = true }` draws a separator line.

The second argument can also be a function `(view, x, y)` that returns the
items, or `nil` for none, when the menu opens. Use this when the items depend
on what's under the pointer.

`ContextMenu.add` returns a handle. Pass it to `ContextMenu.remove` to take
the items away again, for example when a plugin turns itself off.

A plugin that defines its own view gives it a menu by overriding
`View:get_context_menu(x, y)` instead. It takes the click position and
returns a list of items, or `nil` for no menu.

## Color Themes
Colors themes in lite are lua modules which overwrite the color fields of lite's
`core.style` module. Color themes should be placed in the `data/user/colors`
directory.

A color theme can be set by requiring it in your user module:
```lua
require "user.colors.winter"
```

Color themes can be downloaded from the [color themes repository](https://github.com/rxi/lite-colors).

