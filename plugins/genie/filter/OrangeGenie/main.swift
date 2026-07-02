// OrangeGenie — menu-bar shell + the screen filter (Sprint-1 Task #6).
// Menu-bar presence (NSStatusItem) with a Filter ON/OFF toggle. When ON: a STATIC OG-orange tint
// (the always-know-it's-on trust signal — photosensitive-safe, no animation) + renders the co-pilot
// marks from /tmp/genie_marks.json on a transparent, click-through, screensaver-level overlay.
// Reuses the window/paint approach from genie_overlay.swift.
//
// Build:  ./build.sh   →   open OrangeGenie.app
import Cocoa

struct Mark: Decodable { let x: Double; let y: Double; let w: Double; let h: Double; let label: String? }
let MARKS_PATH = "/tmp/genie_marks.json"

enum ScopeMode { case fullscreen, window, app }
enum Presence { case tint, frameDot, dotOnly, none } // on-screen indicator level (menu-bar logo glow is the always-on floor)

// Shared filter state (read by every overlay view)
final class FilterState {
    static let shared = FilterState()
    var on = false
    var marks: [Mark] = []
    var scopeMode: ScopeMode = .fullscreen
    var scopeRect: CGRect = .zero      // GLOBAL top-left coords of the watched window/app (ignored when fullscreen)
    var scopeLabel: String = "Whole screen"
    var presence: Presence = .frameDot // default: Subtle
    var flash: String? = nil           // transient on-state banner ("🪔 Your Lamp is lit!")
}

final class OverlayView: NSView {
    override var isFlipped: Bool { true } // top-left origin to match web/screen coords

    // GLOBAL top-left rect → this window's local (flipped, top-left) rect
    func localRect(_ g: CGRect) -> NSRect {
        guard let w = self.window else { return .zero }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? w.frame.maxY
        let winTopGlobalTL = primaryTop - w.frame.maxY
        return NSRect(x: g.minX - w.frame.minX, y: g.minY - winTopGlobalTL, width: g.width, height: g.height)
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        guard FilterState.shared.on else { return } // OFF = fully clear (true off-state)

        // 1) Presence indicator — STEADY (no animation; AUTO photosensitive no-strobe). The menu-bar logo glow is
        //    the always-on floor; this is the optional on-screen layer chosen in Presence settings.
        let pr = FilterState.shared.presence
        let scoped = FilterState.shared.scopeMode != .fullscreen
        let region = scoped ? localRect(FilterState.shared.scopeRect).intersection(bounds) : bounds
        if !region.isNull && !region.isEmpty {
            if pr == .tint { // the "loud" wash
                NSColor(srgbRed: 1.0, green: 0.416, blue: 0.0, alpha: 0.05).setFill(); region.fill()
            }
            if pr == .tint || pr == .frameDot { // orange border around the watched region (or the whole screen)
                NSColor(srgbRed: 1.0, green: 0.416, blue: 0.0, alpha: 0.55).setStroke()
                let fr = scoped ? region : region.insetBy(dx: 2, dy: 2) // inset for fullscreen so the edge shows
                let p = NSBezierPath(rect: fr); p.lineWidth = scoped ? 2 : 3; p.stroke()
            }
            if pr == .tint || pr == .frameDot || pr == .dotOnly { // steady presence dot, bottom-right of the region
                let cx = region.maxX - 16, cy = region.maxY - 16
                NSColor(srgbRed: 1.0, green: 0.416, blue: 0.0, alpha: 0.18).setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - 11, y: cy - 11, width: 22, height: 22)).fill()
                NSColor(srgbRed: 1.0, green: 0.416, blue: 0.0, alpha: 0.95).setFill()
                NSBezierPath(ovalIn: NSRect(x: cx - 5, y: cy - 5, width: 10, height: 10)).fill()
            }
            // pr == .none → nothing on-screen; only the lit menu-bar logo (the trust floor) signals active.
        }

        // 1b) transient "🪔 Your Lamp is lit!" banner on activation (centered near top, auto-clears)
        if let msg = FilterState.shared.flash {
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 15), .foregroundColor: NSColor.white]
            let sz = (msg as NSString).size(withAttributes: attrs)
            let bw = sz.width + 36, bh = sz.height + 22
            let pill = NSRect(x: (bounds.width - bw) / 2, y: 64, width: bw, height: bh)
            NSColor(srgbRed: 0.04, green: 0.04, blue: 0.04, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
            NSColor(srgbRed: 1.0, green: 0.416, blue: 0.0, alpha: 0.85).setStroke()
            let bp = NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12); bp.lineWidth = 1.5; bp.stroke()
            (msg as NSString).draw(at: NSPoint(x: pill.minX + 18, y: pill.minY + 11), withAttributes: attrs)
        }

        // 2) co-pilot marks (green box + "✅ Genie: click this" pill)
        let green = NSColor(srgbRed: 0.086, green: 0.639, blue: 0.290, alpha: 1.0)
        let fill  = NSColor(srgbRed: 0.863, green: 0.988, blue: 0.906, alpha: 0.45)
        let win = self.window
        for m in FilterState.shared.marks {
            // marks are GLOBAL top-left screen coords → convert to this window's local (top-left, flipped view)
            guard let w = win else { continue }
            let lx = m.x - w.frame.minX
            // global TL y → local TL y within this screen's window
            let primaryTop = NSScreen.screens.first?.frame.maxY ?? w.frame.maxY
            let winTopGlobalTL = primaryTop - w.frame.maxY
            let ly = m.y - winTopGlobalTL
            let r = NSRect(x: lx, y: ly, width: m.w, height: m.h)
            if r.maxX < 0 || r.minX > bounds.width || r.maxY < 0 || r.minY > bounds.height { continue }
            let path = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
            fill.setFill(); path.fill(); green.setStroke(); path.lineWidth = 3; path.stroke()
            let text = m.label ?? "✅ Genie: click this"
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 13), .foregroundColor: NSColor.white]
            let sz = (text as NSString).size(withAttributes: attrs)
            let pill = NSRect(x: min(r.maxX - sz.width - 22, bounds.width - sz.width - 26), y: max(r.minY - sz.height - 8, 2), width: sz.width + 16, height: sz.height + 6)
            green.setFill(); NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
            (text as NSString).draw(at: NSPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: attrs)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var windows: [NSWindow] = []
    var views: [OverlayView] = []
    var lastMTime: TimeInterval = 0

    // Genie-face menu-bar glyph drawn from the SVG coords as a MONOCHROME TEMPLATE
    // (ring + 2 eyes + mouth opaque; center cut out via even-odd) → adapts white-on-dark like native icons.
    static func faceGlyph(_ T: CGFloat, active: Bool = false) -> NSImage {
        let img = NSImage(size: NSSize(width: T, height: T))
        img.lockFocus()
        let s = T / 2048.0
        func R(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ rx: CGFloat) -> NSBezierPath {
            let fy = 2048 - y - h // flip SVG top-left → AppKit bottom-left
            return NSBezierPath(roundedRect: NSRect(x: x * s, y: fy * s, width: w * s, height: h * s), xRadius: rx * s, yRadius: rx * s)
        }
        // ACTIVE → filled OG-orange (logo "lights up", non-template). IDLE → monochrome template (adapts white-on-dark).
        (active ? NSColor(srgbRed: 1.0, green: 0.322, blue: 0.0, alpha: 1.0) : NSColor.black).setFill()
        let ring = R(230, 230, 1588, 1588, 270)
        ring.append(R(440, 440, 1168, 1168, 180))
        ring.windingRule = .evenOdd
        ring.fill()                       // outer frame minus inner = the face ring
        R(760, 840, 140, 220, 70).fill()  // left eye
        R(1148, 840, 140, 220, 70).fill() // right eye
        R(894, 1260, 260, 44, 22).fill()  // mouth
        img.unlockFocus()
        img.isTemplate = !active
        return img
    }
    func updateIcon() { statusItem?.button?.image = Self.faceGlyph(20, active: FilterState.shared.on) }

    func applicationDidFinishLaunching(_ note: Notification) {
        // menu-bar presence
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button { b.image = Self.faceGlyph(20) }
        rebuildMenu()
        buildOverlays()
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { [weak self] _ in self?.reloadMarks() }
    }

    func rebuildMenu() {
        let m = NSMenu()
        let toggle = NSMenuItem(title: FilterState.shared.on ? "🟠 Filter: ON" : "Filter: OFF", action: #selector(toggleFilter), keyEquivalent: "")
        toggle.target = self
        m.addItem(toggle)
        m.addItem(.separator())
        // Scope submenu — Full Screen / Select Window / Select Application
        let scopeItem = NSMenuItem(title: "Watching: \(FilterState.shared.scopeLabel)", action: nil, keyEquivalent: "")
        let scopeMenu = NSMenu()
        let full = NSMenuItem(title: "Full Screen", action: #selector(setFullScreen), keyEquivalent: "")
        full.target = self; full.state = FilterState.shared.scopeMode == .fullscreen ? .on : .off
        scopeMenu.addItem(full)
        // Select Window ▸
        let winParent = NSMenuItem(title: "Select Window", action: nil, keyEquivalent: "")
        let winMenu = NSMenu()
        for w in liveWindows() {
            let t = w.title.isEmpty ? w.owner : "\(w.owner) — \(w.title)"
            let it = NSMenuItem(title: t.count > 48 ? String(t.prefix(48)) + "…" : t, action: #selector(pickWindow(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = ["mode": "window", "rect": NSValue(rect: w.bounds), "label": w.owner]
            winMenu.addItem(it)
        }
        if winMenu.items.isEmpty { winMenu.addItem(NSMenuItem(title: "(grant Screen Recording to list windows)", action: nil, keyEquivalent: "")) }
        winParent.submenu = winMenu; scopeMenu.addItem(winParent)
        // Select Application ▸
        let appParent = NSMenuItem(title: "Select Application", action: nil, keyEquivalent: "")
        let appMenu = NSMenu()
        for a in liveApps() {
            let it = NSMenuItem(title: a.name, action: #selector(pickApp(_:)), keyEquivalent: "")
            it.target = self; it.representedObject = ["mode": "app", "rect": NSValue(rect: a.bounds), "label": a.name]
            appMenu.addItem(it)
        }
        appParent.submenu = appMenu; scopeMenu.addItem(appParent)
        scopeItem.submenu = scopeMenu
        m.addItem(scopeItem)
        // Presence submenu — on-screen indicator level (logo glow is the always-on floor underneath)
        let presItem = NSMenuItem(title: "Presence", action: nil, keyEquivalent: "")
        let pm = NSMenu()
        let presOpts: [(String, Presence)] = [("Tint (loud)", .tint), ("Frame + Dot", .frameDot), ("Dot only", .dotOnly), ("None  🔒", .none)]
        for (i, opt) in presOpts.enumerated() {
            let it = NSMenuItem(title: opt.0, action: #selector(setPresence(_:)), keyEquivalent: "")
            it.target = self; it.tag = i; it.state = FilterState.shared.presence == opt.1 ? .on : .off
            pm.addItem(it)
        }
        presItem.submenu = pm; m.addItem(presItem)
        m.addItem(NSMenuItem(title: "Meeting Copilot… (soon)", action: nil, keyEquivalent: "")) // Task #8 stub
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "API Keys… (soon)", action: nil, keyEquivalent: ""))   // Task: key vault
        m.addItem(NSMenuItem(title: "Security: Passcode (soon)", action: nil, keyEquivalent: ""))
        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit OrangeGenie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
        statusItem.menu = m
        updateIcon() // logo lights up / dims with state
    }

    func buildOverlays() {
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false
            w.level = .screenSaver
            w.ignoresMouseEvents = true                 // click-through — never steals interaction
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            w.setFrame(screen.frame, display: true)
            let v = OverlayView(frame: NSRect(origin: .zero, size: screen.frame.size))
            w.contentView = v
            w.orderFrontRegardless()
            windows.append(w); views.append(v)
        }
        redraw()
    }

    @objc func toggleFilter() {
        FilterState.shared.on.toggle()
        if FilterState.shared.on {
            FilterState.shared.flash = "🪔  Your Lamp is lit!  ·  Pick what to watch in the menu — or I'll stand by."
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { FilterState.shared.flash = nil; self.redraw() }
        } else {
            FilterState.shared.marks = []; FilterState.shared.flash = nil
        }
        rebuildMenu(); redraw()
    }

    func redraw() { views.forEach { $0.needsDisplay = true } }

    // ---- scope enumeration (READ-ONLY; never activates or moves a window) ----
    struct WinInfo { let owner: String; let title: String; let bounds: CGRect }
    func liveWindows() -> [WinInfo] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let arr = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        let mePID = Int(ProcessInfo.processInfo.processIdentifier)
        var out: [WinInfo] = []
        for w in arr {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
            let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0)
            if rect.width < 120 || rect.height < 80 { continue }
            if (w[kCGWindowOwnerPID as String] as? Int) == mePID { continue }
            let owner = w[kCGWindowOwnerName as String] as? String ?? "?"
            if ["Window Server", "Dock", "OrangeGenie", "Control Center", "Notification Center"].contains(owner) { continue }
            out.append(WinInfo(owner: owner, title: w[kCGWindowName as String] as? String ?? "", bounds: rect))
        }
        return out
    }
    func liveApps() -> [(name: String, bounds: CGRect)] {
        var map: [String: CGRect] = [:]
        for w in liveWindows() { map[w.owner] = (map[w.owner].map { $0.union(w.bounds) }) ?? w.bounds }
        return map.map { (name: $0.key, bounds: $0.value) }.sorted { $0.name < $1.name }
    }
    @objc func setFullScreen() {
        FilterState.shared.scopeMode = .fullscreen; FilterState.shared.scopeRect = .zero
        FilterState.shared.scopeLabel = "Whole screen"
        FilterState.shared.on = true   // choosing a scope turns the filter on (matches Select Window/App)
        rebuildMenu(); redraw()
    }
    @objc func pickWindow(_ sender: NSMenuItem) { applyScope(sender, .window) }
    @objc func pickApp(_ sender: NSMenuItem) { applyScope(sender, .app) }
    func applyScope(_ sender: NSMenuItem, _ mode: ScopeMode) {
        guard let d = sender.representedObject as? [String: Any], let rv = d["rect"] as? NSValue else { return }
        FilterState.shared.scopeMode = mode
        FilterState.shared.scopeRect = rv.rectValue
        FilterState.shared.scopeLabel = (d["label"] as? String) ?? "Selected"
        FilterState.shared.on = true            // choosing a scope turns the filter on
        rebuildMenu(); redraw()
        // We deliberately do NOT raise/activate the target — the filter never moves your windows.
    }
    @objc func setPresence(_ sender: NSMenuItem) {
        let all: [Presence] = [.tint, .frameDot, .dotOnly, .none]
        guard sender.tag >= 0 && sender.tag < all.count else { return }
        // NOTE: passcode gate for .none lands with the Security/vault task; for now it just sets the level.
        FilterState.shared.presence = all[sender.tag]
        rebuildMenu(); redraw()
    }

    func reloadMarks() {
        guard FilterState.shared.on else { return }
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: MARKS_PATH), let mt = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 else { return }
        if mt == lastMTime { return }
        lastMTime = mt
        if let data = fm.contents(atPath: MARKS_PATH), let marks = try? JSONDecoder().decode([Mark].self, from: data) {
            FilterState.shared.marks = marks; redraw()
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory) // menu-bar only, no Dock, no focus steal
let delegate = AppDelegate()
app.delegate = delegate
app.run()
