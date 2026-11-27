#!/bin/sh
# launcher/release.sh   -> dist/ff13-launcher-<platform>-<arch>.(zip | tar.gz)
# Makes the release of the launcher for the system it runs on:
#   WSL (Windows)  build/WhiteRecompLauncher_windows.exe (launcher/build.sh: packs launcher/bundle.bin with build/bundle.exe first)
#                  -> dist/ff13-launcher-windows-x64.zip
#   Linux          odin build (needs launcher/bundle.bin, made on Windows, and Odin's stb libraries built:
#                  vendor/stb/src/build_stb.sh) -> dist/ff13-launcher-linux-x64.tar.gz
#   macOS          odin build for arm64 and amd64, joined with lipo; "WhiteRecomp.app" with Info.plist, MoltenVK (the
#                  launcher draws with Vulkan, and so does the game it builds) and SDL2 (the game's window, controllers
#                  and sound) in Contents/Frameworks; signed with the hardened runtime, notarized and stapled
#                  -> dist/ff13-launcher-macos.zip. Its bundle: launcher/build.sh macos (on Windows/WSL) makes
#                  build/bundle_macos.bin; BUNDLE=that file (default launcher/bundle.bin).
# Every release holds the launcher (its packed bundle: the translated C sources, the runtime's C sources and the
# Windows movie converter), README.md and THIRD_PARTY_LICENSES.txt (launcher/release/).
# Env: ODIN (the compiler). macOS: BUNDLE, MOLTENVK (path of libMoltenVK.dylib; default from $VULKAN_SDK),
# MOLTENVK_LICENSE (its LICENSE file), SDL2 (libSDL2-2.0.0.dylib; default Homebrew's -- for Intel Macs too it must hold
# both architectures, e.g. lipo of an arm64 and an x86_64 build), SDL2_LICENSE (its LICENSE.txt), MACOS_SIGN_ID ("Developer ID Application: ..."; unset: not signed), NOTARY_PROFILE (a
# `xcrun notarytool store-credentials` profile; unset: not notarized).
set -eu
cd "$(dirname "$0")/.."
ROOT=$PWD
REL=launcher/release
mkdir -p dist

case "$(uname -s)" in
Linux)
	if grep -qi microsoft /proc/version 2>/dev/null && [ -z "${RELEASE_NATIVE_LINUX:-}" ]; then
		# WSL: the Windows release (RELEASE_NATIVE_LINUX=1 makes the Linux one here instead)
		sh launcher/build.sh
		D=dist/ff13-launcher-windows-x64
		rm -rf "$D" "$D.zip"
		mkdir -p "$D"
		cp build/WhiteRecompLauncher_windows.exe "$D/"
		cp $REL/README.md $REL/THIRD_PARTY_LICENSES.txt "$D/"
		sed -i 's/$/\r/' "$D/THIRD_PARTY_LICENSES.txt"
		WD=$(wslpath -w "$ROOT/dist")
		powershell.exe -NoProfile -Command "Compress-Archive -Force -Path '$WD\\ff13-launcher-windows-x64\\*' -DestinationPath '$WD\\ff13-launcher-windows-x64.zip'"
		ls -la "$D.zip"
		exit 0
	fi
	ODIN=${ODIN:-odin}
	[ -f launcher/bundle.bin ] || { echo "launcher/bundle.bin is missing: make it on Windows (launcher/build.sh)"; exit 1; }
	D=dist/ff13-launcher-linux-x64
	rm -rf "$D"
	mkdir -p "$D"
	"$ODIN" build launcher -collection:shared=shared -o:speed -out:"$D/ff13-launcher"
	cp $REL/README.md $REL/THIRD_PARTY_LICENSES.txt "$D/"
	tar -C dist -czf "$D.tar.gz" ff13-launcher-linux-x64
	ls -la "$D.tar.gz"
	;;
Darwin)
	ODIN=${ODIN:-odin}
	if [ -n "${BUNDLE:-}" ]; then cp "$BUNDLE" launcher/bundle.bin; fi
	[ -f launcher/bundle.bin ] || { echo "launcher/bundle.bin is missing: make it on Windows (launcher/build.sh macos) and pass BUNDLE="; exit 1; }
	MVK=${MOLTENVK:-${VULKAN_SDK:-/usr/local}/lib/libMoltenVK.dylib}
	[ -f "$MVK" ] || { echo "MoltenVK not found ($MVK): install the Vulkan SDK or set MOLTENVK"; exit 1; }
	MVK_LICENSE=${MOLTENVK_LICENSE:-${VULKAN_SDK:-/usr/local}/share/doc/MoltenVK/LICENSE}
	[ -f "$MVK_LICENSE" ] || { echo "MoltenVK's LICENSE not found ($MVK_LICENSE): set MOLTENVK_LICENSE"; exit 1; }
	BREW_SDL=$(brew --prefix sdl2 2>/dev/null || true)
	SDL=${SDL2:-$BREW_SDL/lib/libSDL2-2.0.0.dylib}
	[ -f "$SDL" ] || { echo "SDL2 not found ($SDL): brew install sdl2, or set SDL2"; exit 1; }
	SDL_LICENSE=${SDL2_LICENSE:-$BREW_SDL/share/doc/sdl2/LICENSE.txt}
	[ -f "$SDL_LICENSE" ] || SDL_LICENSE=$(ls "$BREW_SDL"/LICENSE* 2>/dev/null | head -1)
	[ -f "$SDL_LICENSE" ] || { echo "SDL2's LICENSE.txt not found: set SDL2_LICENSE"; exit 1; }
	# (the game a Mac builds is its own kind: an Intel Mac's needs the x86_64 half of each library)
	for L in "$MVK" "$SDL"; do
		case " $(lipo -archs "$L") " in *" x86_64 "*" arm64 "* | *" arm64 "*" x86_64 "*) ;;
		*) echo "warning: $L is only $(lipo -archs "$L"): the game will not find it on the other kind of Mac" ;; esac
	done
	APP="dist/WhiteRecomp.app"
	rm -rf "$APP" dist/ff13-launcher-macos.zip
	mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
	# one program for both kinds of Mac (each builds its own kind of game: ARM64 on Apple silicon, x86-64 on Intel)
	"$ODIN" build launcher -collection:shared=shared -o:speed -target:darwin_arm64 -out:dist/ff13-launcher-arm64
	"$ODIN" build launcher -collection:shared=shared -o:speed -target:darwin_amd64 -out:dist/ff13-launcher-amd64
	lipo -create -output "$APP/Contents/MacOS/ff13-launcher" dist/ff13-launcher-arm64 dist/ff13-launcher-amd64
	rm -f dist/ff13-launcher-arm64 dist/ff13-launcher-amd64
	cp "$MVK" "$APP/Contents/Frameworks/libMoltenVK.dylib"
	cp "$SDL" "$APP/Contents/Frameworks/libSDL2-2.0.0.dylib"
	cp $REL/Info.plist "$APP/Contents/Info.plist"
	cp $REL/README.md "$APP/Contents/Resources/"
	# Wine (WINE: the wine folder of Gcenx's "Wine Stable.app" -- its Contents/Resources/wine -- and WINE_LICENSE, its
	# LGPL text): Convert Movies and the HD Textures import run Windows programs through it, and players cannot be asked
	# to install Homebrew (deps.odin app_wine). Its Mach-O files are signed one by one (ad hoc without MACOS_SIGN_ID):
	# code inside an app has to be signed.
	if [ -n "${WINE:-}" ]; then
		[ -x "$WINE/bin/wine" ] || { echo "WINE=$WINE has no bin/wine"; exit 1; }
		[ -f "${WINE_LICENSE:-}" ] || { echo "WINE_LICENSE (Wine's COPYING.LIB) not set"; exit 1; }
		ditto "$WINE" "$APP/Contents/Resources/wine"
		find "$APP/Contents/Resources/wine" -type f \( -perm -u+x -o -name '*.dylib' -o -name '*.so' \) | while IFS= read -r f; do
			case "$(file -b "$f")" in *Mach-O*) codesign --force --sign "${MACOS_SIGN_ID:--}" "$f" ;; esac
		done
	else
		echo "WINE not set: the app carries no Wine (Convert Movies and the HD import then need one installed)"
	fi
	{ cat $REL/THIRD_PARTY_LICENSES.txt
	  if [ -n "${WINE:-}" ]; then
	    printf '\n\n--------------------------------------------------------------------------------------------------------------------\n'
	    printf '12. Wine (https://www.winehq.org; this build: https://github.com/Gcenx/macOS_Wine_builds; source: https://gitlab.winehq.org/wine/wine)\n'
	    printf -- '--------------------------------------------------------------------------------------------------------------------\n\n'
	    cat "$WINE_LICENSE"
	  fi
	  printf '\n\n--------------------------------------------------------------------------------------------------------------------\n'
	  printf '5. MoltenVK (https://github.com/KhronosGroup/MoltenVK)\n'
	  printf -- '--------------------------------------------------------------------------------------------------------------------\n\n'
	  cat "$MVK_LICENSE"
	  printf '\n\n--------------------------------------------------------------------------------------------------------------------\n'
	  printf '8. SDL2 (https://www.libsdl.org)\n'
	  printf -- '--------------------------------------------------------------------------------------------------------------------\n\n'
	  cat "$SDL_LICENSE"; } > "$APP/Contents/Resources/THIRD_PARTY_LICENSES.txt"
	if [ -n "${MACOS_SIGN_ID:-}" ]; then
		codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_ID" "$APP/Contents/Frameworks/libMoltenVK.dylib"
		codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_ID" "$APP/Contents/Frameworks/libSDL2-2.0.0.dylib"
		codesign --force --timestamp --options runtime --sign "$MACOS_SIGN_ID" "$APP"
		codesign --verify --strict --verbose=2 "$APP"
	else
		echo "MACOS_SIGN_ID not set: the app is not signed (Gatekeeper will block it on other Macs)"
	fi
	ditto -c -k --keepParent "$APP" dist/ff13-launcher-macos.zip
	if [ -n "${MACOS_SIGN_ID:-}" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
		xcrun notarytool submit dist/ff13-launcher-macos.zip --keychain-profile "$NOTARY_PROFILE" --wait
		xcrun stapler staple "$APP"
		rm -f dist/ff13-launcher-macos.zip
		ditto -c -k --keepParent "$APP" dist/ff13-launcher-macos.zip # (again, with the ticket stapled)
	else
		echo "NOTARY_PROFILE not set: not notarized"
	fi
	cp $REL/README.md $REL/THIRD_PARTY_LICENSES.txt dist/ 2>/dev/null || true
	ls -la dist/ff13-launcher-macos.zip
	;;
*)
	echo "release.sh: run it on Windows (WSL), Linux or macOS"
	exit 1
	;;
esac
