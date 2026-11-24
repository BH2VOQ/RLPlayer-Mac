#!/usr/bin/env node
'use strict';

/* Capture the REAL native RLPlayer.app (AppKit UI, no WKWebView) for the website / README.
 *
 * Why this exists: the previous capture tool drove `rtaweb` — the browser-shell build.
 * The shipped `.app` renders AppKit view controllers instead, so screenshots taken from
 * rtaweb are NOT what the user sees. This driver:
 *
 *   1. launches /Applications/RLPlayer.app with an isolated state dir + library dir
 *      (cover cache symlinked read-through so real album art still appears),
 *   2. drives its real UI through the Accessibility API (no synthetic keystrokes),
 *   3. captures the real window with ScreenCaptureKit at 2x.
 *
 * Audio discipline: backend=null + volume=-120, so nothing is ever opened or audible.
 *
 * Usage: node website/tools/capture-native-ui.js --authorized [--app <path>] [--only a,b]
 */
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync, spawnSync } = require('child_process');

const args = process.argv.slice(2);
if (!args.includes('--authorized')) {
  throw new Error('Refusing UI automation without the explicit --authorized flag.');
}
const argOf = (name, fallback) => {
  const at = args.indexOf(name);
  return at >= 0 && args[at + 1] ? args[at + 1] : fallback;
};

const project = path.resolve(__dirname, '../..');
const website = path.resolve(__dirname, '..');
const app = path.resolve(argOf('--app', '/Applications/RLPlayer.app'));
const exe = path.join(app, 'Contents/MacOS/RLPlayer');
const realState = path.join(os.homedir(), 'Library/Application Support/RLPlayer');
const musicDir = '/Users/august/Music/RLMusic';
const only = argOf('--only', '');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'rlp-native-capture-'));
// Persistent helper cache (swiftc is slow; reuse across runs).
const helperDir = path.join(os.tmpdir(), 'rlp-native-capture-helpers');
fs.mkdirSync(helperDir, { recursive: true });

if (!fs.existsSync(exe)) throw new Error('App executable not found: ' + exe);

const stateDir = path.join(tmp, 'state');
const libDir = path.join(tmp, 'library');
for (const d of [stateDir, libDir]) fs.mkdirSync(d, { recursive: true });
for (const leaf of ['covercache', 'artistcache']) {
  const src = path.join(realState, leaf);
  if (fs.existsSync(src)) fs.symlinkSync(src, path.join(stateDir, leaf));
}
// A real, saved 20-band calibration curve so the EQ page shows a working curve instead of
// a flat line. This is the same file the app itself reads/writes (rlplayer-peq.txt).
const peqFreqs = [20, 25, 40, 63, 80, 125, 200, 315, 500, 800, 1250, 2000, 3150, 5000, 8000, 10000, 12500, 16000, 18000, 20000];
const peqGains = [2.8, 3.4, 3.0, 1.8, 0.6, -0.4, -1.1, -1.5, -1.2, -0.5, 0.2, 1.4, 2.6, 3.2, 2.1, 0.4, -1.6, -2.4, 1.2, 2.0];
const peqLines = ['# rlplayer PEQ v1', 'bypass=0', 'preamp=-2', 'name=Chamber 20-Band'];
peqFreqs.forEach((f, i) => peqLines.push(`band=${i + 1},PK,${f},${peqGains[i]},1.41`));
// PEQ is resolved through path_in_exe_dir(), which honours RLPLAYER_STATE_DIR first, and the
// active UI mode picks rlplayer-peq-<mode>.txt over the generic file.
for (const leaf of ['rlplayer-peq.txt', 'rlplayer-peq-listen.txt', 'rlplayer-peq-pro.txt']) {
  fs.writeFileSync(path.join(stateDir, leaf), peqLines.join('\n') + '\n');
  fs.writeFileSync(path.join(libDir, leaf), peqLines.join('\n') + '\n');
}

for (const leaf of ['rlplayer-index.tsv', 'rlplayer-index.dirs.tsv', 'rlplayer-favs.json']) {
  const src = path.join(realState, leaf);
  if (fs.existsSync(src)) fs.copyFileSync(src, path.join(libDir, leaf));
}
fs.writeFileSync(path.join(libDir, 'rlplayer-library.conf'), musicDir + '\n');
fs.writeFileSync(path.join(stateDir, 'rlplayer-settings.conf'),
  'backend=null\ndevice=-1\nbits=-1\nscanonstartup=0\nmetaon=1\nmetallm=0\nvolume=0\ntheme=light\nuistyle=apple\nlang=zh\nuimode=listen\n');

const env = {
  ...process.env,
  RLPLAYER_STATE_DIR: stateDir,
  RLPLAYER_LIBRARY_DIR: libDir,
  HOME: path.join(tmp, 'home')
};
fs.mkdirSync(env.HOME, { recursive: true });

// ---------- helpers (Swift, built once) ----------
function writeHelper(name, source) {
  const src = path.join(helperDir, name + '.swift');
  const bin = path.join(helperDir, name);
  const prev = fs.existsSync(src) ? fs.readFileSync(src, 'utf8') : '';
  if (prev === source && fs.existsSync(bin)) return bin;
  fs.writeFileSync(src, source);
  const r = spawnSync('/usr/bin/arch', ['-arm64', 'swiftc', '-O', src, '-o', bin], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error('swiftc failed for ' + name + ': ' + (r.stderr || '').slice(0, 800));
  return bin;
}
fs.mkdirSync(helperDir, { recursive: true });

const AX_COMMON = `
import Cocoa
import ApplicationServices

let bundleId = "com.rta.rlplayer"
func rlApp() -> NSRunningApplication? {
    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleId }
}
func attr(_ e: AXUIElement, _ k: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(e, k as CFString, &v) == .success ? v : nil
}
func sv(_ e: AXUIElement, _ k: String) -> String { (attr(e, k) as? String) ?? "" }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }
func allElements(_ root: AXUIElement, limit: Int = 4000) -> [AXUIElement] {
    var out: [AXUIElement] = []; var stack = [root]
    while let e = stack.popLast() {
        out.append(e)
        if out.count > limit { break }
        stack.append(contentsOf: kids(e))
    }
    return out
}
`;

const winIdBin = writeHelper('winid', `${AX_COMMON}
let sem = DispatchSemaphore(value: 0)
var found: CGWindowID = 0
import ScreenCaptureKit
SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { c, _ in
    if let w = c?.windows.first(where: { $0.owningApplication?.bundleIdentifier == bundleId && $0.frame.width > 400 }) {
        found = w.windowID
    }
    sem.signal()
}
sem.wait()
if found == 0 { print("0") } else { print("\\(found)") }
`);

const shotBin = writeHelper('shot', `
import Cocoa
import CoreGraphics
import ScreenCaptureKit

let argv = CommandLine.arguments
guard argv.count >= 3, let wid = UInt32(argv[1]) else { print("usage: shot <winId> <out> [scale]"); exit(1) }
let outPath = argv[2]
let scale = argv.count > 3 ? (Double(argv[3]) ?? 2.0) : 2.0
_ = NSApplication.shared

final class OneShot: NSObject, SCStreamOutput, SCStreamDelegate {
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let px = CMSampleBufferGetImageBuffer(sb) else { return }
        let ci = CIImage(cvPixelBuffer: px)
        guard let img = CIContext().createCGImage(ci, from: ci.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        if let d = rep.representation(using: .png, properties: [:]) {
            try? d.write(to: URL(fileURLWithPath: outPath))
            print("OK \\(img.width)x\\(img.height)")
            exit(0)
        }
    }
}
let sem = DispatchSemaphore(value: 0)
var content: SCShareableContent?
SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { c, _ in content = c; sem.signal() }
sem.wait()
guard let content, let win = content.windows.first(where: { $0.windowID == wid }) else { print("nowin"); exit(3) }
let filter = SCContentFilter(desktopIndependentWindow: win)
let cfg = SCStreamConfiguration()
cfg.width = Int(win.frame.width * scale)
cfg.height = Int(win.frame.height * scale)
cfg.showsCursor = false
cfg.ignoreShadowsSingleWindow = true
let out = OneShot()
let stream = SCStream(filter: filter, configuration: cfg, delegate: out)
try stream.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "q"))
Task { try await stream.startCapture() }
DispatchQueue.main.asyncAfter(deadline: .now() + 10) { print("timeout"); exit(4) }
dispatchMain()
`);

// Generic AX command runner: reads a JSON action list, executes, prints JSON results.
const axBin = writeHelper('axdo', `${AX_COMMON}
// usage: axdo <action> [args...]
//   click-id <identifier> | click-text <text> | press-key <keycode> | click-at <x> <y>
//   state                | wait-id <id> <sec> | dump <filter>
let argv = CommandLine.arguments
guard argv.count >= 2, let app = rlApp() else { print("{\\"ok\\":false,\\"why\\":\\"app not running\\"}"); exit(2) }
let ax = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(ax, 5.0)
let cmd = argv[1]

func window() -> AXUIElement? {
    // Pick the LARGEST window: clicking can spawn small transient panels/popovers, and taking
    // taking the first entry then makes every later query inspect the wrong window.
    let ws = (attr(ax, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    var best: AXUIElement? = nil
    var bestArea: CGFloat = -1
    for w in ws {
        let f = frame(w)
        let area = f.width * f.height
        if area > bestArea { bestArea = area; best = w }
    }
    return best
}
func frame(_ e: AXUIElement) -> CGRect {
    var pos = CGPoint.zero, size = CGSize.zero
    if let p = attr(e, kAXPositionAttribute), CFGetTypeID(p) == AXValueGetTypeID() {
        AXValueGetValue(p as! AXValue, .cgPoint, &pos)
    }
    if let s = attr(e, kAXSizeAttribute), CFGetTypeID(s) == AXValueGetTypeID() {
        AXValueGetValue(s as! AXValue, .cgSize, &size)
    }
    return CGRect(origin: pos, size: size)
}
func findBy(_ pred: (AXUIElement) -> Bool) -> AXUIElement? {
    guard let w = window() else { return nil }
    return allElements(w).first(where: pred)
}
func postToApp(_ ev: CGEvent?) {
    guard let ev, let a = rlApp() else { return }
    ev.postToPid(a.processIdentifier)
}

func doubleClickCenter(_ e: AXUIElement) -> Bool {
    let f = frame(e)
    if f.width < 1 || f.height < 1 { return false }
    let p = CGPoint(x: f.midX, y: f.midY)
    for n in 1...2 {
        let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
        down?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
        up?.setIntegerValueField(.mouseEventClickState, value: Int64(n))
        postToApp(down)
        usleep(25000)
        postToApp(up)
        usleep(60000)
    }
    return true
}

func clickCenter(_ e: AXUIElement) -> Bool {
    let f = frame(e)
    if f.width < 1 || f.height < 1 { return false }
    let p = CGPoint(x: f.midX, y: f.midY)
    let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left)
    let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left)
    postToApp(down)
    usleep(40000)
    postToApp(up)
    return true
}

switch cmd {
case "winid":
    if let w = window() { print(Int(frame(w).width)) } else { print(0) }
case "dump":
    let filter = argv.count > 2 ? argv[2] : ""
    guard let w = window() else { print("{}"); exit(0) }
    var rows: [String] = []
    for e in allElements(w) {
        let role = sv(e, kAXRoleAttribute)
        let title = sv(e, kAXTitleAttribute)
        let desc = sv(e, kAXDescriptionAttribute)
        let val = sv(e, kAXValueAttribute)
        let ident = sv(e, "AXIdentifier")
        let line = "\\(role)|t=\\(title)|d=\\(desc)|v=\\(val)|id=\\(ident)"
        if filter.isEmpty || line.contains(filter) { rows.append(line) }
    }
    print(rows.joined(separator: "\\n"))
case "click-id":
    let want = argv[2]
    if let e = findBy({ sv($0, "AXIdentifier") == want }) { print(clickCenter(e) ? "OK" : "NOSIZE") }
    else { print("MISSING") }
case "click-text":
    let want = argv[2]
    if let e = findBy({ sv($0, kAXTitleAttribute) == want || sv($0, kAXDescriptionAttribute) == want || sv($0, kAXValueAttribute) == want }) {
        print(clickCenter(e) ? "OK" : "NOSIZE")
    } else { print("MISSING") }
case "click-contains":
    let want = argv[2]
    if let e = findBy({ sv($0, kAXTitleAttribute).contains(want) || sv($0, kAXValueAttribute).contains(want) }) {
        print(clickCenter(e) ? "OK" : "NOSIZE")
    } else { print("MISSING") }
case "rowlabels":
    var seen: [String] = []
    for e in allElements(window() ?? ax) where sv(e, kAXRoleAttribute) == "AXRow" {
        var parts: [String] = []
        for k in kids(e) { parts.append(sv(k, "AXIdentifier") + "=" + sv(k, kAXValueAttribute) + "/" + sv(k, kAXDescriptionAttribute)) }
        seen.append(parts.joined(separator: ","))
    }
    for one in seen { print(one) }
case "sidebar":
    // Click a sidebar nav row. The row's label is an AXStaticText with AXIdentifier == "label";
    // clicking the ROW (not the text) is what the real UI expects.
    let want = argv[2]
    var labelEl: AXUIElement? = nil
    for e in allElements(window() ?? ax) where sv(e, "AXIdentifier") == "label" && sv(e, kAXValueAttribute) == want {
        labelEl = e; break
    }
    if labelEl == nil { print("MISSING"); break }
    var target: AXUIElement = labelEl!
    for _ in 0..<4 {
        if sv(target, kAXRoleAttribute) == "AXRow" { break }
        guard let up = attr(target, kAXParentAttribute), CFGetTypeID(up) == AXUIElementGetTypeID() else { break }
        target = up as! AXUIElement
    }
    print(clickCenter(target) ? "OK" : "NOSIZE")
case "frames":
    for e in allElements(window() ?? ax) where sv(e, kAXRoleAttribute) == (argv.count > 2 ? argv[2] : "AXImage") {
        let f = frame(e)
        print(String(format: "%.0f,%.0f %.0fx%.0f id=%@", f.origin.x, f.origin.y, f.width, f.height, sv(e, "AXIdentifier")))
    }
case "album-menu-open":
    // Fallback path: the card's context menu has a real "打开" item. Open it on the FIRST card
    // and press the menu item through the Accessibility API (the click gesture needs a live
    // event stream that synthetic CGEvents sometimes don't satisfy on the collection view).
    var firstCard: AXUIElement? = nil
    var cardArea: CGFloat = 0
    for e in allElements(window() ?? ax) where sv(e, kAXRoleAttribute) == "AXImage" {
        let f = frame(e)
        if f.width < 120 || f.height < 120 || f.origin.x < 300 { continue }
        if cardArea == 0 { cardArea = f.width * f.height; firstCard = e; break }
    }
    if firstCard == nil { print("MISSING"); break }
    let f = frame(firstCard!)
    let p = CGPoint(x: f.midX, y: f.midY)
    postToApp(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: .right))
    usleep(60000)
    postToApp(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: .right))
    usleep(500000)
    var titles: [String] = []
    for e in allElements(ax) where sv(e, kAXRoleAttribute) == "AXMenuItem" { titles.append(sv(e, kAXTitleAttribute)) }
    print("MENU:" + titles.joined(separator: ","))
case "album-open":
    // Open the top-left album card. Cards are inside the collection view, so:
    //   * skip the playback bar (bottom ~150pt) and the sidebar (left ~380pt),
    //   * require a real cover-sized square (>=140pt),
    //   * pick the SMALLEST y then x so we always hit the first card, never a half-scrolled one.
    guard let w = window() else { print("MISSING"); break }
    let wf = frame(w)
    let maxY = wf.origin.y + wf.height - 150
    var best: AXUIElement? = nil
    var bestY = CGFloat.greatestFiniteMagnitude
    var bestX = CGFloat.greatestFiniteMagnitude
    for e in allElements(w) where sv(e, kAXRoleAttribute) == "AXImage" {
        let f = frame(e)
        if f.width < 140 || f.height < 140 { continue }
        if f.origin.x < 380 { continue }
        if f.origin.y < wf.origin.y + 60 || f.origin.y > maxY { continue }
        if f.origin.y < bestY - 1 || (abs(f.origin.y - bestY) <= 1 && f.origin.x < bestX) {
            bestY = f.origin.y; bestX = f.origin.x; best = e
        }
    }
    if best == nil { print("MISSING"); break }
    print(clickCenter(best!) ? "OK" : "NOSIZE")
case "segment":
    // Settings tab bars are NSSegmentedControls whose children surface as AXRadioButton with the
    // label in AXDescription. Match on the label directly and click its centre — relying on the
    // control's own AXIdentifier is brittle (it is not always exported).
    let want = argv.count > 3 ? argv[3] : argv[2]
    var hit: AXUIElement? = nil
    for e in allElements(window() ?? ax) where sv(e, kAXRoleAttribute) == "AXRadioButton" && sv(e, kAXDescriptionAttribute) == want { hit = e; break }
    if hit == nil {
        var seen: [String] = []
        for e in allElements(window() ?? ax) where sv(e, kAXRoleAttribute) == "AXRadioButton" { seen.append(sv(e, kAXDescriptionAttribute)) }
        print("MISSING:" + seen.joined(separator: ","))
        break
    }
    print(clickCenter(hit!) ? "OK" : "NOSIZE")
case "album-open-play":
    // Open the top-left album card (single click), then press the real "播放整张" button on the
    // detail page. The hover-only play badge needs a genuine mouse-enter event, which synthetic
    // events do not always deliver to a tracking area.
    guard let w = window() else { print("MISSING"); break }
    let wf = frame(w)
    let maxY = wf.origin.y + wf.height - 150
    var card: AXUIElement? = nil
    var bestY = CGFloat.greatestFiniteMagnitude
    var bestX = CGFloat.greatestFiniteMagnitude
    for e in allElements(w) where sv(e, kAXRoleAttribute) == "AXImage" {
        let f = frame(e)
        if f.width < 140 || f.height < 140 || f.origin.x < 380 { continue }
        if f.origin.y < wf.origin.y + 60 || f.origin.y > maxY { continue }
        if f.origin.y < bestY - 1 || (abs(f.origin.y - bestY) <= 1 && f.origin.x < bestX) {
            bestY = f.origin.y; bestX = f.origin.x; card = e
        }
    }
    if card == nil { print("MISSING"); break }
    _ = clickCenter(card!)
    usleep(1500000)
    var playBtn: AXUIElement? = nil
    for _ in 0..<30 {
        for e in allElements(window() ?? ax) where sv(e, kAXRoleAttribute) == "AXButton" && sv(e, kAXTitleAttribute) == "播放整张" { playBtn = e; break }
        if playBtn != nil { break }
        usleep(300000)
    }
    if playBtn == nil { print("NOBTN"); break }
    let err = AXUIElementPerformAction(playBtn!, kAXPressAction as CFString)
    print(err == .success ? "OK" : "FAIL\(err.rawValue)")
case "np-open":
    // The playback-bar cover is a plain NSImageView that opens Now Playing in -mouseDown:
    // (the app posts RLPOpenNowPlayingNotification in-process, so a cross-process distributed
    // notification cannot reach it). Drive it with a REAL click at its centre.
    if let b = allElements(window() ?? ax).first(where: { sv($0, "AXIdentifier") == "pb.cover" }) {
        print(clickCenter(b) ? "OK" : "NOSIZE")
        break
    }
    print("MISSING")
case "rightclick-at":
    let x = Double(argv[2]) ?? 0, y = Double(argv[3]) ?? 0
    do {
        let p = CGPoint(x: x, y: y)
        postToApp(CGEvent(mouseEventSource: nil, mouseType: .rightMouseDown, mouseCursorPosition: p, mouseButton: .right))
        usleep(40000)
        postToApp(CGEvent(mouseEventSource: nil, mouseType: .rightMouseUp, mouseCursorPosition: p, mouseButton: .right))
        print("OK")
    }
case "menus":
    // Dump the open menu tree (AXMenuBar of the app + AXMenu of the front menu window).
    var out: [String] = []
    for e in allElements(ax) where ["AXMenuItem","AXMenu"].contains(sv(e, kAXRoleAttribute)) {
        out.append(sv(e, kAXRoleAttribute) + "|" + sv(e, kAXTitleAttribute))
    }
    for one in out { print(one) }
case "menupress":
    let want = argv[2]
    var hit: AXUIElement? = nil
    for e in allElements(ax) where sv(e, kAXRoleAttribute) == "AXMenuItem" && sv(e, kAXTitleAttribute).contains(want) { hit = e; break }
    if hit == nil { print("MISSING") } else {
        let err = AXUIElementPerformAction(hit!, kAXPressAction as CFString)
        print(err == .success ? "OK" : "PRESS_FAIL_\(err.rawValue)")
    }
case "resize":
    // Resize the main window (pt). AXSize is honoured immediately; the app re-lays out its grid.
    let w = Double(argv[2]) ?? 1900, h = Double(argv[3]) ?? 1200
    guard let win = window() else { print("NOWIN"); break }
    var sz = CGSize(width: w, height: h)
    if let v = AXValueCreate(.cgSize, &sz) {
        let err = AXUIElementSetAttributeValue(win, kAXSizeAttribute as CFString, v)
        print(err == .success ? "OK" : "FAIL\(err.rawValue)")
    } else { print("NOVAL") }
case "rowactions":
    let want2 = argv[2]
    var lbl: AXUIElement? = nil
    for e in allElements(window() ?? ax) where sv(e, "AXIdentifier") == "label" && sv(e, kAXValueAttribute) == want2 { lbl = e; break }
    if lbl == nil { print("MISSING"); break }
    var row: AXUIElement = lbl!
    for _ in 0..<4 {
        if sv(row, kAXRoleAttribute) == "AXRow" { break }
        guard let up = attr(row, kAXParentAttribute), CFGetTypeID(up) == AXUIElementGetTypeID() else { break }
        row = up as! AXUIElement
    }
    var names: CFArray? = nil
    let e2 = AXUIElementCopyActionNames(row, &names)
    print("row=\(sv(row, kAXRoleAttribute)) actionsErr=\(e2.rawValue) actions=\((names as? [String]) ?? [])")
case "rowpress":
    let want3 = argv[2]
    var lbl3: AXUIElement? = nil
    for e in allElements(window() ?? ax) where sv(e, "AXIdentifier") == "label" && sv(e, kAXValueAttribute) == want3 { lbl3 = e; break }
    if lbl3 == nil { print("MISSING"); break }
    var row3: AXUIElement = lbl3!
    for _ in 0..<4 {
        if sv(row3, kAXRoleAttribute) == "AXRow" { break }
        guard let up = attr(row3, kAXParentAttribute), CFGetTypeID(up) == AXUIElementGetTypeID() else { break }
        row3 = up as! AXUIElement
    }
    let err2 = AXUIElementPerformAction(row3, kAXPressAction as CFString)
    print(err2 == .success ? "OK" : "FAIL\(err2.rawValue)")
case "activate":
    app.activate(options: [])
    usleep(300000)
    print("OK")
case "click-at":
    let x = Double(argv[2]) ?? 0, y = Double(argv[3]) ?? 0
    let p = CGPoint(x: x, y: y)
    postToApp(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: p, mouseButton: .left))
    usleep(40000)
    postToApp(CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: p, mouseButton: .left))
    print("OK")
case "key":
    let code = UInt16(argv[2]) ?? 0
    postToApp(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
    usleep(20000)
    postToApp(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false))
    print("OK")
case "raise":
    app.activate(options: [.activateIgnoringOtherApps])
    print("OK")
default:
    print("unknown")
}
`);

function run(bin, argv) {
  try {
    return execFileSync(bin, argv, { encoding: 'utf8', timeout: 90000, env }).trim();
  } catch (e) {
    return 'ERR ' + (e.stderr || e.message || '').toString().split('\n')[0];
  }
}
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const outDir = path.join(tmp, 'shots');
fs.mkdirSync(outDir, { recursive: true });

function shot(name) {
  const winId = run(winIdBin, []).split('\n').pop().trim();
  if (!/^\d+$/.test(winId) || winId === '0') throw new Error('No real window found for capture: ' + winId);
  const out = path.join(outDir, name + '.png');
  const res = run(shotBin, [winId, out, '2']);
  if (!res.startsWith('OK')) throw new Error('ScreenCaptureKit failed for ' + name + ': ' + res);
  const webp = path.join(website, 'assets', name + '.webp');
  execFileSync('/usr/local/bin/cwebp', ['-quiet', '-q', '92', out, '-o', webp], { stdio: 'ignore' });
  const info = execFileSync('sips', ['-g', 'pixelWidth', '-g', 'pixelHeight', webp], { encoding: 'utf8' });
  console.log('CAPTURED ' + name + ' <- ' + res + '\n' + info.trim());
  return webp;
}

(async () => {
  const wanted = (n) => !only || only.split(',').map((s) => s.trim()).includes(n);
  let child = null;
  try {
    // Launch the executable directly (never `open -n`): a second instance would make the
    // Accessibility helper attach to the wrong process and every click would silently miss.
    child = require('child_process').spawn(exe, [], { env, stdio: ['ignore', 'pipe', 'pipe'], detached: true });
    let log = '';
    child.stdout.on('data', (d) => { log += d.toString(); });
    child.stderr.on('data', (d) => { log += d.toString(); });

    let up = false;
    for (let i = 0; i < 120; i += 1) {
      await sleep(500);
      const w = run(axBin, ['winid']);
      if (/^\d+$/.test(w) && Number(w) > 400) { up = true; break; }
    }
    if (!up) throw new Error('Native window never appeared. Log tail:\n' + log.slice(-1500));
    console.log('REAL NATIVE WINDOW UP (' + run(axBin, ['winid']) + ' pt wide)');
    // postToPid keeps the pointer still, but NSTableView row selection still requires the app
    // to be the key window, so activate it once at the start.
    run(axBin, ['activate']);
    await sleep(1500);

    const dumpAll = () => run(axBin, ['dump']);
    // The settings page builds its tab controls asynchronously, and a click that lands before
    // the app is frontmost is swallowed entirely. Retry nav+activation until the tab row exists.
    async function navSettings(timeoutMs = 40000) {
      const t0 = Date.now();
      while (Date.now() - t0 < timeoutMs) {
        await clickText('设置', '界面风格');
        await sleep(900);
        const d = dumpAll();
        if (d.includes('界面风格') || d.includes('音频处理')) return true;
      }
      return false;
    }
    // Sidebar navigation goes through the row-label matcher (page headings share the same text).
    // A click can land while the window is still re-laying out after a resize, so verify the
    // page actually changed and retry a few times.
    const PAGE_MARKERS = {
      '聆听室': '安静听歌，常用设置就在卡片里',
      '专辑': '打开音乐库',
      '艺术家': '位艺术家',
      '曲目': '默认排序',
      '设置': '界面风格',
      '播放队列': '队列',
      '最近播放': '最近播放',
      '我的最爱': '我的最爱',
    };
    const clickText = async (t, expect) => {
      for (let i = 0; i < 6; i += 1) {
        run(axBin, ['activate']);
        const r = run(axBin, ['sidebar', t]);
        await sleep(900);
        const d = dumpAll();
        const want = expect || PAGE_MARKERS[t] || t;
        const ok = d.includes(want);
        console.log('  nav ' + t + ' -> ' + r + (ok ? ' (on page)' : ' (retry)'));
        if (ok) return 'OK';
      }
      return 'FAILED';
    };

    // Wait until the album grid has painted real cover bitmaps (AXImage with a size), not the
    // letter placeholder. Covers stream in asynchronously from the (symlinked) cover cache.
    async function waitCovers(minCount = 12, timeoutMs = 30000) {
      const t0 = Date.now();
      while (Date.now() - t0 < timeoutMs) {
        const d = dumpAll();
        const imgs = (d.match(/AXImage/g) || []).length;
        if (imgs >= minCount) return true;
        await sleep(600);
      }
      return false;
    }

    // ---- 聆听室 / 快速开始 ----
    if (wanted('ui-quickstart')) {
      await clickText('聆听室');
      await sleep(1800);
      shot('ui-quickstart');
    }

    // ---- 专辑网格 ----
    if (wanted('ui-library')) {
      await clickText('专辑');
      await sleep(2000);
      const ok = await waitCovers(20);
      console.log('  covers ready=' + ok);
      await sleep(1200);
      shot('ui-library');
    }

    // ---- start real playback on the NullSink (no device, no sound) ----
    async function startPlayback() {
      const nav = await clickText('专辑');
      console.log('  nav 专辑 (for playback) -> ' + nav);
      await sleep(2200);
      const r = run(axBin, ['album-open-play']);
      console.log('  play first album (null sink) -> ' + r);
      for (let i = 0; i < 40; i += 1) {
        await sleep(500);
        const d = dumpAll();
        if (d.includes('bit-perfect') || /\d+:\d\d \/ \d+:\d\d/.test(d)) return true;
      }
      return false;
    }

    // ---- 专辑详情 ----
    if (wanted('ui-album-detail')) {
      // Must be on the album grid first: the 聆听室 home also shows album covers, and
      // double-clicking one of those does not open the detail page.
      await clickText('专辑');
      await sleep(1800);
      const r = run(axBin, ['album-open']);
      console.log('  open first album -> ' + r);
      if (r === 'OK') {
        for (let i = 0; i < 30; i += 1) {
          await sleep(400);
          const d = dumpAll();
          if (d.includes('播放整张') || d.includes('曲目列表') || d.includes('返回专辑')) break;
        }
        await sleep(1800);
        shot('ui-album-detail');
        run(axBin, ['key', '53']);   // Esc → back to the grid
        await sleep(1200);
      }
    }

    // ---- 艺术家 ----
    if (wanted('ui-artists')) {
      await clickText('艺术家');
      await sleep(2400);
      shot('ui-artists');
    }

    // ---- 曲目 ----
    if (wanted('ui-tracks')) {
      await clickText('曲目');
      await sleep(2200);
      // Widen only AFTER navigating: the sidebar row click needs the app frontmost at its
      // launch size, but a 1900pt window stops the index column from clipping.
      console.log('  resize -> ' + run(axBin, ['resize', '1900', '1180']));
      await sleep(2000);
      // The index column must be fully visible; if the table is still narrow, widen once more.
      const d = dumpAll();
      if (!/\b2216\b/.test(d)) console.log('  track count not visible yet');
      await sleep(1000);
      shot('ui-tracks');
    }

    // ---- 设置 · 输出 ----
    if (wanted('ui-output')) {
      console.log('  settings ready=' + await navSettings());
      const r = run(axBin, ['segment', 'settings.tabs', '输出']);
      console.log('  pane 输出 -> ' + r);
      await sleep(1600);
      shot('ui-output');
    }

    // ---- 设置 · EQ ----
    if (wanted('ui-dsp')) {
      console.log('  settings ready=' + await navSettings());
      const g = run(axBin, ['segment', 'settings.groups', '音频处理']);
      console.log('  group 音频处理 -> ' + g);
      // The audio tab row is rebuilt after the group switches; pressing EQ before it exists
      // silently does nothing.
      let r = '';
      for (let i = 0; i < 20; i += 1) {
        await sleep(500);
        r = run(axBin, ['segment', 'settings.tabs', 'EQ']);
        if (r === 'OK') break;
      }
      console.log('  pane EQ -> ' + r);
      await sleep(2200);
      shot('ui-dsp');
    }

    // ---- 正在播放 ----
    if (wanted('ui-hero')) {
      const d0 = dumpAll();
      if (d0.includes('未播放') || !/\d+:\d\d \/ \d+:\d\d/.test(d0)) {
        await startPlayback();
        await sleep(1500);
      }
      const np = run(axBin, ['np-open']);
      console.log('  open now playing -> ' + np);
      for (let i = 0; i < 40; i += 1) {
        await sleep(500);
        const d = dumpAll();
        if (!d.includes('歌词加载中') && !d.includes('没有歌词')) break;
      }
      await sleep(1800);
      shot('ui-hero');
    }

    if (args.includes('--keep')) {
      console.log('KEEPING APP ALIVE (pid ' + (child && child.pid) + '); press Ctrl-C to stop');
      await new Promise(() => {});
    }
    console.log('SHOT DIR ' + outDir);
    console.log('TMP ROOT ' + tmp);
  } catch (e) {
    console.error('[CAPTURE ERROR] ' + (e.stack || e.message));
    process.exitCode = 1;
  } finally {
    if (child && child.pid) {
      try { process.kill(-child.pid, 'SIGTERM'); } catch (err) { /* already gone */ }
    }
    spawnSync('pkill', ['-f', exe]);
  }
})();
