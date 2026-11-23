// macOS: the built game as an app of its own, ~/Applications/FINAL FANTASY XIII (WhiteRecomp).app -- the XIII icon in
// Launchpad, Spotlight and the Dock, and the game started from it without the launcher's Run. Made (again) by each
// Build on a Mac. Its program is a small script that starts the built game in its folder (data_path("game"), where
// Run starts it), with its .cfg there as always; when there is no built game (Clear Cache, or not built yet) it opens
// the launcher instead, or says so. Made on this Mac, so it is not quarantined: Gatekeeper lets it run unsigned.
// The icon (Contents/Resources/WhiteRecomp.icns): the PNGs of launcher/macos_icon.png (res/whiterecomp_icon.png, 1024 px, ic10) and the
// AppImage's (256 px, ic08), in an .icns file written here (its entries may be PNG data since macOS 10.7).
package launcher

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

MAC_APP_NAME :: "FINAL FANTASY XIII (WhiteRecomp).app"

@(private = "file")
ICON_1024 :: #load("macos_icon.png")
@(private = "file")
ICON_256 :: #load("appimage_icon.png")

mac_app_path :: proc() -> string {
	return pjoin({os.get_env("HOME", context.temp_allocator), "Applications", MAC_APP_NAME}, context.temp_allocator)
}

// a path inside '...' for sh
@(private = "file")
sh_quote :: proc(s: string) -> string {
	q, _ := strings.replace_all(s, "'", "'\\''", context.temp_allocator)
	return fmt.tprintf("'%s'", q)
}
@(private = "file")
xml_escape :: proc(s: string) -> string {
	a, _ := strings.replace_all(s, "&", "&amp;", context.temp_allocator)
	b, _ := strings.replace_all(a, "<", "&lt;", context.temp_allocator)
	return b
}

@(private = "file")
icns :: proc() -> []u8 {
	b := make([dynamic]u8, context.temp_allocator)
	be32 :: proc(b: ^[dynamic]u8, v: int) {append(b, u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))}
	total := 8 + 8 + len(ICON_256) + 8 + len(ICON_1024)
	append(&b, "icns")
	be32(&b, total)
	append(&b, "ic08")
	be32(&b, 8 + len(ICON_256))
	append(&b, ..ICON_256)
	append(&b, "ic10")
	be32(&b, 8 + len(ICON_1024))
	append(&b, ..ICON_1024)
	return b[:]
}

// the app made (or brought up to date) for the game built at exe (in dir); false (and why, in the log) if it could not be
mac_app_install :: proc(t: ^Task, exe, dir: string) -> bool {
	when ODIN_OS != .Darwin {return false} else {
		app := mac_app_path()
		contents := pjoin({app, "Contents"}, context.temp_allocator)
		macos := pjoin({contents, "MacOS"}, context.temp_allocator)
		res := pjoin({contents, "Resources"}, context.temp_allocator)
		if os.make_directory_all(macos) != nil || os.make_directory_all(res) != nil {
			logf(t, "Could not make %s: start the game with Run.", app)
			return false
		}
		// the launcher's own .app (Contents/Frameworks -> the .app), for "no game built yet"
		launcher_app := ""
		if fw := app_frameworks_dir(); fw != "" {launcher_app = filepath.dir(filepath.dir(fw))}
		script := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&script, "#!/bin/sh\n# made by WhiteRecomp's launcher (each Build): starts the built game\n")
		fmt.sbprintf(&script, "GAME=%s\nDIR=%s\n", sh_quote(exe), sh_quote(dir))
		fmt.sbprintf(&script, "if [ -x \"$GAME\" ]; then cd \"$DIR\" && exec \"$GAME\"; fi\n")
		if launcher_app != "" {fmt.sbprintf(&script, "[ -d %s ] && exec /usr/bin/open %s\n", sh_quote(launcher_app), sh_quote(launcher_app))}
		fmt.sbprintf(&script, "/usr/bin/osascript -e 'display alert \"FINAL FANTASY XIII is not built\" message \"Open the WhiteRecomp launcher and press Build.\"'\nexit 1\n")
		prog := pjoin({macos, "WhiteRecomp"}, context.temp_allocator)
		plist := fmt.tprintf(`<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleName</key>
	<string>FINAL FANTASY XIII</string>
	<key>CFBundleDisplayName</key>
	<string>FINAL FANTASY XIII (WhiteRecomp)</string>
	<key>CFBundleIdentifier</key>
	<string>io.github.ff13port.game</string>
	<key>CFBundleExecutable</key>
	<string>WhiteRecomp</string>
	<key>CFBundleIconFile</key>
	<string>WhiteRecomp</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>1.0</string>
	<key>CFBundleVersion</key>
	<string>1</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.role-playing-games</string>
	<key>WhiteRecompGame</key>
	<string>%s</string>
</dict>
</plist>
`, xml_escape(exe))
		ok := os.write_entire_file(prog, transmute([]u8)strings.to_string(script)) == nil
		ok = ok && os.chmod(prog, {.Read_User, .Write_User, .Execute_User, .Read_Group, .Execute_Group, .Read_Other, .Execute_Other}) == nil
		ok = ok && os.write_entire_file(pjoin({contents, "Info.plist"}, context.temp_allocator), transmute([]u8)plist) == nil
		ok = ok && os.write_entire_file(pjoin({res, "WhiteRecomp.icns"}, context.temp_allocator), icns()) == nil
		if !ok {
			logf(t, "Could not write %s: start the game with Run.", app)
			return false
		}
		// (Finder and the Dock read the icon again: the app's date changed, and LaunchServices told)
		_, _ = run(t, {"/usr/bin/touch", app}, mode = .Quiet)
		lsr := "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
		if file_exists(lsr) {_, _ = run(t, {lsr, "-f", app}, mode = .Quiet)}
		logf(t, "The game is in Applications too (%s): start it from there, Launchpad or Spotlight, without the launcher.", app)
		return true
	}
}
