# WhiteRecomp

Extremely optimized re-compilation of FF13 currently targeting x64 Windows, x64/ARM64 Linux, macOS, and Android.

WhiteRecomp builds a native port of **FINAL FANTASY XIII** on your own computer. It uses your own Steam version of the game to do this.

If you're having issues (rendering, slowdowns) with the recomp, please join the Discord and message me: https://discord.gg/FHpmpnBJC

The core translation component (XRC; x86 -> C translator+re-compiler) is now open source! It lives at https://github.com/ps4star/XRC

> [!IMPORTANT]
> WhiteRecomp does **not** contain the game or any copyrighted game data or assets. You need a legitimate copy of FINAL FANTASY XIII installed from Steam (the current Steam version).

## Download

Get the launcher for your system from the [Releases page](https://github.com/ps4star/WhiteRecomp/releases):

| System | File |
| --- | --- |
| Windows (64-bit) | `WhiteRecompLauncher_windows.exe` |
| Linux (x86-64) | `WhiteRecompLauncher_linux` (run `chmod +x` on it first; less tested than Windows; needs glibc 2.35 or newer: Ubuntu 22.04, Debian 12, Fedora 36, SteamOS 3 and later) |
| Linux (ARM64) | `WhiteRecompLauncher_linux_arm64` (run `chmod +x` on it first; glibc 2.35 or newer, as above; new and least tested: it builds and runs the game on the ARM64 computer itself, which needs Clang, Vulkan drivers and SDL2) |
| macOS 11 or newer (Apple silicon or Intel) | `WhiteRecompLauncher_macos.zip`: unzip it and open `WhiteRecomp.app`. It isn't signed, so the first time right-click it and choose **Open** (or run `xattr -dr com.apple.quarantine WhiteRecomp.app`). **Experimental and untested so far**: see [macOS](#macos). |

Put the launcher in a folder of its own. **Build** creates the game beside it.

## Quick start

1. **Start the launcher.** It finds the game through Steam. If it doesn't, press **Browse…** and pick the `FINAL FANTASY XIII` folder (the one containing `white_data`).
2. **Install what it says is missing.** Usually that's just a C compiler. The launcher offers to install one, and asks for administrator permission only for an install that needs it.
3. **Options** (optional). See [Options](#options) below.
4. **Build.** This compiles the game, which takes a few minutes. The result is `WhiteRecomp.exe` (Linux: `WhiteRecomp`) beside the launcher, with `WhiteRecomp.cfg` next to it, which records where your game and saves are.
5. **Run** starts the game. You can also start `WhiteRecomp.exe` directly.
6. **Cutscenes** play straight from the game's own movie files when **Cutscene Files** is set to **Bink2** ([Options > Cutscenes](#cutscenes)); nothing to convert. Or, for MP4: **Convert Movies** (on Linux and macOS it needs Wine) converts the game's cutscenes to MP4, once. There are about 7 hours of them (English and Japanese), so it takes a while, but it can be stopped and resumed.
7. **Discard Movies** (optional, MP4 only). Once the MP4s exist, this frees about 40 GB by cutting the original movie files down. Bink2 then can't be used any more.

**As AppImage** (Linux launchers: the switch above **Build**). When it's on, Build makes one file, `WhiteRecomp-x86_64.AppImage` (or `-aarch64` on ARM64), instead of `WhiteRecomp` and its `WhiteRecomp.cfg`: the game, its settings and an icon packed into a single program you can keep anywhere. **Run** starts it. AppImages open through FUSE (`libfuse2` / `libfuse2t64`); without it, Run has the AppImage unpack itself to a temporary folder first. With `mksquashfs` installed (`squashfs-tools`) the AppImage is compressed (about a third of the size); without it, it's packed uncompressed.

A **Build** compiles only what changed since the last one, so a second Build is much quicker than the first. Files an older launcher unpacked that this one no longer has are deleted. **Clear Cache** (left of Build) clears the launcher's data folder (`%LOCALAPPDATA%\ff13-launcher` on Windows, `~/Library/Application Support/ff13-launcher` on macOS, `~/.local/share/ff13-launcher` on Linux): the unpacked sources, the compiled objects and the tools, so the next Build starts over and compiles everything. Use it if a Build behaves strangely after an update. Kept: your saves (`cdrive`), the launcher's settings (`settings.txt`), the Android signing key and an FFmpeg you put in `ffmpeg/` yourself. While a task runs, **Cancel** appears left of the buttons.

## Requirements

- **FINAL FANTASY XIII from Steam.** WhiteRecomp reads the game program (`ffxiiiimg.exe`, which must be the current Steam version, unmodified) and all the game's files from your install. It uses the game's own movie decoder (`bink2w32.dll`) to play cutscenes (Bink2) or to convert them (MP4). Both Steam editions work: the North America / Europe one and the region-locked **Asian** one. The Home tab shows which one it found, **EN** or **JP**, after "Game folder". In the Asian edition, **Space** confirms in menus (Enter does not) and the voices are Japanese only; that is how that edition behaves. A patched `ffxiiiimg.exe` (a 4GB patch, for instance) is refused: have Steam restore it (Properties > Installed Files > Verify integrity of game files). WhiteRecomp doesn't need such patches ([Memory](#memory) is 4 GB by default).
- **Clang** (the C compiler the game is built with).
  - On Windows: LLVM-MinGW, or MSYS2's Clang. Visual C++ can't build the game.
  - On Linux: `clang`, or GCC (`gcc`) if you prefer it.
  - On macOS: Apple's command line tools (`xcode-select --install`; the launcher offers to start that).
  - The launcher lists every compiler it can use and offers to install Clang if there is none.
  - If you installed Clang and the launcher still doesn't find it, use **Choose clang.exe…** (Windows) or **Choose clang…** (macOS) in its "A C compiler is needed" dialog and pick the compiler yourself. The dialog also lists every compiler it tried and why it couldn't use it. LLVM's own Windows download targets Visual C++ and can't build the game: use LLVM-MinGW. On Windows the launcher also finds a compiler whose folder you added to PATH after the launcher was started.
  - **Steam Deck (SteamOS):** SteamOS removes the C headers from its system, so Clang alone can't build anything. The launcher's **Install it for me** unlocks SteamOS's read-only system, installs Clang and puts the headers back (it asks for your password: set one first with `passwd` in Konsole if you haven't). A SteamOS update undoes this; press Install it for me again afterwards.
- **A GPU with Vulkan 1.3.**
- **SDL2 (Linux):** the launcher's window and the game both use it, on Wayland or X11. Most desktops already have it, but not all (a fresh Xubuntu does not). When it is missing, the launcher says so in a dialog when it starts and offers to install it (it asks for your password); or install `libsdl2-2.0-0` (Ubuntu, Debian), `SDL2` (Fedora) or `sdl2` (Arch) yourself. The macOS app carries its own.
- **Movies:** the converter is a 32-bit Windows program that uses the game's own Bink DLL. On Linux (x86-64) and macOS it runs through **Wine**, which must run 32-bit programs (Wine 9 or later; on Debian and Ubuntu also `wine32`; on Apple silicon Macs also Rosetta 2). The Requirements list finds Wine and can install it. With no Wine installed, it uses the Wine inside one of Steam's **Proton** versions (from any Steam library, including a microSD card, and custom ones such as GE-Proton). On a **Steam Deck** that is the way: SteamOS's system partition is read-only and too small for Wine's packages, so the launcher does not offer to install them there. If no Proton is installed, install one in Steam (Library, search "Proton"). The launcher brings the FFmpeg program it needs (the Windows one, for Wine), and gives Wine a folder of its own in the launcher's data folder, so your own Wine setup isn't touched. On ARM64 Linux, convert on another PC. Playing converted movies needs no FFmpeg program, because the game has FFmpeg's libraries built in.
- **Steam achievements and overlay (Windows, Linux):** have Steam running and signed in when you start the game. See [Steam Integration](#steam-integration).

## macOS

macOS support is new and has not been run on a Mac yet. Reports of what works and what doesn't are very welcome.

- **The game files:** FINAL FANTASY XIII on Steam is a Windows game, so Steam for macOS won't install it. Copy the `FINAL FANTASY XIII` folder from a Windows PC (or from a CrossOver or Whisky install of Steam), then pick it with **Browse…**.
- **What Build makes:** a native game for your Mac (ARM64 on Apple silicon, x86-64 on Intel Macs) in `~/Library/Application Support/ff13-launcher/game`, not beside the launcher (nothing may be added inside a signed app). **Run** starts it.
- **Graphics, sound and controllers:** the app carries MoltenVK (Vulkan on Apple's Metal) and SDL2, and the launcher and the game use those.
- **Not on macOS:** Steam achievements and the overlay, and the Debug & Profile Tools' profiler.

## Options

The **Options** tab is saved between sessions.

- **Build options:** most options change how the game is compiled, so they take effect the next time you press **Build**.
- **Game options:** **Resolution**, **Window Scaling**, **Graphics**, **Effects Resolution**, **Steam Integration**, **Pipeline Build Threads** and **Memory** are passed to the game when it starts. They take effect the next time you start the game, with no rebuild.

The options are grouped as on the tab: Display, Graphics, Audio & Controls, Cutscenes, Steam (Windows, Linux), Performance and Build.

### Display

#### Resolution

The resolution the game renders at, passed to the game as `-Width=W -Height=H`: 854 x 480, 960 x 540, **1280 x 720** (default), 1600 x 900, 1920 x 1080, 2560 x 1440, 3200 x 1800 or 3840 x 2160. Higher is sharper and costs more GPU time; 480 and 540 are for slow GPUs. Takes effect the next time the game starts, with no Build needed.

The game's window opens at this size. You can resize or maximize it, and **F11** switches fullscreen on and off. The picture is scaled to fit the window with its shape kept, so a window of another shape gets black bars (a maximized window too: the title bar and taskbar take some of its height).

#### Window Scaling

**Fit** (default) keeps the picture's 16:9 shape, with black bars in a window of another shape. **Stretch** fills the whole window, squeezing the picture to the window's shape. Takes effect the next time the game starts, with no Build needed.

#### FPS

The frame rate cap: **30** or **60** (default). The game's logic runs in 1/60 s steps, so these are the two supported rates.

#### Graphics Driver

- **Vulkan (Recommended)**, the default and the only choice on Linux: the port's own renderer.
- **D3D9** (Windows only): Windows' own Direct3D 9. It's currently broken: the game stops at the cutscene after the first fight.

### Graphics

#### Graphics

A preset for shadows and anti-aliasing. Takes effect the next time the game starts.

| Choice | Shadows | Anti-aliasing |
| --- | --- | --- |
| Ultrafast (Worst Quality) | Off | Off |
| Fast | 512 x 512 | 2x FXAA |
| **Fancy (Default)** | 1024 x 1024, the game's default | 4x FXAA |
| Ultrafancy | 8192 x 8192 | 8x FXAA |
| Custom | As set below | As set below |

**Custom** shows three more options under Graphics:

- **Shadow Resolution:** the size of the shadow maps, passed to the game as `-Shadow=N` exactly as the original launcher does. **Off** draws no shadow maps at all (the fastest); 512 is blurrier and cheaper; 1024 is the game's default; 2048, 4096 and 8192 (the original launcher's maximum) are sharper and costlier.
- **Anti-alias Method:**
  - **FXAA** (default): a cheap smoothing filter on the 3D image, applied before the HUD is drawn so the HUD stays sharp.
  - **MSAA:** the game's own multisampling, passed as `-MSAA=N` like the original launcher. Sharper on fine detail, but costly, especially on integrated GPUs.
- **Anti-alias Quality:** **1x** (off), **2x**, **4x** (default) or **8x**. For FXAA, higher smooths longer edges; for MSAA it's the samples per pixel, and if your GPU can't do the count you pick, the game uses the most it supports.

#### Effects Resolution

How the game's glowing effects (fire, sparks, magic, most of a battle's spell effects) are drawn. Vulkan only; takes effect the next time the game starts, with no Build needed.

- **Half (Default):** the effects that add light are drawn at half the resolution and then added to the picture. They cost about a quarter of the GPU time, which matters in effect-heavy battles on integrated GPUs. They look a little softer, and an effect just behind the edge of a character can show slightly past it.
- **Full:** every effect at full resolution, as the original game draws them.

### Audio & Controls

#### Audio

- **On** (default): music, sound effects and voices.
- **Off:** no sound output and no audio processing at all, for example if you want to play your own music. The game's audio engine is replaced by a silent stand-in that only keeps time.

#### Gamepad Scanning

How the game finds controllers. FINAL FANTASY XIII only reads DirectInput controllers; on Linux, any controller SDL2 knows (Xbox, PlayStation, Switch and most others) is presented to the game as an Xbox 360 controller.

- **Every 2 seconds (Default):** a controller plugged in while you play is found within 2 seconds.
- **Once:** only the controllers connected when the game starts are used. Plug one in later and you need to restart the game.

### Cutscenes

#### Cutscene Files

Which files the game plays its cutscenes from. FINAL FANTASY XIII's cutscenes are Bink 2 videos (the `.wmp` files in `white_data/movie`). Only the kinds your game folder has are offered:

- **Bink2:** the game's own videos, played by its own Bink library (`bink2w32.dll`, translated like the rest of the game). Nothing to convert. Offered while the `.wmp` files are complete (not cut down by Discard Movies).
- **MP4:** the MP4s **Convert Movies** made from them, played with FFmpeg's libraries (Windows, Linux, macOS) or the system's decoder (Android). Offered once some exist.

If neither is there (the `.wmp` files discarded or missing, and no MP4s), the option is grayed out, every cutscene is skipped, and the launcher says to re-install the game from Steam (or verify its files) to get them back. Switching needs no new Build. A Build's `WhiteRecomp.cfg` follows what is there: after Discard Movies, the game uses the MP4s.

#### Cutscenes

With **MP4**, each cutscene is converted to an MP4 once. **Convert Movies** on the Home tab does them all, using every CPU thread but one. The game itself no longer converts anything while you play.

Many movie files hold several cutscenes one after another (`z016_us.win32.wmp` holds 8). Each cutscene gets its own MP4: the first one `<name>.mp4`, the others `<name>_<offset>.mp4`. Older launchers converted only the first cutscene of each file, so later scenes played the wrong video under their subtitles, or were skipped (and `z004` never finished converting). MP4s converted now come with a `.v10` file in the movie folder. When the launcher starts and finds MP4s without it, it deletes them and asks you to run **Convert Movies** again. If you used **Discard Movies** with an older launcher, those cutscenes were cut out of the files: have Steam restore them first (Properties > Installed Files > Verify integrity of game files), then Convert Movies.

- **Play** (with Bink2) or **Play if converted** (with MP4; default): with MP4, a cutscene plays once its MP4 exists, and is skipped until then.
- **Auto-skip:** every cutscene is skipped, even converted ones, which is handy for replays and speedruns. Converted ones play again if you switch back (followed by a new Build).

### Steam

#### Steam Integration

Windows and Linux (x86-64 PCs; not ARM64 builds).

- **On** (default): with Steam running and signed in when the game starts, achievements unlock on your Steam account with Steam's pop-up in the game window, the Steam overlay works (**Shift+Tab**; Vulkan graphics driver), and Steam shows you as playing FINAL FANTASY XIII. On Linux the game uses your Steam installation's own `steamclient.so` (regular or Flatpak Steam); the overlay is less certain there than on Windows, but achievements don't depend on it. Without Steam running, the game plays normally without them; start Steam before the game, since a Steam started later isn't noticed.
- **Off:** none of that. The game doesn't touch Steam at all.

Takes effect the next time the game starts, with no Build needed. Steam Cloud saves aren't supported either way; saves stay on your computer.

### Performance

#### Pipeline Build Threads

How many threads prepare the renderer's graphics pipelines in the background. A new effect or area needs new pipelines the first time it appears, and until one is ready the objects using it are skipped for a frame or two. The default, marked **(Best)**, is half your CPU threads (at most 8). The maximum is your CPU threads minus one (at most 16). Takes effect the next time the game starts, with no Build needed.

#### Memory

How much memory the game can address.

- **4GB (Recommended)** (default): the address space a 4 GB-patched exe gets.
- **2GB:** what the original, unpatched exe gets.

### Build

#### Compiler

The C compiler that builds the game. The launcher lists every Clang it finds on the system, and Clang is the default: it produces a noticeably faster game.

On Linux, GCC is offered too (listed after Clang). Profile-Guided Optimization needs Clang, so it's off with GCC; Link-Time Optimization works with both. On Windows and macOS, only Clang is used.

#### Optimization Level

How hard the compiler optimizes the game. The default is **1**.

| Level | Build time | Game speed |
| --- | --- | --- |
| 0 | Fastest build | Slowest game. Only useful for debugging. |
| **1 (Recommended)** | A few minutes | Fast |
| 2 | Slower build | About the same as 1 |
| 3 | Slowest build | About the same as 1 |

Levels above 1 haven't measured faster than 1.

#### Profile-Guided Optimization

- **On** (default): the game is compiled with a profile recorded while playing it, so the compiler optimizes for how the game actually runs: about 6% less CPU time per frame on the game's main thread.
- **Off:** built without the profile.

On Windows it also needs LLVM's linker (`ld.lld.exe`) next to `clang.exe` (MSYS2: the `mingw-w64-ucrt-x86_64-lld` package); the launcher says so if it's missing. If your Clang is too old to read the profile, the Build says so and goes on without it.

#### Link-Time Optimization

- **Off** (default): each source file is optimized on its own. This is the faster Build.
- **On:** the compiler also optimizes across files when it links the game (`-flto`), which can make the game a little faster. The Build takes noticeably longer.

With Clang on Windows, this needs LLVM's linker (`ld.lld.exe`) next to `clang.exe`. In MSYS2 that's the `mingw-w64-ucrt-x86_64-lld` package. If it's missing, the launcher says so and builds without LTO. GCC, and Clang on Linux, need nothing extra.

#### Experimental Optimizations

- **Off** (default): only tested optimizations.
- **On:** also enables newer optimizations that are less tested and **may break things**, such as visual glitches, crashes or a softlock.

Turn it off again (and Build) if anything goes wrong. Bug reports from playing with it on are welcome; please say it was on.

#### Debug & Profile Tools

- **Off** (default): the game prints nothing and, on Windows, opens no console window. No Vulkan debugging, validation, capture or profiling layer is loaded either, even if your environment or an installed tool (RenderDoc, Nsight, the Vulkan SDK's layers) asks for one. Steam's overlay is still loaded when [Steam Integration](#steam-integration) is on, and other overlays and OBS game capture keep working.
- **On:** a console window with logs, plus:
  - an **FPS counter** in the top right corner of the game window
  - stack traces if the game crashes or hangs
  - the profiler and tracing switches (environment variables starting with `XRC_`) for diagnosing problems

  These cost almost nothing while unused.

#### Always on

Every Build also uses these, with no option to turn them off:

- **`-march=native`:** the game is compiled for your own CPU's instruction set, since the computer that builds it is the one that plays it. A game built on one computer may not run on an older CPU.
- **Fast math (`-ffast-math -fno-associative-math`):** faster floating-point code. The parts of the translated code that must behave exactly like an x86 CPU (NaN checks, float compares, float-to-integer conversions) are written so fast math can't change them. Reassociation (regrouping sums) stays off, because it breaks the game's own rounding tricks: the title menu disappears. Other results may differ from the original in the last bits.
- **On Linux:** the distributions' hardening defaults (position-independent executables, control-flow protection, stack protector) are turned off. They cost speed and protect nothing here.

## Cross-Compile

The **Cross-Compile** tab builds the game for another kind of computer than the one the launcher runs on, with the Options tab's options: **Linux ARM64** (a Raspberry Pi 4 or 5, an ARM laptop, Asahi Linux on an Apple-silicon Mac) or **Android ARM64** (phones, tablets, Android handhelds). It works from the Windows and the Linux launcher.

- **Target:** Linux ARM64 (64-bit ARM, glibc 2.35 or newer: Debian 12, Ubuntu 22.04, Raspberry Pi OS 12 and later), or Android ARM64 (Android 10 or newer, 64-bit ARM, Vulkan graphics).
- **CPU:** **Any ARM64 CPU** (default) runs everywhere; choosing the device's CPU (Raspberry Pi 4, Raspberry Pi 5, Apple M1/M2, ...) is faster there, but that build needs that CPU or a newer one. For Android, **Any ARM64 phone** (default) runs everywhere; Cortex-A76 and Cortex-X1 suit 2019 and 2021 or later flagships.
- **Needs:** Clang and LLVM's linker (lld). LLVM-MinGW and MSYS2's Clang on Windows come with lld; on Linux install it, e.g. `sudo apt install lld`. Everything for the target (its system headers and libraries, its FFmpeg) is packed in the launcher.
- **Build for Linux ARM64** builds into the folder `WhiteRecomp-linux-arm64` beside the launcher. Copy that folder to the ARM64 computer, put (or link) your `FINAL FANTASY XIII` folder inside it, and run `./WhiteRecomp` there. Its `README.txt` has the steps. That computer needs Vulkan drivers and SDL2 (e.g. `sudo apt install libsdl2-2.0-0 mesa-vulkan-drivers`). Convert the cutscenes on a Windows PC first: they travel with the game folder.
- **As AppImage** (Linux targets: the switch above the Build button). When it's on, the Linux build is one file, `WhiteRecomp-aarch64.AppImage`, in that folder (with a `README.txt`) instead of the program, its `.cfg` and `cdrive`. Copy the AppImage to the other computer, put (or link) your `FINAL FANTASY XIII` folder next to it, `chmod +x` it and run it. Saves go in `cdrive/` next to the AppImage. It needs FUSE there to open (`sudo apt install libfuse2`, or `libfuse2t64`), or start it with `--appimage-extract-and-run`. It's compressed when this computer has `mksquashfs` (squashfs-tools; Linux and macOS), else packed uncompressed (the Windows launcher always does that).
- **Build for Android ARM64** makes `WhiteRecomp.apk` in the folder `WhiteRecomp-android-arm64` beside the launcher. No Android SDK or Java is needed: the launcher writes and signs the APK itself, with a key it makes the first time (`android_key.bin` and `android_cert.der` in its data folder; keep them, since Android installs an update over the app only when it's signed by the same key). Install the APK on the device, copy your `FINAL FANTASY XIII` folder to the device's internal storage or to the top of a microSD card (the game looks on every card and USB drive; anywhere else, put the folder's full path, e.g. `/storage/1234-ABCD/Games/FINAL FANTASY XIII`, in `Android/data/com.whiterecomp.ff13/files/game_dir.txt`), start the app and allow access to your files. The folder's `README.txt` has the steps. Cutscenes play through Android's own video decoder (convert the movies on a PC first, with Convert Movies: the `.mp4` files go with the game folder). It has **on-screen touch controls**: A, B, **0** (pause: the controller's Start) and **1** (select / skip: Back), and two analog sticks. Put a finger down anywhere else on the left half of the screen and a stick appears there, a ring with a knob that follows your finger: that's the left stick (moving). Do the same on the right half for the right stick (the camera). The controls hide as soon as you use a game controller and come back when you touch the screen. `XRC_TOUCH=0` in the device's `ff13.cfg` turns them off (a touch is then the mouse). A game controller, or a keyboard and mouse, work too. The APK is built with the Options tab's options as set, packed in it. **Use Android Preset** (on the Cross-Compile tab, with Android ARM64 chosen) sets them for a phone: 960x540, 60 fps, 512 shadows (the lowest that keeps them), anti-aliasing off, effects at half resolution, 4 GB of memory, optimization level -O1 and 2 Pipeline Build Threads; sound, cutscenes and the rest stay as they are. These become the Options tab's settings, so a Build for your PC uses them too until you change them back; an `ff13.cfg` in `Android/data/com.whiterecomp.ff13/files` on the device overrides them.

## Features & Mods

Options that change what the game plays. They go into the built game's settings, so they apply the next time you start the game, with no rebuild.

### Language

- **Voice:** **English** (the default) or **Japanese**, cutscenes included. Both voice sets come with the game. Convert Movies converts both cutscene sets, so either plays.
- **Subtitles:** **English** (the default) or **Japanese**: subtitles, menus and all other text. The PC release only offers Japanese voices, not Japanese text, although the Japanese text is in its files: the port turns it on. Any voice works with any text language.

These replace the language you chose for the game in Steam.

## What the download contains

- **The launcher program.** Packed inside it are:
  - **The translated game code:** C source files generated from the game program and compiled on your computer.
  - **The runtime those sources run on:** C sources for memory, threads, files, graphics (Vulkan), sound and movies.
  - **FFmpeg's libraries** (libavformat, libavcodec, libswresample, libavutil; LGPL 2.1 or later), which the game is linked with to play the movies.
  - **For the Cross-Compile tab:** Linux ARM64's system headers and libraries (from Ubuntu's packages) and FFmpeg's libraries for Linux ARM64; Android's system headers and link libraries for API 29, Clang's runtime for ARM64 Android and the NativeActivity glue (from the Android NDK: Apache 2.0, BSD, the Linux headers' GPL-2.0 with the syscall exception; their `NOTICE` is extracted with them), and the APK's compiled manifest.
  - **On Windows, the movie converter:** a 32-bit Windows program.
  - **On Windows, the Steam achievements helper:** a small 32-bit Windows program that loads your install's own Steam files (`sgw.dll` and `steam_api.dll`), since the 64-bit game can't. Nothing of Valve's is included.
  - **On Windows, the FFmpeg program it encodes with** (`ffmpeg.exe`, GPL 3). It's a separate program; see `THIRD_PARTY_LICENSES.txt`.
- **`THIRD_PARTY_LICENSES.txt`:** the licenses of the libraries and fonts in the launcher, and of FFmpeg, with where to get its source and how to use your own build of it.

## Building the launcher

The launcher's sources are in [`launcher_src/`](launcher_src/). It's written in [Odin](https://odin-lang.org/) and is built inside the main decompilation project, because the bundle it carries (the translated code, the runtime and the tools) comes from that project's build. See [`launcher_src/README.md`](launcher_src/README.md).
