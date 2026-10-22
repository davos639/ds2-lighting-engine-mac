# DS2 Lighting Engine on Mac

Play **Dark Souls II: Scholar of the First Sin** with the **[DS2 Lighting Engine](https://www.nexusmods.com/darksouls2/mods/1146)** mod on an Apple Silicon Mac, through CrossOver, big and sharp.

One Terminal command sets up your CrossOver bottle and adds a **DS2 Lighting Engine** app that starts the game full screen, on a 16:9 monitor and on a MacBook. It also turns on the mod's upscaling, which goes to Apple's MetalFX here and should let smaller Macs run it too (not tested yet), and fixes the game's frame limiter, which holds 54-55 FPS under Wine instead of 60.

> **This project is unofficial and not maintained.** It isn't made or supported by the mod's author, Ganaboy, so please don't ask them about it. I made it for myself and I'm sharing it as is. I won't answer issues or keep it up to date with new versions of macOS, CrossOver or the mod. If it breaks for you, fork it and fix it. Everything that was learned along the way is in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## What you need

| | Tested with |
|---|---|
| A Mac with Apple Silicon (M1 or newer), macOS 14 or newer | MacBook Pro 14" M5 Pro, macOS 27.2 |
| [CrossOver](https://www.codeweavers.com/crossover) 26 or newer (paid, 14-day free trial) | CrossOver 26.0 |
| Dark Souls II: Scholar of the First Sin (Steam), installed in a CrossOver bottle | |
| DS2 Lighting Engine by Ganaboy, downloaded by you from Nexus Mods | 0.9.50.1 (the regular version, not Path Tracing) |

Intel Macs are not supported. The original 32-bit Dark Souls II (not Scholar of the First Sin) is not supported by the mod.

## Install

1. **Get the game running in CrossOver.** CrossOver keeps each Windows program in a *bottle*, a separate Windows setup with its own settings. Install Steam in CrossOver (it creates a bottle for it), install Dark Souls II: Scholar of the First Sin in that Steam, start it once and quit.
2. **Download the mod.** On the [Nexus page](https://www.nexusmods.com/darksouls2/mods/1146) (you need a free Nexus account), open *Files* and download the main file with *Manual download*: the regular version, not the Path Tracing one. You don't need to unpack it.
3. **Run the installer.** Quit Steam in CrossOver (Steam menu > Exit, not just closing its window). Open the Terminal app (in Applications > Utilities, or press Cmd+Space and type Terminal), paste this and press Return:

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/davos639/ds2-lighting-engine-mac/main/install.sh)"
   ```

   It finds CrossOver and the game. When asked, drag the downloaded mod archive (or the folder your browser unpacked it to) into the Terminal window and press Enter, then pick the resolution. If macOS asks whether Terminal may access your Downloads folder, allow it.
4. **Play.** Always start the game with **DS2 Lighting Engine** from Applications (or Spotlight), not from Steam or CrossOver. If the game is in Steam, the app opens Steam itself (sign in if it asks) and closes it after the game. Click the game when it appears: it doesn't load until its window is active. It then fills the screen by itself.

   On the first start macOS asks whether DS2 Lighting Engine may use the microphone. That's Wine opening the sound devices; the game doesn't use the microphone, so *Don't Allow* is fine.

To pass options, such as `--upscaling off` or `--resolution 1920x1080`, add them after a `_`: `/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/davos639/ds2-lighting-engine-mac/main/install.sh)" _ --upscaling off`. With `_ --help` it lists all options and changes nothing.

If you'd rather not run a script straight from the internet, download this repository (*Code → Download ZIP*) and read `install.sh`. Then in Terminal type `bash ` (with a space after it), drag `install.sh` from the unpacked folder into the window, add `--build-from-source` and any other options, and press Return. That compiles the helper from `src/` instead of using the prebuilt `bin/ds2mac` (it needs the Xcode Command Line Tools). The installer removes macOS's download quarantine from the folder so the helper can run.

### Play offline

Dark Souls II can soft-ban players whose game it thinks is modified, and nobody can promise that the Lighting Engine or this project's changes to `DarkSoulsII.exe` go unnoticed. Both stay in place after you quit, also when you start the game from Steam in this bottle, until you run the uninstaller and let it remove the mod files. So set the game to start offline in its network settings and play offline, at your own risk.

### Resolution

The installer offers two render resolutions:

- **2560x1440** for Pro and Max chips. This is what was tested.
- **1920x1080** for base M-series chips and MacBook Airs. The Lighting Engine is heavy.

To change it later, run the installer again.

### Upscaling (MetalFX)

The Lighting Engine can render the game smaller and scale it up with DLSS or FSR. On a Mac, DXMT hands DLSS to Apple's **MetalFX** temporal upscaler, so it works on any Apple Silicon Mac. The installer turns it on:

- the mod's *flip model* swap chain, which its upscaling needs. The mod then makes the game window borderless and as large as the screen; on a MacBook that's the whole 16:10 screen, with the mod scaling its HUD to fit.
- DLSS, at *Ultra Quality* (77% of the resolution) with 30 or more GPU cores, *Quality* (67%) with 14 or more, *Balanced* (58%) below that
- `DXMT_ENABLE_NVEXT=1` in the bottle, DXMT's switch for DLSS. Like the DXMT backend it applies to the whole bottle: other games in it see an NVIDIA GPU.

To change it, press F1 in the game (fn+F1 on a Mac keyboard), *User settings*, and press *Save*. FSR (the mod's other upscaler) works too. To keep the mod's own settings, run the installer with `--upscaling off`.

On the M5 Pro this was tested on, upscaling didn't raise the frame rate (the game's own frame limiter was the cap, see below), but it leaves the GPU plenty of headroom: 8.5 ms per frame at DLSS Quality. Base M-series chips have half the GPU cores or fewer, and that's where it should make the difference. That hasn't been tried.

### 60 FPS

Dark Souls II caps itself at 60 FPS by sleeping out the rest of each frame. Under Wine on macOS that sleep wakes a little late and the game doesn't make up for it, so it runs at 54-55 FPS with a doubled frame about every 12 frames, whatever the graphics settings. The launcher changes one number in `DarkSoulsII.exe` so the game sleeps half of the wait and spins the rest: a steady 60. It costs a little CPU (the game's main thread goes from about 35% to 50% of a core). To turn it off, set `FRAME_LIMITER=0` in `~/Library/Application Support/ds2le-mac/config.sh`.

## What it changes

Everything is backed up to `~/Library/Application Support/ds2le-mac/backup/` before it's changed (for `DarkSoulsII.exe`, the changed bytes, not the whole file).

| What | Change | Why |
|---|---|---|
| Bottle graphics backend | DXMT | D3DMetal crashes the mod and DXVK gives a black screen |
| Bottle environment `DXMT_ENABLE_NVEXT` | `1` | DXMT's DLSS support, which uses MetalFX |
| `C:\windows\system32\d3d11.dll` in the bottle | a patched copy of CrossOver's own DXMT `d3d11.dll` | DXMT refuses the mod's depth buffer, so the 3D world is black |
| `HKCU\Software\Wine\AppDefaults\DarkSoulsII.exe\DllOverrides` | `d3d11`, `dxgi` = `native,builtin` | load the mod and the patched DLL |
| `HKCU\Software\Wine\Mac Driver\RetinaMode` | `y` | sharp image. This applies to the whole bottle, so other games in it get smaller, sharper windows too |
| `HKCU\Control Panel\Colors` (4 button colors) | black | removes a white frame Wine draws around the picture |
| `GraphicsConfig_SOFS.xml` | resolution and window mode, set before each start; game's own antialiasing off | a window the mod makes full screen (or the game's own fullscreen on 16:9 screens with the flip model off); the mod has its own antialiasing |
| `DarkSoulsII.exe`, on screens without 16:9 modes | one rarely used entry in the game's list of window sizes (usually 2048x1152) replaced, before each start | the game only accepts window sizes from that list; a MacBook needs one that matches its screen. Steam's *Verify integrity of game files* also puts it back |
| `DarkSoulsII.exe` | 2 bytes of its frame limiter, before each start | a steady 60 FPS instead of 54-55 (see above) |
| `ds2le_user_settings.ini` (the mod's settings) | `enable_flip_model_swapchain=1`, `antialiasing_method=2` (DLSS), `nvidia_dlss_quality` | upscaling; only these three, on the first install or with `--upscaling dlss`. If you install the mod with the installer and already have this file, yours is kept. `uninstall.sh` puts back the values they had |
| Game folder | the mod's files, if you gave the installer the archive | |
| Applications | **DS2 Lighting Engine.app** | the launcher |
| Your display, only while the game runs | a lower "looks like" resolution | makes the game big; macOS switches it back when the game exits |

Nothing from the game, the mod or CrossOver is included in this repository. The installer patches your own copy of CrossOver's DXMT, and CrossOver.app itself is never modified.

## Uninstall

```bash
"$HOME/Library/Application Support/ds2le-mac/uninstall.sh"
```

It restores everything from the backups and asks whether to remove the mod files too.

## Troubleshooting

The launcher writes a log to `~/Library/Application Support/ds2le-mac/launch.log`.

- **The game is slow or laggy at full screen, or (with the flip model off) in a small window.** The display mode wasn't changed: something was still running in the bottle when you started the game, for example the Steam client, or you started the game from Steam or CrossOver. Without the change the mod renders at the screen's full Retina resolution, which is much heavier. Quit everything, wait a minute, start it with DS2 Lighting Engine. `launch.log` says which display mode and window size were used.
- **The game sits at a small window, or a black screen, and doesn't load.** Dark Souls II waits until its window is active. Click it, or switch to it with Cmd+Tab. A black screen that stays also happens when the mod's flip model meets the game's own fullscreen mode, for example after starting the game from Steam with fullscreen turned on in its options. The launcher always starts it windowed.
- **Thin white lines at the right and bottom edge.** Wine paints the window before the game's first frame. They usually go away by themselves; if not, switch to another window and back.
- **Black 3D world, only the menus and HUD visible.** CrossOver was probably updated and replaced DXMT. Run the installer again. If it says this DXMT can't be patched, the new DXMT build differs from the one this was made for, see [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md#2-the-patched-d3d11dll).
- **The game quits by itself.** Don't change display settings or plug in a display while the game runs. Any change of the game's buffer size crashes the mod.
- **Grass shimmers.** Press fn+F1 in the game for the mod's menu. Under *Shading/Quality/Performance*, MSAA 2x or 4x smooths the grass a lot, at a cost in fps.
- **Below 60 fps, or the controls feel slow.** When the GPU can't keep up, frames queue up and every queued frame adds about 17 ms of input lag. In the mod's menu (fn+F1, *User settings*), lower the DLSS quality one step, or its heaviest effects: MSAA, global illumination, screen-space reflections, shadow filtering, volumetric fog. Then press *Save*. A wired controller also responds more steadily than Bluetooth.
- **Measuring.** Apple's Metal HUD shows the frame rate, the GPU time per frame and a graph of frame intervals. Add `"MTL_HUD_ENABLED" = "1"` under `[EnvironmentVariables]` in the bottle's `cxbottle.conf` (`~/Library/Application Support/CrossOver/Bottles/<bottle>/cxbottle.conf`) and remove it again afterwards. The mod's own counter is under *Performance stats* in its menu.
- **How the screen is filled.** `STRETCH` in `~/Library/Application Support/ds2le-mac/config.sh`: `1` picks automatically, `mirror` fills the full width of any screen with a virtual display but adds input lag and looks soft on external monitors, `0` doesn't change the display (with the flip model the game then fills the screen at its full resolution, which is slow on Retina screens).
- **External displays.** The launcher uses the main display, the one with the menu bar. Disconnect other displays or don't plug them in while playing. Full screen needs a monitor for which macOS offers HiDPI ("looks like") modes, typically 4K and 5K monitors. On a 1440p or 1080p monitor without them, the launcher falls back to a virtual display (full screen, a bit more input lag), or pick 1920x1080 in the installer.
- **Renamed or deleted the bottle.** Run the uninstaller with `--bottle "NEW NAME"`, or with `--forget` if the bottle is gone.

## Not tested

- **Starting the game through the Steam client.** The launcher starts Steam with `-applaunch 335300` and closes it after the game, because Steam keeps the bottle running. This path hasn't been tested yet.
- **Other Macs and monitors.** Tested on a MacBook Pro 14" (M5 Pro) and a 27" 4K monitor, at 2560x1440 with the Dock hidden. The launcher picks display modes from what your screen offers, so other Macs, a visible Dock and 1920x1080 should work, but they haven't been tried.
- **Other builds of `DarkSoulsII.exe`.** The changes to the window-size list and the frame limiter were tried on one build of the game and haven't been checked against the current Steam build. Both are found by their byte patterns; if your build differs, the launcher notices and leaves that part alone.
- **Upscaling on base M-series chips and MacBook Airs.** Upscaling works on the M5 Pro, but nobody has measured how much it helps on smaller GPUs, so the DLSS levels the installer picks are guesses.
- **A mod download without a settings file.** If the mod's archive has no `ds2le_user_settings.ini`, the installer creates one with only its three settings and the mod uses its defaults for the rest. Install and uninstall were tested that way, but not a game start with such a file.
- **CrossOver versions other than 26.0** and newer versions of the mod.

## How it works

In short:

1. The game runs through DXMT, with a patch to DXMT's render-target check.
2. With Retina mode the game's 2560x1440 picture is a 1280x720-point window, and macOS won't scale a Wine window. So the launcher makes the screen smaller instead, just for the game: on a 16:9 monitor the mode that "looks like" 1280x720, exactly 2560x1440 pixels; on a 14" MacBook Pro "looks like" 1280x800, 2560x1600 pixels. The mod's flip model then makes the game window borderless and as large as the screen.
3. The mod's DLSS goes through DXMT to Apple's MetalFX upscaler.
4. Two bytes in the game's frame limiter turn 54-55 FPS into a steady 60.
5. When the game exits, the helper process exits and macOS switches the display back.

The full story, with every dead end, is in [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md).

## Files

| File | |
|---|---|
| `install.sh`, `uninstall.sh` | set up and undo everything |
| `launcher/ds2le-launch.sh` | what the DS2 Lighting Engine app runs |
| `src/ds2mac.swift`, `src/CGVirtualDisplay.h`, `src/build.sh` | the helper: display modes, the game's window-size list and frame limiter, DXMT patcher, game and mod settings, virtual display |
| `bin/ds2mac` | the helper, built from `src/` with `src/build.sh` (arm64, ad-hoc signed). Run the installer with `--build-from-source` to build it yourself (needs the Xcode Command Line Tools) |
| `docs/dxmt-issue.md` | a draft bug report for DXMT, so this patch might one day be unnecessary |

## Credits

- [DS2 Lighting Engine](https://www.nexusmods.com/darksouls2/mods/1146) by Ganaboy. Not included here; please download it from its page.
- [DXMT](https://github.com/3Shain/dxmt) by Feifan He (3Shain), the Direct3D 11 to Metal layer that CrossOver ships.
- The virtual display trick builds on what others found about the private `CGVirtualDisplay` API, such as [KhaosT/CGVirtualDisplay](https://github.com/KhaosT/CGVirtualDisplay) and [pasky/hidpi-mirror](https://github.com/pasky/hidpi-mirror).
- Built with the help of Claude (Anthropic).

Not affiliated with FromSoftware, Bandai Namco, CodeWeavers, Valve or the mod's author. Dark Souls is a trademark of its owners.

## License

MIT, see [LICENSE](LICENSE). This covers the code in this repository only.
