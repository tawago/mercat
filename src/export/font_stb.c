/*
 * font_stb.c — the single STB_TRUETYPE_IMPLEMENTATION translation unit.
 *
 * exactly one translation unit in the whole build may define
 * STB_TRUETYPE_IMPLEMENTATION, and no Zig source may define it. This file is
 * that unit. All callers reach stb_truetype through src/export/font.zig, which
 * declares the C entry points it needs via extern; this .c file only pulls in
 * the vendored single-header implementation.
 *
 * The vendored header lives at vendor/stb/stb_truetype.h (see vendor/stb/PIN.txt
 * for the pinned commit + SHA-256). The include path is supplied by build.zig.
 */

#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
