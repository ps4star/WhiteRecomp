// The launcher's look and controls: Windows 11's (Fluent, light) -- a light window, white cards, 4 px rounded
// buttons with a blue accent one, a tab strip, drop-down lists, on/off switches, tooltips at the mouse and links.
// Immediate mode: each control is drawn and answers for this frame. The list of an open drop-down, and a tooltip, are
// drawn last (gui_end), above everything; while a list is open it takes the clicks (gui_begin).
package launcher

import "core:math"
import "core:strings"
import "core:time"
import "shared:iv_system/platform"
import "shared:iv_system/ren"
import ui "shared:iv_ui"

// ---------------------------------------------------------------------------------------------- colors
WIN_BG :: ren.Color{243, 243, 243, 255}
CARD :: ren.Color{251, 251, 251, 255}
CARD_BORDER :: ren.Color{229, 229, 229, 255}
TEXT :: ren.Color{27, 27, 27, 255}
DIM :: ren.Color{96, 96, 96, 255}
FAINT :: ren.Color{160, 160, 160, 255}
BTN :: ren.Color{253, 253, 253, 255}
BTN_HOT :: ren.Color{246, 246, 246, 255}
BTN_DOWN :: ren.Color{240, 240, 240, 255}
BTN_BORDER :: ren.Color{213, 213, 213, 255}
BTN_BORDER_BOTTOM :: ren.Color{186, 186, 186, 255}
DIS_FILL :: ren.Color{245, 245, 245, 255}
DIS_BORDER :: ren.Color{229, 229, 229, 255}
ACCENT :: ren.Color{0, 95, 184, 255}
ACCENT_HOT :: ren.Color{25, 110, 191, 255}
ACCENT_DOWN :: ren.Color{49, 125, 197, 255}
ACCENT_BORDER :: ren.Color{0, 80, 160, 255}
ACCENT_OFF :: ren.Color{199, 199, 199, 255}
GOOD :: ren.Color{15, 123, 15, 255}
// the Run button's green
GREEN :: ren.Color{16, 124, 16, 255}
GREEN_HOT :: ren.Color{36, 138, 36, 255}
GREEN_DOWN :: ren.Color{56, 150, 56, 255}
GREEN_BORDER :: ren.Color{10, 100, 10, 255}
BAD :: ren.Color{196, 43, 28, 255}
WARN :: ren.Color{157, 93, 0, 255}
LOG_BG :: ren.Color{255, 255, 255, 255}

// ---------------------------------------------------------------------------------------------- the frame's state
Gui :: struct {
	dl:                   ^ren.Draw_List,
	win:                  ^platform.Window,
	font, small, bold, big: ^ren.Font,
	mouse:                [2]int,
	clicked:              bool, // pressed this frame
	down:                 bool, // held
	modal:                bool, // a dialog is open: only its controls work
	in_modal:             bool, // drawing the dialog
	s:                    f32, // dpi scale
	screen:               ui.Rect,
	cursor:               platform.Cursor_Shape,
	// the open drop-down list
	dd_open:              string, // its id ("": none)
	dd_anchor:            ui.Rect,
	dd_items:             [dynamic]string,
	dd_enabled:           [dynamic]bool,
	dd_sel:               int,
	dd_result_id:         string, // a choice made in the list, for that drop-down on the next frame
	dd_result:            int,
	// the tooltip: the zone the mouse is over, since when, and what to show
	tip_id:               string,
	tip_since:            time.Time,
	tip_text:             string,
	tip_seen:             bool, // a zone was hovered this frame
	// the slider being dragged (its id; "": none)
	drag_id:              string,
}

px :: proc(g: ^Gui, v: int) -> int {return int(f32(v) * g.s)}

inside :: proc(r: ui.Rect, p: [2]int) -> bool {return p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h}

// can the controls being drawn take the mouse? (not under a dialog or an open list)
live :: proc(g: ^Gui) -> bool {return (!g.modal || g.in_modal) && g.dd_open == ""}

gui_begin :: proc(g: ^Gui) {
	g.cursor = .Default
	g.tip_seen = false
	if g.dd_open == "" || !g.clicked {return}
	// a click while a list is open: a choice, or it closes; either way nothing under it sees the click
	box, item_h := dd_box(g)
	for _, i in g.dd_items {
		if inside(dd_item_rect(g, box, item_h, i), g.mouse) && g.dd_enabled[i] {
			g.dd_result_id = g.dd_open
			g.dd_result = i
		}
	}
	if inside(box, g.mouse) && g.dd_result_id == "" {return} // (a disabled item or the padding: stays open)
	g.dd_open = ""
	g.clicked = false
}

gui_end :: proc(g: ^Gui) {
	if g.dd_open != "" {draw_dd_list(g)}
	if !g.tip_seen {g.tip_id = ""}
	if g.tip_id != "" && g.tip_text != "" && time.duration_milliseconds(time.since(g.tip_since)) > 450 {draw_tooltip(g)}
	if g.win != nil && g.win.cursor_shape != g.cursor {platform.set_cursor_shape(g.win, g.cursor)}
}

// ---------------------------------------------------------------------------------------------- shapes
// A rounded rectangle, anti-aliased at its corners: row by row, the corner rows' spans with their edge pixels
// partly covered.
fill_round :: proc(g: ^Gui, r: ui.Rect, radius: int, c: ren.Color) {
	if r.w <= 0 || r.h <= 0 {return}
	rad := min(radius, r.w / 2, r.h / 2)
	if rad <= 0 {ren.draw_rect(g.dl, r, c); return}
	ren.draw_rect(g.dl, {r.x, r.y + rad, r.w, r.h - 2 * rad}, c)
	fr := f32(rad)
	for i in 0 ..< rad {
		dy := fr - (f32(i) + 0.5) // from the corner circle's center to the row's middle
		dx := fr - math.sqrt(max(0, fr * fr - dy * dy)) // the corner's inset on this row
		solid := int(math.ceil(dx))
		cov := f32(solid) - dx // how much of the edge pixel is inside
		for y in ([2]int{r.y + i, r.y + r.h - 1 - i}) {
			ren.draw_rect(g.dl, {r.x + solid, y, r.w - 2 * solid, 1}, c)
			if solid > 0 && cov > 0.02 {
				ec := c
				ec.a = u8(f32(c.a) * cov)
				ren.draw_rect(g.dl, {r.x + solid - 1, y, 1, 1}, ec)
				ren.draw_rect(g.dl, {r.x + r.w - solid, y, 1, 1}, ec)
			}
		}
	}
}

// filled, with a 1 px border
round_box :: proc(g: ^Gui, r: ui.Rect, radius: int, fill, border: ren.Color) {
	fill_round(g, r, radius, border)
	fill_round(g, ui.inset(r, 1), max(0, radius - 1), fill)
}

circle :: proc(g: ^Gui, cx, cy, d: int, c: ren.Color) {fill_round(g, {cx - d / 2, cy - d / 2, d, d}, d / 2, c)}

card :: proc(g: ^Gui, r: ui.Rect) {round_box(g, r, px(g, 7), CARD, CARD_BORDER)}

// a small downward chevron centered at (cx, cy)
chevron :: proc(g: ^Gui, cx, cy: int, c: ren.Color) {
	n := px(g, 4)
	t := max(1, px(g, 1)) + 1
	for i in 0 ..= n {
		y := cy - n / 2 + i
		ren.draw_rect(g.dl, {cx - n + i - t / 2, y, t, 1}, c)
		ren.draw_rect(g.dl, {cx + n - i - t / 2, y, t, 1}, c)
	}
}

// ---------------------------------------------------------------------------------------------- text
text_w :: proc(f: ^ren.Font, s: string) -> int {
	w, _ := ren.font_measure(f, s)
	return w
}

// s cut down to fit w pixels, with an ellipsis
fit :: proc(f: ^ren.Font, s: string, w: int) -> string {
	if text_w(f, s) <= w {return s}
	lo, hi := 0, len(s)
	for lo < hi {
		mid := (lo + hi + 1) / 2
		if text_w(f, strings.concatenate({s[:mid], "…"}, context.temp_allocator)) <= w {lo = mid} else {hi = mid - 1}
	}
	for lo > 0 && (s[lo] & 0xc0) == 0x80 {lo -= 1}
	return strings.concatenate({s[:lo], "…"}, context.temp_allocator)
}

label :: proc(g: ^Gui, f: ^ren.Font, s: string, r: ui.Rect, c: ren.Color, center := false) {
	t := fit(f, s, r.w)
	w := text_w(f, t)
	x := r.x + (center ? (r.w - w) / 2 : 0)
	ren.draw_text(g.dl, f, t, {x, r.y + (r.h - f.line_height) / 2}, c)
}

// the lines of s that fit w pixels (words kept whole; "\n" breaks)
wrap :: proc(f: ^ren.Font, s: string, w: int) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for para in strings.split(s, "\n", context.temp_allocator) {
		line := ""
		for word in strings.fields(para, context.temp_allocator) {
			try := line == "" ? word : strings.concatenate({line, " ", word}, context.temp_allocator)
			if line != "" && text_w(f, try) > w {
				append(&out, line)
				line = word
			} else {
				line = try
			}
		}
		append(&out, line)
	}
	return out[:]
}

// wrapped text from (r.x, r.y); returns the height used
paragraph :: proc(g: ^Gui, f: ^ren.Font, s: string, r: ui.Rect, c: ren.Color, gap := 0) -> int {
	y := r.y
	for l in wrap(f, s, r.w) {
		ren.draw_text(g.dl, f, l, {r.x, y}, c)
		y += f.line_height + gap
	}
	return y - r.y
}

// ---------------------------------------------------------------------------------------------- controls
button :: proc(g: ^Gui, r: ui.Rect, text: string, enabled := true, primary := false, f: ^ren.Font = nil, green := false) -> bool {
	f := f if f != nil else g.font
	ok := enabled && live(g)
	hot := ok && inside(r, g.mouse)
	rad := px(g, 4)
	tc := TEXT
	if !enabled {
		if primary || green {fill_round(g, r, rad, ACCENT_OFF); tc = WIN_BG} else {round_box(g, r, rad, DIS_FILL, DIS_BORDER); tc = FAINT}
	} else if green {
		round_box(g, r, rad, hot ? (g.down ? GREEN_DOWN : GREEN_HOT) : GREEN, GREEN_BORDER)
		tc = ren.WHITE
	} else if primary {
		round_box(g, r, rad, hot ? (g.down ? ACCENT_DOWN : ACCENT_HOT) : ACCENT, ACCENT_BORDER)
		tc = ren.WHITE
	} else {
		round_box(g, r, rad, hot ? (g.down ? BTN_DOWN : BTN_HOT) : BTN, BTN_BORDER)
		ren.draw_rect(g.dl, {r.x + rad, r.y + r.h - 1, r.w - 2 * rad, 1}, BTN_BORDER_BOTTOM)
		if hot && g.down {tc = DIM}
	}
	label(g, f, text, ui.inset_xy(r, px(g, 10), 0), tc, center = true)
	return hot && g.clicked
}

// A tab strip; returns the selected tab.
tabs :: proc(g: ^Gui, r: ui.Rect, names: []string, sel: int) -> int {
	out := sel
	x := r.x
	for name, i in names {
		w := text_w(g.bold, name) + px(g, 28)
		tr := ui.Rect{x, r.y, w, r.h - px(g, 4)}
		hot := live(g) && inside(tr, g.mouse)
		if hot && i != sel {fill_round(g, ui.inset_xy(tr, 0, px(g, 3)), px(g, 4), ren.Color{0, 0, 0, 10})}
		label(g, i == sel ? g.bold : g.font, name, tr, i == sel || hot ? TEXT : DIM, center = true)
		if i == sel {
			uw := px(g, 22)
			fill_round(g, {tr.x + (tr.w - uw) / 2, r.y + r.h - px(g, 6), uw, px(g, 3)}, px(g, 2), ACCENT)
		}
		if hot && g.clicked {out = i}
		x += w + px(g, 4)
	}
	ren.draw_rect(g.dl, {r.x - px(g, 24), r.y + r.h - 1, g.screen.w, 1}, CARD_BORDER)
	return out
}

// A drop-down list (id: unique per control, a string literal). enabled: per item (nil: all). Returns the selection
// and whether it changed this frame.
dropdown :: proc(g: ^Gui, id: string, r: ui.Rect, items: []string, sel: int, enabled: []bool = nil, active := true) -> (int, bool) {
	res, changed := sel, false
	if g.dd_result_id == id {
		res = g.dd_result
		changed = res != sel
		g.dd_result_id = ""
	}
	ok := active && live(g)
	hot := ok && inside(r, g.mouse)
	open := g.dd_open == id
	rad := px(g, 4)
	if !active {
		round_box(g, r, rad, DIS_FILL, DIS_BORDER)
	} else {
		round_box(g, r, rad, open ? BTN_DOWN : hot ? BTN_HOT : BTN, BTN_BORDER)
		ren.draw_rect(g.dl, {r.x + rad, r.y + r.h - 1, r.w - 2 * rad, 1}, BTN_BORDER_BOTTOM)
	}
	text := res >= 0 && res < len(items) ? items[res] : ""
	label(g, g.font, text, {r.x + px(g, 11), r.y, r.w - px(g, 40), r.h}, active ? TEXT : FAINT)
	chevron(g, r.x + r.w - px(g, 18), r.y + r.h / 2, active ? DIM : FAINT)
	if hot && g.clicked {
		for s in g.dd_items {delete(s)}
		clear(&g.dd_items)
		clear(&g.dd_enabled)
		for s, i in items {
			append(&g.dd_items, strings.clone(s))
			append(&g.dd_enabled, enabled == nil || (i < len(enabled) && enabled[i]))
		}
		g.dd_open = id
		g.dd_anchor = r
		g.dd_sel = res
		g.clicked = false
	}
	return res, changed
}

@(private = "file")
dd_box :: proc(g: ^Gui) -> (box: ui.Rect, item_h: int) {
	item_h = px(g, 32)
	pad := px(g, 4)
	h := len(g.dd_items) * item_h + 2 * pad
	return ui.popup(g.dd_anchor, g.dd_anchor.w, h, ui.inset(g.screen, px(g, 4)), .Bottom, px(g, 2)), item_h
}
@(private = "file")
dd_item_rect :: proc(g: ^Gui, box: ui.Rect, item_h, i: int) -> ui.Rect {
	pad := px(g, 4)
	return {box.x + pad, box.y + pad + i * item_h, box.w - 2 * pad, item_h}
}
@(private = "file")
draw_dd_list :: proc(g: ^Gui) {
	box, item_h := dd_box(g)
	for k in 1 ..= 4 {fill_round(g, ui.translate(ui.outset(box, k), 0, k), px(g, 8) + k, ren.Color{0, 0, 0, 7})} // (the shadow)
	round_box(g, box, px(g, 7), ren.Color{249, 249, 249, 255}, ren.Color{206, 206, 206, 255})
	for s, i in g.dd_items {
		ir := dd_item_rect(g, box, item_h, i)
		ok := g.dd_enabled[i]
		hot := ok && inside(ir, g.mouse)
		if hot || i == g.dd_sel {fill_round(g, ui.inset_xy(ir, 0, px(g, 2)), px(g, 4), hot ? ren.Color{0, 0, 0, 14} : ren.Color{0, 0, 0, 8})}
		if i == g.dd_sel {fill_round(g, {ir.x, ir.y + ir.h / 2 - px(g, 8), px(g, 3), px(g, 16)}, px(g, 2), ACCENT)}
		label(g, g.font, s, {ir.x + px(g, 12), ir.y, ir.w - px(g, 16), ir.h}, ok ? TEXT : FAINT)
		if hot {g.cursor = .Default}
	}
}

// An on / off switch with its "On" / "Off"; returns the state and whether it changed.
toggle :: proc(g: ^Gui, r: ui.Rect, on: bool, active := true) -> (bool, bool) {
	tw, th := px(g, 40), px(g, 20)
	track := ui.Rect{r.x, r.y + (r.h - th) / 2, tw, th}
	zone := ui.Rect{r.x, r.y, tw + px(g, 12) + text_w(g.font, "Off"), r.h}
	ok := active && live(g)
	hot := ok && inside(zone, g.mouse)
	kd := hot ? px(g, 14) : px(g, 12) // (the knob grows under the mouse)
	if on {
		fill_round(g, track, th / 2, !active ? ACCENT_OFF : hot ? ACCENT_HOT : ACCENT)
		circle(g, track.x + tw - th / 2, track.y + th / 2, kd, ren.WHITE)
	} else {
		round_box(g, track, th / 2, !active ? DIS_FILL : hot ? BTN_HOT : BTN, !active ? DIS_BORDER : ren.Color{134, 134, 134, 255})
		circle(g, track.x + th / 2, track.y + th / 2, kd, !active ? FAINT : ren.Color{93, 93, 93, 255})
	}
	label(g, g.font, on ? "On" : "Off", {track.x + tw + px(g, 12), r.y, zone.w - tw - px(g, 12), r.h}, active ? TEXT : FAINT)
	if hot && g.clicked {return !on, true}
	return on, false
}

// A slider from lo to hi: click or drag along it. Returns the value, whether it moved, and whether a drag (or a click)
// just ended -- the moment to save.
slider :: proc(g: ^Gui, id: string, r: ui.Rect, v, lo, hi: int, active := true) -> (int, bool, bool) {
	th := px(g, 4)
	kd := px(g, 16)
	track := ui.Rect{r.x + kd / 2, r.y + (r.h - th) / 2, r.w - kd, th}
	ok := active && live(g)
	hot := ok && inside(r, g.mouse)
	if hot && g.clicked {g.drag_id = id}
	nv, done := v, false
	if g.drag_id == id {
		if ok && g.down {
			t := clamp(f32(g.mouse.x - track.x) / f32(max(track.w, 1)), 0, 1)
			nv = lo + int(t * f32(hi - lo) + 0.5)
		} else {g.drag_id = ""; done = true}
	}
	f := clamp(f32(nv - lo) / f32(max(hi - lo, 1)), 0, 1)
	kx := track.x + int(f * f32(track.w))
	round_box(g, track, th / 2, !active ? DIS_FILL : BTN_HOT, !active ? DIS_BORDER : BTN_BORDER)
	if active && kx - track.x >= th {fill_round(g, {track.x, track.y, kx - track.x, th}, th / 2, hot || g.drag_id == id ? ACCENT_HOT : ACCENT)}
	circle(g, kx, track.y + th / 2, hot || g.drag_id == id ? kd + px(g, 2) : kd, !active ? FAINT : ACCENT)
	circle(g, kx, track.y + th / 2, kd / 2, ren.WHITE)
	return nv, nv != v, done
}

// A zone that shows text in a tooltip at the mouse when it rests there.
tooltip_zone :: proc(g: ^Gui, id: string, r: ui.Rect, text: string) {
	if !live(g) || !inside(r, g.mouse) {return}
	g.tip_seen = true
	if g.tip_id != id {
		g.tip_id = id
		g.tip_since = time.now()
	}
	g.tip_text = text
}
@(private = "file")
draw_tooltip :: proc(g: ^Gui) {
	maxw := px(g, 380)
	lines := wrap(g.small, g.tip_text, maxw)
	w := 0
	for l in lines {w = max(w, text_w(g.small, l))}
	pad := px(g, 9)
	lh := g.small.line_height + px(g, 2)
	box := ui.Rect{g.mouse.x + px(g, 14), g.mouse.y + px(g, 20), w + 2 * pad, len(lines) * lh + 2 * pad - px(g, 2)}
	box = ui.keep_inside(box, ui.inset(g.screen, px(g, 4)))
	for k in 1 ..= 3 {fill_round(g, ui.translate(ui.outset(box, k), 0, k), px(g, 6) + k, ren.Color{0, 0, 0, 7})}
	round_box(g, box, px(g, 5), ren.Color{249, 249, 249, 255}, ren.Color{204, 204, 204, 255})
	for l, i in lines {ren.draw_text(g.dl, g.small, l, {box.x + pad, box.y + pad + i * lh}, TEXT)}
}

// A link: accent text, underlined under the mouse; opens url when clicked. Returns its width.
link :: proc(g: ^Gui, x, y: int, text, url: string, f: ^ren.Font = nil) -> int {
	f := f if f != nil else g.font
	w := text_w(f, text)
	r := ui.Rect{x, y, w, f.line_height}
	hot := live(g) && inside(r, g.mouse)
	ren.draw_text(g.dl, f, text, {x, y}, hot ? ACCENT_HOT : ACCENT)
	if hot {
		ren.draw_rect(g.dl, {x, y + f.ascent + px(g, 2), w, max(1, px(g, 1))}, ACCENT_HOT)
		g.cursor = .Hand
		if g.clicked {open_url(url)}
	}
	return w
}

// a thin progress bar (t < 0: a moving block)
progress_bar :: proc(g: ^Gui, r: ui.Rect, t: f32, moving: bool) {
	fill_round(g, {r.x, r.y + r.h / 2 - max(1, px(g, 1)) / 2, r.w, max(1, px(g, 1))}, 0, ren.Color{138, 138, 138, 255})
	if t >= 0 {
		fill_round(g, {r.x, r.y, max(r.h, int(f32(r.w) * min(t, 1))), r.h}, r.h / 2, ACCENT)
	} else if moving {
		w := r.w / 4
		x := int(time.duration_seconds(time.since({})) * 320) % (r.w + w) - w
		x0, x1 := max(r.x, r.x + x), min(r.x + r.w, r.x + x + w)
		if x1 > x0 {fill_round(g, {x0, r.y, x1 - x0, r.h}, r.h / 2, ACCENT)}
	}
}

// a status dot
dot :: proc(g: ^Gui, x, y: int, c: ren.Color) {circle(g, x, y, px(g, 10), c)}
