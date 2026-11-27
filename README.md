# WhiteRecomp

Extremely optimized re-compilation of FF13 currently targeting x64 Windows, x64/ARM64 Linux, macOS, and Android.

WhiteRecomp builds a native port of **FINAL FANTASY XIII** on your own computer. It uses your own Steam version of the game to do this.

If you're having issues (rendering, slowdowns) with the recomp, please join the Discord and message me: https://discord.gg/FHpmpnBJC

The core translation component (XRC; x86 -> C translator+re-compiler) is now open source! It lives at https://github.com/ps4star/XRC

> [!IMPORTANT]
> WhiteRecomp does **not** contain the game or any copyrighted game data or assets. You need a legitimate copy of FINAL FANTASY XIII installed from Steam (the current Steam version).

## I Am Looking For Work

Hi! My Internet name is ps4star and I'm currently making barely above a living wage working as an IRL physical security guard. I have about 8 years of (completely self-taught) total software development experience and 4 years of reverse-engineering experience. I am looking for any full-time or temporary/contract software engineering or reverse-engineering work. You could also hire me to do a recomp or specific port(s) of your favorite game, if you want.

I have experience in low-level ecosystems such as C, Odin, and various ISA assembly languages. I specifically love to optimize the ever-loving crap out of software to take full advantage of a user's hardware. Please reach out to me on discord (username is ps4star), or send me an e-mail at star_recomps@proton.me

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

**The launcher's language:** the drop-down at the top right of its window (English, 日本語, 繁體中文, 简体中文, 한국어, Русский, Deutsch, Français, Español, Português (Brasil), Italiano, Polski). It changes only the launcher's own text; the game's language is under [Features & Mods > Language](#language).

**As AppImage** (Linux launchers: the switch above **Build**). When it's on, Build makes one file, `WhiteRecomp-x86_64.AppImage` (or `-aarch64` on ARM64), instead of `WhiteRecomp` and its `WhiteRecomp.cfg`: the game, its settings and an icon packed into a single program you can keep anywhere. **Run** starts it. AppImages open through FUSE (`libfuse2` / `libfuse2t64`); without it, Run has the AppImage unpack itself to a temporary folder first. With `mksquashfs` installed (`squashfs-tools`) the AppImage is compressed (about a third of the size); without it, it's packed uncompressed.

A **Build** compiles only what changed since the last one, so a second Build is much quicker than the first. Files an older launcher unpacked that this one no longer has are deleted. **Clear Cache** (left of Build) deletes everything the launcher and the game have stored: the whole data folder (`%LOCALAPPDATA%\ff13-launcher` on Windows, `~/Library/Application Support/ff13-launcher` on macOS, `~/.local/share/ff13-launcher` on Linux) -- the unpacked sources, the compiled objects, the tools, imported HD textures and an FFmpeg you put in `ffmpeg/` yourself -- and, beside the launcher, the built game with its `.cfg`, logs, crash reports and pipeline caches (nothing else in that folder), so the next Build starts over and compiles everything. Use it if a Build behaves strangely. After you update the launcher (a new version, or new downloads of the same version), it notices that your game was built by the older one and asks you to **Clear Cache and Build** -- do that, or the game keeps the old code and its bugs (Run reads **Rebuild to Run** until then). Kept: your saves (`cdrive`), the Android signing key, and the launcher's settings (`settings.txt`, the language) only if every one of them is a setting this version has -- a file from an older version with an option that is gone or a value it no longer takes is deleted, and every setting goes back to its default. While a task runs, **Cancel** appears left of the buttons.

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
- **Movies:** the converter is a 32-bit Windows program that uses the game's own Bink DLL. On Linux (x86-64) and macOS it runs through **Wine**, which must run 32-bit programs (Wine 9 or later; on Debian and Ubuntu also `wine32`). **On macOS, Wine comes inside WhiteRecomp.app**: nothing to install (on Apple silicon Macs it needs Rosetta 2, which the Requirements list offers to install). The Requirements list finds Wine and can install it. With no Wine installed, it uses the Wine inside one of Steam's **Proton** versions (from any Steam library, including a microSD card, and custom ones such as GE-Proton). On a **Steam Deck** that is the way: SteamOS's system partition is read-only and too small for Wine's packages, so the launcher does not offer to install them there. If no Proton is installed, install one in Steam (Library, search "Proton"). The launcher brings the FFmpeg program it needs (the Windows one, for Wine), and gives Wine a folder of its own in the launcher's data folder, so your own Wine setup isn't touched. On ARM64 Linux, convert on another PC. Playing converted movies needs no FFmpeg program, because the game has FFmpeg's libraries built in.
- **Steam achievements and overlay (Windows, Linux):** have Steam running and signed in when you start the game. See [Steam Integration](#steam-integration).

## macOS

macOS support is new and has not been run on a Mac yet. Reports of what works and what doesn't are very welcome.

- **The game files:** FINAL FANTASY XIII on Steam is a Windows game, so Steam for macOS won't install it. Copy the `FINAL FANTASY XIII` folder from a Windows PC (or from a CrossOver or Whisky install of Steam), then pick it with **Browse…**.
- **What Build makes:** a native game for your Mac (ARM64 on Apple silicon, x86-64 on Intel Macs) in `~/Library/Application Support/ff13-launcher/game`, not beside the launcher (nothing may be added inside a signed app). **Run** starts it.
- **A Mac app for the game:** each Build also puts **FINAL FANTASY XIII (WhiteRecomp).app** in `~/Applications`, with the game's icon. Start the game from there, Launchpad or Spotlight without opening the launcher (with no game built, it opens the launcher instead).
- **Saves:** besides Steam's own folder (`~/Library/Application Support/Steam/userdata/<account>/292120/remote`), the game looks in CrossOver and Whisky bottles for the original game's saves when it starts (see Steam Cloud saves).
- **Graphics, sound and controllers:** the app carries MoltenVK (Vulkan on Apple's Metal) and SDL2, so there is nothing to install. Each Build copies both next to the built game, so the game keeps working if you move, update or delete the launcher's app.
- **Not on macOS:** the Steam overlay, and the Debug & Profile Tools' profiler. Steam achievements and Steam Cloud work with Steam for Mac running.

## Options

The **Options** tab is saved between sessions.

- **Build options:** most options change how the game is compiled, so they take effect the next time you press **Build**.
- **Game options:** **Resolution**, **Window Scaling**, **Start Fullscreen**, **HDR**, **Graphics**, **Effects Resolution**, **Steam Integration**, **Pipeline Build Threads** and **Memory** are passed to the game when it starts. They take effect the next time you start the game, with no rebuild.

The options are grouped as on the tab: Display, Graphics, Audio & Controls, Cutscenes, Steam (Windows, Linux), Performance and Build.

### Display

#### Aspect Ratio

The picture's shape, which chooses the resolutions **Resolution** offers: **16:9** (default), **16:10** or **Ultrawide** (21:9 and 32:9). It is not a setting of its own: it follows the resolution chosen.

- **16:10** fills a 16:10 screen at its own resolution (sharp, no scaling, nothing stretched): the view keeps 16:9's width and shows more above and below, and the menus and HUD keep their 16:9 layout in the middle. Only the prerendered movies, made for 16:9, have thin black bars above and below.
- **Ultrawide** widens the view with the Ultrawide Fix's patches (see Thanks): the menus stay 16:9 in the middle.

#### Resolution

The resolution the game renders at, passed to the game as `-Width=W -Height=H`, from the list for the chosen **Aspect Ratio**:

- **16:9:** 854 x 480, 960 x 540, **1280 x 720** (default), 1600 x 900, 1920 x 1080, 2560 x 1440, 3200 x 1800 or 3840 x 2160. 480 and 540 are for slow GPUs.
- **16:10:** 1200 x 750 (about as many pixels as 1280 x 720), 1440 x 900, 1680 x 1050, 1920 x 1200, 2560 x 1600, 2880 x 1800 or 3840 x 2400.
- **Ultrawide:** 1280 x 540, 2560 x 1080, 3440 x 1440, 3840 x 1600 or 5120 x 2160 (21:9); 3840 x 1080 or 5120 x 1440 (32:9).

Higher is sharper and costs more GPU time. Takes effect the next time the game starts, with no Build needed.

The game's window opens at this size. You can resize or maximize it, and **F11** switches fullscreen on and off. The picture is scaled to fit the window with its shape kept, so a window of another shape gets black bars (a maximized window too: the title bar and taskbar take some of its height).

#### Window Scaling

**Fit** (default) keeps the picture's shape (its Aspect Ratio), with black bars in a window of another shape. **Stretch** fills the whole window, squeezing the picture to the window's shape. Takes effect the next time the game starts, with no Build needed.

#### Start Fullscreen

**On** opens the game in borderless fullscreen (the desktop's own display mode, so there is no mode switch). **F11** still switches between fullscreen and a window. **Off** (default) opens a window. Takes effect the next time the game starts, with no Build needed.

#### HDR

**On** sends an HDR10 picture when your display is in HDR mode. On Windows, that means turning on **Settings > Display > Use HDR**. Without HDR mode the game shows its usual SDR picture, and the log says why.

The game still renders its normal SDR image; the port expands it for HDR:

- Everything up to mid-brightness stays exactly as in SDR. The game's white and the HUD sit at **Paper White** (default 200 nits).
- Only the 3D image's highlights are spread above that, up to **Peak Brightness** (default 1000 nits). That covers skies, lights, sparks and magic.
- The HUD, menus and cutscenes are never expanded.

Set **Peak Brightness** to your display's peak, and raise or lower **Paper White** to make the whole picture brighter or darker. Takes effect the next time the game starts, with no Build needed.

#### FPS

The frame rate cap: **30** or **60** (default). The game's logic runs in 1/60 s steps, so these are the two supported rates.

#### Graphics Driver

- **Vulkan**, the only choice: the port's own renderer. (Windows' own Direct3D 9 was removed.)

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

How the game finds controllers. FINAL FANTASY XIII only reads DirectInput controllers and only has button layouts for a few of them. On every system (on Windows SDL2 is built into the game, which uses it for its window, keyboard and mouse too), any controller SDL2 knows (Xbox, PlayStation 3/4/5, Switch and most others) is presented to the game as an Xbox 360 controller, so the buttons are always where the game expects them: a PlayStation controller's Cross is A, Circle is B, Square is X and Triangle is Y. Rebuild after updating the launcher for this to apply.

- **Every 2 seconds (Default):** a controller plugged in while you play is found within 2 seconds.
- **Once:** only the controllers connected when the game starts are used. Plug one in later and you need to restart the game.

### Cutscenes

#### Cutscene Files

Which files the game plays its cutscenes from. FINAL FANTASY XIII's cutscenes are Bink 2 videos (the `.wmp` files in `white_data/movie`). Only the kinds your game folder has are offered:

- **Bink2:** the game's own videos, played by its own Bink library (`bink2w32.dll`, translated like the rest of the game). Nothing to convert. Offered while the `.wmp` files are complete (not cut down by Discard Movies).
- **MP4:** the MP4s **Convert Movies** made from them, played with FFmpeg's libraries (Windows, Linux, macOS) or the system's decoder (Android). Offered once some exist.

If neither is there (the `.wmp` files discarded or missing, and no MP4s), the option is grayed out, every cutscene is skipped, and the launcher says to re-install the game from Steam (or verify its files) to get them back. Switching needs no new Build. A Build's `WhiteRecomp.cfg` follows what is there: after Discard Movies, the game uses the MP4s.

The setting chooses which kind is tried **first**. If a cutscene doesn't open that way (its MP4 not converted yet or damaged, or its `.wmp` file cut down by Discard Movies), the game plays it the other way, and only skips it if neither works. So with MP4 chosen, a cutscene you haven't converted yet still plays from its `.wmp` file, and with Bink2 chosen, a discarded one still plays from its MP4.

#### Cutscenes

With **MP4**, each cutscene is converted to an MP4 once. **Convert Movies** on the Home tab does them all, using every CPU thread but one. The game itself no longer converts anything while you play.

Many movie files hold several cutscenes one after another (`z016_us.win32.wmp` holds 8). Each cutscene gets its own MP4: the first one `<name>.mp4`, the others `<name>_<offset>.mp4`. Older launchers converted only the first cutscene of each file, so later scenes played the wrong video under their subtitles, or were skipped (and `z004` never finished converting). The launcher never deletes converted MP4s by itself: if your cutscenes were converted by a launcher older than v0.0.10 and play the wrong video, delete the MP4s in `white_data/movie` and press **Convert Movies**. If you used **Discard Movies** with such an old launcher, those cutscenes were cut out of the files: have Steam restore them first (Properties > Installed Files > Verify integrity of game files), then Convert Movies.

- **Play** (with Bink2) or **Play if converted** (with MP4; default): with MP4, a cutscene plays from its MP4 once that exists, and until then from its `.wmp` file if that is complete (see [Cutscene Files](#cutscene-files)); it is skipped only when it has neither.
- **Auto-skip:** every cutscene is skipped, even converted ones, which is handy for replays and speedruns. The game goes straight on to what follows (before v0.0.19's update, skipping the opening cutscene left a black screen for a few minutes). Converted ones play again if you switch back (followed by a new Build).

### Steam

#### Steam Integration

Windows, Linux (x86-64, and ARM64 with Steam running under FEX or Box64) and macOS (Steam for Mac).

- **On** (default): with Steam running and signed in when the game starts, achievements unlock on your Steam account with Steam's pop-up in the game window, the Steam overlay works (**Shift+Tab**; Vulkan graphics driver), and Steam shows you as playing FINAL FANTASY XIII. Discord shows it too ("Playing FINAL FANTASY XIII") when Discord is running; `XRC_DISCORD=0` turns that off. On Linux the game uses your Steam installation's own `steamclient.so` (regular or Flatpak Steam); the overlay is less certain there than on Windows, but achievements don't depend on it. Without Steam running, the game plays normally without them; start Steam before the game, since a Steam started later isn't noticed.
- **Off:** none of that. The game doesn't touch Steam at all, Steam Cloud included.

Takes effect the next time the game starts, with no Build needed.

#### Steam Cloud saves

With Steam Integration on and Steam Cloud enabled for your account and for FINAL FANTASY XIII (Steam's settings), the game keeps its save files (`ff13-00.dat` is Save Data 01, `ff13-01.dat` Save Data 02, and so on) in step with Steam Cloud:

- When the game starts, a cloud save newer than the one on your computer is copied in. Saves made with the original game, or on another computer, show up under **Load Game**. A save on your computer that is newer than the cloud's is sent to the cloud.
- Each time you save, the save goes to the cloud.
- Whichever copy is replaced, the computer's or the cloud's, is kept first in `save_cloud_backup`, next to the game's `save` folder (`cdrive\Users\Player\AppData\Local\SquareEnix\FinalFantasyXIII`).

When the game starts it also looks for saves outside the cloud, and copies in any that are newer than yours:

- Steam's own folders: `Steam\userdata\<account>\<app>\remote`, the `<app>` folder, and the account folder. It checks every account and every app ID, so the Japan/Asia edition is covered whatever its ID. This includes a save file you put there by hand, which Steam itself doesn't list until it syncs it.
- The original game's save folder: `%LOCALAPPDATA%\SquareEnix\FinalFantasyXIII\save` on Windows, and Proton's copy of it on Linux.
- Wine prefixes on Linux and macOS: `~/.wine`, CrossOver and Whisky bottles (macOS), Bottles (Linux): the original game's save folder in them, and a Windows Steam's `userdata` there.
- The folders you add under **Features & Mods > Save Folders**.

A file counts as a save if it is named like `ff13-00.dat`, or if it is a `.dat` file of a save's exact size (300600 bytes); a renamed one becomes Save Data 01. A copied file counts as new from the moment it was copied, even though copying keeps the old "modified" date. The game's log lists every save it found and where.

If Steam isn't running, saves found this way are still copied in, and the saves you make go into Steam's `remote` folder instead (an older copy there kept first in `save_cloud_backup`); Steam sends them to the cloud when it next starts. With Steam Cloud off in Steam's settings, or Steam Integration off, nothing is sent or written to Steam's folders. Steam uploads the saves when the game ends.

### Performance

#### Pipeline Build Threads

How the renderer prepares its graphics pipelines. A new effect or area needs new pipelines the first time it appears. **Best (Default):** half your CPU threads (1 to 8) prepare pipelines in the background. **1** up to your CPU threads minus one (at most 16): that many threads. Until a pipeline is ready the objects using it are skipped for a frame or two (pipelines seen before load from the disk cache and are quick). Takes effect the next time the game starts, with no Build needed.

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

#### Profiler

Only with Debug & Profile Tools on, Windows only. **On:** F12 in the game starts a capture and F12 again stops it; the report (where the game's time went, by function and by thread) is saved beside the game as `WhiteRecomp-profile-<date>-<time>.txt`. **Off** (default): F12 does nothing. Changing it needs no Build.

#### Always on

Every Build also uses these, with no option to turn them off:

- **`-march=native`:** the game is compiled for your own CPU's instruction set, since the computer that builds it is the one that plays it. A game built on one computer may not run on an older CPU.
- **Fast math (`-ffast-math`), minus the parts that change results:** faster floating-point code. The parts of the translated code that must behave exactly like an x86 CPU (NaN checks, float compares, float-to-integer conversions) are written so fast math can't change them. Kept off: reassociation (`-fno-associative-math`: regrouping sums breaks the game's own rounding tricks, and the title menu disappears), dividing by multiplying with the reciprocal (`-fno-reciprocal-math`), dropping the sign of zero or assuming there are no NaNs (`-fsigned-zeros -fno-finite-math-only`), fused multiply-adds (`-ffp-contract=off`) and, on x86, the CPU's reciprocal estimates (`-mrecip=none`). Each of these made some results differ from an x86 CPU's in the last bits, so they stay off; together they measured no slower.
- **On Linux:** the distributions' hardening defaults (position-independent executables, control-flow protection, stack protector) are turned off. They cost speed and protect nothing here.

## Cross-Compile

The **Cross-Compile** tab builds the game for another kind of computer than the one the launcher runs on, with the Options tab's options: **Linux ARM64** (a Raspberry Pi 4 or 5, an ARM laptop, Asahi Linux on an Apple-silicon Mac) or **Android ARM64** (phones, tablets, Android handhelds). It works from the Windows and the Linux launcher.

- **Target:** Linux ARM64 (64-bit ARM, glibc 2.35 or newer: Debian 12, Ubuntu 22.04, Raspberry Pi OS 12 and later), or Android ARM64 (Android 10 or newer, 64-bit ARM, Vulkan graphics).
- **CPU:** **Any ARM64 CPU** (default) runs everywhere; choosing the device's CPU (Raspberry Pi 4, Raspberry Pi 5, Apple M1/M2, ...) is faster there, but that build needs that CPU or a newer one. For Android, **Any ARM64 phone** (default) runs everywhere; Cortex-A76 and Cortex-X1 suit 2019 and 2021 or later flagships.
- **Needs:** Clang and LLVM's linker (lld). LLVM-MinGW and MSYS2's Clang on Windows come with lld; on Linux install it, e.g. `sudo apt install lld`. Everything for the target (its system headers and libraries, its FFmpeg) is packed in the launcher.
- **Build for Linux ARM64** builds into the folder `WhiteRecomp-linux-arm64` beside the launcher. Copy that folder to the ARM64 computer, put (or link) your `FINAL FANTASY XIII` folder inside it, and run `./WhiteRecomp` there. Its `README.txt` has the steps. That computer needs Vulkan drivers and SDL2 (e.g. `sudo apt install libsdl2-2.0-0 mesa-vulkan-drivers`). Convert the cutscenes on a Windows PC first: they travel with the game folder.
- **As AppImage** (Linux targets: the switch above the Build button). When it's on, the Linux build is one file, `WhiteRecomp-aarch64.AppImage`, in that folder (with a `README.txt`) instead of the program, its `.cfg` and `cdrive`. Copy the AppImage to the other computer, put (or link) your `FINAL FANTASY XIII` folder next to it, `chmod +x` it and run it. Saves go in `cdrive/` next to the AppImage. It needs FUSE there to open (`sudo apt install libfuse2`, or `libfuse2t64`), or start it with `--appimage-extract-and-run`. It's compressed when this computer has `mksquashfs` (squashfs-tools; Linux and macOS), else packed uncompressed (the Windows launcher always does that).
- **Build for Android ARM64** makes `WhiteRecomp.apk` in the folder `WhiteRecomp-android-arm64` beside the launcher. No Android SDK or Java is needed: the launcher writes and signs the APK itself, with a key it makes the first time (`android_key.bin` and `android_cert.der` in its data folder; keep them, since Android installs an update over the app only when it's signed by the same key). Install the APK on the device, copy your `FINAL FANTASY XIII` folder to the device's internal storage or to the top of a microSD card (the game looks on every card and USB drive; anywhere else, put the folder's full path, e.g. `/storage/1234-ABCD/Games/FINAL FANTASY XIII`, in `Android/data/com.whiterecomp.ff13/files/game_dir.txt`), start the app and allow access to your files. The folder's `README.txt` has the steps. Cutscenes play through Android's own video decoder (convert the movies on a PC first, with Convert Movies: the `.mp4` files go with the game folder). Copying the `.mp4` files without the large `.wmp` movie files works too, and so does a folder with its `.wmp` files whole and no `.mp4` files (the game then plays the `.wmp` files itself). It has **on-screen touch controls**: A, B, **0** (pause: the controller's Start) and **1** (select / skip: Back), and two analog sticks. Put a finger down anywhere else on the left half of the screen and a stick appears there, a ring with a knob that follows your finger: that's the left stick (moving). Do the same on the right half for the right stick (the camera). The controls hide as soon as you use a game controller and come back when you touch the screen. `XRC_TOUCH=0` in the device's `ff13.cfg` turns them off (a touch is then the mouse). A game controller, or a keyboard and mouse, work too. The APK is built with the Options tab's options as set, packed in it. **Use Android Preset** (on the Cross-Compile tab, with Android ARM64 chosen) sets them for a phone: 960x540, 60 fps, 512 shadows (the lowest that keeps them), anti-aliasing off, effects at half resolution, 4 GB of memory, optimization level -O1 and 2 Pipeline Build Threads; sound, cutscenes and the rest stay as they are. These become the Options tab's settings, so a Build for your PC uses them too until you change them back; an `ff13.cfg` in `Android/data/com.whiterecomp.ff13/files` on the device overrides them.

## Features & Mods

Options that change what the game plays. They go into the built game's settings, so they apply the next time you start the game, with no rebuild.

### Language

- **Voice:** **English** (the default) or **Japanese**, cutscenes included. Both voice sets come with the game. Convert Movies converts both cutscene sets, so either plays.
- **Subtitles & UI:** **English** (the default), **Japanese**, **French**, **German**, **Italian** or **Spanish**: subtitles, menus and all other text. Every one of them is in the game's files; the PC release only lets you pick some of them (Japanese text is not offered at all), the port lets you pick any. Any voice works with any text language. With the Asian (JP) edition of the game, **Korean** and **Traditional Chinese** are offered too (only that edition has their text).

These replace the language you chose for the game in Steam.

### Cutscenes

- **Cutscene Colors:** **Corrected** (the default) or **Original**. FINAL FANTASY XIII's cutscenes are encoded in full color range, but the PC release shows them as if they were limited range, which crushes dark scenes to black and blows out bright ones. **Corrected** shows them as encoded, keeping the detail in shadows and highlights. **Original** gives the PC release's look. With **Cutscene Files** set to MP4 the cutscenes already had the corrected colors; with Bink2 they had the PC release's look until now.
- **Brightness**, **Contrast** and **Saturation:** sliders for the cutscenes' picture, in percent; 100% leaves it as it is (**Reset** puts a slider back). Brightness goes from 50% to 150% (black stays black), Contrast from 50% to 150% (around mid-gray), and Saturation from 0% (black and white) to 200%. They apply to both MP4 and Bink2 cutscenes, and need no rebuild.

The idea comes from the L'Cienema mod by cyanea-bt. The port does it its own way (in the game's movie shader) and uses none of the mod's files.

### Save Folders

More folders to look for saves in, each time the game starts: the `.dat` save files directly in each folder (not its subfolders) are copied in when they are newer than yours, as Steam's are (see Steam Cloud saves). **Add Folder…** adds one; each has a remove button.

If the game's own save folder can't be used (it can't be opened or written, or a save can't be copied into it), the game reads each save where it was found instead: the newest copy of each, from Steam's folders, these folders and the original game's folder (any that don't exist are skipped). New saves then go into the original game's save folder (`%LOCALAPPDATA%\SquareEnix\FinalFantasyXIII\save` on Windows), or else the first of these folders that isn't one of Steam's. The game's log says when this happens.

### HD Textures

Two HD mods can be imported, and one switch turns them on or off together: with **HD Textures** on, the game uses every HD pack that is installed (one or both); with it off, the game's own textures. Both go in `white_data_hd`, next to the game's `white_data` (or in the launcher's data folder when the game's folder can't be written). Your game files are not changed.

**FF XIII HD Project:** the [FF XIII HD Project](https://www.nexusmods.com/finalfantasy13/mods/17) mod's textures, imported from its ZIP file:

- **Get** opens the mod's page on Nexus Mods to download the ZIP.
- **Import ZIP…** picks the ZIP. The launcher checks it, then runs the mod's own installer steps on copies of the game's archives (the mod's Windows tools; through Wine on Linux and macOS) and puts the results in `white_data_hd`. It takes a while (about half an hour or more), needs about 25 GB free while it runs (the launcher checks before it starts), and keeps about 12 GB. If it stops (an error, Cancel, a crash, a full disk), the next **Import ZIP…** goes on from the files already unpacked: each one is checked against the ZIP and only missing or damaged ones are unpacked again. It is made for the voice language set at the time (English or Japanese voices use different archives).
- **HD Textures On/Off:** off until an HD mod has been imported, on by itself after an import. No rebuild needed.
- **Discard Old Assets** (after a finished import): deletes the mod's ZIP and the game's original archives that the HD copies replace, to free space. HD Textures then stays on, and the original game can't start without those archives: Steam's **Verify integrity of game files** brings them back.

**HD Fonts & GUI:** the [HD Font & GUI](https://www.nexusmods.com/finalfantasy13/mods/67) mod's sharper fonts, menus, cursor and map tiles, imported from its archive (the standalone version's `.rar`, or a `.zip` of its `hd_textures` folder):

- **Get** opens the mod's page on Nexus Mods.
- **Import Archive…** picks the archive and unpacks its `hd_textures` folder (about 3.5 GB) into `white_data_hd`. It takes under a minute. The mod's own `version.dll` isn't used or needed: the port swaps the textures itself, the same way the DLL does (by their contents, as the game loads them). HD Textures turns on by itself after an import.
- Importing the HD Project again keeps this pack.

### Better Button Icons

The [Console Button Prompts](https://www.nexusmods.com/finalfantasy13/mods/60) mod's console-style button icons, picked by what you play with. On the Features & Mods tab, under **Button Icons**:

- **Get** opens the mod's page on Nexus Mods (download its ZIP, v2.0).
- **Import ZIP…** picks the ZIP and takes the two sets of button icons out of it (a few seconds; the game's own files are not changed, and the mod's installer is not run). **Button Icons** turns on by itself.
- In the game, with no controller plugged in, the on-screen prompts show your keyboard's keys. With a PlayStation controller (DualShock, DualSense) they show Cross, Circle, Square and Triangle; with any other controller, the Xbox 360 buttons. Plugging a controller in or out switches them within a couple of seconds, and the game's **On-Screen Button Explanations** setting follows by itself.

### Boosters

For a quicker or easier playthrough. Turn on **Boosters** on the Features & Mods tab, and in the game the keys F1 to F4 and F8 switch each booster on and off. Each one starts off, and any of them can be switched back off at any time. When you press a key, the boosters' states show at the top left of the screen for a few seconds. While Boosters is on, F1 to F4 and F8 do nothing else in the game.

- **F1, Game Speed:** 1x, 2x, 4x, 8x, then back to 1x. The game runs that many times as fast: battles, the field and scenes the engine plays. Movies and voices play at their usual speed, and the play time on your save counts real time.
- **F2, Max Stats:** in battle the party has 99,999 HP and 9,999 Strength and Magic. Only the battle's copy changes: the Crystarium and the Status menu show your real stats. Switched off during a battle, the party's real stats come back at once, and their HP keep the same share of the max HP.
- **F3, Max Gil:** 999,999,999 gil to spend. Your own gil is kept meanwhile, along with any gil you earn. Spending is free, and when you switch Max Gil off your own gil comes back. If you save while it is on, the save holds 999,999,999 gil.
- **F4, One-Hit Kills:** any hit defeats the enemy it lands on. An enemy that a scene needs alive still survives with the HP it must keep.
- **F8, Max CP:** every character's CP stays at 999,999, so the Crystarium is free, as far as the story has opened it. Each character's own CP is kept meanwhile, and CP you earn still goes to it. When you switch Max CP off, everyone's own CP comes back. What you bought in the Crystarium stays bought. If you save while it is on, the save holds 999,999 CP.

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

## Thanks

- **[Steamless](https://github.com/atom0s/Steamless)** by atom0s
- **killer-m** (on Nexus Mods), the creator of the FINAL FANTASY XIII Ultrawide Fix. The ultrawide support (21:9, 32:9 and wider) re-implements that mod's patches.
- **Dendonflo** (on Nexus Mods), the creator of the HD Font & GUI mod (with **MorningSpice**), whose textures **HD Fonts & GUI** imports.
- **Krisan Thyme** (on Nexus Mods), the creator of the Console Button Prompts mod (with **Echelo** and **Scarlet Crusade**), whose icons **Better Button Icons** imports.
