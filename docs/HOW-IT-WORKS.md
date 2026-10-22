# How it works

Everything below was found on a MacBook Pro 14" (M5 Pro, macOS 27.2) and a 27" 4K monitor with CrossOver 26.0, Dark Souls II: Scholar of the First Sin and DS2 Lighting Engine 0.9.50.1, in October 2026.

The DS2 Lighting Engine is a `dxgi.dll` in the game folder, built on the ReShade API. It hooks Direct3D 11, replaces the game's shaders and adds its own lighting passes. On Windows you drop it in and play. On a Mac a series of separate problems stood in the way.

## 1. Which DirectX translation layer

CrossOver can translate Direct3D 11 to Metal in three ways. Only one works with the mod:

| Backend | Result |
|---|---|
| D3DMetal (Apple's GPTK 3, and 4.0 beta) | the mod crashes at start (`Assertion failed ... core_result`) when it creates an unordered-access view in a format D3DMetal doesn't support |
| DXVK (Vulkan via MoltenVK) | completely black screen |
| **DXMT** | works, after the patch below |

The installer sets `"CX_GRAPHICS_BACKEND" = "dxmt"` in the bottle's `cxbottle.conf`, the same setting as *Graphics backend* in the bottle's advanced settings in CrossOver.

## 2. The patched d3d11.dll

With DXMT the menus and HUD showed, but the 3D world was black. DXMT's log had one line repeated every frame:

```
OMSetRenderTargets: invalid render targets
```

DXMT's `ValidateSetRenderTargets` (in `src/d3d11/d3d11_context_impl.cpp`) rejects the call when the depth-stencil view is smaller than a render target, and then nothing is bound at all. The mod binds such pairs. Microsoft's documentation says the sizes should match, so strictly the mod is out of spec, but Windows drivers draw it anyway. DXMT already computes the smaller of the two sizes right after the check, so dropping the check makes it render into the overlapping area.

The installer copies CrossOver's own `lib/dxmt/x86_64-windows/d3d11.dll` and replaces both size comparisons with no-ops. They are found by this byte pattern, which occurs once in `OMSetRenderTargets` and once in `OMSetRenderTargetsAndUnorderedAccessViews`:

```
8B 48 0C              mov  ecx, [rax+0Ch]     ; render target width
39 CD                 cmp  ebp, ecx
0F 82 ?? ?? 00 00     jb   invalid            ; -> 66 0F 1F 44 00 00 (6-byte nop)
8B 40 10              mov  eax, [rax+10h]     ; render target height
41 39 C4              cmp  r12d, eax
0F 82 ?? ?? 00 00     jb   invalid            ; -> 66 0F 1F 44 00 00
```

In CrossOver 26.0 (DXMT `v0.72-25-gf35d839`) these are at file offsets `0xE9188`, `0xE9194`, `0xF7578` and `0xF7584`. The installer also zeroes the 16-byte `Wine builtin DLL` marker at offset `0x40`, so Wine treats the copy as a native DLL.

The copy goes into the bottle's `C:\windows\system32\d3d11.dll`, with the override `d3d11=native,builtin` for `DarkSoulsII.exe`. It has to be `system32`: the mod's ReShade hooks only `C:\windows\system32\d3d11.dll`, and a DLL in the game folder is ignored. CrossOver.app itself can't be modified, because macOS App Management protects it. `WINEDLLPATH` and `DllPath` don't override Wine's builtin DLLs.

The patched DLL still talks to CrossOver's own `winemetal`, so it has to come from the same CrossOver version. If CrossOver updates and the game turns black again, run the installer again. If the pattern isn't found any more, the new DXMT was compiled differently. Then look at the same function in that DXMT version, or check whether it has started accepting these targets.

Upstream DXMT still has the check as of October 2026. [dxmt-issue.md](dxmt-issue.md) is a draft report for it. DXMT doesn't accept AI-written pull requests, so a fix has to come from a human.

## 3. A sharp image: Retina mode

By default Wine treats one Windows pixel as one macOS point, so a 2560x1440 game is drawn at 2560x1440 points and blurred. With `HKCU\Software\Wine\Mac Driver\RetinaMode=y` one Windows pixel is half a point, and the picture is pixel-sharp. Wine only reads this value bottle-wide, so a per-game `AppDefaults` key has no effect.

## 4. Filling the screen

This was the hard part.

**The problem.** With Retina mode a 2560x1440 game is a 1280x720-point window. A 14" MacBook Pro's screen is 1512x982 points, so the game covers about 85% of the width. The green button doesn't help: Wine's Mac driver pins the size of a window the game didn't make resizable, so in macOS fullscreen it is just centered on black. MacBook screens have no 16:9 display modes, and in its own fullscreen mode at 3024x1964 the mod draws a 16:9 image at the top with a black band below. The game only accepts window sizes from a fixed list (800x450, 1024x576, 1152x648, 1280x720, 1440x810, 1600x900, 1680x945, 1920x1080, 2048x1152, 2560x1440, 3200x1800, 3840x2160), and only 16:9 works: in its own fullscreen at 2560x1600 the game stretches the picture vertically and cuts off the bottom of the HUD.

**Making the screen smaller instead of the window bigger.** If the screen were about 1280 points wide, the 1280-point window would fill it. Three rules limit how:

- Wine adds a 1-point 3D client edge on each side of the game's window, so the window is 1282 points wide. On the 1280x800 mode the game shrinks its client area to fit and resizes its swap chain to 2556x1440. **Any swap-chain resize after the mod starts crashes the game.** The game also limits its window to the screen's work area, so the menu bar, title bar and Dock have to fit as well.
- **Changing the display mode while the game runs makes it quit.**
- **Wine records the display mode when the bottle's `wineserver` starts** and keeps Retina mode only while the mode stays the same. Any change has to happen before Wine starts and last until it exits.

So the launcher changes the main display before the game starts and holds the change in a helper process (`ds2mac mode`, using `kCGConfigureForAppOnly`) until the bottle's `wineserver` has exited. macOS undoes app-only changes when that process exits, even if it crashes. `ds2mac plan` decides what to switch to, every time the game starts:

| Screen | Display mode | Game | Fills | Input lag |
|---|---|---|---|---|
| 16:9 (tested: 27" 4K monitor) | "looks like 1280x720", exactly 2560x1440 pixels, 60 Hz | its own fullscreen mode at 2560x1440 | the whole screen | lowest: macOS presents a fullscreen game directly |
| anything else (tested: MacBook Pro 14") | "looks like 1280x800", 120 Hz | a 2552x1436 window, put into the game's size list first | 99.8% of the width, 16:9 with thin bars above and below | normal for a window, which is low |

That table is without the mod's flip model. With it (section 5), which the installer turns on, the game always starts windowed and the mod makes the window borderless and as large as the display mode: 2560x1440 on the monitor, 2560x1600 on the MacBook. On the MacBook the game then renders 16:10; the mod scales its HUD to fit (`ModUIScale(1.0, 1.111)` in `DS2LE.log`). The display mode switch is still what sets the size.

**The game's own fullscreen mode** only works when the desktop is exactly the game's size and has a 60 Hz mode of that size. On the 4K monitor at its usual "looks like 2560x1440" (5120x2880 pixels), Wine gave the game the full 5120x2880, which ran at 22 fps with ghosting and heavy lag. At "looks like 1280x720" there's nothing to change: 2560x1440 game pixels map 1:1 to the desktop. Without a 60 Hz mode of its size (for example on a 120 Hz-only virtual display) the game falls back to 1280x720. The launcher switches `FullScreen` in `GraphicsConfig_SOFS.xml` on or off before each start, to match.

**The window on a MacBook.** For every HiDPI mode of the screen, `ds2mac plan` takes the widest 16:9 window that fits: 2 points narrower than the mode for Wine's client edge, and short enough for the title bar, the menu bar and the Dock, because the game shrinks itself to the work area. It keeps the window within 3% of the chosen render size, so sharpness and frame rate stay the same, and picks the mode where the window covers the most of the width. On a 14" MacBook Pro with the Dock hidden that's "looks like 1280x800" with a 1276x718-point window (2552x1436 pixels). With the Dock always visible the window has to be shorter, so it covers a few percent less of the width (by the formula, about 97% with a standard-size Dock; not tested).

If no mode fits at all, for example on a monitor that offers no HiDPI modes, the launcher falls back to the virtual display described below. In the window case it prefers a 120 Hz or 60 Hz mode, which pace the game's 60 fps evenly.

**The game's size list.** Dark Souls II only accepts window sizes from twelve int32 width/height pairs in `DarkSoulsII.exe`'s data section (file offset `0x157BB50` in the build used here). `ds2mac res-table` finds the list by its fixed entries and replaces one of the rarely used ones with the new size, keeping the list sorted: 2048x1152 for sizes between 1920 and 2560 wide. It's 8 bytes, done before each start because a Steam update or file check puts the original back, and undone by `uninstall.sh` (`res-table --restore`). If the list can't be found, the launcher falls back to the standard 2560x1440 window in the narrowest mode it fits, 1352x845 on a 14" MacBook Pro: about 94% of the width with the flip model off; with it, the mod fills that whole mode (2704x1690 pixels, a little slower). The Lighting Engine works at 2552x1436 without problems; it only crashes if the size changes after it has started.

**Earlier attempts.** The first version mirrored the screen to a virtual display a few points wider than the window (`STRETCH=mirror`, still available). It fills the full width on any screen, but clearly adds input lag, and on an external monitor the monitor receives a non-native signal and looks soft. The second used the narrowest mode the standard 2560x1440 window fits in (95% of a MacBook's width, 85% of a 16:9 monitor's): no extra lag, but the bars at the sides were too much on a 14" screen.

**The virtual display** (`STRETCH=mirror`) uses the private `CGVirtualDisplay` API, the same one BetterDisplay and DeskPad use. `ds2mac display-size` computes a size from the window, the screen's aspect ratio below the notch and the Dock (1284x798 points on a 14" MacBook Pro), and `ds2mac stretch` creates it, mirrors the main display to it with `CGConfigureDisplayMirrorOfDisplay`, and switches it to its HiDPI mode. Details that each took a while to find:

- The virtual display has to be created before any other CoreGraphics display call in the process. CG caches the display list on first use, and a display added later has no modes. That's why `display-size` and `stretch` run as separate processes.
- `sizeInMillimeters` must be whole millimetres, or the display gets no modes.
- With `hiDPI = 1` the mode is given in points and `maxPixels` is twice that.
- Mirroring picks the 1x mode. Setting the HiDPI mode before mirroring fails with error 1001, so it has to come after.
- Its refresh rate must match the real screen. A 120 Hz virtual display on a 60 Hz monitor made frame pacing uneven.

Also: Dark Souls II doesn't continue past its 1280x720 startup window until that window has focus.

## 5. Upscaling: the flip model and MetalFX

The Lighting Engine's upscaling (FSR 3 and DLSS, `amd_fsr_quality` and `nvidia_dlss_quality` in `ds2le_user_settings.ini`) only takes effect with its *flip model* swap chain, `enable_flip_model_swapchain=1`, which is also the mod's default when the file doesn't say otherwise. Without it, FSR runs as antialiasing at full resolution and DLSS as DLAA.

The flip model doesn't create a second swap chain. The mod rewrites the game's own `CreateSwapChain` description (flip-discard, a frame-latency waitable object, 3 buffers, the size of the monitor), forces every `ResizeBuffers` to the monitor size, turns the game's `SetFullscreenState(TRUE)` into `FALSE`, restyles the window to a borderless popup the size of the monitor, and reports the smaller render size to the game through hooked `GetDesc`/`GetClientRect`.

The first test of it hung on a black screen. That test also had the game's own fullscreen turned on, as the launcher did then on a 16:9 monitor. With the game windowed, the flip model works under DXMT on both the MacBook and the monitor, with FSR (Quality and Performance tried) and with DLSS. So the launcher reads the mod's setting and, with the flip model, always starts the game windowed.

DLSS works because DXMT has an NVIDIA extension shim (NVEXT, enabled with `DXMT_ENABLE_NVEXT=1` in the bottle's environment) that implements NGX's DLSS feature with Apple's MetalFX temporal scaler. With it DXMT reports an NVIDIA GPU (vendor 0x10DE) to every program in the bottle and writes three NVIDIA values under `HKEY_LOCAL_MACHINE` that it only removes when it runs without NVEXT; `uninstall.sh` deletes them if NVEXT wasn't on before. `DS2LE.log` then says `NVIDIA NGX initialized successfully and dlss feature is available`, and the Metal HUD lists `MetalFX ... Scaling: Temporal` with input and target size. In the mod the quality levels are NGX's: 0 Performance (50%), 1 Balanced (58%), 2 Quality (67%), 3 Ultra Performance (33%), 4 Ultra Quality (77%), 5 DLAA.

On the M5 Pro the frame rate didn't change with upscaling, not even at 1280x800: the cap was the game's frame limiter (section 7). GPU time at DLSS Quality was 8.5 ms per frame, so upscaling leaves a lot of headroom, which is what smaller GPUs need.

DXMT logs one `Failed to create PSO: Fragment input(s) user(texcoords0) mismatching vertex shader output` with the flip model; nothing visible was missing. With MSAA and DLSS the mod logs `Error while trying to resolve msaa Lighting buffer`; it still looked right.

## 6. Input lag

Beyond the display method, two things decide how responsive the game feels:

- **GPU headroom.** DXMT lets the game queue up to 3 frames (its device-level maximum frame latency, hard-coded like the D3D11 default; `src/dxmt/dxmt_command_queue.hpp`; the mod sets 2). When the GPU can't hold 60 fps, the queue stays full and every frame in it is about 17-18 ms more lag, so lowering the mod's heaviest effects or its DLSS level makes the game feel more responsive, not only smoother.
- **The controller.** macOS Game Mode doubles the Bluetooth polling rate, but it only turns on for apps marked as games in macOS fullscreen, which CrossOver isn't. It can be forced with `gamepolicyctl game-mode set on`, but that tool only comes with the full Xcode. A wired controller avoids the question.

The mod's menu cursor (fn+F1) always trails the macOS cursor a little, on any system: the macOS cursor is drawn by the display hardware, the mod's cursor inside the game's frame.

## 7. A steady 60 FPS: the game's frame limiter

In every configuration the game ran at 54-55 FPS (18.1-18.5 ms per frame): windowed or fullscreen, 60 Hz monitor or 120 Hz MacBook, native resolution or upscaled from 1280x800, MSAA off or 8x. The Metal HUD's frame-interval graph showed why: a flat line at 16.67 ms with a spike to a doubled frame about every 12 frames. GPU time was 8.5 ms (at DLSS Quality), and no thread of the game used a full core (the main thread about 35%).

Dark Souls II paces itself (`DarkSoulsII.exe` 0x140B4A380 in the build used here). It times each frame with `QueryPerformanceCounter`, averages the last three, and if they're under 1/61 s it sleeps the remaining whole milliseconds with `Sleep()`, then spins with `Sleep(0)` up to the deadline. Under Wine on macOS that `Sleep()` wakes about a millisecond late, and because the time spent waiting is left out of the next measurement, the game never makes up for it. 16.7 ms plus about 1.4 ms is the 18.1 ms measured.

The fix changes the multiplier that turns the remaining milliseconds into microseconds for its `Sleep` wrapper from 1000 to 500. The game sleeps half the wait and spins the rest up to the exact deadline:

```
FF 15 ?? ?? ?? ??     call [QueryPerformanceCounter]
69 DB E8 03 00 00     imul ebx, ebx, 1000      ; -> 69 DB F4 01 00 00 (500)
8B CB                 mov  ecx, ebx
E8 ?? ?? ?? ??        call sleep_microseconds
```

With it the Metal HUD shows 60.00 FPS and a flat 16.67 ms line. The main thread goes from about 35% to 50% of a core. Not sleeping at all (only spinning) also gives 60, at about 65%. `ds2mac frame-limiter <exe> on|off` makes the change, the launcher applies it before each start (`FRAME_LIMITER=0` in `config.sh` turns that off), and `uninstall.sh` puts the original bytes back.

Things that were suspected on the way and didn't change the frame rate: DXMT's present pacing (`DXMT_CONFIG=d3d11.preferredMaxFrameRate=240`), the game's per-frame `GetCursorPos` (taken out for a test), DXMT's per-present display query (`WMTQueryDisplaySettingForLayer`, patched out), a window over the game to force compositing, and the wineserver (about 1% CPU). Snapshots taken with `winedbg` kept catching the main thread in `GetCursorPos`; that turned out to be a sampling artifact.

## 8. The white frame

The game window has `WS_EX_CLIENTEDGE`, so Wine draws a sunken 3D border around the picture in the system button colors, light grey and white. Stretched to fullscreen this becomes a bright line around the image. The installer sets `ButtonShadow`, `ButtonDkShadow`, `ButtonLight` and `ButtonHilight` under `HKCU\Control Panel\Colors` to black, so the border disappears into the black background. As a side effect, classic Windows buttons in this bottle have black edges.

## What didn't work

- **D3DMetal 3.0 and GPTK 4.0 beta:** the mod crashes creating a UAV.
- **DXVK:** black screen.
- **The patched d3d11.dll in the game folder:** the mod's hooks don't see it.
- **`WINEDLLPATH` / `DllPath`:** they don't override builtin DLLs.
- **The patched DLL inside CrossOver.app, or inside a copy of it:** macOS blocks it (App Management and quarantine).
- **The game's own fullscreen at 3024x1964:** a 16:9 image at the top, black below.
- **Window sizes 2880x1620 or 3024x1704:** the game doesn't accept them.
- **DXMT's MetalFX swapchain upscaling (`DXMT_METALFX_SPATIAL_SWAPCHAIN`):** the game hangs at the logo, and it only adds sharpness, not size. The mod's DLSS through DXMT's NVEXT is the MetalFX path that works.
- **Changing `contentsScale` in DXMT:** it only zooms inside the same 1280x720-point window.
- **The real 1280x800 display mode with the standard 2560x1440 window:** the window is 2 points too wide, and the game crashes on `ResizeBuffers(2556x1440)`. With a 2552x1436 window it works.
- **The game's own fullscreen on a monitor at "looks like 2560x1440":** 5120x2880 rendering, 22 fps, ghosting, heavy lag. It works at "looks like 1280x720".
- **Changing the display mode while playing:** the game quits.
- **The game's own fullscreen at 2560x1600 on a MacBook:** stretched vertically, the bottom of the HUD cut off.
- **A virtual 16:9 display plus the game's own fullscreen on a MacBook:** full width, but the mirroring adds input lag.
- **The mod's flip model together with the game's own fullscreen:** black screen, the game hangs. Windowed, the flip model works (section 5).

Ideas that were found but not tried: Wine's `EmulateModeset` with the game's own fullscreen, `LogPixels`/DPI scaling, macOS Accessibility Zoom, window upscalers based on ScreenCaptureKit, and lowering DXMT's frame queue with another patch to its `d3d11.dll`.
