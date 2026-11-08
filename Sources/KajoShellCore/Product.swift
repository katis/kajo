import Foundation
import KajoGenerator

// Module 11b (docs/modules/distribution.md, part 1): the Kajo app, the macOS
// shell launched with no `mode=`. It copies the checkout it carries
// (`Contents/Resources/Kajo-<version>/`) to Application Support once per
// version, opens the development image with the tools on it (9c's `mode=dev`,
// the changes the tools make written back to the copied checkout's `tools/`),
// and puts File > New App... (the generator over the copied checkout) and
// File > Install Command Line Tool... (a symbolic link to the bundled `kajo`)
// in the menu bar. The measurement modes stay behind `mode=`.
//
// The parts that touch the file system are plain functions over paths, so
// the tests run them against scratch directories; the app reads two
// overrides from its environment for the same reason (KAJO_SUPPORT_DIR for
// Application Support's Kajo folder, KAJO_CLI_LINK_DIR for /usr/local/bin).

/// Whether `path` is a directory (following a link).
func isDirectory(_ path: String) -> Bool {
    (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
}

/// Why New App did not make a project, as the window shows it.
public struct NewAppFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

/// Where the Kajo app's parts are, for one bundle and environment.
public struct ProductPaths: Sendable, Equatable {
    /// The version the bundle carries (CFBundleShortVersionString).
    public let version: String
    /// `Contents/Resources/Kajo-<version>`, the checkout in the bundle.
    public let bundledCheckout: String
    /// Application Support's Kajo folder (or KAJO_SUPPORT_DIR).
    public let supportRoot: String
    /// `Contents/Helpers/kajo`, the CLI (`kajo` and `kajo mcp`). Not
    /// `Contents/MacOS/kajo`: on a case-insensitive volume that name is
    /// the app's own executable, `Kajo`.
    public let cli: String
    /// `Contents/Resources/xcodegen/bin/xcodegen`, its presets in
    /// `share/` beside `bin/` where it looks for them (in `Contents/Helpers`
    /// the presets would be unsigned files in a code directory, which
    /// codesign refuses).
    public let xcodegen: String
    /// Where File > Install Command Line Tool... puts the link
    /// (/usr/local/bin, or KAJO_CLI_LINK_DIR).
    public let linkDirectory: String

    /// `<support>/<version>`: the checkout generated projects pin.
    public var installedCheckout: String { supportRoot + "/" + version }

    public init(version: String, bundle: String, environment: [String: String] = [:], home: String = NSHomeDirectory()) {
        self.version = version
        bundledCheckout = bundle + "/Contents/Resources/Kajo-" + version
        supportRoot = environment["KAJO_SUPPORT_DIR"] ?? home + "/Library/Application Support/Kajo"
        cli = bundle + "/Contents/Helpers/kajo"
        xcodegen = bundle + "/Contents/Resources/xcodegen/bin/xcodegen"
        linkDirectory = environment["KAJO_CLI_LINK_DIR"] ?? "/usr/local/bin"
    }

    /// The running app's.
    public static func current() -> ProductPaths {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0"
        return ProductPaths(version: v, bundle: Bundle.main.bundlePath, environment: ProcessInfo.processInfo.environment)
    }
}

/// What installing the checkout did.
public enum CheckoutInstall: Equatable, Sendable {
    /// Copied now (bytes, milliseconds).
    case copied(Int, Double)
    /// This version's folder was already there, complete.
    case present
    /// The bundle carries no checkout (a build from the repository).
    case noCheckout
    case failed(String)

    /// The Transcript's line for it.
    public func line(_ paths: ProductPaths) -> String {
        switch self {
        case .copied(let bytes, let ms):
            "Kajo \(paths.version): copied the Kajo checkout to \(paths.installedCheckout) (\(bytes / 1_000_000) MB in \(Int(ms)) ms); new apps pin it, and the tools write their changes to its tools/"
        case .present: "Kajo \(paths.version): the Kajo checkout is \(paths.installedCheckout)"
        case .noCheckout: "Kajo \(paths.version): this build carries no checkout (built from the repository); New App needs KAJO_CHECKOUT"
        case .failed(let why): "Kajo \(paths.version): could not copy the Kajo checkout to \(paths.installedCheckout): \(why)"
        }
    }
}

public enum CheckoutInstaller {
    /// The file that marks a version's folder complete; written last.
    public static let marker = ".kajo-checkout"

    /// Copy `from` to `to` unless `to` is already a complete copy: into a
    /// sibling temporary folder first, then renamed, so an interrupted copy
    /// is never taken for a checkout. A folder without the marker (left by
    /// a crash, or not Kajo's) is moved aside, never deleted.
    public static func install(from: String, to: String) -> CheckoutInstall {
        let fm = FileManager.default
        guard isDirectory(from) else { return .noCheckout }
        if fm.fileExists(atPath: to + "/" + marker) { return .present }
        let t0 = Date()
        let parent = (to as NSString).deletingLastPathComponent
        let partial = to + ".partial-\(ProcessInfo.processInfo.processIdentifier)"
        do {
            try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            try? fm.removeItem(atPath: partial)
            try fm.copyItem(atPath: from, toPath: partial)
            let bytes = directoryBytes(partial)
            try Data("Kajo checkout, copied by the Kajo app from \(from)\n".utf8).write(to: URL(fileURLWithPath: partial + "/" + marker))
            if fm.fileExists(atPath: to) {
                try fm.moveItem(atPath: to, toPath: to + ".incomplete-\(Int(Date().timeIntervalSince1970))")
            }
            try fm.moveItem(atPath: partial, toPath: to)
            return .copied(bytes, Date().timeIntervalSince(t0) * 1000)
        } catch {
            try? fm.removeItem(atPath: partial)
            return .failed(error.localizedDescription)
        }
    }

    static func directoryBytes(_ path: String) -> Int {
        var n = 0
        let e = FileManager.default.enumerator(atPath: path)
        while let p = e?.nextObject() as? String {
            if let a = try? FileManager.default.attributesOfItem(atPath: path + "/" + p), a[.type] as? FileAttributeType == .typeRegular {
                n += (a[.size] as? Int) ?? 0
            }
        }
        return n
    }
}

/// File > Install Command Line Tool...: `<dir>/kajo` as a symbolic link to
/// the bundled CLI, made only when the developer asks.
public enum CommandLineTool {
    public enum Outcome: Equatable, Sendable {
        case linked(String)
        /// The directory cannot be written (on a fresh Mac /usr/local/bin is
        /// root's): the command to run instead.
        case needsPermission(String)
        /// Something that is not our link is there already.
        case occupied(String)
        case failed(String)
    }

    public static func install(cli: String, into dir: String) -> Outcome {
        let fm = FileManager.default
        let link = dir + "/kajo"
        let command = "sudo mkdir -p \(dir) && sudo ln -sf '\(cli)' \(link)"
        guard fm.isExecutableFile(atPath: cli) else { return .failed("no kajo in the app at \(cli)") }
        if let a = try? fm.attributesOfItem(atPath: link) {
            guard a[.type] as? FileAttributeType == .typeSymbolicLink,
                  let dest = try? fm.destinationOfSymbolicLink(atPath: link),
                  dest.hasSuffix("/Contents/Helpers/kajo") else { return .occupied(link) }
            // Ours, from this or another copy of the app: replaced.
            guard fm.isWritableFile(atPath: dir) else { return .needsPermission(command) }
            do { try fm.removeItem(atPath: link) } catch { return .failed(error.localizedDescription) }
        } else {
            guard isDirectory(dir), fm.isWritableFile(atPath: dir) else {
                return .needsPermission(command)
            }
        }
        do {
            try fm.createSymbolicLink(atPath: link, withDestinationPath: cli)
            return .linked(link)
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}

/// What the New App window asks, as a generator spec over the checkout.
public struct NewAppRequest: Sendable, Equatable {
    public var name: String
    public var bundleIdentifier: String
    /// The directory the project folder `<name>` is made in.
    public var location: String
    public var platforms: [AppPlatform]

    public init(name: String, bundleIdentifier: String, location: String, platforms: [AppPlatform]) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.location = location
        self.platforms = platforms
    }

    public var directory: String { (location as NSString).appendingPathComponent(name) }

    /// Write the project and make its Xcode project: the project file's
    /// path, or the refusal's text.
    public func create(checkout: String, xcodegen: String?) -> Result<String, NewAppFailure> {
        let spec = AppProjectSpec(name: name, bundleIdentifier: bundleIdentifier, kajo: .path(checkout), platforms: platforms)
        if let r = AppProjectGenerator.check(spec) ?? AppProjectGenerator.checkCheckout(spec.kajo) { return .failure(NewAppFailure(r.description)) }
        guard location.hasPrefix("/") else { return .failure(NewAppFailure("choose a folder for the project")) }
        switch AppProjectGenerator.write(spec, into: directory) {
        case .failure(let r): return .failure(NewAppFailure(r.description))
        case .success: break
        }
        #if os(macOS)
        do {
            guard try AppProjectGenerator.generateXcodeProject(in: directory, xcodegen: xcodegen) else {
                return .failure(NewAppFailure("the project is written to \(directory), but no xcodegen was found to make its Xcode project"))
            }
        } catch {
            return .failure(NewAppFailure("\(error)"))
        }
        return .success(directory + "/" + name + ".xcodeproj")
        #else
        // KajoShellCore is the iOS shell's too, where no process can be run.
        return .failure(NewAppFailure("the project is written to \(directory); make its Xcode project on a Mac"))
        #endif
    }
}

#if os(macOS)
import AppKit
import KajoApp
import KajoAppDevelopment

/// The Kajo app: what the macOS shell does when launched with no `mode=`.
/// `newapp=<Name> bundle=<id> into=<dir> [platforms=macOS,iOS]` fills the
/// New App window and presses Create, for a scripted round trip;
/// KAJO_OPEN_XCODE=0 in the environment keeps Xcode closed afterwards.
@MainActor public final class ProductMode: NSObject {
    let options: LaunchOptions
    let host: AppKitHost
    let pairing: PairingScreen
    let paths: ProductPaths
    var dev: DevMode?
    var wizard: NewAppWindow?
    public private(set) var install: CheckoutInstall = .noCheckout

    public init(_ options: LaunchOptions, host: AppKitHost, pairing: PairingScreen, paths: ProductPaths = .current()) {
        self.options = options
        self.host = host
        self.pairing = pairing
        self.paths = paths
    }

    /// The checkout New App pins: the copied one, or KAJO_CHECKOUT for a
    /// build from the repository.
    var checkout: String {
        if case .noCheckout = install, let c = ProcessInfo.processInfo.environment["KAJO_CHECKOUT"] { return c }
        return paths.installedCheckout
    }

    /// Before the first frame: the menu bar, so the tools' Tools menu joins it.
    public func installMenus() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let app = NSMenu(title: "Kajo")
        app.addItem(NSMenuItem(title: "About Kajo", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        let pair = NSMenuItem(title: "Pairing…", action: #selector(PairingScreen.toggle), keyEquivalent: "p")
        pair.keyEquivalentModifierMask = [.command, .shift]
        pair.target = pairing
        app.addItem(pair)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Kajo", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(NSMenuItem(title: "Quit Kajo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = app
        bar.addItem(appItem)
        let fileItem = NSMenuItem()
        let file = NSMenu(title: "File")
        let new = NSMenuItem(title: "New App…", action: #selector(newApp), keyEquivalent: "n")
        new.target = self
        file.addItem(new)
        let cli = NSMenuItem(title: "Install Command Line Tool…", action: #selector(installCommandLineTool), keyEquivalent: "")
        cli.target = self
        file.addItem(cli)
        fileItem.submenu = file
        bar.addItem(fileItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }

    /// After the first frame: the checkout, then the tools on the
    /// development image, then the Transcript line.
    public func start() {
        install = CheckoutInstaller.install(from: paths.bundledCheckout, to: paths.installedCheckout)
        let line = install.line(paths)
        Output.shared.emit("product version=\(paths.version) checkout=\(paths.installedCheckout) install=\(installTag)")
        var o = LaunchOptions([])
        o.values = options.values
        o.values["mode"] = "dev"
        if o.values["project"] == nil, installTag != "none", installTag != "failed" {
            o.values["project"] = paths.installedCheckout + "/tools"
        }
        let d = DevMode(o, platform: host, pairing: pairing)
        dev = d
        d.start()
        if let rt = d.runtime, let p = rt.vm.spawn("showLine:", receiver: "Transcript", arguments: [.string(line)]) {
            rt.vm.release(p)
        }
        if options["cli-install"] != nil { installCommandLineTool() }
        if let name = options["newapp"] {
            DispatchQueue.main.async { MainActor.assumeIsolated { self.scriptedNewApp(name) } }
        }
    }

    var installTag: String {
        switch install {
        case .copied: "copied"
        case .present: "present"
        case .noCheckout: "none"
        case .failed: "failed"
        }
    }

    @objc func newApp() {
        let w = wizard ?? NewAppWindow { [weak self] request in
            guard let self else { return .failure(NewAppFailure("the app is closing")) }
            return self.create(request)
        }
        wizard = w
        w.show()
    }

    func create(_ r: NewAppRequest) -> Result<String, NewAppFailure> {
        let result = r.create(checkout: checkout, xcodegen: paths.xcodegen)
        switch result {
        case .success(let project):
            Output.shared.emit("newapp=ok project=\(project)")
            if ProcessInfo.processInfo.environment["KAJO_OPEN_XCODE"] != "0" {
                NSWorkspace.shared.open(URL(fileURLWithPath: project))
            }
        case .failure(let why):
            Output.shared.emit("newapp=refused why=\(why.description.replacingOccurrences(of: " ", with: "_"))")
        }
        return result
    }

    func scriptedNewApp(_ name: String) {
        newApp()
        guard let w = wizard else { return }
        let ps = (options["platforms"] ?? "macOS,iOS").split(separator: ",").compactMap { AppPlatform(rawValue: String($0)) }
        w.fill(NewAppRequest(name: name, bundleIdentifier: options["bundle"] ?? "", location: options["into"] ?? "", platforms: ps))
        w.create(nil)
    }

    @objc func installCommandLineTool() {
        let outcome = CommandLineTool.install(cli: paths.cli, into: paths.linkDirectory)
        let alert = NSAlert()
        switch outcome {
        case .linked(let l):
            alert.messageText = "Installed kajo"
            alert.informativeText = "\(l) now runs the kajo in this app (kajo new, kajo eval, kajo mcp, ...)."
        case .needsPermission(let command):
            alert.messageText = "\(paths.linkDirectory) needs an administrator"
            alert.informativeText = "Run this in Terminal to install kajo:\n\n\(command)"
        case .occupied(let l):
            alert.messageText = "\(l) is already there"
            alert.informativeText = "It is not a link to Kajo's kajo, so it was left alone."
        case .failed(let why):
            alert.messageText = "Could not install kajo"
            alert.informativeText = why
        }
        Output.shared.emit("cli-install=\(outcome)")
        if options["cli-install"] == nil { alert.runModal() }
    }

    /// `cli-install=1`: the menu item's action at launch, for the test of it
    /// (the alert is not shown).
    public func scriptedCommandLineTool() { installCommandLineTool() }
}

/// File > New App...: the name, the bundle identifier, the folder, the two
/// targets; Create writes the project and opens it in Xcode.
@MainActor final class NewAppWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    let name = NSTextField(string: "")
    let bundle = NSTextField(string: "")
    let location = NSTextField(string: "")
    let mac = NSButton(checkboxWithTitle: "Mac", target: nil, action: nil)
    let ios = NSButton(checkboxWithTitle: "iPhone and iPad", target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    let onCreate: (NewAppRequest) -> Result<String, NewAppFailure>

    init(onCreate: @escaping (NewAppRequest) -> Result<String, NewAppFailure>) {
        self.onCreate = onCreate
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = "New App"
        window.isReleasedWhenClosed = false
        window.delegate = self
        let v = window.contentView!
        func label(_ s: String, _ y: CGFloat) {
            let l = NSTextField(labelWithString: s)
            l.alignment = .right
            l.frame = NSRect(x: 12, y: y + 3, width: 120, height: 18)
            v.addSubview(l)
        }
        label("Name", 222); name.frame = NSRect(x: 140, y: 220, width: 320, height: 24)
        name.placeholderString = "Sample"
        label("Bundle identifier", 188); bundle.frame = NSRect(x: 140, y: 186, width: 320, height: 24)
        bundle.placeholderString = "com.example.sample"
        label("Folder", 154); location.frame = NSRect(x: 140, y: 152, width: 230, height: 24)
        location.stringValue = NSHomeDirectory() + "/Developer"
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        choose.frame = NSRect(x: 374, y: 148, width: 92, height: 30)
        label("Targets", 120); mac.frame = NSRect(x: 140, y: 120, width: 80, height: 20)
        ios.frame = NSRect(x: 230, y: 120, width: 200, height: 20)
        mac.state = .on
        ios.state = .on
        status.frame = NSRect(x: 20, y: 50, width: 440, height: 60)
        status.font = .systemFont(ofSize: 11)
        let create = NSButton(title: "Create", target: self, action: #selector(create(_:)))
        create.keyEquivalent = "\r"
        create.frame = NSRect(x: 370, y: 12, width: 96, height: 32)
        for x in [name, bundle, location, choose, mac, ios, status, create] as [NSView] { v.addSubview(x) }
        window.center()
    }

    func show() { window.makeKeyAndOrderFront(nil) }

    func fill(_ r: NewAppRequest) {
        name.stringValue = r.name
        bundle.stringValue = r.bundleIdentifier
        location.stringValue = r.location
        mac.state = r.platforms.contains(.macOS) ? .on : .off
        ios.state = r.platforms.contains(.iOS) ? .on : .off
    }

    var request: NewAppRequest {
        var ps: [AppPlatform] = []
        if mac.state == .on { ps.append(.macOS) }
        if ios.state == .on { ps.append(.iOS) }
        let loc = (location.stringValue as NSString).expandingTildeInPath
        return NewAppRequest(name: name.stringValue, bundleIdentifier: bundle.stringValue, location: loc, platforms: ps)
    }

    @objc func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        p.prompt = "Choose"
        p.beginSheetModal(for: window) { [weak self] r in
            guard r == .OK, let u = p.url else { return }
            MainActor.assumeIsolated { self?.location.stringValue = u.path }
        }
    }

    @objc func create(_ sender: Any?) {
        let r = request
        // The folder may not exist yet: make it, as the panel would.
        if r.location.hasPrefix("/") { try? FileManager.default.createDirectory(atPath: r.location, withIntermediateDirectories: true) }
        switch onCreate(r) {
        case .success(let project):
            status.stringValue = "Made \(project); opening it in Xcode."
        case .failure(let why):
            status.stringValue = why.description
        }
    }
}
#endif
