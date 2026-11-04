// The macOS shell (module 9a): AppKit behind the view primitive, one
// NSWindow per Smalltalk Window, a CADisplayLink from the status window's
// view. Everything else is KajoShellCore, shared with the iOS shell.
//
//   KajoShell.app/Contents/MacOS/KajoShell mode=tests|golden|scenario|demo key=value...

import AppKit
import IOKit.pwr_mgt
import KajoShellCore
import KajoVM
import QuartzCore

/// y grows downwards in every container, as on UIKit (ADR 0010).
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor final class MacPlatform: NSObject, ShellPlatform, NSWindowDelegate {
    struct Entry {
        let kind: String
        let view: NSView
        var window: NSWindow? = nil
    }

    var entries: [Int: Entry] = [:]
    var next = 1
    var eventHandler: ((ShellEvent) -> Void)?
    let statusWindow: NSWindow
    let statusLabel: NSTextField
    var link: CADisplayLink?
    var tickHandler: (@MainActor (Double, Double) -> Void)?
    /// Windows Smalltalk closed (no close event goes back for those).
    var closing: Set<ObjectIdentifier> = []

    override init() {
        statusWindow = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 520, height: 120),
                                styleMask: [.titled, .miniaturizable], backing: .buffered, defer: false)
        statusWindow.title = "Kajo shell"
        statusLabel = NSTextField(wrappingLabelWithString: "starting")
        statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        statusLabel.frame = NSRect(x: 12, y: 12, width: 496, height: 96)
        super.init()
        statusWindow.contentView?.addSubview(statusLabel)
        statusWindow.isReleasedWhenClosed = false
        statusWindow.orderFront(nil)
    }

    var maximumFramesPerSecond: Int { (statusWindow.screen ?? NSScreen.main)?.maximumFramesPerSecond ?? 60 }

    func showStatus(_ line: String) { statusLabel.stringValue = String(line.prefix(600)) }

    var displayAssertion: IOPMAssertionID = 0

    func startDisplayLink(_ tick: @escaping @MainActor (Double, Double) -> Void) {
        tickHandler = tick
        // An asleep display delivers no frames: wake it (user activity, as a
        // key press would) and keep it awake while the link runs, as the
        // iOS shell keeps the idle timer off. No setting is changed.
        var activity: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity("Kajo shell measurement" as CFString, kIOPMUserActiveLocal, &activity)
        _ = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn), "Kajo shell measurement" as CFString,
                                        &displayAssertion)
        // The screen's link, not a view's: a view's stops while its window
        // is occluded, and the measurement must not depend on window order.
        guard let screen = statusWindow.screen ?? NSScreen.main else { return }
        let l = screen.displayLink(target: self, selector: #selector(frame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stopDisplayLink() {
        link?.invalidate()
        link = nil
        if displayAssertion != 0 { IOPMAssertionRelease(displayAssertion); displayAssertion = 0 }
    }

    @objc func frame(_ l: CADisplayLink) { tickHandler?(l.timestamp, l.targetTimestamp) }

    // MARK: the view host

    func viewCall(_ call: ViewCall) -> ShellValue? {
        let a = call.arguments
        if call.op == "create" {
            guard case .string(let kind)? = a.first, let e = make(kind) else { return nil }
            let h = next
            next += 1
            entries[h] = e
            e.view.identifier = NSUserInterfaceItemIdentifier("\(h)")
            return .int(Int64(h))
        }
        guard let e = entries[call.handle] else { return nil }
        switch call.op {
        case "set":
            guard a.count == 2, case .string(let k) = a[0] else { return nil }
            return set(e, k, a[1]) ? a[1] : nil
        case "get":
            guard a.count == 1, case .string(let k) = a[0] else { return nil }
            return get(e, k)
        case "frame":
            guard a.count == 4, let x = a[0].double, let y = a[1].double, let w = a[2].double, let h = a[3].double else { return nil }
            if let win = e.window {
                let screen = win.screen ?? NSScreen.main
                let top = screen?.visibleFrame.maxY ?? 800
                win.setContentSize(NSSize(width: w, height: h))
                win.setFrameTopLeftPoint(NSPoint(x: x, y: top - y))
            } else {
                e.view.frame = NSRect(x: x, y: y, width: w, height: h)
            }
            return .nil
        case "origin":
            guard a.count == 2, let x = a[0].double, let y = a[1].double else { return nil }
            e.view.setFrameOrigin(NSPoint(x: x, y: y))
            return .nil
        case "add":
            guard case .int(let c)? = a.first, let child = entries[Int(c)], child.window == nil else { return nil }
            e.view.addSubview(child.view)
            return .nil
        case "call":
            guard case .string(let m)? = a.first else { return nil }
            return invoke(e, m, Array(a.dropFirst()))
        default:
            return nil
        }
    }

    func make(_ kind: String) -> Entry? {
        switch kind {
        case "window":
            let w = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 400, height: 300),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            let content = FlippedView()
            w.contentView = content
            w.delegate = self
            return Entry(kind: kind, view: content, window: w)
        case "view":
            let v = FlippedView(frame: NSRect(x: 0, y: 0, width: 10, height: 10))
            v.wantsLayer = true
            return Entry(kind: kind, view: v)
        case "label":
            let l = NSTextField(labelWithString: "")
            l.frame = NSRect(x: 0, y: 0, width: 100, height: 20)
            return Entry(kind: kind, view: l)
        case "button":
            let b = NSButton(title: "", target: self, action: #selector(clicked(_:)))
            b.frame = NSRect(x: 0, y: 0, width: 100, height: 30)
            return Entry(kind: kind, view: b)
        case "slider":
            let s = NSSlider(value: 0, minValue: 0, maxValue: 1, target: self, action: #selector(slid(_:)))
            s.frame = NSRect(x: 0, y: 0, width: 100, height: 24)
            return Entry(kind: kind, view: s)
        case "textView":
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
            (scroll.documentView as? NSTextView)?.isEditable = false
            (scroll.documentView as? NSTextView)?.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            return Entry(kind: kind, view: scroll)
        default:
            return nil
        }
    }

    func textView(_ e: Entry) -> NSTextView? { (e.view as? NSScrollView)?.documentView as? NSTextView }

    func set(_ e: Entry, _ k: String, _ v: ShellValue) -> Bool {
        switch (k, e.view) {
        case ("text", let l as NSTextField): l.stringValue = v.string ?? "\(v)"
        case ("text", _) where e.kind == "textView": textView(e)?.string = v.string ?? "\(v)"
        case ("title", _) where e.window != nil: e.window!.title = v.string ?? "\(v)"
        case ("title", let b as NSButton): b.title = v.string ?? "\(v)"
        case ("value", let s as NSSlider): s.doubleValue = v.double ?? 0
        case ("minimum", let s as NSSlider): s.minValue = v.double ?? 0
        case ("maximum", let s as NSSlider): s.maxValue = v.double ?? 1
        case ("hidden", _): e.view.isHidden = v == .bool(true)
        case ("color", _):
            e.view.wantsLayer = true
            e.view.layer?.backgroundColor = color(v.string ?? "").cgColor
        case ("x", _), ("y", _), ("width", _), ("height", _):
            guard let d = v.double else { return false }
            var f = e.view.frame
            switch k {
            case "x": f.origin.x = d
            case "y": f.origin.y = d
            case "width": f.size.width = d
            default: f.size.height = d
            }
            e.view.frame = f
        default: return false
        }
        return true
    }

    func get(_ e: Entry, _ k: String) -> ShellValue? {
        func num(_ d: CGFloat) -> ShellValue { d == d.rounded() ? .int(Int64(d)) : .double(Double(d)) }
        switch (k, e.view) {
        case ("text", let l as NSTextField): return .string(l.stringValue)
        case ("text", _) where e.kind == "textView": return .string(textView(e)?.string ?? "")
        case ("title", _) where e.window != nil: return .string(e.window!.title)
        case ("title", let b as NSButton): return .string(b.title)
        case ("value", let s as NSSlider): return .double(s.doubleValue)
        case ("minimum", let s as NSSlider): return .double(s.minValue)
        case ("maximum", let s as NSSlider): return .double(s.maxValue)
        case ("hidden", _): return .bool(e.view.isHidden)
        case ("x", _): return num(e.view.frame.origin.x)
        case ("y", _): return num(e.view.frame.origin.y)
        case ("width", _): return num(e.window.map { $0.contentLayoutRect.width } ?? e.view.frame.width)
        case ("height", _): return num(e.window.map { $0.contentLayoutRect.height } ?? e.view.frame.height)
        default: return nil
        }
    }

    func invoke(_ e: Entry, _ m: String, _ args: [ShellValue]) -> ShellValue? {
        switch m {
        case "show":
            e.window?.makeKeyAndOrderFront(nil)
            return .nil
        case "close":
            if let w = e.window {
                closing.insert(ObjectIdentifier(w))
                w.close()
            }
            return .nil
        case "appendLine":
            guard let t = textView(e) else { return nil }
            let line = args.first?.string ?? ""
            let s = t.string.isEmpty ? line : t.string + "\n" + line
            t.string = s
            t.scrollToEndOfDocument(nil)
            return .nil
        case "clear":
            textView(e)?.string = ""
            return .nil
        default:
            return nil
        }
    }

    func releaseView(_ handle: Int) {
        guard let e = entries.removeValue(forKey: handle) else { return }
        if let w = e.window {
            closing.insert(ObjectIdentifier(w))
            w.close()
        } else {
            e.view.removeFromSuperview()
        }
    }

    func color(_ name: String) -> NSColor {
        switch name {
        case "red": .systemRed
        case "green": .systemGreen
        case "blue": .systemBlue
        case "orange": .systemOrange
        case "gray": .systemGray
        case "black": .black
        case "white": .white
        default: .clear
        }
    }

    // MARK: native events

    func handle(of v: NSView) -> Int { Int(v.identifier?.rawValue ?? "") ?? 0 }

    func now() -> UInt64 { NSApp.currentEvent.map { UInt64($0.timestamp * 1e9) } ?? ShellVM.now() }

    @objc func clicked(_ b: NSButton) {
        eventHandler?(ShellEvent(kind: .click, target: handle(of: b), timeNs: now()))
    }

    @objc func slid(_ s: NSSlider) {
        eventHandler?(ShellEvent(kind: .valueChanged, target: handle(of: s), value: .double(s.doubleValue), timeNs: now()))
    }

    func windowWillClose(_ n: Notification) {
        guard let w = n.object as? NSWindow else { return }
        if closing.remove(ObjectIdentifier(w)) != nil { return }
        guard let content = w.contentView else { return }
        eventHandler?(ShellEvent(kind: .close, target: handle(of: content), timeNs: ShellVM.now()))
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var platform: MacPlatform?
    var app: ShellApp?

    func applicationDidFinishLaunching(_ n: Notification) {
        let p = MacPlatform()
        platform = p
        let a = ShellApp(platform: p)
        app = a
        Output.shared.setOnLine(statusSink { [weak p] line in p?.showStatus(line) })
        NSApp.activate()
        // After the first frame, as on iOS.
        DispatchQueue.main.async { MainActor.assumeIsolated { a.start() } }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }
}

@main @MainActor enum Main {
    static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
