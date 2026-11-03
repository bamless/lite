#include <string.h>

#include "api.h"
#include "lib/md4c/md4c.h"

/* ** Adapt md4c parsing to an AST composed of nested lua tables, for comnsumption
** by `mardownview.lua` */

static const char *block_types[] = {
  "doc", "quote", "ul", "ol", "li", "hr", "h", "code_block", "html_block", "p",
  "table", "thead", "tbody", "tr", "th", "td", "footnotes", "footnote",
  "admonition", "blank",
};

static const char *span_types[] = {
  "em", "strong", "a", "img", "code", "ins", "del", "math", "display_math",
  "wikilink", "u", "spoiler", "sup", "sub", "footnote_ref", "mark",
};


static void push_utf8(lua_State *L, unsigned cp) {
  char buf[4];
  int n;
  if (cp == 0 || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) { cp = 0xFFFD; }
  if (cp < 0x80) {
    buf[0] = cp; n = 1;
  } else if (cp < 0x800) {
    buf[0] = 0xC0 | (cp >> 6); buf[1] = 0x80 | (cp & 0x3F); n = 2;
  } else if (cp < 0x10000) {
    buf[0] = 0xE0 | (cp >> 12); buf[1] = 0x80 | ((cp >> 6) & 0x3F);
    buf[2] = 0x80 | (cp & 0x3F); n = 3;
  } else {
    buf[0] = 0xF0 | (cp >> 18); buf[1] = 0x80 | ((cp >> 12) & 0x3F);
    buf[2] = 0x80 | ((cp >> 6) & 0x3F); buf[3] = 0x80 | (cp & 0x3F); n = 4;
  }
  lua_pushlstring(L, buf, n);
}


/* md4c hands entities over verbatim, as `&name;`, `&#123;` or `&#x7B;`.
** TODO: the full HTML5 list of named entities; unknown names stay verbatim. */
static void push_entity(lua_State *L, const char *text, size_t size) {
  static const struct { const char *name; unsigned cp; } named[] = {
    { "amp", '&' }, { "lt", '<' }, { "gt", '>' }, { "quot", '"' },
    { "apos", '\'' }, { "nbsp", 0xA0 }, { "copy", 0xA9 }, { "reg", 0xAE },
    { "trade", 0x2122 }, { "mdash", 0x2014 }, { "ndash", 0x2013 },
    { "hellip", 0x2026 }, { "laquo", 0xAB }, { "raquo", 0xBB },
    { "middot", 0xB7 }, { "bull", 0x2022 }, { "deg", 0xB0 }, { "times", 0xD7 },
    { "divide", 0xF7 }, { "plusmn", 0xB1 }, { "larr", 0x2190 },
    { "rarr", 0x2192 }, { "uarr", 0x2191 }, { "darr", 0x2193 },
    { "harr", 0x2194 }, { "euro", 0x20AC }, { "pound", 0xA3 }, { "sect", 0xA7 },
  };
  if (size > 3 && text[1] == '#') {
    int hex = text[2] == 'x' || text[2] == 'X';
    unsigned cp = 0;
    for (size_t i = hex ? 3 : 2; i < size - 1; i++) {
      char c = text[i];
      unsigned digit = (c >= '0' && c <= '9') ? c - '0'
        : (c >= 'a' && c <= 'f') ? c - 'a' + 10 : c - 'A' + 10;
      cp = cp * (hex ? 16 : 10) + digit;
      if (cp > 0x10FFFF) { break; }
    }
    push_utf8(L, cp);
    return;
  }
  for (size_t i = 0; i < sizeof(named) / sizeof(named[0]); i++) {
    size_t len = strlen(named[i].name);
    if (len == size - 2 && memcmp(named[i].name, text + 1, len) == 0) {
      push_utf8(L, named[i].cp);
      return;
    }
  }
  lua_pushlstring(L, text, size);
}


/* Attributes (link targets, titles, code languages) come in pieces, some of
** which are entities. */
static void push_attribute(lua_State *L, const MD_ATTRIBUTE *attr) {
  luaL_Buffer b;
  luaL_buffinit(L, &b);
  for (int i = 0; attr->substr_offsets[i] < attr->size; i++) {
    const char *text = attr->text + attr->substr_offsets[i];
    size_t size = attr->substr_offsets[i + 1] - attr->substr_offsets[i];
    if (attr->substr_types[i] == MD_TEXT_ENTITY) {
      push_entity(L, text, size);
      luaL_addvalue(&b);
    } else if (attr->substr_types[i] == MD_TEXT_NULLCHAR) {
      luaL_addstring(&b, "\xEF\xBF\xBD");
    } else {
      luaL_addlstring(&b, text, size);
    }
  }
  luaL_pushresult(&b);
}


static void set_attribute(lua_State *L, const char *field, const MD_ATTRIBUTE *attr) {
  if (attr->size == 0) { return; }
  push_attribute(L, attr);
  lua_setfield(L, -2, field);
}


static void set_number(lua_State *L, const char *field, lua_Number n) {
  lua_pushnumber(L, n);
  lua_setfield(L, -2, field);
}


static void set_boolean(lua_State *L, const char *field, int b) {
  lua_pushboolean(L, b);
  lua_setfield(L, -2, field);
}


static void set_char(lua_State *L, const char *field, char c) {
  lua_pushlstring(L, &c, 1);
  lua_setfield(L, -2, field);
}


static void append_to_parent(lua_State *L) {
  lua_rawseti(L, -2, lua_objlen(L, -2) + 1);
}


static int push_node(lua_State *L, const char *type) {
  if (!lua_checkstack(L, 4)) { return 1; }
  lua_createtable(L, 0, 2);
  lua_pushstring(L, type);
  lua_setfield(L, -2, "type");
  return 0;
}


static int enter_block(MD_BLOCKTYPE type, void *detail, void *userdata) {
  lua_State *L = userdata;
  if (push_node(L, block_types[type])) { return 1; }
  switch (type) {
    case MD_BLOCK_UL: {
      MD_BLOCK_UL_DETAIL *d = detail;
      set_boolean(L, "tight", d->is_tight);
      break;
    }
    case MD_BLOCK_OL: {
      MD_BLOCK_OL_DETAIL *d = detail;
      set_boolean(L, "tight", d->is_tight);
      set_number(L, "start", d->start);
      set_char(L, "delimiter", d->mark_delimiter);
      break;
    }
    case MD_BLOCK_LI: {
      MD_BLOCK_LI_DETAIL *d = detail;
      if (d->is_task) { set_boolean(L, "checked", d->task_mark != ' '); }
      break;
    }
    case MD_BLOCK_H:
      set_number(L, "level", ((MD_BLOCK_H_DETAIL*) detail)->level);
      break;
    case MD_BLOCK_CODE:
      set_attribute(L, "lang", &((MD_BLOCK_CODE_DETAIL*) detail)->lang);
      break;
    case MD_BLOCK_TH:
    case MD_BLOCK_TD: {
      static const char *aligns[] = { NULL, "left", "center", "right" };
      const char *align = aligns[((MD_BLOCK_TD_DETAIL*) detail)->align];
      if (align) {
        lua_pushstring(L, align);
        lua_setfield(L, -2, "align");
      }
      break;
    }
    case MD_BLOCK_FOOTNOTE_DEF:
      set_number(L, "id", ((MD_BLOCK_FOOTNOTE_DEF_DETAIL*) detail)->id);
      break;
    case MD_BLOCK_ADMONITION:
      set_attribute(L, "kind", &((MD_BLOCK_ADMONITION_DETAIL*) detail)->type);
      break;
    default:
      break;
  }
  return 0;
}


static int leave(void *userdata) {
  lua_State *L = userdata;
  append_to_parent(L);
  return 0;
}


static int leave_block(MD_BLOCKTYPE type, void *detail, void *userdata) {
  return type == MD_BLOCK_DOC ? 0 : leave(userdata);
}


static int enter_span(MD_SPANTYPE type, void *detail, void *userdata) {
  lua_State *L = userdata;
  if (push_node(L, span_types[type])) { return 1; }
  switch (type) {
    case MD_SPAN_A: {
      MD_SPAN_A_DETAIL *d = detail;
      set_attribute(L, "href", &d->href);
      set_attribute(L, "title", &d->title);
      if (d->is_autolink) { set_boolean(L, "autolink", 1); }
      break;
    }
    case MD_SPAN_IMG: {
      MD_SPAN_IMG_DETAIL *d = detail;
      set_attribute(L, "src", &d->src);
      set_attribute(L, "title", &d->title);
      break;
    }
    case MD_SPAN_WIKILINK:
      set_attribute(L, "target", &((MD_SPAN_WIKILINK_DETAIL*) detail)->target);
      break;
    case MD_SPAN_FOOTNOTE_REF:
      set_number(L, "id", ((MD_SPAN_FOOTNOTE_REF_DETAIL*) detail)->id);
      break;
    default:
      break;
  }
  return 0;
}


static int leave_span(MD_SPANTYPE type, void *detail, void *userdata) {
  return leave(userdata);
}


static int text(MD_TEXTTYPE type, const MD_CHAR *text, MD_SIZE size, void *userdata) {
  lua_State *L = userdata;
  if (!lua_checkstack(L, 4)) { return 1; }
  switch (type) {
    case MD_TEXT_NULLCHAR: lua_pushliteral(L, "\xEF\xBF\xBD"); break;
    case MD_TEXT_BR:       lua_pushliteral(L, "\n"); break;
    case MD_TEXT_SOFTBR:   lua_pushliteral(L, " "); break;
    case MD_TEXT_ENTITY:   push_entity(L, text, size); break;
    case MD_TEXT_HTML:
      if (push_node(L, "html")) { return 1; }
      lua_pushlstring(L, text, size);
      lua_rawseti(L, -2, 1);
      break;
    default:
      lua_pushlstring(L, text, size);
      break;
  }
  append_to_parent(L);
  return 0;
}


static int f_parse(lua_State *L) {
  size_t size;
  const char *input = luaL_checklstring(L, 1, &size);
  MD_PARSER parser = {
    .flags = MD_DIALECT_GITHUB,
    .enter_block = enter_block,
    .leave_block = leave_block,
    .enter_span = enter_span,
    .leave_span = leave_span,
    .text = text,
  };
  int base = lua_gettop(L);
  int res = md_parse(input, size, &parser, L);
  if (res != 0) {
    lua_settop(L, base);
    lua_pushnil(L);
    lua_pushstring(L, res < 0 ? "parser error" : "document nested too deeply");
    return 2;
  }
  return 1;
}


static const luaL_Reg lib[] = {
  { "parse", f_parse },
  { NULL, NULL }
};

int luaopen_markdown(lua_State *L) {
  luaL_newlib(L, lib);
  return 1;
}
