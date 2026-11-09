// The UIKit host (module 9a's iOS shell, a library since module 11a):
// UIKit behind the view primitive, the screen's one window with a
// full-screen container per Smalltalk Window, a CADisplayLink asking for
// 120 Hz. The shells (apps/KajoShell-iOS) and a generated app's iOS target
// run this one implementation.

#if os(iOS)
import KajoVM
import QuartzCore
import UIKit

@MainActor public final class UIKitHost: NSObject, ShellPlatform {
    struct Entry {
        let kind: String
        let view: UIView
        var titleLabel: UILabel? = nil
    }

    /// The view every Smalltalk Window's container goes into.
    public let root: UIView
    /// The shells' status line at the bottom of the screen (module 9a); nil
    /// in an app, whose status lines go to its log.
    let statusLabel: UILabel?
    var entries: [Int: Entry] = [:]
    var next = 1
    public var eventHandler: ((ShellEvent) -> Void)?
    /// Module 9c: not measured on iOS.
    public var textDrawn: ((Int) -> Void)?
    public func typeKey(_ handle: Int, _ text: String) -> Bool { false }
    var link: CADisplayLink?
    var tickHandler: (@MainActor (Double, Double) -> Void)?
    /// Views kept above every Smalltalk window (a development build's
    /// pairing screen).
    public var overlays: [UIView] = []

    /// `statusLine`: the shells' status text at the bottom; `spinner`: a
    /// layer the render server turns every frame, so ProMotion never
    /// throttles the display under a measurement.
    public init(root: UIView, statusLine: Bool, spinner: Bool) {
        self.root = root
        statusLabel = statusLine ? UILabel() : nil
        super.init()
        root.backgroundColor = .systemBackground
        if let statusLabel {
            statusLabel.numberOfLines = 0
            statusLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            statusLabel.frame = CGRect(x: 16, y: root.bounds.height - 220, width: root.bounds.width - 32, height: 200)
            statusLabel.autoresizingMask = [.flexibleWidth, .flexibleTopMargin]
            statusLabel.text = "Kajo: starting"
            root.addSubview(statusLabel)
        }
        if spinner {
            // Drawn by the render server every frame, whatever the main thread
            // does: the display is never idle enough for ProMotion to throttle.
            let spinner = CALayer()
            spinner.frame = CGRect(x: root.bounds.width - 50, y: 60, width: 24, height: 24)
            spinner.backgroundColor = UIColor.systemOrange.cgColor
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = 2 * Double.pi
            spin.duration = 1
            spin.repeatCount = .infinity
            spinner.add(spin, forKey: "spin")
            root.layer.addSublayer(spinner)
        }
    }

    public var maximumFramesPerSecond: Int { root.window?.windowScene?.screen.maximumFramesPerSecond ?? 60 }

    /// The status line: the shells' label, else the app's log.
    public var onStatus: ((String) -> Void)?
    public func showStatus(_ line: String) {
        statusLabel?.text = String(line.prefix(1200))
        onStatus?(line)
    }

    /// Keep `overlays` above everything else.
    public func raiseOverlays() {
        for v in overlays where v.superview === root { root.bringSubviewToFront(v) }
    }

    public func startDisplayLink(_ tick: @escaping @MainActor (Double, Double) -> Void) {
        tickHandler = tick
        let l = CADisplayLink(target: self, selector: #selector(frame(_:)))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        l.add(to: .main, forMode: .common)
        link = l
    }

    public func stopDisplayLink() {
        link?.invalidate()
        link = nil
    }

    @objc func frame(_ l: CADisplayLink) { tickHandler?(l.timestamp, l.targetTimestamp) }

    // MARK: the view host

    public func viewCall(_ call: ViewCall) -> ShellValue? {
        let a = call.arguments
        if call.op == "create" {
            guard case .string(let kind)? = a.first, let e = make(kind) else { return nil }
            let h = next
            next += 1
            entries[h] = e
            e.view.tag = h
            return .int(Int64(h))
        }
        if call.op == "openURL" { return openURL(a) }
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
            // The iOS shell is one full-screen window: a Window's frame is
            // its content size request only.
            if e.kind != "window" { e.view.frame = CGRect(x: x, y: y, width: w, height: h) }
            return .nil
        case "origin":
            guard a.count == 2, let x = a[0].double, let y = a[1].double else { return nil }
            e.view.frame.origin = CGPoint(x: x, y: y)
            return .nil
        case "add":
            guard case .int(let c)? = a.first, let child = entries[Int(c)], child.kind != "window" else { return nil }
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
            let v = UIView(frame: root.bounds.inset(by: root.safeAreaInsets))
            v.backgroundColor = .systemBackground
            v.isHidden = true
            let title = UILabel(frame: CGRect(x: 16, y: 8, width: v.bounds.width - 32, height: 28))
            title.font = .boldSystemFont(ofSize: 17)
            v.addSubview(title)
            return Entry(kind: kind, view: v, titleLabel: title)
        case "view":
            return Entry(kind: kind, view: UIView(frame: CGRect(x: 0, y: 0, width: 10, height: 10)))
        case "label":
            let l = UILabel(frame: CGRect(x: 0, y: 0, width: 100, height: 20))
            l.font = .monospacedDigitSystemFont(ofSize: 17, weight: .regular)
            return Entry(kind: kind, view: l)
        case "button":
            let b = UIButton(type: .system)
            b.frame = CGRect(x: 0, y: 0, width: 100, height: 36)
            b.addTarget(self, action: #selector(tapped(_:event:)), for: .touchUpInside)
            return Entry(kind: kind, view: b)
        case "slider":
            let s = UISlider(frame: CGRect(x: 0, y: 0, width: 100, height: 30))
            s.addTarget(self, action: #selector(slid(_:event:)), for: .valueChanged)
            return Entry(kind: kind, view: s)
        case "textView":
            let t = UITextView(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
            t.isEditable = false
            t.delegate = self
            t.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            return Entry(kind: kind, view: t)
        default:
            return nil
        }
    }

    func set(_ e: Entry, _ k: String, _ v: ShellValue) -> Bool {
        switch (k, e.view) {
        case ("text", let l as UILabel): l.text = v.string ?? "\(v)"
        case ("text", let t as UITextView): t.text = v.string ?? "\(v)"
        // Module 9c: the text view's second round (the other kinds are
        // the Mac's for now, docs/modules/developer-ui.md).
        case ("editable", let t as UITextView): t.isEditable = v == .bool(true)
        case ("keys", _ as UITextView): break
        case ("title", _) where e.kind == "window": e.titleLabel?.text = v.string ?? "\(v)"
        case ("title", let b as UIButton): b.setTitle(v.string ?? "\(v)", for: .normal)
        case ("value", let s as UISlider): s.value = Float(v.double ?? 0)
        case ("minimum", let s as UISlider): s.minimumValue = Float(v.double ?? 0)
        case ("maximum", let s as UISlider): s.maximumValue = Float(v.double ?? 1)
        case ("hidden", _): e.view.isHidden = v == .bool(true)
        case ("color", _): e.view.backgroundColor = color(v.string ?? "")
        case ("x", _), ("y", _), ("width", _), ("height", _):
            guard let d = v.double else { return false }
            switch k {
            case "x": e.view.frame.origin.x = d
            case "y": e.view.frame.origin.y = d
            case "width": e.view.frame.size.width = d
            default: e.view.frame.size.height = d
            }
        default: return false
        }
        return true
    }

    /// The discoverability follow-up: an http or https URL opened by the
    /// system (the tools' Help menu); anything else is refused.
    func openURL(_ a: [ShellValue]) -> ShellValue? {
        guard a.count == 1, let s = a[0].string, let u = URL(string: s), u.scheme == "https" || u.scheme == "http" else { return nil }
        UIApplication.shared.open(u)
        return .bool(true)
    }

    func get(_ e: Entry, _ k: String) -> ShellValue? {
        func num(_ d: CGFloat) -> ShellValue { d == d.rounded() ? .int(Int64(d)) : .double(Double(d)) }
        switch (k, e.view) {
        case ("text", let l as UILabel): return .string(l.text ?? "")
        case ("text", let t as UITextView): return .string(t.text ?? "")
        case ("editable", let t as UITextView): return .bool(t.isEditable)
        case ("focused", let t as UITextView): return .bool(t.isFirstResponder)
        case ("selection", let t as UITextView):
            let r = TextOffsets.byteRange(t.text ?? "", t.selectedRange)
            return .string("\(r.start) \(r.stop)")
        case ("title", _) where e.kind == "window": return .string(e.titleLabel?.text ?? "")
        case ("title", let b as UIButton): return .string(b.title(for: .normal) ?? "")
        case ("value", let s as UISlider): return .double(Double(s.value))
        case ("minimum", let s as UISlider): return .double(Double(s.minimumValue))
        case ("maximum", let s as UISlider): return .double(Double(s.maximumValue))
        case ("hidden", _): return .bool(e.view.isHidden)
        case ("x", _): return num(e.view.frame.origin.x)
        case ("y", _): return num(e.view.frame.origin.y)
        case ("width", _): return num(e.view.frame.width)
        case ("height", _): return num(e.view.frame.height)
        default: return nil
        }
    }

    func invoke(_ e: Entry, _ m: String, _ args: [ShellValue]) -> ShellValue? {
        switch m {
        case "show":
            guard e.kind == "window" else { return nil }
            e.view.isHidden = false
            if let statusLabel { root.insertSubview(e.view, belowSubview: statusLabel) } else { root.addSubview(e.view) }
            raiseOverlays()
            return .nil
        case "close":
            guard e.kind == "window" else { return nil }
            e.view.removeFromSuperview()
            return .nil
        case "appendLine":
            guard let t = e.view as? UITextView else { return nil }
            let line = args.first?.string ?? ""
            t.text = (t.text ?? "").isEmpty ? line : t.text + "\n" + line
            t.scrollRangeToVisible(NSRange(location: (t.text as NSString).length, length: 0))
            return .nil
        case "clear":
            (e.view as? UITextView)?.text = ""
            return .nil
        case "select":
            guard let t = e.view as? UITextView, args.count == 2, let a = args[0].int, let b = args[1].int,
                  let r = TextOffsets.nsRange(t.text ?? "", start: Int(a), stop: Int(b)) else { return nil }
            t.selectedRange = r
            return .nil
        case "scrollTo":
            guard let t = e.view as? UITextView, let a = args.first?.int,
                  let r = TextOffsets.nsRange(t.text ?? "", start: Int(a), stop: Int(a) - 1) else { return nil }
            t.scrollRangeToVisible(r)
            return .nil
        case "focus":
            guard let t = e.view as? UITextView else { return nil }
            t.becomeFirstResponder()
            return .nil
        case "setStyles":
            guard let t = e.view as? UITextView, args.count % 3 == 0 else { return nil }
            var triples: [(Int64?, Int64?, String?)] = []
            var k = 0
            while k + 2 < args.count { triples.append((args[k].int, args[k + 1].int, args[k + 2].string)); k += 3 }
            let text = t.text ?? ""
            let plain = UIFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let out = NSMutableAttributedString(string: text, attributes: [.font: plain, .foregroundColor: UIColor.label])
            for (r, st) in TextOffsets.styles(text, triples) {
                switch st {
                case .bold: out.addAttribute(.font, value: UIFont.monospacedSystemFont(ofSize: 11, weight: .bold), range: r)
                case .color(let c): out.addAttribute(.foregroundColor, value: color(c), range: r)
                case .background(let c): out.addAttribute(.backgroundColor, value: color(c).withAlphaComponent(0.3), range: r)
                }
            }
            let sel = t.selectedRange
            t.attributedText = out
            t.selectedRange = sel
            return .nil
        default:
            return nil
        }
    }

    public func releaseView(_ handle: Int) {
        guard let e = entries.removeValue(forKey: handle) else { return }
        e.view.removeFromSuperview()
    }

    func color(_ name: String) -> UIColor {
        switch name {
        case "red": .systemRed
        case "green": .systemGreen
        case "blue": .systemBlue
        case "orange": .systemOrange
        case "gray": .systemGray
        case "black": .black
        case "white": .white
        case "purple": .systemPurple
        case "brown": .systemBrown
        case "teal": .systemTeal
        case "yellow", "highlight": .systemYellow
        default: .clear
        }
    }

    // MARK: native events (stamped with when they happened)

    func stamp(_ event: UIEvent?) -> UInt64 { event.map { UInt64($0.timestamp * 1e9) } ?? ShellVM.now() }

    @objc func tapped(_ b: UIButton, event: UIEvent?) {
        eventHandler?(ShellEvent(kind: .click, target: b.tag, timeNs: stamp(event)))
    }

    @objc func slid(_ s: UISlider, event: UIEvent?) {
        eventHandler?(ShellEvent(kind: .valueChanged, target: s.tag, value: .double(Double(s.value)), timeNs: stamp(event)))
    }
}

extension UIKitHost: UITextViewDelegate {
    /// Module 9c: the user changed a text view's text.
    public func textViewDidChange(_ t: UITextView) {
        eventHandler?(ShellEvent(kind: .textChanged, target: t.tag, timeNs: ShellVM.now()))
    }
}
#endif
