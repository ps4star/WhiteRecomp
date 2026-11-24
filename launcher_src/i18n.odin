package launcher

// The launcher's languages (the Language drop-down, top right): only the launcher's own texts change, never the game.
// The English text is the key: tr(s) is s in the chosen language, or s itself where that language has no text for it, so
// a string nobody translated (a path, a number, a compiler's message) shows as it is. The widgets that draw text (label,
// wrap and so on: widgets.odin) call tr, so a literal passed to a button, a tooltip or a paragraph is translated without
// the call site knowing; a formatted text translates its format: fmt.tprintf(tr("%d of %d"), a, b).
// The texts are launcher/i18n/<code>.txt (iv_i18n's strings files: "@languages <code>", then each English text on a line
// and its translation under it, after a tab), embedded. The letters English's font lacks come from Noto Sans JP / TC / SC
// / KR (launcher/fonts, cut down by tools/font_subset to the characters the texts use), tried in the chosen language's
// order (the same character is drawn a little differently in Japanese and Chinese). The choice is kept in the data
// folder's language.txt (not in settings.txt: it has nothing to do with a Build).

import "core:os"
import "core:strings"
import i18n "shared:iv_i18n"
import "shared:iv_system/ren"
import ren_assets "shared:iv_system/ren/assets"
import ren_ttf "shared:iv_system/ren/ttf"
import ui "shared:iv_ui"

Lang :: struct {
	code: string,
	name: string, // in its own letters (the drop-down)
	cjk:  [4]int, // the order the CJK fonts are tried in (CJK_FONTS)
}

JP :: 0
TC :: 1
SC :: 2
KR :: 3
CJK_FONTS := [4][]u8 {
	#load("fonts/NotoSansJP-launcher.ttf"),
	#load("fonts/NotoSansTC-launcher.ttf"),
	#load("fonts/NotoSansSC-launcher.ttf"),
	#load("fonts/NotoSansKR-launcher.ttf"),
}

LANGS := [?]Lang {
	{"en", "English", {JP, TC, SC, KR}},
	{"ja", "日本語", {JP, TC, SC, KR}},
	{"zh-Hant", "繁體中文", {TC, SC, JP, KR}},
	{"zh-Hans", "简体中文", {SC, TC, JP, KR}},
	{"ko", "한국어", {KR, JP, TC, SC}},
	{"ru", "Русский", {JP, TC, SC, KR}},
	{"de", "Deutsch", {JP, TC, SC, KR}},
	{"fr", "Français", {JP, TC, SC, KR}},
	{"es", "Español", {JP, TC, SC, KR}},
	{"pt-BR", "Português (Brasil)", {JP, TC, SC, KR}},
	{"it", "Italiano", {JP, TC, SC, KR}},
	{"pl", "Polski", {JP, TC, SC, KR}},
}

TRANSLATIONS := [?]string {
	#load("i18n/ja.txt", string),
	#load("i18n/zh-Hant.txt", string),
	#load("i18n/zh-Hans.txt", string),
	#load("i18n/ko.txt", string),
	#load("i18n/ru.txt", string),
	#load("i18n/de.txt", string),
	#load("i18n/fr.txt", string),
	#load("i18n/es.txt", string),
	#load("i18n/pt-BR.txt", string),
	#load("i18n/it.txt", string),
	#load("i18n/pl.txt", string),
}

catalog: i18n.Catalog
lang_cur := 0 // in LANGS
lang_next := -1 // chosen this frame: the fonts are made again before the next frame is drawn

// the fonts the Gui's are made from (main)
Font_Source :: struct {
	lib:               ^ren_assets.Library,
	r:                 ^ren.Renderer,
	regular, semibold: string,
}
font_src: Font_Source

i18n_init :: proc() {
	i18n.init(&catalog, "en")
	for t in TRANSLATIONS {i18n.load_text_static(&catalog, t)}
	if d, err := os.read_entire_file(data_path("language.txt"), context.temp_allocator); err == nil {
		code := strings.trim_space(string(d))
		for l, i in LANGS {if l.code == code {lang_select(i)}}
	}
}

lang_select :: proc(i: int) {
	if i < 0 || i >= len(LANGS) {return}
	if i == 0 || i18n.set_language(&catalog, LANGS[i].code) {lang_cur = i}
	if i == 0 {i18n.set_language(&catalog, "en")}
}

// s in the chosen language (s itself where it has none)
tr :: proc(s: string) -> string {
	if lang_cur == 0 || s == "" {return s}
	return i18n.get(&catalog, s)
}

// the Gui's four fonts, with the CJK fallbacks in the chosen language's order (the old ones destroyed: call between frames)
fonts_make :: proc(g: ^Gui) {
	for f in ([]^ren.Font{g.font, g.small, g.bold, g.big}) {if f != nil {ren_ttf.destroy(f)}}
	mk :: proc(g: ^Gui, name: string, em: f32) -> ^ren.Font {
		f := ren_assets.font_make(font_src.lib, font_src.r, name, em * g.s)
		if f != nil {for k in LANGS[lang_cur].cjk {ren_ttf.add_fallback(f, CJK_FONTS[k])}}
		return f
	}
	g.font = mk(g, font_src.regular, 14)
	g.small = mk(g, font_src.regular, 12)
	g.bold = mk(g, font_src.semibold, 14)
	g.big = mk(g, font_src.semibold, 20)
}

// a language chosen in the drop-down: taken (and kept) before the next frame
lang_apply :: proc(g: ^Gui) {
	if lang_next < 0 {return}
	i := lang_next
	lang_next = -1
	if i == lang_cur {return}
	lang_select(i)
	fonts_make(g)
	_ = os.write_entire_file(data_path("language.txt"), transmute([]u8)LANGS[lang_cur].code)
}

// the drop-down at the right of the tab strip
lang_dropdown :: proc(g: ^Gui, r: ui.Rect) {
	names: [len(LANGS)]string
	for l, i in LANGS {names[i] = l.name}
	if i, changed := dropdown(g, "language", r, names[:], lang_cur, raw = true); changed {lang_next = i} // (raw: each name as written, in every language)
}
