local common = require "core.common"
local style = {}

-- path and unscaled size per font, so a user module can replace one and keep
-- it across a scale change
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
  tab_width = 10.3,
}

-- unscaled pixels: hairlines and pointer targets
style.px = {
  divider_size = 1,
  scrollbar_size = 4,
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

function style.set_scale(scale)
  style.scale = scale

  for name, font in pairs(style.fonts) do
    style[name] = renderer.font.load(font[1], font[2] * scale)
  end

  local em = style.font:get_height()
  style.padding = {
    x = common.round(em * style.em.padding_x),
    y = common.round(em * style.em.padding_y)
  }
  style.tab_width = common.round(em * style.em.tab_width)

  style.divider_size = common.round(style.px.divider_size * scale)
  style.scrollbar_size = common.round(style.px.scrollbar_size * scale)
  style.caret_width = common.round(style.px.caret_width * scale)
end

return style
