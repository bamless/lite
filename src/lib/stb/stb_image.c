/* Only the formats images in documents commonly use. stb_image isn't hardened
** against malicious files, so fewer decoders also means less exposed code. */
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
/* keeps width * height * 4 well within an `int` in `ren_new_image` */
#define STBI_MAX_DIMENSIONS 16384
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
