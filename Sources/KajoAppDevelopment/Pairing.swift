import Foundation
import KajoApp
import KajoVM
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// Module 9d's pairing screen, a development build's since module 11a: the
// token large, the Bonjour name and the addresses, what the listener does,
// and a "new token" button that ends every session. In the iOS shell it is
// shown while the shell serves (`showsAtOnce`); in an app it is reached
// from the running app (a shake on iOS, the app menu's Pairing item on the
// Mac) and closed again. The Mac shell keeps 9d's status line.

#if os(iOS)
/// The UIKit pairing panel over every Smalltalk window.
@MainActor public final class PairingScreen: NSObject, PairingPresenter {
    let host: UIKitHost
    /// Shown as soon as there is something to show (the iOS shell's serve
    /// mode); else only when `toggle()` asks.
    let showsAtOnce: Bool
    public var onNewToken: (() -> Void)?
    var info: PairingInfo?
    var panel: UIView?
    let name = UILabel()
    let token = UILabel()
    let addresses = UILabel()
    let status = UILabel()
    public private(set) var isShown = false

    public init(host: UIKitHost, showsAtOnce: Bool) {
        self.host = host
        self.showsAtOnce = showsAtOnce
    }

    public func showPairing(_ info: PairingInfo?) {
        self.info = info
        guard info != nil else { return hide() }
        if showsAtOnce || isShown { show() }
    }

    /// The way in and out: a shake (or a test) shows the panel, the next
    /// one or its Close button hides it.
    public func toggle() {
        if isShown { hide() } else { show() }
    }

    func show() {
        guard let info else { return }
        let root = host.root
        if panel == nil {
            let v = UIView(frame: CGRect(x: 12, y: root.safeAreaInsets.top + 44, width: root.bounds.width - 24, height: 210))
            v.backgroundColor = UIColor.secondarySystemBackground.withAlphaComponent(0.95)
            v.layer.cornerRadius = 12
            v.autoresizingMask = [.flexibleWidth]
            name.font = .boldSystemFont(ofSize: 17)
            token.font = .monospacedSystemFont(ofSize: 28, weight: .bold)
            token.adjustsFontSizeToFitWidth = true
            addresses.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            addresses.numberOfLines = 3
            status.font = .systemFont(ofSize: 13)
            status.numberOfLines = 2
            let w = v.bounds.width - 24
            name.frame = CGRect(x: 12, y: 8, width: w, height: 22)
            token.frame = CGRect(x: 12, y: 34, width: w, height: 40)
            addresses.frame = CGRect(x: 12, y: 78, width: w, height: 48)
            status.frame = CGRect(x: 12, y: 128, width: w, height: 36)
            let b = UIButton(type: .system)
            b.setTitle("New token", for: .normal)
            b.frame = CGRect(x: 12, y: 166, width: 140, height: 36)
            b.addTarget(self, action: #selector(newToken), for: .touchUpInside)
            for l in [name, token, addresses, status] {
                l.autoresizingMask = [.flexibleWidth]
                v.addSubview(l)
            }
            v.addSubview(b)
            if !showsAtOnce {
                let c = UIButton(type: .system)
                c.setTitle("Close", for: .normal)
                c.frame = CGRect(x: v.bounds.width - 112, y: 166, width: 100, height: 36)
                c.autoresizingMask = [.flexibleLeftMargin]
                c.addTarget(self, action: #selector(close), for: .touchUpInside)
                v.addSubview(c)
            }
            panel = v
        }
        name.text = "Kajo serves: " + (info.name.isEmpty ? "(advertising)" : info.name)
        token.text = info.token
        addresses.text = info.addresses.map { $0.contains(":") ? "[\($0)]:\(info.port)" : "\($0):\(info.port)" }.joined(separator: "\n")
        status.text = info.status
        if let v = panel {
            if v.superview == nil { root.addSubview(v) }
            if !host.overlays.contains(v) { host.overlays.append(v) }
            host.raiseOverlays()
        }
        isShown = true
    }

    func hide() {
        if let v = panel {
            v.removeFromSuperview()
            host.overlays.removeAll { $0 === v }
        }
        isShown = false
    }

    @objc func newToken() { onNewToken?() }
    @objc func close() { hide() }

    /// Module 9d: a secret in a secure field of the host's own.
    public func askSecret(_ prompt: String, _ done: @escaping (String?) -> Void) {
        let a = UIAlertController(title: "Pair a target", message: prompt, preferredStyle: .alert)
        a.addTextField { $0.isSecureTextEntry = true }
        a.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(nil) })
        a.addAction(UIAlertAction(title: "Pair", style: .default) { [weak a] _ in done(a?.textFields?.first?.text) })
        host.root.window?.rootViewController?.present(a, animated: true)
    }
}
#elseif os(macOS)
/// The AppKit pairing screen: the shell's status line (module 9d) or, in an
/// app, a window the app menu's Pairing item opens.
@MainActor public final class PairingScreen: NSObject, PairingPresenter, NSWindowDelegate {
    public enum Style: Sendable { case statusLine, window }
    let host: AppKitHost
    let style: Style
    public var onNewToken: (() -> Void)?
    var info: PairingInfo?
    var window: NSWindow?
    let name = NSTextField(labelWithString: "")
    let token = NSTextField(labelWithString: "")
    let addresses = NSTextField(wrappingLabelWithString: "")
    let status = NSTextField(wrappingLabelWithString: "")
    public var isShown: Bool { window?.isVisible ?? false }

    public init(host: AppKitHost, style: Style) {
        self.host = host
        self.style = style
    }

    public func showPairing(_ info: PairingInfo?) {
        self.info = info
        switch style {
        case .statusLine:
            guard let i = info else { return }
            host.showStatus("serving tcp \(i.name) port \(i.port) \(i.addresses.joined(separator: " ")) token \(i.token) \(i.status)")
        case .window:
            if isShown { fill() }
        }
    }

    /// The app menu's Pairing item: open the window (again), or close it.
    @objc public func toggle() {
        if isShown { window?.close() } else { open() }
    }

    func open() {
        guard info != nil else { return }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 230), styleMask: [.titled, .closable],
                             backing: .buffered, defer: false)
            w.title = "Pairing"
            w.isReleasedWhenClosed = false
            w.delegate = self
            name.font = .boldSystemFont(ofSize: 15)
            token.font = .monospacedSystemFont(ofSize: 26, weight: .bold)
            token.isSelectable = true
            addresses.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
            status.font = .systemFont(ofSize: 12)
            name.frame = NSRect(x: 16, y: 190, width: 388, height: 22)
            token.frame = NSRect(x: 16, y: 148, width: 388, height: 36)
            addresses.frame = NSRect(x: 16, y: 84, width: 388, height: 60)
            status.frame = NSRect(x: 16, y: 52, width: 388, height: 30)
            let b = NSButton(title: "New token", target: self, action: #selector(newToken))
            b.frame = NSRect(x: 12, y: 12, width: 120, height: 30)
            for v in [name, token, addresses, status, b] { w.contentView?.addSubview(v) }
            w.center()
            window = w
        }
        fill()
        window?.makeKeyAndOrderFront(nil)
    }

    func fill() {
        guard let info else { return }
        name.stringValue = "Kajo serves: " + (info.name.isEmpty ? "(advertising)" : info.name)
        token.stringValue = info.token
        addresses.stringValue = info.addresses.map { $0.contains(":") ? "[\($0)]:\(info.port)" : "\($0):\(info.port)" }.joined(separator: "\n")
        status.stringValue = info.status
    }

    @objc func newToken() { onNewToken?() }

    /// Module 9d: a target's pairing token, typed into a secure field of
    /// the host's own (it goes to the client transport, never the image).
    public func askSecret(_ prompt: String, _ done: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Pair a target"
        alert.informativeText = prompt
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Pair")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        let answer = alert.runModal()
        done(answer == .alertFirstButtonReturn ? field.stringValue : nil)
    }
}
#endif
