// TrueType fonts for `ren`, rasterized by stb_truetype at one pixel size: a glyph is drawn into the atlas the first time a text
// needs it, so a font of thousands of glyphs costs only the ones that are used. The atlas is an R8 (.Coverage) texture, which
// every backend can draw, so the same ren.draw_text calls work on all of them (a CPU backend copies the coverage into its picture).
//
//   font := ren_ttf.create(&renderer, LIBERATION_BOLD, 18)        // a 18 pixel high font
//   ren.draw_text(dl, font, "Quest log", {20, 40}, ren.WHITE)
//   w, h := ren.font_measure(font, "Quest log")
//   ren_ttf.destroy(font, &renderer)
//
// Sizes are in pixels of the target: a program that scales its picture for a high-DPI window makes the font at the scaled size
// (and makes it again when the scale changes). Glyphs are placed on whole pixels (no sub-pixel positioning), which keeps them
// sharp. Not done: sub-pixel kerning tables (GPOS; only the old `kern` table of the font is used), hinting, right-to-left and
// shaping (a codepoint is a glyph), colour fonts.
package ren_ttf

import "base:runtime"
import "core:log"
import "core:math"
import stbtt "vendor:stb/truetype"
import ren ".."
import ui "../../../iv_ui"

// A font a glyph is taken from when the font itself has none (add_fallback).
@(private)
Fallback_Face :: struct {
	info:  stbtt.fontinfo,
	data:  []u8,
	scale: f32,
}

// What the font needs besides the ren.Font: the stb state and the atlas packing.
@(private)
Face :: struct {
	renderer:   ^ren.Renderer,
	info:       stbtt.fontinfo,
	data:       []u8, // the font file (stb keeps pointing into it: it must stay as it is)
	scale:      f32,
	ascent:     int,
	atlas:      ren.Texture,
	atlas_size: int, // the atlas is square
	// shelf packing: glyphs go left to right in a row as high as the tallest in it; a row is full -> the next
	shelf_x:    int,
	shelf_y:    int,
	shelf_h:    int,
	full:       bool, // the atlas has no room left (reported once)
	allocator:  runtime.Allocator,
	// fonts for the characters this one lacks (add_fallback), tried in order; each scaled to the same em as the font
	fallbacks:  [8]Fallback_Face,
	n_fallback: int,
}

PADDING :: 1 // texels round each glyph, so that the edge of one never bleeds into its neighbour

// Makes a font of `pixel_height` (the distance from the top of the tallest letter to the bottom of the lowest, as stb defines
// it) from the bytes of a .ttf file, which must stay alive as long as the font does. `atlas_size` is the side of the square
// atlas (1024 holds some thousand glyphs of a normal size).
create :: proc(
	r: ^ren.Renderer,
	ttf: []u8,
	pixel_height: f32,
	atlas_size := 1024,
	fallback: rune = '?',
	allocator := context.allocator,
) -> (
	font: ^ren.Font,
	ok: bool,
) {
	face := new(Face, allocator)
	face.allocator = allocator
	face.renderer = r
	face.data = ttf
	face.atlas_size = atlas_size
	defer if !ok {
		free(face, allocator)
	}

	if !stbtt.InitFont(&face.info, raw_data(ttf), stbtt.GetFontOffsetForIndex(raw_data(ttf), 0)) {
		log.error("ren_ttf: not a font stb_truetype can read")
		return nil, false
	}
	face.scale = stbtt.ScaleForPixelHeight(&face.info, pixel_height)
	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&face.info, &ascent, &descent, &line_gap)
	face.ascent = int(math.round(f32(ascent) * face.scale))
	line_height := int(math.round(f32(ascent - descent + line_gap) * face.scale))

	atlas, made := ren.texture_create(r, {width = atlas_size, height = atlas_size, format = .R8, filter = .Nearest, use = {.Dynamic}})
	if !made {
		log.error("ren_ttf: the renderer could not make the glyph atlas")
		return nil, false
	}
	face.atlas = atlas

	font = ren.font_create(
		{texture = atlas, atlas_size = {atlas_size, atlas_size}, material = .Coverage, line_height = line_height, ascent = face.ascent, fallback = fallback},
		allocator,
	)
	font.provider = make_glyph
	font.kerning = kerning
	font.user = face
	font.on_destroy = on_destroy
	return font, true
}

// Adds a font that the characters `font` (made by create or create_em) lacks are taken from, at the same em size and on the
// same baseline (up to 8, tried in the order they were added; a glyph already made stays as it is). The bytes must stay alive as
// long as the font does. false: not a font stb_truetype can read, or 8 are there already.
add_fallback :: proc(font: ^ren.Font, ttf: []u8) -> bool {
	if font == nil || font.user == nil {
		return false
	}
	face := (^Face)(font.user)
	if face.n_fallback == len(face.fallbacks) {
		return false
	}
	fb := &face.fallbacks[face.n_fallback]
	if !stbtt.InitFont(&fb.info, raw_data(ttf), stbtt.GetFontOffsetForIndex(raw_data(ttf), 0)) {
		return false
	}
	fb.data = ttf
	// the same em in pixels as the font: its scale times its units per em
	em_px := face.scale * units_per_em(face.data)
	if em_px <= 0 {
		return false
	}
	fb.scale = stbtt.ScaleForMappingEmToPixels(&fb.info, em_px)
	face.n_fallback += 1
	return true
}

// Frees a font made by create (and its atlas texture, in the renderer it was made for).
destroy :: proc(font: ^ren.Font) {
	ren.font_destroy(font) // (calls on_destroy)
}

// The units per em of a TrueType file (the "head" table), 0 if it cannot be read.
units_per_em :: proc(ttf: []u8) -> f32 {
	be16 :: proc(d: []u8, at: int) -> int {
		if at < 0 || at + 2 > len(d) {
			return 0
		}
		return int(d[at]) << 8 | int(d[at + 1])
	}
	be32 :: proc(d: []u8, at: int) -> int {
		return be16(d, at) << 16 | be16(d, at + 2)
	}
	base := int(stbtt.GetFontOffsetForIndex(raw_data(ttf), 0))
	n := be16(ttf, base + 4)
	for i in 0 ..< n {
		rec := base + 12 + i * 16
		if rec + 16 > len(ttf) {
			break
		}
		if string(ttf[rec:rec + 4]) == "head" {
			return f32(be16(ttf, be32(ttf, rec + 8) + 18))
		}
	}
	return 0
}

// Makes a font whose em (the square the designer drew the letters in) is `em_px` pixels, instead of one whose whole height is (what
// `create` takes): so that the same text at a given em looks the same in fonts of different line heights.
create_em :: proc(
	r: ^ren.Renderer,
	ttf: []u8,
	em_px: f32,
	atlas_size := 1024,
	fallback: rune = '?',
	allocator := context.allocator,
) -> (
	font: ^ren.Font,
	ok: bool,
) {
	info: stbtt.fontinfo
	if !stbtt.InitFont(&info, raw_data(ttf), stbtt.GetFontOffsetForIndex(raw_data(ttf), 0)) {
		return nil, false
	}
	ascent, descent, line_gap: i32
	stbtt.GetFontVMetrics(&info, &ascent, &descent, &line_gap)
	upem := units_per_em(ttf)
	if upem <= 0 {
		return nil, false
	}
	return create(r, ttf, em_px * f32(ascent - descent) / upem, atlas_size, fallback, allocator)
}

// Is the atlas of the font full (a glyph that is not in it yet cannot be drawn)? Make a new font then.
is_full :: proc(font: ^ren.Font) -> bool {
	if font == nil || font.user == nil {
		return false
	}
	return (^Face)(font.user).full
}

// Advances of a font file without an atlas or a size: in em (1 = the font's em).
Metrics :: struct {
	info: stbtt.fontinfo,
	upem: f32,
}

metrics_init :: proc(m: ^Metrics, ttf: []u8) -> bool {
	if !stbtt.InitFont(&m.info, raw_data(ttf), stbtt.GetFontOffsetForIndex(raw_data(ttf), 0)) {
		return false
	}
	m.upem = units_per_em(ttf)
	return m.upem > 0
}

// The advance of a character in em, and whether the font has it.
metrics_advance :: proc(m: ^Metrics, c: rune) -> (adv: f32, ok: bool) {
	index := stbtt.FindGlyphIndex(&m.info, c)
	if index == 0 && c != 0 {
		return 0, false
	}
	advance, lsb: i32
	stbtt.GetCodepointHMetrics(&m.info, c, &advance, &lsb)
	return f32(advance) / m.upem, true
}

// The vertical measures of a font file in em: how far letters rise above the baseline (ascent), how far they hang below it (descent, positive), and the
// gap the designer left between lines.
metrics_vertical :: proc(m: ^Metrics) -> (ascent, descent, line_gap: f32) {
	a, d, g: i32
	stbtt.GetFontVMetrics(&m.info, &a, &d, &g)
	return f32(a) / m.upem, f32(-d) / m.upem, f32(g) / m.upem
}

@(private)
on_destroy :: proc(font: ^ren.Font) {
	face := (^Face)(font.user)
	if face == nil {
		return
	}
	ren.texture_destroy(face.renderer, face.atlas)
	free(face, face.allocator)
	font.user = nil
}

@(private)
kerning :: proc(font: ^ren.Font, a, b: rune) -> f32 {
	face := (^Face)(font.user)
	if stbtt.FindGlyphIndex(&face.info, a) == 0 || stbtt.FindGlyphIndex(&face.info, b) == 0 {return 0} // (a fallback's glyph: no pairs across fonts)
	return f32(stbtt.GetCodepointKernAdvance(&face.info, a, b)) * face.scale
}

// Rasterizes one glyph into the atlas (the font's provider).
@(private)
make_glyph :: proc(font: ^ren.Font, c: rune) -> (g: ren.Glyph, ok: bool) {
	face := (^Face)(font.user)
	info, scale := &face.info, face.scale
	index := stbtt.FindGlyphIndex(info, c)
	for i in 0 ..< face.n_fallback { // the font has none: the first fallback that has it
		if index != 0 || c == 0 {break}
		fb := &face.fallbacks[i]
		if fi := stbtt.FindGlyphIndex(&fb.info, c); fi != 0 {info, scale, index = &fb.info, fb.scale, fi}
	}
	if index == 0 && c != 0 { // no font has such a glyph (0 is .notdef)
		return {}, false
	}

	advance, left_bearing: i32
	stbtt.GetCodepointHMetrics(info, c, &advance, &left_bearing)
	g.codepoint = c
	g.advance = f32(advance) * scale

	x0, y0, x1, y1: i32
	stbtt.GetCodepointBitmapBox(info, c, scale, scale, &x0, &y0, &x1, &y1)
	w, h := int(x1 - x0), int(y1 - y0)
	if w <= 0 || h <= 0 { // a space: it moves the pen and has no picture
		return g, true
	}

	// room in the atlas
	if face.shelf_x + w + PADDING > face.atlas_size {
		face.shelf_x = 0
		face.shelf_y += face.shelf_h + PADDING
		face.shelf_h = 0
	}
	if face.shelf_y + h + PADDING > face.atlas_size {
		if !face.full {
			face.full = true
			log.warnf("ren_ttf: the %dx%d glyph atlas is full: glyphs that are not in it yet are not drawn", face.atlas_size, face.atlas_size)
		}
		return {}, false
	}

	pixels := make([]u8, w * h, context.temp_allocator)
	stbtt.MakeCodepointBitmap(info, raw_data(pixels), i32(w), i32(h), i32(w), scale, scale, c)
	region := ui.Rect{face.shelf_x, face.shelf_y, w, h}
	if !ren.texture_update(face.renderer, face.atlas, region, pixels) {
		return {}, false
	}
	face.shelf_x += w + PADDING
	face.shelf_h = max(face.shelf_h, h)

	g.src = region
	g.offset = {int(x0), face.ascent + int(y0)} // (y0 counts up from the baseline, negative above it)
	return g, true
}

