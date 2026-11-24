package launcher

// The launcher's own shaders (launcher/*.fs, compiled into shaders_spv.odin by tools/launcher_shader.sh): the window
// background (bg.fs, a still FF13 blue-and-white Aero picture) and the panes of frosted glass the panels are (glass.fs).
// As in NorseCode (its gfx.odin): the background is drawn at half size into a texture, shrunk to a quarter and blurred
// (iv_system's built-in blur, two passes along x and y each, then shrunk to an eighth and blurred three more times); the window shows the half-size picture, and every pane looks
// through itself at the blurred copy. The picture never changes, so all of that is drawn again only when the window's
// size does. Where the renderer cannot run shaders or render into textures: the flat colours of before (WIN_BG behind,
// CARD / LOG_BG panels).

import "shared:iv_system/ren"
import ren_assets "shared:iv_system/ren/assets"
import ui "shared:iv_ui"

Bg_Uniforms :: struct {
	res:   [2]f32,
	scale: f32,
}

Glass_Uniforms :: struct {
	rect:   [4]f32,
	res:    [2]f32,
	border: [4]f32,
	radius: f32,
	scale:  f32,
	milk:   f32,
	gloss:  f32,
}

Blur_Uniforms :: struct {
	step_uv: [2]f32,
}

bg_shader, glass_shader, blur_shader: ren.Shader
bg_tex, blur_a, blur_b, frost_a, frost_b: ren.Texture // the background at half size; quarter size, blurred (ping-pong); eighth size, blurred more (what the glass shows)
bg_size: [2]int // the window size they were drawn for ({0, 0}: not yet)
bg_r: ^ren.Renderer

shaders_init :: proc(r: ^ren.Renderer, lib: ^ren_assets.Library) {
	bg_r = r
	bg_shader, _ = ren.shader_create(r, {spirv = BG_SPV[:], uniform_size = size_of(Bg_Uniforms)})
	glass_shader, _ = ren.shader_create(r, {spirv = GLASS_SPV[:], uniform_size = size_of(Glass_Uniforms), sampler_count = 1})
	if ren_assets.add_builtin_shader(lib, r, "blur") {blur_shader, _ = ren_assets.shader_get(lib, "blur")}
	if bg_shader == 0 || glass_shader == 0 || blur_shader == 0 { // (all or none: the glass needs the blurred background)
		ren.shader_destroy(r, bg_shader)
		ren.shader_destroy(r, glass_shader)
		bg_shader, glass_shader = 0, 0
	}
}

shaders_destroy :: proc(r: ^ren.Renderer) {
	for t in ([]ren.Texture{bg_tex, blur_a, blur_b, frost_a, frost_b}) {ren.texture_destroy(r, t)}
	ren.shader_destroy(r, bg_shader)
	ren.shader_destroy(r, glass_shader)
}

// the textures for a window of this size, and the background drawn and blurred into them; false: they cannot be made
@(private = "file")
bg_prepare :: proc(g: ^Gui) -> bool {
	size := [2]int{max(g.screen.w, 1), max(g.screen.h, 1)}
	if size == bg_size {return true}
	r := bg_r
	for t in ([]ren.Texture{bg_tex, blur_a, blur_b, frost_a, frost_b}) {ren.texture_destroy(r, t)}
	half, quarter := [2]int{max(size.x / 2, 1), max(size.y / 2, 1)}, [2]int{max(size.x / 4, 1), max(size.y / 4, 1)}
	mk :: proc(r: ^ren.Renderer, s: [2]int) -> (ren.Texture, bool) {
		return ren.texture_create(r, {width = s.x, height = s.y, format = .RGBA8, filter = .Linear, wrap = .Clamp, use = {.Render_Target}})
	}
	eighth := [2]int{max(size.x / 8, 1), max(size.y / 8, 1)}
	ok1, ok2, ok3, ok4, ok5: bool
	bg_tex, ok1 = mk(r, half)
	blur_a, ok2 = mk(r, quarter)
	blur_b, ok3 = mk(r, quarter)
	frost_a, ok4 = mk(r, eighth)
	frost_b, ok5 = mk(r, eighth)
	if !ok1 || !ok2 || !ok3 || !ok4 || !ok5 { // (no render targets: the flat look from now on)
		for t in ([]ren.Texture{bg_tex, blur_a, blur_b, frost_a, frost_b}) {ren.texture_destroy(r, t)}
		bg_tex, blur_a, blur_b, frost_a, frost_b = 0, 0, 0, 0, 0
		bg_shader, glass_shader = 0, 0
		return false
	}
	bg_size = size

	dl := g.dl
	ren.push_blend(dl, .Opaque)
	defer ren.pop_blend(dl)
	u := Bg_Uniforms{res = {f32(half.x), f32(half.y)}, scale = g.s * 0.5}
	{
		ren.scope_target(dl, bg_tex, half)
		ren.draw_shader(dl, bg_shader, {0, 0, half.x, half.y}, nil, ([^]u8)(&u)[:size_of(u)])
	}
	{
		ren.scope_target(dl, blur_a, quarter)
		ren.draw_image(dl, bg_tex, {0, 0, quarter.x, quarter.y}, ren.FULL_UV, ren.WHITE, .Textured)
	}
	pass :: proc(dl: ^ren.Draw_List, q: [2]int, spread: f32, a, b: ren.Texture) {
		hu := Blur_Uniforms{{spread / f32(q.x), 0}}
		{
			ren.scope_target(dl, b, q)
			ren.draw_shader(dl, blur_shader, {0, 0, q.x, q.y}, []ren.Texture{a}, ([^]u8)(&hu)[:size_of(hu)])
		}
		vu := Blur_Uniforms{{0, spread / f32(q.y)}}
		{
			ren.scope_target(dl, a, q)
			ren.draw_shader(dl, blur_shader, {0, 0, q.x, q.y}, []ren.Texture{b}, ([^]u8)(&vu)[:size_of(vu)])
		}
	}
	pass(dl, quarter, 1.6, blur_a, blur_b)
	pass(dl, quarter, 2.6, blur_a, blur_b)
	// shrunk again and blurred more: a smooth frost with no trace of the ribbons' edges (more than NorseCode)
	{
		ren.scope_target(dl, frost_a, eighth)
		ren.draw_image(dl, blur_a, {0, 0, eighth.x, eighth.y}, ren.FULL_UV, ren.WHITE, .Textured)
	}
	pass(dl, eighth, 1.6, frost_a, frost_b)
	pass(dl, eighth, 2.6, frost_a, frost_b)
	pass(dl, eighth, 4.0, frost_a, frost_b)
	return true
}

// the window background (nothing where shaders do not run: begin_frame cleared to WIN_BG)
draw_background :: proc(g: ^Gui) {
	if bg_shader == 0 || !bg_prepare(g) {return}
	ren.push_blend(g.dl, .Opaque)
	ren.draw_image(g.dl, bg_tex, g.screen, ren.FULL_UV, ren.WHITE, .Textured)
	ren.pop_blend(g.dl)
}

// a panel (a card, the log, the folder list): nothing at all over the background (it shows through; no border); where
// shaders do not run, the flat card of before
panel :: proc(g: ^Gui, r: ui.Rect, radius: int, fallback := CARD) {
	if glass_shader == 0 || bg_size == {} {round_box(g, r, radius, fallback, CARD_BORDER)}
}

// the panes' border: a light blue line that reads on the background
GLASS_EDGE :: ren.Color{132, 168, 214, 230}

// a panel: a pane of frosted glass with its border (milk: its white tint, 0 .. 1; edge: its border line); `fallback`
// filled where shaders do not run
glass_box :: proc(g: ^Gui, r: ui.Rect, radius: int, milk: f32 = 0.15, fallback := CARD, edge := true) {
	if glass_shader == 0 || bg_size == {} {round_box(g, r, radius, fallback, edge ? CARD_BORDER : fallback); return}
	border := GLASS_EDGE
	if !edge {border.a = 0}
	u := Glass_Uniforms {
		rect   = {f32(r.x), f32(r.y), f32(r.w), f32(r.h)},
		res    = {f32(g.screen.w), f32(g.screen.h)},
		border = {f32(border.r) / 255, f32(border.g) / 255, f32(border.b) / 255, f32(border.a) / 255},
		radius = f32(radius),
		scale  = g.s,
		milk   = milk,
		gloss  = 1,
	}
	ren.draw_shader(g.dl, glass_shader, r, []ren.Texture{frost_a}, ([^]u8)(&u)[:size_of(u)])
}

// a line between rows or under a heading: only on the flat look (over the shader background, nothing)
separator :: proc(g: ^Gui, r: ui.Rect) {
	if glass_shader == 0 || bg_size == {} {ren.draw_rect(g.dl, r, CARD_BORDER)}
}
