// ds2mac: the native helper behind install.sh and the launcher.
//
//   ds2mac plan <W>x<H> [--standard]             how to show a game rendering at W x H on the
//                                                main display (see plan below)
//   ds2mac mode <W>x<H>[@Hz] -- command args...  run a command while the main display uses the
//                                                HiDPI mode that looks like W x H points
//   ds2mac res-table <exe> <W>x<H>|--restore|--show|--list "<12 WxH>"   the game's window-size list
//   ds2mac frame-limiter <exe> on|off|--show     the game's 60 FPS limiter: on = steady 60 under Wine
//   ds2mac stretch <W>x<H>[@Hz] -- command args...   run a command while the main display mirrors
//                                                a HiDPI virtual display of W x H points at Hz
//                                                (default 60; see stretch below)
//   ds2mac stretch <W>x<H>[@Hz] --test <seconds> the same without a command, to try it out
//   ds2mac display-size <W>x<H>                  print the virtual display size and refresh rate
//                                                (WxH@Hz) for a game window of W x H points
//                                                (2560x1440 pixels = 1280x720 points)
//   ds2mac patch-d3d11 <in.dll> <out.dll>        write a copy of DXMT's d3d11.dll without the
//                                                render-target size checks
//   ds2mac graphics-config <xml> <W>x<H> [--fullscreen]   set Dark Souls II's resolution, windowed
//                                                (or its own fullscreen), antialiasing off
//   ds2mac exe-arch <file.exe>                   print x64 or x86
//   ds2mac ini <file> <section> <key> [<value>|-]   print, set or remove one key of an ini file
//
// build: see build.sh
import AppKit
import CoreGraphics
import CryptoKit
import Foundation

let version = "1.0.0"
setvbuf(stdout, nil, _IOLBF, 0)

func log(_ s: String) { print("ds2mac: \(s)") }
func fail(_ s: String, code: Int32 = 1) -> Never {
  FileHandle.standardError.write("ds2mac: \(s)\n".data(using: .utf8)!)
  exit(code)
}
func parseSize(_ s: String) -> (Int, Int)? {
  let p = s.lowercased().split(separator: "x").compactMap { Int($0) }
  return p.count == 2 && p[0] > 0 && p[1] > 0 ? (p[0], p[1]) : nil
}
func sha256(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }

// App-only display changes: macOS undoes them when this process exits, even if it crashes.
func configure(_ body: (CGDisplayConfigRef?) -> Void) -> CGError {
  var config: CGDisplayConfigRef?
  guard CGBeginDisplayConfiguration(&config) == .success else { return .failure }
  body(config)
  let err = CGCompleteDisplayConfiguration(config, .forAppOnly)
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 1))
  return err
}

// Keep the display change while the command runs (or for --test seconds), then exit, which undoes it.
func holdWhileRunning(_ args: [String], usage: String, what: String) -> Never {
  // Losing the display change mid-game would turn Wine's Retina scaling off, so ignore hangups.
  // INT and TERM still end cleanly.
  signal(SIGHUP, SIG_IGN)
  for sig in [SIGINT, SIGTERM] { signal(sig) { _ in exit(0) } }
  if args[1] == "--test" {
    Thread.sleep(forTimeInterval: Double(args.count > 2 ? args[2] : "5") ?? 5)
    exit(0)
  }
  guard args[1] == "--", args.count > 2 else { fail(usage, code: 2) }
  let child = Process()
  child.executableURL = URL(fileURLWithPath: args[2])
  child.arguments = Array(args[3...])
  do { try child.run() } catch { fail("could not start \(args[2]): \(error)") }
  child.waitUntilExit()
  log("command finished, \(what)")
  exit(0)
}

// The Dock's size, which Dark Souls II keeps its window clear of: the game shrinks its window to the
// work area, and any buffer resize crashes the Lighting Engine. The Dock may be on another screen now
// but can move to the main one, so take the largest.
func dockInsets() -> (bottom: Int, side: Int) {
  let screens = NSScreen.screens
  let bottom = screens.map { max(0, $0.visibleFrame.minY - $0.frame.minY) }.max() ?? 0
  let side = screens.map { max(0, $0.frame.width - $0.visibleFrame.width) }.max() ?? 0
  return (Int(bottom.rounded(.up)), Int(side.rounded(.up)))
}

// Room a game window of winW x winH points needs: Wine adds a 1pt client edge on each side, and the
// height also needs the title bar and the menu bar.
func neededSize(winW: Int, winH: Int) -> (w: Int, h: Int, dockBottom: Int, dockSide: Int) {
  let dock = dockInsets()
  return (winW + 4 + dock.side, winH + 70 + dock.bottom, dock.bottom, dock.side)
}

func hidpiModes(_ display: CGDirectDisplayID) -> [CGDisplayMode] {
  let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
  return ((CGDisplayCopyAllDisplayModes(display, opts) as? [CGDisplayMode]) ?? []).filter {
    $0.isUsableForDesktopGUI() && $0.pixelWidth == $0.width * 2
  }
}

// MARK: - plan

// How to show the game on the main display, for a render size of 2560x1440 or 1920x1080. Prints
// "fullscreen|window <W>x<H>@<Hz> <renderW>x<renderH>": the display mode to switch to (for mode)
// and the game's resolution.
//  - A 16:9 screen with a HiDPI mode of exactly half the render size: the game's own fullscreen at
//    that size, in a 60 Hz mode (without one the game falls back to 1280x720). Fills the screen and
//    has the lowest input lag. A 4K monitor goes to "looks like 1280x720".
//  - Any other screen, like a MacBook's: the game in a 16:9 window as wide as the screen. For every
//    HiDPI mode this takes the widest window that fits, with the Dock, and picks the mode where the
//    window covers the most of the width. The window stays within 3% of the render size, so the
//    game keeps its sharpness and its frame rate. A
//    MacBook Pro 14" goes to "looks like 1280x800" with a 2552x1436 window, 99.8% of the width. That
//    size isn't in the game's list, so the launcher adds it there with res-table. With --standard
//    the window stays at the render size.
func plan(_ args: [String]) -> Never {
  let usage = "usage: ds2mac plan <W>x<H> [--standard]"
  guard (args.count == 1 || (args.count == 2 && args[1] == "--standard")), let (rw, rh) = parseSize(args[0]) else {
    fail(usage, code: 2)
  }
  let standard = args.count == 2
  let display = CGMainDisplayID()
  guard let current = CGDisplayCopyDisplayMode(display) else { fail("cannot read the display mode") }
  let modes = hidpiModes(display)
  func preferRefresh(_ hz: Double) -> (CGDisplayMode, CGDisplayMode) -> Bool {
    return { a, b in
      let da = abs(a.refreshRate - hz), db = abs(b.refreshRate - hz)
      if abs(da - db) > 0.5 { return da < db }
      return a.refreshRate > b.refreshRate
    }
  }
  let screenAspect = Double(current.width) / Double(current.height)
  if abs(screenAspect - 16.0 / 9.0) < 0.02,
    let m = modes.filter({ $0.width == rw / 2 && $0.height == rh / 2 && abs($0.refreshRate - 60) < 1 })
      .min(by: preferRefresh(60))
  {
    print("fullscreen \(m.width)x\(m.height)@\(Int(m.refreshRate.rounded())) \(rw)x\(rh)")
    exit(0)
  }

  let dock = dockInsets()
  let maxW = standard ? rw / 2 : rw / 2 * 103 / 100
  let minW = standard ? rw / 2 : rw / 2 * 97 / 100
  var best: (mode: CGDisplayMode, w: Int, h: Int, fill: Double)?
  // Wider modes than the current one are fine too: the change only lasts while the game runs.
  for m in modes {
    var w = min(m.width - 4 - dock.side, maxW)
    var h = Int((Double(w) * 9 / 16).rounded())
    let maxH = m.height - 70 - dock.bottom
    if h > maxH {
      h = maxH
      w = Int(Double(h) * 16 / 9)
    }
    w &= ~1
    h = Int((Double(w) * 9 / 16).rounded()) & ~1
    if standard && (w != rw / 2 || h != rh / 2) { continue }
    if w < minW { continue }
    let fill = Double(w + 2) / Double(m.width)
    let better: Bool
    if let b = best {
      if abs(fill - b.fill) > 0.005 {
        better = fill > b.fill
      } else if w != b.w {
        better = w < b.w  // the same coverage for fewer pixels
      } else {
        // A refresh rate that's a multiple of the game's 60 fps paces evenly: 120, then 60.
        func rank(_ x: CGDisplayMode) -> Int { abs(x.refreshRate - 120) < 1 ? 0 : abs(x.refreshRate - 60) < 1 ? 1 : 2 }
        better = rank(m) != rank(b.mode) ? rank(m) < rank(b.mode) : preferRefresh(current.refreshRate)(m, b.mode)
      }
    } else {
      better = true
    }
    if better { best = (m, w, h, fill) }
  }
  guard let b = best else { fail("no display mode fits a \(rw)x\(rh) game window", code: 4) }
  FileHandle.standardError.write(
    ("ds2mac: \(current.width)x\(current.height) -> \(b.mode.width)x\(b.mode.height), window \(b.w)x\(b.h)pt, "
      + "\(Int(b.fill * 1000) / 10)% of the width (dock \(dock.bottom)/\(dock.side))\n").data(using: .utf8)!)
  print("window \(b.mode.width)x\(b.mode.height)@\(Int(b.mode.refreshRate.rounded())) \(b.w * 2)x\(b.h * 2)")
  exit(0)
}

// MARK: - res-table

// Dark Souls II only accepts window sizes from a fixed list in DarkSoulsII.exe's data section, twelve
// int32 width/height pairs: 800x450, 1024x576, 1152x648, 1280x720, 1440x810, 1600x900, 1680x945,
// 1920x1080, 2048x1152, 2560x1440, 3200x1800, 3840x2160 (at file offset 0x157BB50 in the build this
// was made with). To allow another size, one of the less common entries is replaced so the list
// stays sorted: 1152x648, 1440x810, 1680x945, 2048x1152 or 3200x1800, whichever lies between the
// new size's neighbours. The other entries identify the list.
let resolutionTable: [(Int32, Int32)] = [
  (800, 450), (1024, 576), (1152, 648), (1280, 720), (1440, 810), (1600, 900), (1680, 945),
  (1920, 1080), (2048, 1152), (2560, 1440), (3200, 1800), (3840, 2160),
]
let replaceableSlots = [2, 4, 6, 8, 10]

func resTable(_ args: [String]) -> Never {
  let usage = "usage: ds2mac res-table <DarkSoulsII.exe> <W>x<H> | --restore | --show | --list \"<12 WxH>\""
  guard args.count == 2 || (args.count == 3 && args[1] == "--list") else { fail(usage, code: 2) }
  guard let data = FileManager.default.contents(atPath: args[0]) else { fail("cannot read \(args[0])") }
  let bytes = [UInt8](data)
  func pair(_ o: Int) -> (Int32, Int32) {
    func i32(_ p: Int) -> Int32 {
      Int32(bitPattern: UInt32(bytes[p]) | UInt32(bytes[p + 1]) << 8 | UInt32(bytes[p + 2]) << 16 | UInt32(bytes[p + 3]) << 24)
    }
    return (i32(o), i32(o + 4))
  }
  // Find the list by its fixed entries; the replaceable ones may hold an earlier size.
  let first = [UInt8]([0x20, 0x03, 0, 0, 0xC2, 0x01, 0, 0])  // 800, 450
  var found: [Int] = []
  var i = 0
  while i + 96 <= bytes.count {
    if bytes[i] == first[0] && Array(bytes[i..<(i + 8)]) == first {
      let ok = (0..<12).allSatisfy { k in
        let p = pair(i + 8 * k)
        if replaceableSlots.contains(k) { return p.0 > 0 && p.1 > 0 && p.0 < 8192 && p.1 < 8192 }
        return p == resolutionTable[k]
      }
      if ok { found.append(i) }
    }
    i += 4
  }
  guard found.count == 1, let offset = found.first else {
    fail("the resolution list was not found in \(args[0]) (\(found.count) matches)", code: 4)
  }
  var table = (0..<12).map { pair(offset + 8 * $0) }
  if args[1] == "--show" {
    print(table.map { "\($0.0)x\($0.1)" }.joined(separator: " "))
    exit(0)
  }
  var wanted = resolutionTable
  if args[1] == "--list" {
    let sizes = args[2].split(separator: " ").compactMap { parseSize(String($0)) }
    guard sizes.count == 12 else { fail("--list needs 12 sizes", code: 2) }
    wanted = sizes.map { (Int32($0.0), Int32($0.1)) }
  } else if args[1] != "--restore" {
    guard let (w, h) = parseSize(args[1]) else { fail(usage, code: 2) }
    let size = (Int32(w), Int32(h))
    if !resolutionTable.contains(where: { $0 == size }) {
      guard let k = replaceableSlots.first(where: { resolutionTable[$0 - 1].0 < size.0 && size.0 < resolutionTable[$0 + 1].0 })
      else { fail("\(w)x\(h) can't be added to the list", code: 2) }
      wanted[k] = size
    }
  }
  if (0..<12).allSatisfy({ table[$0] == wanted[$0] }) {
    log("resolution list already right at 0x\(String(offset, radix: 16, uppercase: true))")
    exit(0)
  }
  guard let fh = FileHandle(forUpdatingAtPath: args[0]) else { fail("cannot write \(args[0])") }
  var out = Data()
  for (w, h) in wanted {
    for v in [w, h] { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
  }
  do {
    try fh.seek(toOffset: UInt64(offset))
    try fh.write(contentsOf: out)
    try fh.close()
  } catch { fail("cannot write \(args[0]): \(error)") }
  table = wanted
  log("resolution list at 0x\(String(offset, radix: 16, uppercase: true)): "
    + replaceableSlots.map { "\(table[$0].0)x\(table[$0].1)" }.joined(separator: ", "))
  exit(0)
}

// MARK: - frame-limiter

// Dark Souls II caps itself at 60 FPS: it measures each frame with QueryPerformanceCounter, sleeps
// the whole milliseconds that are left with Sleep(), then spins with Sleep(0) up to the deadline.
// Under Wine on macOS that Sleep() often wakes a millisecond or two late and the game never makes up
// for it, so a frame takes about 18 ms: 54-55 FPS, and every 12th frame or so stays on screen for two
// refreshes. Sleeping half of the wait and spinning the rest keeps it at a steady 60:
//   FF 15 ?? ?? ?? ??     call [QueryPerformanceCounter]
//   69 DB E8 03 00 00     imul ebx, ebx, 1000     ; ms -> us for the Sleep(us) wrapper <- 500
//   8B CB                 mov ecx, ebx
//   E8                    call sleep_us
let limiterPattern: [UInt8?] = [0xFF, 0x15, nil, nil, nil, nil, 0x69, 0xDB, nil, nil, 0x00, 0x00, 0x8B, 0xCB, 0xE8]
let limiterOriginal: [UInt8] = [0xE8, 0x03]  // 1000
let limiterHalf: [UInt8] = [0xF4, 0x01]  // 500

func frameLimiter(_ args: [String]) -> Never {
  let usage = "usage: ds2mac frame-limiter <DarkSoulsII.exe> on | off | --show"
  guard args.count == 2, ["on", "off", "--show"].contains(args[1]) else { fail(usage, code: 2) }
  guard let data = FileManager.default.contents(atPath: args[0]) else { fail("cannot read \(args[0])") }
  let bytes = [UInt8](data)
  var found: [Int] = []
  for i in 0..<max(0, bytes.count - limiterPattern.count + 1) where bytes[i] == 0xFF && bytes[i + 6] == 0x69 {
    if limiterPattern.enumerated().allSatisfy({ $0.element == nil || bytes[i + $0.offset] == $0.element! }) {
      let imm = Array(bytes[(i + 8)..<(i + 10)])
      if imm == limiterOriginal || imm == limiterHalf { found.append(i + 8) }
    }
  }
  guard found.count == 1, let at = found.first else {
    fail("the frame limiter was not found in \(args[0]) (\(found.count) matches)", code: 4)
  }
  let half = Array(bytes[at..<(at + 2)]) == limiterHalf
  if args[1] == "--show" {
    print(half ? "on" : "off")
    exit(0)
  }
  if half == (args[1] == "on") {
    log("frame limiter already \(args[1]) at 0x\(String(at, radix: 16, uppercase: true))")
    exit(0)
  }
  guard let fh = FileHandle(forUpdatingAtPath: args[0]) else { fail("cannot write \(args[0])") }
  do {
    try fh.seek(toOffset: UInt64(at))
    try fh.write(contentsOf: Data(args[1] == "on" ? limiterHalf : limiterOriginal))
    try fh.close()
  } catch { fail("cannot write \(args[0]): \(error)") }
  log("frame limiter \(args[1] == "on" ? "sleeps half the wait" : "as shipped") at 0x\(String(at, radix: 16, uppercase: true))")
  exit(0)
}

// MARK: - mode

// Switch the main display to the HiDPI mode that looks like W x H points (2W x 2H pixels) while the
// command runs. With 1280x720 on a 16:9 monitor the desktop is exactly 2560x1440 pixels, so the
// game's own fullscreen mode at 2560x1440 fills the screen without Wine changing any display mode.
func mode(_ args: [String]) -> Never {
  let usage = "usage: ds2mac mode <W>x<H>[@Hz] -- command args... | <W>x<H>[@Hz] --test <seconds> | <W>x<H> --check"
  let spec = args.first?.split(separator: "@").map(String.init) ?? []
  guard args.count >= 2, spec.count <= 2, let (w, h) = parseSize(spec[0]) else { fail(usage, code: 2) }
  // The game's own fullscreen looks for a 60 Hz mode of its size and falls back to 1280x720 if
  // there is none, so prefer the refresh rate closest to 60.
  let hz = spec.count == 2 ? Double(spec[1]) ?? 60 : 60
  let display = CGMainDisplayID()
  guard let current = CGDisplayCopyDisplayMode(display) else { fail("cannot read the display mode") }
  let modes = hidpiModes(display).filter { $0.width == w && $0.height == h }
  let best = modes.min { a, b in
    let da = abs(a.refreshRate - hz), db = abs(b.refreshRate - hz)
    if abs(da - db) > 0.5 { return da < db }
    return a.refreshRate > b.refreshRate
  }
  guard let best = best else { fail("display \(display) has no HiDPI \(w)x\(h) mode", code: 4) }
  if args[1] == "--check" {
    // Only for a screen of the same shape: a 16:10 screen offering a 16:9 mode would stretch it.
    let same = abs(Double(current.width) / Double(current.height) - Double(w) / Double(h)) < 0.02
    if same { print("\(w)x\(h)") }
    exit(same ? 0 : 5)
  }
  if current.width != w || current.height != h || current.pixelWidth != w * 2
    || abs(current.refreshRate - best.refreshRate) > 0.5 {
    let err = configure { CGConfigureDisplayWithDisplayMode($0, display, best, nil) }
    guard err == .success, let now = CGDisplayCopyDisplayMode(display), now.width == w else {
      fail("could not switch to \(w)x\(h) (CGError \(err.rawValue))")
    }
  }
  log("display \(display): \(current.width)x\(current.height) -> \(w)x\(h)pt HiDPI \(Int(best.refreshRate)) Hz")
  holdWhileRunning(args, usage: usage, what: "restoring the display mode")
}

// MARK: - stretch

// Wine draws the game window at a fixed size in points: with RetinaMode a 2560x1440 game is a
// 1280x720pt window, and macOS fullscreen only centers it. So instead of scaling the window we make
// the screen smaller: a virtual HiDPI display barely wider than the window, mirrored by the real
// screen, which macOS scales up to fill. The virtual display and the mirroring belong to this
// process (private CGVirtualDisplay API, kCGConfigureForAppOnly) and vanish when it exits, even if
// it crashes.
func stretch(_ args: [String]) -> Never {
  let usage = "usage: ds2mac stretch <W>x<H>[@Hz] -- command args... | <W>x<H>[@Hz] --test <seconds>"
  let spec = args.first?.split(separator: "@").map(String.init) ?? []
  guard args.count >= 2, spec.count <= 2, let (ptW, ptH) = parseSize(spec[0]) else { fail(usage, code: 2) }
  let hz = spec.count == 2 ? Double(spec[1]) ?? 60 : 60

  // Create the virtual display before any other CoreGraphics display call: CG caches the display
  // list on first use, and a display added later then has no modes in this process.
  let desc = CGVirtualDisplayDescriptor()
  desc.queue = DispatchQueue.main
  desc.name = "DS2 Screen"
  desc.maxPixelsWide = UInt32(ptW * 2)
  desc.maxPixelsHigh = UInt32(ptH * 2)
  // Whole millimetres at roughly a MacBook panel's density; fractional sizes leave the display
  // without modes.
  desc.sizeInMillimeters = CGSize(
    width: (Double(ptW) * 0.2352).rounded(), height: (Double(ptH) * 0.2352).rounded())
  desc.vendorID = 0xD52
  desc.productID = 0x0002
  desc.serialNum = 0x0001
  let virtual = CGVirtualDisplay(descriptor: desc)
  let settings = CGVirtualDisplaySettings()
  settings.hiDPI = 1
  // With hiDPI the mode is given in points and rendered at 2x. The refresh rate should match the
  // mirroring screen; a 120 Hz virtual display on a 60 Hz monitor makes frame pacing uneven.
  settings.modes = [CGVirtualDisplayMode(width: UInt(ptW), height: UInt(ptH), refreshRate: hz)]
  guard virtual.apply(settings) else { fail("could not create the virtual display") }
  let vid = virtual.displayID
  RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))

  // Mirror the main display, the one with the menu bar, where the game window opens.
  var online = [CGDirectDisplayID](repeating: 0, count: 16)
  var onlineCount: UInt32 = 0
  CGGetOnlineDisplayList(16, &online, &onlineCount)
  let others = online.prefix(Int(onlineCount)).filter { $0 != vid }
  let main = CGMainDisplayID()
  guard let target = main != vid && others.contains(main) ? main : others.first
  else { fail("no screen to mirror") }

  func hidpiModes() -> [CGDisplayMode] {
    let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
    return ((CGDisplayCopyAllDisplayModes(vid, opts) as? [CGDisplayMode]) ?? [])
      .filter { $0.width == ptW && $0.height == ptH && $0.pixelWidth == ptW * 2 }
  }
  func isHiDPI() -> Bool {
    guard let m = CGDisplayCopyDisplayMode(vid) else { return false }
    return m.width == ptW && m.pixelWidth == ptW * 2
  }
  for _ in 0..<50 where hidpiModes().isEmpty {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
  }
  guard !hidpiModes().isEmpty else { fail("the virtual display has no HiDPI \(ptW)x\(ptH) mode") }

  let mirrored = configure { CGConfigureDisplayMirrorOfDisplay($0, target, vid) }
  guard mirrored == .success else { fail("mirroring failed (CGError \(mirrored.rawValue))") }
  // Mirroring selects the 1x mode. Switch to the HiDPI one, trying every duplicate because some of
  // them cannot be set.
  for m in hidpiModes() where !isHiDPI() {
    _ = configure { CGConfigureDisplayWithDisplayMode($0, vid, m, nil) }
  }
  guard isHiDPI() else { fail("could not switch the virtual display to HiDPI \(ptW)x\(ptH)") }
  log("display \(target) mirrors virtual display \(vid), \(ptW)x\(ptH)pt HiDPI \(Int(hz)) Hz")
  holdWhileRunning(args, usage: usage, what: "removing the virtual display")
}

// MARK: - display-size

// Size of the virtual display for stretch, for a game window of winW x winH points: as narrow as
// possible so the window fills the screen's width, with the aspect ratio of the screen below the
// notch so nothing is cut off, and with room for the window (see neededSize).
func displaySize(_ args: [String]) -> Never {
  guard args.count == 1, let (winW, winH) = parseSize(args[0]) else {
    fail("usage: ds2mac display-size <W>x<H>", code: 2)
  }
  // The first screen is the main display, the one stretch mirrors.
  guard let screen = NSScreen.screens.first else { fail("no screen found") }
  let frame = screen.frame
  let notch = screen.safeAreaInsets.top
  let need = neededSize(winW: winW, winH: winH)
  let hz = max(30, min(120, screen.maximumFramesPerSecond))
  let aspect = frame.width / (frame.height - notch)

  let minW = need.w, minH = need.h
  var w = minW
  // 1% narrower than the screen's aspect so rounding never leaves bars at the sides.
  var h = Int((Double(w) / aspect * 0.99).rounded(.down)) & ~1
  if h < minH {
    h = minH + (minH & 1)
    w = Int((Double(h) * aspect / 0.99).rounded(.up))
    w += w & 1
  }
  FileHandle.standardError.write(
    ("ds2mac: screen \(Int(frame.width))x\(Int(frame.height))pt, notch \(Int(notch))pt, "
      + "dock bottom \(need.dockBottom)pt side \(need.dockSide)pt, \(hz) Hz -> \(w)x\(h)pt\n").data(using: .utf8)!)
  print("\(w)x\(h)@\(hz)")
  exit(0)
}

// MARK: - patch-d3d11

// DXMT's OMSetRenderTargets refuses render target and depth-stencil views of different sizes
// (ValidateSetRenderTargets). The Lighting Engine binds such pairs, so the whole 3D scene stays
// black. Both size comparisons are found by their byte pattern, in OMSetRenderTargets and in
// OMSetRenderTargetsAndUnorderedAccessViews:
//   8B 48 0C        mov ecx, [rax+0Ch]     ; RTV width
//   39 CD           cmp ebp, ecx
//   0F 82 ?? ?? 00 00  jb invalid          ; <- NOP
//   8B 40 10        mov eax, [rax+10h]     ; RTV height
//   41 39 C4        cmp r12d, eax
//   0F 82 ?? ?? 00 00  jb invalid          ; <- NOP
// After that DXMT already renders into the smaller of the two sizes. The "Wine builtin DLL" marker
// is cleared so Wine loads the copy as a native DLL.
func patchD3D11(_ args: [String]) -> Never {
  guard args.count == 2 else { fail("usage: ds2mac patch-d3d11 <in.dll> <out.dll>", code: 2) }
  guard let input = FileManager.default.contents(atPath: args[0]) else { fail("cannot read \(args[0])") }
  var bytes = [UInt8](input)
  let pattern: [UInt8?] = [
    0x8B, 0x48, 0x0C, 0x39, 0xCD, 0x0F, 0x82, nil, nil, 0x00, 0x00,
    0x8B, 0x40, 0x10, 0x41, 0x39, 0xC4, 0x0F, 0x82, nil, nil, 0x00, 0x00,
  ]
  let jumps = [5, 17]
  let nop6: [UInt8] = [0x66, 0x0F, 0x1F, 0x44, 0x00, 0x00]
  func matches(at i: Int, _ p: [UInt8?]) -> Bool {
    for (j, b) in p.enumerated() where b != nil && bytes[i + j] != b! { return false }
    return true
  }
  var patchedPattern = pattern
  for j in jumps { for k in 0..<6 { patchedPattern[j + k] = nop6[k] } }

  var found: [Int] = []
  var already: [Int] = []
  for i in 0..<max(0, bytes.count - pattern.count + 1) {
    if matches(at: i, pattern) { found.append(i) } else if matches(at: i, patchedPattern) { already.append(i) }
  }
  if found.isEmpty && already.count == 2 { fail("\(args[0]) is already patched", code: 3) }
  guard found.count == 2 else {
    fail("expected 2 render-target size checks in \(args[0]), found \(found.count). "
      + "This DXMT build is not supported", code: 4)
  }
  for i in found { for j in jumps { bytes.replaceSubrange((i + j)..<(i + j + 6), with: nop6) } }

  let marker = Array("Wine builtin DLL".utf8)
  if let m = (0..<min(0x400, bytes.count - marker.count)).first(where: {
    Array(bytes[$0..<($0 + marker.count)]) == marker
  }) {
    bytes.replaceSubrange(m..<(m + marker.count), with: [UInt8](repeating: 0, count: marker.count))
  } else {
    log("note: no \"Wine builtin DLL\" marker found")
  }
  let out = Data(bytes)
  do { try out.write(to: URL(fileURLWithPath: args[1]), options: .atomic) } catch {
    fail("cannot write \(args[1]): \(error)")
  }
  let offsets = found.flatMap { i in jumps.map { String(format: "0x%X", i + $0) } }
  log("patched \(offsets.joined(separator: ", ")); sha256 \(sha256(out))")
  exit(0)
}

// MARK: - graphics-config

// GraphicsConfig_SOFS.xml is UTF-16 with CRLF line endings. Edit it in place in its own encoding,
// or create it from the game's defaults if the game has never been started.
func graphicsConfig(_ args: [String]) -> Never {
  let usage = "usage: ds2mac graphics-config <xml> <W>x<H> [--fullscreen] | <xml> --from <original.xml>"
  if args.count == 3 && args[1] == "--from" { graphicsConfigRestore(args[0], from: args[2]) }
  guard args.count == 2 || (args.count == 3 && args[2] == "--fullscreen"), let (w, h) = parseSize(args[1]) else {
    fail(usage, code: 2)
  }
  let fullscreen = args.count == 3
  let path = args[0]
  var encoding = String.Encoding.utf16LittleEndian
  var bom = Data()
  var text: String
  if let data = FileManager.default.contents(atPath: path) {
    if data.starts(with: [0xFF, 0xFE]) {
      bom = Data([0xFF, 0xFE])
    } else if data.starts(with: [0xFE, 0xFF]) {
      bom = Data([0xFE, 0xFF])
      encoding = .utf16BigEndian
    } else if data.count < 2 || data[data.startIndex + 1] != 0 {
      encoding = .utf8
    }
    guard let t = String(data: data.dropFirst(bom.count), encoding: encoding) else {
      fail("cannot decode \(path)")
    }
    text = t
  } else {
    text = [
      "<?xml version=\"1.0\" encoding=\"UTF-16\" ?>",
      "<config><Resolution-WindowScreenWidth>1280</Resolution-WindowScreenWidth>",
      "<Resolution-WindowScreenHeight>720</Resolution-WindowScreenHeight>",
      "<Resolution-FullScreenWidth>1920</Resolution-FullScreenWidth>",
      "<Resolution-FullScreenHeight>1080</Resolution-FullScreenHeight>",
      "<ChangeAllSettings>CUSTOM</ChangeAllSettings>",
      "<TextureQuality>HIGH</TextureQuality>",
      "<ShadowQuality>HIGH</ShadowQuality>",
      "<EffectsQuality>HIGH</EffectsQuality>",
      "<AnisotropicFiltering>HIGH</AnisotropicFiltering>",
      "<WaterSurfaceQuality>HIGH</WaterSurfaceQuality>",
      "<High-qualityCharacterRendering>HIGH</High-qualityCharacterRendering>",
      "<ModelQuality>HIGH</ModelQuality>",
      "<FullScreen>OFF</FullScreen>",
      "<Auto-detectBestRenderingSettings>OFF</Auto-detectBestRenderingSettings>",
      "<Antialiasing>OFF</Antialiasing>",
      "<MotionBlur>ON</MotionBlur>",
      "<CameraMotionBlur>ON</CameraMotionBlur>",
      "<DepthOfField>ON</DepthOfField>",
      "<SSAO>HIGH</SSAO>",
      "</config>",
      "",
    ].joined(separator: "\r\n")
    try? FileManager.default.createDirectory(
      atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    log("\(path) did not exist, creating it")
  }
  func set(_ tag: String, _ value: String) {
    let re = try! NSRegularExpression(pattern: "<\(tag)>[^<]*</\(tag)>")
    let all = NSRange(text.startIndex..., in: text)
    let element = "<\(tag)>\(value)</\(tag)>"
    if re.firstMatch(in: text, range: all) != nil {
      text = re.stringByReplacingMatches(
        in: text, range: all, withTemplate: NSRegularExpression.escapedTemplate(for: element))
    } else if let end = text.range(of: "</config>") {
      text.insert(contentsOf: element + "\r\n", at: end.lowerBound)
    } else {
      fail("\(path) has no <config> element")
    }
  }
  set("Resolution-WindowScreenWidth", String(w))
  set("Resolution-WindowScreenHeight", String(h))
  if fullscreen {
    set("Resolution-FullScreenWidth", String(w))
    set("Resolution-FullScreenHeight", String(h))
  }
  set("FullScreen", fullscreen ? "ON" : "OFF")
  set("Antialiasing", "OFF")
  guard let body = text.data(using: encoding) else { fail("cannot encode \(path)") }
  do { try (bom + body).write(to: URL(fileURLWithPath: path), options: .atomic) } catch {
    fail("cannot write \(path): \(error)")
  }
  log("\(fullscreen ? "fullscreen" : "windowed") \(w)x\(h), antialiasing off")
  exit(0)
}

// The settings graphics-config manages, put back from a copy of the original file; everything else
// the player changed in the game since stays.
let managedGraphicsTags = [
  "Resolution-WindowScreenWidth", "Resolution-WindowScreenHeight", "Resolution-FullScreenWidth",
  "Resolution-FullScreenHeight", "FullScreen", "Antialiasing",
]
func readUTF16Config(_ path: String) -> (text: String, encoding: String.Encoding, bom: Data)? {
  guard let data = FileManager.default.contents(atPath: path) else { return nil }
  var encoding = String.Encoding.utf16LittleEndian
  var bom = Data()
  if data.starts(with: [0xFF, 0xFE]) {
    bom = Data([0xFF, 0xFE])
  } else if data.starts(with: [0xFE, 0xFF]) {
    bom = Data([0xFE, 0xFF])
    encoding = .utf16BigEndian
  } else if data.count < 2 || data[data.startIndex + 1] != 0 {
    encoding = .utf8
  }
  guard let text = String(data: data.dropFirst(bom.count), encoding: encoding) else { return nil }
  return (text, encoding, bom)
}
func graphicsConfigRestore(_ path: String, from origPath: String) -> Never {
  guard let orig = readUTF16Config(origPath) else { fail("cannot read \(origPath)") }
  guard var cur = readUTF16Config(path) else {
    // Nothing there any more: the original is all there is.
    do { try FileManager.default.copyItem(atPath: origPath, toPath: path) } catch { fail("cannot write \(path): \(error)") }
    exit(0)
  }
  for tag in managedGraphicsTags {
    let re = try! NSRegularExpression(pattern: "<\(tag)>[^<]*</\(tag)>")
    guard let m = re.firstMatch(in: orig.text, range: NSRange(orig.text.startIndex..., in: orig.text)),
      let r = Range(m.range, in: orig.text)
    else { continue }
    let all = NSRange(cur.text.startIndex..., in: cur.text)
    cur.text = re.stringByReplacingMatches(
      in: cur.text, range: all, withTemplate: NSRegularExpression.escapedTemplate(for: String(orig.text[r])))
  }
  guard let body = cur.text.data(using: cur.encoding) else { fail("cannot encode \(path)") }
  do { try (cur.bom + body).write(to: URL(fileURLWithPath: path), options: .atomic) } catch {
    fail("cannot write \(path): \(error)")
  }
  log("resolution, window mode and antialiasing as before")
  exit(0)
}

// MARK: - ini

// One key of an ini file such as the Lighting Engine's ds2le_user_settings.ini (CRLF). Without a
// value it prints the key's value, or "-" if the key or the file is missing. "-" as the value
// removes the key. Everything else in the file stays byte for byte: line endings, a UTF-8 BOM, text
// that isn't UTF-8 (read as Latin-1, which maps every byte), and a symlink to the file.
func iniKey(_ args: [String]) -> Never {
  guard args.count == 3 || args.count == 4 else {
    fail("usage: ds2mac ini <file> <section> <key> [<value> | -]", code: 2)
  }
  let (path, section, key) = (args[0], "[\(args[1])]", args[2])
  let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
  var raw = Data()
  if FileManager.default.fileExists(atPath: url.path) {
    guard let d = FileManager.default.contents(atPath: url.path) else { fail("cannot read \(path)", code: 5) }
    raw = d
  } else if args.count == 3 {
    print("-")
    exit(0)
  }
  let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
  let hasBOM = raw.starts(with: bom)
  if hasBOM { raw = Data(raw.dropFirst(3)) }
  guard !raw.contains(0) else { fail("\(path) is not a plain text ini", code: 5) }
  let encoding: String.Encoding = String(data: raw, encoding: .utf8) != nil ? .utf8 : .isoLatin1
  let text = String(data: raw, encoding: encoding) ?? ""
  let eol = text.contains("\r\n") || text.isEmpty ? "\r\n" : "\n"
  let endsWithEOL = text.isEmpty || text.hasSuffix(eol)
  var lines = text.components(separatedBy: eol)
  if lines.last == "" { lines.removeLast() }
  var inSection = false, sectionEnd: Int? = nil, keyLine: Int? = nil
  for (i, line) in lines.enumerated() {
    let t = line.trimmingCharacters(in: .whitespaces)
    if t.hasPrefix("[") {
      if inSection { break }
      inSection = t == section
      if inSection { sectionEnd = i + 1 }
      continue
    }
    guard inSection else { continue }
    if !t.isEmpty { sectionEnd = i + 1 }
    if keyLine == nil, let eq = t.firstIndex(of: "="), t[..<eq].trimmingCharacters(in: .whitespaces) == key { keyLine = i }
  }
  if args.count == 3 {
    if let k = keyLine, let eq = lines[k].firstIndex(of: "=") {
      print(lines[k][lines[k].index(after: eq)...].trimmingCharacters(in: .whitespaces))
    } else {
      print("-")
    }
    exit(0)
  }
  let value = args[3]
  switch (keyLine, value) {
  case (let k?, "-"): lines.remove(at: k)
  case (let k?, _): lines[k] = "\(key)=\(value)"
  case (nil, "-"): exit(0)
  case (nil, _):
    if let end = sectionEnd {
      lines.insert("\(key)=\(value)", at: end)
    } else {
      if let last = lines.last, !last.isEmpty { lines.append("") }
      lines += [section, "\(key)=\(value)"]
    }
  }
  var out = Data(hasBOM ? bom : [])
  let joined = lines.joined(separator: eol) + (endsWithEOL ? eol : "")
  out.append(joined.data(using: encoding) ?? Data(joined.utf8))
  do { try out.write(to: url, options: .atomic) } catch { fail("cannot write \(path): \(error)") }
  exit(0)
}

// MARK: - exe-arch

func exeArch(_ args: [String]) -> Never {
  guard args.count == 1 else { fail("usage: ds2mac exe-arch <file.exe>", code: 2) }
  guard let h = FileHandle(forReadingAtPath: args[0]) else { fail("cannot read \(args[0])") }
  let head = [UInt8](h.readData(ofLength: 4096))
  func u32(_ o: Int) -> Int { Int(head[o]) | Int(head[o + 1]) << 8 | Int(head[o + 2]) << 16 | Int(head[o + 3]) << 24 }
  guard head.count >= 0x40, head[0] == 0x4D, head[1] == 0x5A else { fail("not an .exe file") }
  let pe = u32(0x3C)
  guard pe + 6 <= head.count, head[pe..<(pe + 4)].elementsEqual([0x50, 0x45, 0, 0]) else {
    fail("not a PE file")
  }
  switch Int(head[pe + 4]) | Int(head[pe + 5]) << 8 {
  case 0x8664: print("x64")
  case 0x14C: print("x86")
  case let m: print(String(format: "unknown-0x%X", m))
  }
  exit(0)
}

// MARK: - main

let args = Array(CommandLine.arguments.dropFirst())
switch args.first {
case "plan": plan(Array(args.dropFirst()))
case "res-table": resTable(Array(args.dropFirst()))
case "frame-limiter": frameLimiter(Array(args.dropFirst()))
case "mode": mode(Array(args.dropFirst()))
case "stretch": stretch(Array(args.dropFirst()))
case "display-size": displaySize(Array(args.dropFirst()))
case "patch-d3d11": patchD3D11(Array(args.dropFirst()))
case "graphics-config": graphicsConfig(Array(args.dropFirst()))
case "exe-arch": exeArch(Array(args.dropFirst()))
case "ini": iniKey(Array(args.dropFirst()))
case "--version": print(version)
default:
  fail("""
    usage: ds2mac plan <W>x<H> [--standard]
           ds2mac res-table <exe> <W>x<H> | --restore | --show | --list "<12 WxH>"
           ds2mac frame-limiter <exe> on | off | --show
           ds2mac stretch <W>x<H>[@Hz] -- command args... | stretch <W>x<H>[@Hz] --test <seconds>
           ds2mac display-size <W>x<H>
           ds2mac patch-d3d11 <in.dll> <out.dll>
           ds2mac mode <W>x<H> -- command args... | mode <W>x<H> --test <seconds> | mode <W>x<H> --check
           ds2mac graphics-config <xml> <W>x<H> [--fullscreen] | graphics-config <xml> --from <orig.xml>
           ds2mac exe-arch <file.exe>
           ds2mac ini <file> <section> <key> [<value> | -]
    """, code: 2)
}
