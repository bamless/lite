#include <stdio.h>
#include <stdbool.h>
#include <assert.h>
#include <math.h>
#include "lib/stb/stb_truetype.h"
#include "lib/stb/stb_image.h"
#include "renderer.h"

/* Glyphs are baked in sets of 256 consecutive codepoints, enough to cover all of Unicode. */
#define MAX_CODEPOINT 0x10FFFF
#define MAX_GLYPHSET ((MAX_CODEPOINT + 1) / 256)

struct RenImage {
  RenColor *pixels;
  int width, height;
  unsigned id;
};

typedef struct {
  RenImage *image;
  stbtt_bakedchar glyphs[256];
} GlyphSet;

struct RenFont {
  void *data;
  stbtt_fontinfo stbfont;
  GlyphSet *sets[MAX_GLYPHSET];
  float size;
  int height;
};


static SDL_Window *window;
static struct { int left, top, right, bottom; } clip;

static SDL_Renderer *renderer;
static SDL_Texture *texture;
static bool has_vsync;
static struct { RenColor *pixels; int w, h; } framebuffer;


static void* check_alloc(void *ptr);


static void update_framebuffer_size(void) {
  int w, h;
#if __APPLE__
  SDL_GetWindowSize(window, &w, &h);
#else
  SDL_GetRendererOutputSize(renderer, &w, &h);
#endif
  if (w < 1) { w = 1; }
  if (h < 1) { h = 1; }
  if (texture && w == framebuffer.w && h == framebuffer.h) { return; }

  free(framebuffer.pixels);
  framebuffer.pixels = check_alloc(calloc((size_t) w * h, sizeof(RenColor)));
  framebuffer.w = w;
  framebuffer.h = h;

  /* `RenColor` is laid out b, g, r, a, which on a little-endian machine is
  ** the 32-bit `ARGB8888`, so pixels can be uploaded without conversion */
  if (texture) { SDL_DestroyTexture(texture); }
  texture = SDL_CreateTexture(renderer, SDL_PIXELFORMAT_ARGB8888,
    SDL_TEXTUREACCESS_STREAMING, w, h);
  if (!texture) {
    fprintf(stderr, "Fatal error: could not create the window texture: %s\n", SDL_GetError());
    exit(EXIT_FAILURE);
  }
}


static void* check_alloc(void *ptr) {
  if (!ptr) {
    fprintf(stderr, "Fatal error: memory allocation failed\n");
    exit(EXIT_FAILURE);
  }
  return ptr;
}


static const char* utf8_to_codepoint(const char* p, unsigned* dst) {
  const unsigned char* s = (const unsigned char*)p;
  unsigned res, n;
  if(s[0] < 0x80) {
      res = s[0];
      n = 0;
  } else if((s[0] & 0xe0) == 0xc0) {
      res = s[0] & 0x1f;
      n = 1;
  } else if((s[0] & 0xf0) == 0xe0) {
      res = s[0] & 0x0f;
      n = 2;
  } else if((s[0] & 0xf8) == 0xf0) {
      res = s[0] & 0x07;
      n = 3;
  } else {
      *dst = 0xFFFD;
      return p + 1;
  }
  for(unsigned i = 1; i <= n; i++) {
      if((s[i] & 0xc0) != 0x80) {
          *dst = 0xFFFD;
          return p + i;
      }
      res = (res << 6) | (s[i] & 0x3f);
  }
  *dst = res > MAX_CODEPOINT ? 0xFFFD : res;
  return p + n + 1;
}


void ren_init(SDL_Window *win) {
  assert(win);
  window = win;

  SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "nearest");

  /* Prefer a vsynced renderer. If that fails we take any renderer at all, and
  ** the main loop falls back to pacing itself with `system.sleep`. */
  renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_PRESENTVSYNC);
  if (!renderer) { renderer = SDL_CreateRenderer(window, -1, 0); }
  if (!renderer) {
    fprintf(stderr, "Fatal error: could not create a renderer: %s\n",
      SDL_GetError());
    exit(EXIT_FAILURE);
  }
  SDL_RendererInfo info;
  has_vsync = SDL_GetRendererInfo(renderer, &info) == 0 && (info.flags & SDL_RENDERER_PRESENTVSYNC);

  update_framebuffer_size();
  ren_set_clip_rect( (RenRect) { 0, 0, framebuffer.w, framebuffer.h } );
}


bool ren_has_vsync(void) {
  return has_vsync;
}


void ren_present(void) {
  SDL_RenderClear(renderer);
  SDL_RenderCopy(renderer, texture, NULL, NULL);
  SDL_RenderPresent(renderer);
}


void ren_update_rects(RenRect *rects, int count) {
  for (int i = 0; i < count; i++) {
    RenRect r = rects[i];
    SDL_UpdateTexture(texture, (SDL_Rect*) &r,
      framebuffer.pixels + r.x + r.y * framebuffer.w,
      framebuffer.w * sizeof(RenColor));
  }

  static bool initial_frame = true;
  if (initial_frame) {
    SDL_ShowWindow(window);
    initial_frame = false;
  }

  ren_present();
}


void ren_set_clip_rect(RenRect rect) {
  clip.left   = rect.x;
  clip.top    = rect.y;
  clip.right  = rect.x + rect.width;
  clip.bottom = rect.y + rect.height;
}


void ren_get_size(int *x, int *y) {
  update_framebuffer_size();
  *x = framebuffer.w;
  *y = framebuffer.h;
}


RenImage* ren_new_image(int width, int height) {
  assert(width > 0 && height > 0);
  RenImage *image = malloc(sizeof(RenImage) + width * height * sizeof(RenColor));
  check_alloc(image);
  image->pixels = (void*) (image + 1);
  image->width = width;
  image->height = height;
  static unsigned next_id = 0;
  image->id = ++next_id;
  return image;
}


RenImage* ren_load_image(const char *filename, const char **error) {
  int width, height, channels;
  unsigned char *data = stbi_load(filename, &width, &height, &channels, 4);
  if (!data) {
    *error = stbi_failure_reason();
    return NULL;
  }
  RenImage *image = ren_new_image(width, height);
  for (int i = 0; i < width * height; i++) {
    unsigned char *p = data + i * 4;
    image->pixels[i] = (RenColor) { .r = p[0], .g = p[1], .b = p[2], .a = p[3] };
  }
  stbi_image_free(data);
  return image;
}

RenImage* ren_load_image_bytes(const void* bytes, size_t len, const char** error) {
  int width, height, channels;
  unsigned char *data = stbi_load_from_memory(bytes, len, &width, &height, &channels, 4);
  if (!data) {
    *error = stbi_failure_reason();
    return NULL;
  }
  RenImage *image = ren_new_image(width, height);
  for (int i = 0; i < width * height; i++) {
    unsigned char *p = data + i * 4;
    image->pixels[i] = (RenColor) { .r = p[0], .g = p[1], .b = p[2], .a = p[3] };
  }
  stbi_image_free(data);
  return image;
}


RenImage* ren_resize_image(RenImage *src, int width, int height) {
  RenImage *dst = ren_new_image(width, height);
  for (int y = 0; y < height; y++) {
    int sy0 = (int64_t) y * src->height / height;
    int sy1 = (int64_t) (y + 1) * src->height / height;
    if (sy1 <= sy0) { sy1 = sy0 + 1; }
    for (int x = 0; x < width; x++) {
      int sx0 = (int64_t) x * src->width / width;
      int sx1 = (int64_t) (x + 1) * src->width / width;
      if (sx1 <= sx0) { sx1 = sx0 + 1; }
      uint64_t r = 0, g = 0, b = 0, a = 0, n = 0;
      for (int sy = sy0; sy < sy1; sy++) {
        for (int sx = sx0; sx < sx1; sx++) {
          RenColor c = src->pixels[sx + sy * src->width];
          r += c.r * c.a; g += c.g * c.a; b += c.b * c.a; a += c.a;
          n++;
        }
      }
      dst->pixels[x + y * width] = a == 0 ? (RenColor) { 0 } : (RenColor) {
        .r = r / a, .g = g / a, .b = b / a, .a = a / n };
    }
  }
  return dst;
}


void ren_get_image_size(RenImage *image, int *width, int *height) {
  *width = image->width;
  *height = image->height;
}


unsigned ren_get_image_id(RenImage *image) {
  return image->id;
}


void ren_free_image(RenImage *image) {
  free(image);
}


static GlyphSet* load_glyphset(RenFont *font, int idx) {
  GlyphSet *set = check_alloc(calloc(1, sizeof(GlyphSet)));

  /* init image */
  int width = 128;
  int height = 128;
retry:
  set->image = ren_new_image(width, height);

  /* load glyphs */
  float s =
    stbtt_ScaleForMappingEmToPixels(&font->stbfont, 1) /
    stbtt_ScaleForPixelHeight(&font->stbfont, 1);
  int res = stbtt_BakeFontBitmap(
    font->data, 0, font->size * s, (void*) set->image->pixels,
    width, height, idx * 256, 256, set->glyphs);

  /* retry with a larger image buffer if the buffer wasn't large enough */
  if (res < 0) {
    width *= 2;
    height *= 2;
    ren_free_image(set->image);
    goto retry;
  }

  /* adjust glyph yoffsets and xadvance */
  int ascent, descent, linegap;
  stbtt_GetFontVMetrics(&font->stbfont, &ascent, &descent, &linegap);
  float scale = stbtt_ScaleForMappingEmToPixels(&font->stbfont, font->size);
  int scaled_ascent = ascent * scale + 0.5;
  for (int i = 0; i < 256; i++) {
    set->glyphs[i].yoff += scaled_ascent;
    set->glyphs[i].xadvance = floor(set->glyphs[i].xadvance);
  }

  /* convert 8bit data to 32bit */
  for (int i = width * height - 1; i >= 0; i--) {
    uint8_t n = *((uint8_t*) set->image->pixels + i);
    set->image->pixels[i] = (RenColor) { .r = 255, .g = 255, .b = 255, .a = n };
  }

  return set;
}


static GlyphSet* get_glyphset(RenFont *font, int codepoint) {
  int idx = codepoint >> 8;
  if (!font->sets[idx]) {
    font->sets[idx] = load_glyphset(font, idx);
  }
  return font->sets[idx];
}


RenFont* ren_load_font(const char *filename, float size) {
  RenFont *font = NULL;
  FILE *fp = NULL;

  /* init font */
  font = check_alloc(calloc(1, sizeof(RenFont)));
  font->size = size;

  /* load font into buffer */
  fp = fopen(filename, "rb");
  if (!fp) { return NULL; }
  /* get size */
  fseek(fp, 0, SEEK_END); int buf_size = ftell(fp); fseek(fp, 0, SEEK_SET);
  /* load */
  font->data = check_alloc(malloc(buf_size));
  int _ = fread(font->data, 1, buf_size, fp); (void) _;
  fclose(fp);
  fp = NULL;

  /* init stbfont */
  int ok = stbtt_InitFont(&font->stbfont, font->data, 0);
  if (!ok) { goto fail; }

  /* get height and scale */
  int ascent, descent, linegap;
  stbtt_GetFontVMetrics(&font->stbfont, &ascent, &descent, &linegap);
  float scale = stbtt_ScaleForMappingEmToPixels(&font->stbfont, size);
  font->height = (ascent - descent + linegap) * scale + 0.5;

  /* make tab and newline glyphs invisible */
  stbtt_bakedchar *g = get_glyphset(font, '\n')->glyphs;
  g['\t'].x1 = g['\t'].x0;
  g['\n'].x1 = g['\n'].x0;

  return font;

fail:
  if (fp) { fclose(fp); }
  if (font) { free(font->data); }
  free(font);
  return NULL;
}


void ren_free_font(RenFont *font) {
  for (int i = 0; i < MAX_GLYPHSET; i++) {
    GlyphSet *set = font->sets[i];
    if (set) {
      ren_free_image(set->image);
      free(set);
    }
  }
  free(font->data);
  free(font);
}


void ren_set_font_tab_width(RenFont *font, int n) {
  GlyphSet *set = get_glyphset(font, '\t');
  set->glyphs['\t'].xadvance = n;
}


int ren_get_font_tab_width(RenFont *font) {
  GlyphSet *set = get_glyphset(font, '\t');
  return set->glyphs['\t'].xadvance;
}


int ren_get_font_width(RenFont *font, const char *text) {
  int x = 0;
  const char *p = text;
  unsigned codepoint;
  while (*p) {
    p = utf8_to_codepoint(p, &codepoint);
    GlyphSet *set = get_glyphset(font, codepoint);
    stbtt_bakedchar *g = &set->glyphs[codepoint & 0xff];
    x += g->xadvance;
  }
  return x;
}


/* Returns the advance width of `text`, like `ren_get_font_width`, and stores
** in `bounds` a rect covering every pixel `ren_draw_text` can touch when
** drawing it at (x, y). That's the line box (advance width by font height)
** grown by glyph ink reaching outside it: typographic metrics don't bound
** glyph bitmaps, and even the bundled fonts overhang by 1-2px (e.g. `j`, `(`,
** accented capitals). Glyph positions are computed exactly as in
** `ren_draw_text`, including its float to int conversion. */
int ren_get_text_bounds(RenFont *font, const char *text, int x, int y, RenRect *bounds) {
  int x1 = x, y1 = y, x2 = x, y2 = y + font->height;
  int pen = x;
  const char *p = text;
  unsigned codepoint;
  while (*p) {
    p = utf8_to_codepoint(p, &codepoint);
    GlyphSet *set = get_glyphset(font, codepoint);
    stbtt_bakedchar *g = &set->glyphs[codepoint & 0xff];
    int w = g->x1 - g->x0;
    int h = g->y1 - g->y0;
    /* invisible glyphs (tab, newline) draw nothing */
    if (w > 0 && h > 0) {
      int gx = pen + g->xoff;
      int gy = y + g->yoff;
      if (gx < x1) { x1 = gx; }
      if (gy < y1) { y1 = gy; }
      if (gx + w > x2) { x2 = gx + w; }
      if (gy + h > y2) { y2 = gy + h; }
    }
    pen += g->xadvance;
  }
  if (pen > x2) x2 = pen;
  *bounds = (RenRect) { x1, y1, x2 - x1, y2 - y1 };
  return pen - x;
}


int ren_get_font_height(RenFont *font) {
  return font->height;
}


static inline RenColor blend_pixel(RenColor dst, RenColor src) {
  int ia = 0xff - src.a;
  dst.r = ((src.r * src.a) + (dst.r * ia)) >> 8;
  dst.g = ((src.g * src.a) + (dst.g * ia)) >> 8;
  dst.b = ((src.b * src.a) + (dst.b * ia)) >> 8;
  return dst;
}


static inline RenColor blend_pixel2(RenColor dst, RenColor src, RenColor color) {
  src.a = (src.a * color.a) >> 8;
  int ia = 0xff - src.a;
  dst.r = ((src.r * color.r * src.a) >> 16) + ((dst.r * ia) >> 8);
  dst.g = ((src.g * color.g * src.a) >> 16) + ((dst.g * ia) >> 8);
  dst.b = ((src.b * color.b * src.a) >> 16) + ((dst.b * ia) >> 8);
  return dst;
}


#define rect_draw_loop(expr)        \
  for (int j = y1; j < y2; j++) {   \
    for (int i = x1; i < x2; i++) { \
      *d = expr;                    \
      d++;                          \
    }                               \
    d += dr;                        \
  }

void ren_draw_rect(RenRect rect, RenColor color) {
  if (color.a == 0) { return; }

  int x1 = rect.x < clip.left ? clip.left : rect.x;
  int y1 = rect.y < clip.top  ? clip.top  : rect.y;
  int x2 = rect.x + rect.width;
  int y2 = rect.y + rect.height;
  x2 = x2 > clip.right  ? clip.right  : x2;
  y2 = y2 > clip.bottom ? clip.bottom : y2;

  RenColor *d = framebuffer.pixels;
  d += x1 + y1 * framebuffer.w;
  int dr = framebuffer.w - (x2 - x1);

  if (color.a == 0xff) {
    rect_draw_loop(color);
  } else {
    rect_draw_loop(blend_pixel(*d, color));
  }
}


static bool clip_image(RenRect *sub, int *x, int *y) {
  int n;
  if ((n = clip.left - *x) > 0) { sub->width  -= n; sub->x += n; *x += n; }
  if ((n = clip.top  - *y) > 0) { sub->height -= n; sub->y += n; *y += n; }
  if ((n = *x + sub->width  - clip.right ) > 0) { sub->width  -= n; }
  if ((n = *y + sub->height - clip.bottom) > 0) { sub->height -= n; }
  return sub->width > 0 && sub->height > 0;
}


/* Draws a whole image as is. Opaque pixels are copied exactly. */
void ren_blit_image(RenImage *image, int x, int y) {
  RenRect sub = { 0, 0, image->width, image->height };
  if (!clip_image(&sub, &x, &y)) { return; }

  RenColor *s = image->pixels + sub.x + sub.y * image->width;
  RenColor *d = framebuffer.pixels + x + y * framebuffer.w;
  for (int j = 0; j < sub.height; j++) {
    for (int i = 0; i < sub.width; i++) {
      if (s[i].a == 0xff) {
        d[i] = s[i];
      } else if (s[i].a != 0) {
        d[i] = blend_pixel(d[i], s[i]);
      }
    }
    s += image->width;
    d += framebuffer.w;
  }
}


void ren_draw_image(RenImage *image, RenRect *sub, int x, int y, RenColor color) {
  if (color.a == 0) { return; }
  if (!clip_image(sub, &x, &y)) { return; }

  /* draw */
  RenColor *s = image->pixels;
  RenColor *d = framebuffer.pixels;
  s += sub->x + sub->y * image->width;
  d += x + y * framebuffer.w;
  int sr = image->width - sub->width;
  int dr = framebuffer.w - sub->width;

  for (int j = 0; j < sub->height; j++) {
    for (int i = 0; i < sub->width; i++) {
      *d = blend_pixel2(*d, *s, color);
      d++;
      s++;
    }
    d += dr;
    s += sr;
  }
}


int ren_draw_text(RenFont *font, const char *text, int x, int y, RenColor color) {
  RenRect rect;
  const char *p = text;
  unsigned codepoint;
  while (*p) {
    p = utf8_to_codepoint(p, &codepoint);
    GlyphSet *set = get_glyphset(font, codepoint);
    stbtt_bakedchar *g = &set->glyphs[codepoint & 0xff];
    rect.x = g->x0;
    rect.y = g->y0;
    rect.width = g->x1 - g->x0;
    rect.height = g->y1 - g->y0;
    ren_draw_image(set->image, &rect, x + g->xoff, y + g->yoff, color);
    x += g->xadvance;
  }
  return x;
}
