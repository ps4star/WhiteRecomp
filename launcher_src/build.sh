#!/bin/sh
# launcher/build.sh [windows|linux|linux_arm64|macos|all] [odin build flags]   (WSL; default windows; all: windows and linux)
# Builds the launcher: build/WhiteRecompLauncher_windows.exe (Windows), build/WhiteRecompLauncher_linux (Linux x86-64),
# build/WhiteRecompLauncher_linux_arm64 (Linux ARM64: builds and runs the game on the ARM64 machine itself). macos: only
# its bundle, build/bundle_macos.bin (with both macOS FFmpegs: ffmpeg/lib Apple silicon's, ffmpeg/lib_x86_64 Intel's),
# and the launcher type-checked for macOS -- the .app is linked on a Mac (launcher/release.sh, BUNDLE=that file).
#   1. packs what it carries into its bundle.bin (build/bundle.exe --stage (tools/bundle), xz per block, bundle --pack: LZMA blocks, unpacked
#      by launcher/lzma): the translated code (build/xrc_gen: run
#      tools/xrc_build.sh first), the runtime (src/runtime), xrc.h, the Vulkan headers (third_party/vulkan), the
#      profile for Profile-Guided Optimization (build/pgo/ff13.profdata: tools/xrc_build.sh XRC_PGO says how), FFmpeg's
#      static libraries for the target with their headers and license (third_party/ffmpeg: the game links them, for
#      the movies), the movie converter (build/bink2mp4.exe: tools/bink2mp4/build.sh) and the Steam achievements helper
#      (build/steamhelper.exe: tools/steamhelper/build.sh); Windows also the ffmpeg.exe it
#      encodes with (third_party/ffmpeg_exe: a static GPL build, run as its own program), Linux x86-64 and macOS the
#      same one as tools/wine/ffmpeg.exe (the converter runs through Wine there: launcher/wine.odin). Both also carry what the
#      Cross-Compile tab (cross.odin) builds for Linux ARM64 with: its system files (build/arm64_tools/sysroot_min:
#      tools/arm64_toolchain.sh) and its FFmpeg (third_party/ffmpeg/lib/linux_arm64), as cross/linux_arm64/. Each
#      target has its own bundle (their FFmpeg libraries differ), kept in its staging folder.
#   2. odin build, with the iv_* libraries of shared/ as the `shared` collection. odin.exe cannot build on a
#      \\wsl.localhost path, so the packages are staged under the Windows %TEMP% (like tools/bundle/build.sh).
#      Linux: odin.exe cross-compiles an object, linked here by clang with Odin's stb libraries (compiled by
#      clang into the staging folder, as vendor/stb/src/build_stb.sh unix does); the window is SDL2's, loaded at run time. Linux ARM64: the same for -target:linux_arm64, linked
#      by clang with build/arm64_tools' ld (tools/arm64_toolchain.sh), Odin's stb compiled for ARM64 into the staging
#      folder. Both are compiled and linked against Ubuntu 22.04's C library, build/glibc_sysroot/<arch>
#      (tools/glibc_sysroot.sh), not this machine's: linked against a new glibc, the launcher asks for its newest
#      symbol versions and does not start on an older one ("version `GLIBC_2.43' not found"); this way it runs on
#      glibc 2.35 and later. (The game is compiled on the player's machine, against their own.)
# Env: ODIN (odin.exe), LAUNCHER_GEN (the translated code to pack; default build/xrc_gen), LAUNCHER_NO_BUNDLE=1 keeps the target's existing bundle.bin, LAUNCHER_XZ_J (xz processes, 12).
# The launcher's git repo (WhiteRecomp): launcher/publish.sh.
set -u
# (the maintainer's build of the launchers: WSL only -- odin.exe, %TEMP%, wslpath, build/bundle.exe (sh tools/bundle/build.sh) and the translated code
# in build/xrc_gen, none of which a copy of launcher_src has. Players don't build the launcher: they download it, and
# its Build compiles the game on their own computer)
if ! command -v wslpath > /dev/null 2>&1 || ! command -v cmd.exe > /dev/null 2>&1; then
	echo "launcher/build.sh builds the launcher releases on the maintainer's Windows PC (WSL) and cannot run here."
	echo "To play: download the launcher for your system from https://github.com/ps4star/WhiteRecomp/releases"
	echo "(Linux ARM64, e.g. a Raspberry Pi: WhiteRecompLauncher_linux_arm64), chmod +x it, run it, and press Build."
	exit 1
fi
cd "$(dirname "$0")/.." || exit 1
GEN=${LAUNCHER_GEN:-build/xrc_gen} # (the translated code packed: tools/xrc_build.sh's XRC_GEN)
# the translated bink2w32.dll (Cutscene Files: Bink2): its pages and table beside the game's; the runtime's xrc_bink_dll.c
# needs them to link
sh tools/xrc_bink_gen.sh "$GEN/src" || { echo "build.sh: could not translate bink2w32.dll into $GEN/src" >&2; exit 1; }
ODIN=${ODIN:-/mnt/c/Users/psivstar/Documents/git/odin/odin.exe}
ODIN_ROOT=$(dirname "$ODIN")
TARGETS=windows
case "${1:-}" in
windows | linux | linux_arm64 | macos) TARGETS=$1; shift ;;
all) TARGETS="windows linux"; shift ;;
esac
M() { wslpath -m "$1"; }
WTEMP=$(cmd.exe /c 'echo %TEMP%' 2>/dev/null | tr -d '\r')
# glibc_check FILE: refuses a Linux launcher that asks for a glibc newer than the sysroot's 2.35
glibc_check() {
	v=$(llvm-objdump-21 -T "$1" | grep -o "GLIBC_[0-9.]*" | sort -Vu | tail -1)
	case "$v" in GLIBC_2.3[6-9]* | GLIBC_2.[4-9]*) echo "launcher: $1 needs $v (more than glibc 2.35)"; exit 1 ;; esac
	echo "$1: needs $v at most"
}

for T in $TARGETS; do
	case $T in
	windows) FFP=windows_amd64; STAGE="$(wslpath "$WTEMP")/ff13_launcher_build"; FFEXE=third_party/ffmpeg_exe/windows_amd64; FFDST=tools; SDLW=third_party/sdl2/windows_amd64 ;;
	linux) FFP=linux_amd64; STAGE="$(wslpath "$WTEMP")/ff13_launcher_linux"; FFEXE=third_party/ffmpeg_exe/windows_amd64; FFDST=tools/wine; SDLW="" ;;
	linux_arm64) FFP=linux_arm64; STAGE="$(wslpath "$WTEMP")/ff13_launcher_linux_arm64"; FFEXE=""; FFDST=tools; SDLW="" ;;
	macos) FFP=darwin_arm64; STAGE="$(wslpath "$WTEMP")/ff13_launcher_macos"; FFEXE=third_party/ffmpeg_exe/windows_amd64; FFDST=tools/wine; SDLW="" ;;
	esac
	# (macOS: one launcher for both kinds of Mac, so both FFmpegs: lib/ Apple silicon's, lib_x86_64/ Intel's)
	FFX86=""; [ "$T" = macos ] && FFX86="$(M third_party/ffmpeg/lib/darwin_amd64)=ffmpeg/lib_x86_64"
	mkdir -p "$STAGE/launcher"
	rsync -a --delete --exclude bundle.bin launcher/ "$STAGE/launcher/" || exit 1
	rsync -a --delete shared/ "$STAGE/shared/" || exit 1
	if [ -z "${LAUNCHER_NO_BUNDLE:-}" ] || [ ! -f "$STAGE/launcher/bundle.bin" ]; then
		for f in $GEN/xrc_table.c $GEN/match/match_table.c build/bink2mp4.exe build/steamhelper.exe third_party/ffmpeg/lib/$FFP/libavcodec.a build/pgo/ff13.profdata \
			build/arm64_tools/sysroot_min/usr/lib/aarch64-linux-gnu/libc.so third_party/ffmpeg/lib/linux_arm64/libavcodec.a \
			build/android_sysroot/sysroot/glue/android_native_app_glue.c build/android_sysroot/apk/AndroidManifest.xml \
			third_party/appimage/runtime-x86_64 third_party/appimage/runtime-aarch64; do
			[ -f "$f" ] || { echo "launcher: $f is missing (build it first)"; exit 1; }
		done
		BLK="$STAGE/bundle_blocks"
		./build/bundle.exe --stage "$(M "$BLK")" \
			"$(M $GEN/src)=gen/src" "$(M $GEN/xrc_table.c)=gen/xrc_table.c" \
			"$(M $GEN/match)=gen/match" \
			"$(M src/runtime)=runtime" "$(M src/include/xrc.h)=include/xrc.h" \
			"$(M third_party/ffmpeg/include)=ffmpeg/include" "$(M third_party/ffmpeg/lib/$FFP)=ffmpeg/lib" ${FFX86:+"$FFX86"} \
			"$(M third_party/ffmpeg/COPYING.LGPLv2.1.txt)=ffmpeg/COPYING.LGPLv2.1.txt" \
			"$(M third_party/ffmpeg/README.md)=ffmpeg/README.md" \
			"$(M third_party/vulkan/include)=vulkan/include" \
			"$(M third_party/appimage)=appimage" \
			"$(M build/pgo/ff13.profdata)=pgo/ff13.profdata" \
			"$(M build/bink2mp4.exe)=tools/bink2mp4.exe" "$(M build/steamhelper.exe)=tools/steamhelper.exe" \
			"$(M build/arm64_tools/sysroot_min)=cross/linux_arm64/sysroot" \
			"$(M third_party/ffmpeg/lib/linux_arm64)=cross/linux_arm64/ffmpeg/lib" \
			"$(M build/android_sysroot/sysroot)=cross/android_arm64/sysroot" "$(M build/android_sysroot/apk)=cross/android_arm64/apk" \
			${FFEXE:+"$(M $FFEXE/ffmpeg.exe)=$FFDST/ffmpeg.exe" "$(M $FFEXE/LICENSE)=$FFDST/ffmpeg-LICENSE.txt" "$(M $FFEXE/README.txt)=$FFDST/ffmpeg-README.txt"} \
			${SDLW:+"$(M $SDLW/libSDL2.a)=sdl2/libSDL2.a" "$(M $SDLW/README-SDL.txt)=sdl2/README-SDL.txt"} || exit 1
		# each block compressed by xz (LZMA, its dictionary the whole block), cached by its contents in build/bundle_cache:
		# the targets share most blocks (the translated code), and a rebuild compresses only the blocks that changed
		mkdir -p build/bundle_cache
		export BLK
		ls "$BLK"/block_*.raw | xargs -P "${LAUNCHER_XZ_J:-12}" -n 1 sh -c '
			r=$1; c="build/bundle_cache/$(sha256sum < "$r" | cut -c1-64).lzma"
			if [ ! -f "$c" ]; then
				m=$(( ($(stat -c %s "$r") + 1048575) / 1048576 )); [ $m -lt 1 ] && m=1
				xz --format=lzma --lzma1=preset=9e,dict=${m}MiB -c "$r" > "$c.tmp" && mv "$c.tmp" "$c" || exit 1
			fi
			cp "$c" "${r%.raw}.lzma"' _ || { echo "launcher: compressing the bundle failed"; exit 1; }
		./build/bundle.exe --pack "$(M "$BLK")" --out "$(M "$STAGE/launcher/bundle.bin")" || exit 1
	fi
	case $T in
	windows)
		(cd "$STAGE" && "$ODIN" build launcher -out:WhiteRecompLauncher_windows.exe -collection:shared=shared -subsystem:windows -o:speed "$@") || exit 1
		cp "$STAGE/WhiteRecompLauncher_windows.exe" build/WhiteRecompLauncher_windows.exe
		ls -la build/WhiteRecompLauncher_windows.exe
		;;
	linux)
		GS=build/glibc_sysroot/amd64
		[ -f "$GS/usr/lib/x86_64-linux-gnu/libwayland-client.so.0" ] || { echo "launcher: no old-glibc sysroot (run tools/glibc_sysroot.sh)"; exit 1; }
		XCC="clang --target=x86_64-linux-gnu --sysroot=$GS"
		STB="$STAGE/stb_x64_glibc"
		if [ ! -f "$STB/stb_image.a" ]; then # (Odin's stb, compiled by clang: as vendor/stb/src/build_stb.sh unix)
			mkdir -p "$STB"
			for n in stb_truetype stb_rect_pack stb_image; do
				$XCC -c -Os -fPIC "$ODIN_ROOT/vendor/stb/src/$n.c" -o "$STB/$n.o" && llvm-ar-21 rcs "$STB/$n.a" "$STB/$n.o" || exit 1
			done
		fi
		rm -f "$STAGE/whiterecomp_linux.o"
		(cd "$STAGE" && "$ODIN" build launcher -out:whiterecomp_linux.o -collection:shared=shared -target:linux_amd64 -build-mode:obj -o:speed "$@") || exit 1
		$XCC -o build/WhiteRecompLauncher_linux "$STAGE/whiterecomp_linux.o" "$STB/stb_truetype.a" "$STB/stb_rect_pack.a" "$STB/stb_image.a" \
			-lm -ldl -lpthread || exit 1
		glibc_check build/WhiteRecompLauncher_linux
		ls -la build/WhiteRecompLauncher_linux
		;;
	macos)
		# (linking for macOS needs Apple's linker and SDK: only on a Mac -- launcher/release.sh there, with this bundle;
		# here the launcher is type-checked for both kinds of Mac)
		for A in darwin_arm64 darwin_amd64; do
			(cd "$STAGE" && "$ODIN" check launcher -collection:shared=shared -target:$A) || exit 1
		done
		cp "$STAGE/launcher/bundle.bin" build/bundle_macos.bin
		echo "build/bundle_macos.bin: on a Mac, BUNDLE=<it> sh launcher/release.sh"
		ls -la build/bundle_macos.bin
		;;
	linux_arm64)
		AT=build/arm64_tools GS=build/glibc_sysroot/arm64
		[ -x "$AT/bin/aarch64-linux-gnu-ld" ] || { echo "launcher: no ARM64 linker (run tools/arm64_toolchain.sh)"; exit 1; }
		[ -f "$GS/usr/lib/aarch64-linux-gnu/libwayland-client.so.0" ] || { echo "launcher: no old-glibc ARM64 sysroot (run tools/glibc_sysroot.sh)"; exit 1; }
		XCC="clang --target=aarch64-linux-gnu --sysroot=$GS"; XLD="$XCC --ld-path=$AT/bin/aarch64-linux-gnu-ld"
		STB="$STAGE/stb_glibc"
		if [ ! -f "$STB/stb_image.a" ]; then # (Odin's stb, for ARM64: as vendor/stb/src/build_stb.sh unix)
			mkdir -p "$STB"
			for n in stb_truetype stb_rect_pack stb_image; do
				$XCC -c -Os -fPIC "$ODIN_ROOT/vendor/stb/src/$n.c" -o "$STB/$n.o" && llvm-ar-21 rcs "$STB/$n.a" "$STB/$n.o" || exit 1
			done
		fi
		rm -f "$STAGE/whiterecomp_linux_arm64.o"
		(cd "$STAGE" && "$ODIN" build launcher -out:whiterecomp_linux_arm64.o -collection:shared=shared -target:linux_arm64 -build-mode:obj -o:speed "$@") || exit 1
		$XLD -o build/WhiteRecompLauncher_linux_arm64 "$STAGE/whiterecomp_linux_arm64.o" "$STB/stb_truetype.a" "$STB/stb_rect_pack.a" "$STB/stb_image.a" \
			-lm -ldl -lpthread || exit 1
		glibc_check build/WhiteRecompLauncher_linux_arm64
		ls -la build/WhiteRecompLauncher_linux_arm64
		;;
	esac
done
