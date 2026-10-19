local common = require "core.common"
local style = {}

-- -----------------------------------------------------------------------------
-- Settings
-- -----------------------------------------------------------------------------

-- Everything in this section is meant to be changed, by a color theme, a
-- plugin or the user module. Sizes are given in units that don't depend on the
-- display (font points, ems, unscaled pixels).

-- path and unscaled size per font
style.fonts = {
  font      = { EXEDIR .. "/data/fonts/font.ttf",      14 },
  big_font  = { EXEDIR .. "/data/fonts/font.ttf",      34 },
  icon_font = { EXEDIR .. "/data/fonts/icons.ttf",     14 },
  code_font = { EXEDIR .. "/data/fonts/monospace.ttf", 13.5 },
}

-- multiples of the ui font's height
style.em = {
  padding_x = 0.85,
  padding_y = 0.42,
  tab_width = 15.0,
}

-- unscaled pixels: hairlines and pointer targets
style.px = {
  divider_size = 1,
  scrollbar_size = 4,
  scrollbar_hover_size = 10,
  caret_width = 2,
}

-- UI & syntax color
style.background = { common.color "#2e2e32" }
style.background2 = { common.color "#252529" }
style.background3 = { common.color "#252529" }
style.text = { common.color "#97979c" }
style.caret = { common.color "#93DDFA" }
style.accent = { common.color "#e1e1e6" }
style.dim = { common.color "#525257" }
style.divider = { common.color "#202024" }
style.selection = { common.color "#48484f" }
style.line_number = { common.color "#525259" }
style.line_number2 = { common.color "#83838f" }
style.line_highlight = { common.color "#343438" }
style.scrollbar = { common.color "#414146" }
style.scrollbar2 = { common.color "#4b4b52" }

style.syntax = {}
style.syntax["normal"] = { common.color "#e1e1e6" }
style.syntax["symbol"] = { common.color "#e1e1e6" }
style.syntax["comment"] = { common.color "#676b6f" }
style.syntax["keyword"] = { common.color "#E58AC9" }
style.syntax["keyword2"] = { common.color "#F77483" }
style.syntax["number"] = { common.color "#FFA94D" }
style.syntax["literal"] = { common.color "#FFA94D" }
style.syntax["string"] = { common.color "#f7c95c" }
style.syntax["operator"] = { common.color "#93DDFA" }
style.syntax["function"] = { common.color "#93DDFA" }

-- -----------------------------------------------------------------------------
-- Private derived values
-- -----------------------------------------------------------------------------

local derived = {}

local derived_from = {
  scale = "the display scale (or the LITE_SCALE environment variable)",
  font = "style.fonts.font",
  big_font = "style.fonts.big_font",
  icon_font = "style.fonts.icon_font",
  code_font = "style.fonts.code_font",
  padding = "style.em.padding_x and style.em.padding_y",
  tab_width = "style.em.tab_width",
  divider_size = "style.px.divider_size",
  scrollbar_size = "style.px.scrollbar_size",
  scrollbar_hover_size = "style.px.scrollbar_hover_size",
  caret_width = "style.px.caret_width",
}

local function derived_write_error(name, setting)
  error(string.format("style.%s is computed by style.set_scale; set %s instead",
    name, setting), 3)
end

setmetatable(style, {
  __index = derived,
  __newindex = function(t, k, v)
    local setting = derived_from[k] or (style.fonts[k] and "style.fonts." .. k)
    if setting then
      derived_write_error(k, setting)
    end
    rawset(t, k, v)
  end,
})

local function read_only_padding(padding)
  return setmetatable({}, {
    __index = padding,
    __newindex = function(_, k)
      derived_write_error("padding." .. tostring(k), "style.em.padding_" .. tostring(k))
    end,
  })
end

function style.set_scale(scale)
  derived.scale = scale

  for name, font in pairs(style.fonts) do
    derived[name] = renderer.font.load(font[1], font[2] * scale)
  end

  local em = derived.font:get_height()

  derived.padding = read_only_padding {
    x = common.round(em * style.em.padding_x),
    y = common.round(em * style.em.padding_y)
  }

  derived.tab_width = common.round(em * style.em.tab_width)

  derived.divider_size = common.round(style.px.divider_size * scale)
  derived.scrollbar_size = common.round(style.px.scrollbar_size * scale)
  derived.scrollbar_hover_size = common.round(style.px.scrollbar_hover_size * scale)
  derived.caret_width = common.round(style.px.caret_width * scale)
end

return style
