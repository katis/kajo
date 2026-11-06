// Module 9c: the second round of AppKit views behind the view primitive
// (docs/modules/developer-ui.md, ADR 0010's Built (9c) note): an editing text
// view with selection, range styles, bound keys and change events; an
// outline and a table whose data sources hold what the image gave them (the
// whole of it, or pages and children on demand, asked for by an event);
// split and scroll views; toolbars; menus in the menu bar and as context
// menus; window frames. Binding code only: every op is one call from the
// image, and what the toolkit holds is not mirrored in Smalltalk.

import AppKit
import KajoShellCore
import KajoVM

/// An NSTextView that reports the keys the image bound before handling
/// them, and tells the shell when it drew (the typing measurement).
final class KajoTextView: NSTextView {
    var handle = 0
    var keys: Set<String> = []
    var onKey: ((Int, String) -> Void)?
    var onDraw: ((Int) -> Void)?

    func boundKey(_ e: NSEvent) -> String? {
        guard !keys.isEmpty, let c = e.charactersIgnoringModifiers else { return nil }
        let f = e.modifierFlags
        guard let name = TextOffsets.keyName(c, command: f.contains(.command), control: f.contains(.control),
                                             option: f.contains(.option), shift: f.contains(.shift)),
              keys.contains(name) else { return nil }
        return name
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if window?.firstResponder === self, let k = boundKey(e) {
            onKey?(handle, k)
            return true
        }
        return super.performKeyEquivalent(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if let k = boundKey(e) {
            onKey?(handle, k)
            return
        }
        super.keyDown(with: e)
    }

    override func draw(_ r: NSRect) {
        super.draw(r)
        onDraw?(handle)
    }
}

/// An outline's items: ids the image chose, titles, which have children,
/// and which children it was given.
@MainActor final class OutlineSource: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    final class Item {
        let id: Int
        var title = ""
        var expandable = false
        init(_ id: Int) { self.id = id }
    }
    let handle: Int
    var items: [Int: Item] = [:]
    var children: [Int: [Int]] = [:]
    var post: ((ShellEvent) -> Void)?
    var quiet = false
    var asked: Set<Int> = []
    weak var outline: NSOutlineView?

    init(handle: Int) { self.handle = handle }

    func item(_ id: Int) -> Item {
        if let i = items[id] { return i }
        let i = Item(id)
        items[id] = i
        return i
    }

    /// setChildren (addChildren appends): parent, then id, title,
    /// expandable triples.
    func setChildren(_ a: [ShellValue], append: Bool = false) -> Bool {
        guard let p = a.first?.int, (a.count - 1) % 3 == 0 else { return false }
        var ids: [Int] = []
        var k = 1
        while k + 2 < a.count {
            guard let id = a[k].int else { return false }
            let i = item(Int(id))
            i.title = a[k + 1].string ?? "\(a[k + 1])"
            i.expandable = a[k + 2] == .bool(true)
            ids.append(Int(id))
            k += 3
        }
        children[Int(p)] = append ? (children[Int(p)] ?? []) + ids : ids
        asked.remove(Int(p))
        quietly {
            if p == 0 { outline?.reloadData() } else { outline?.reloadItem(items[Int(p)], reloadChildren: true) }
        }
        return true
    }

    /// setTree (addTree goes on with more): id, parent, title triples,
    /// parents first: the whole tree.
    func setTree(_ a: [ShellValue], append: Bool = false) -> Bool {
        guard a.count % 3 == 0 else { return false }
        if !append { children = [:] }
        var k = 0
        while k + 2 < a.count {
            guard let id = a[k].int, let p = a[k + 1].int else { return false }
            let i = item(Int(id))
            i.title = a[k + 2].string ?? "\(a[k + 2])"
            children[Int(p), default: []].append(Int(id))
            k += 3
        }
        for (id, i) in items { i.expandable = !(children[id]?.isEmpty ?? true) }
        quietly { outline?.reloadData() }
        return true
    }

    func quietly(_ f: () -> Void) {
        let q = quiet
        quiet = true
        f()
        quiet = q
    }

    func idOf(_ item: Any?) -> Int { (item as? Item)?.id ?? 0 }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { children[idOf(item)]?.count ?? 0 }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        self.item(children[idOf(item)]?[index] ?? 0)
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? Item)?.expandable ?? false }
    func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        let f = (o.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: nil) as? NSTextField) ?? {
            let t = NSTextField(labelWithString: "")
            t.identifier = NSUserInterfaceItemIdentifier("cell")
            t.lineBreakMode = .byTruncatingTail
            return t
        }()
        f.stringValue = (item as? Item)?.title ?? ""
        return f
    }

    func outlineViewItemWillExpand(_ n: Notification) {
        guard let i = n.userInfo?["NSObject"] as? Item, children[i.id] == nil, !asked.contains(i.id) else { return }
        asked.insert(i.id)
        post?(ShellEvent(kind: .expand, target: handle, value: .int(Int64(i.id)), timeNs: ShellVM.now()))
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard !quiet, let o = outline else { return }
        post?(ShellEvent(kind: .selectionChanged, target: handle, value: .int(Int64(idOf(o.item(atRow: o.selectedRow)))), timeNs: eventTime()))
    }

    @objc func doubleClicked(_ o: NSOutlineView) {
        guard o.clickedRow >= 0 else { return }
        post?(ShellEvent(kind: .doubleClick, target: handle, value: .int(Int64(idOf(o.item(atRow: o.clickedRow)))), timeNs: eventTime()))
    }

    var selectedId: Int {
        guard let o = outline, o.selectedRow >= 0 else { return 0 }
        return idOf(o.item(atRow: o.selectedRow))
    }

    func select(_ id: Int) {
        guard let o = outline else { return }
        quietly {
            let row = items[id].map { o.row(forItem: $0) } ?? -1
            if row >= 0 { o.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false); o.scrollRowToVisible(row) } else { o.deselectAll(nil) }
        }
    }
}

/// A table's rows: all of them, or a count and the pages the image gave.
@MainActor final class TableSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    let handle: Int
    var columns: [String] = []
    var rows: [[String]?] = []
    var asked: Set<Int> = []
    var post: ((ShellEvent) -> Void)?
    var quiet = false
    weak var table: NSTableView?
    static let page = 100

    init(handle: Int) { self.handle = handle }

    func setColumns(_ a: [ShellValue]) -> Bool {
        guard let t = table else { return false }
        for c in t.tableColumns { t.removeTableColumn(c) }
        columns = a.map { $0.string ?? "\($0)" }
        for (k, title) in columns.enumerated() {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("\(k)"))
            c.title = title
            c.width = max(60, (t.enclosingScrollView?.frame.width ?? 200) / CGFloat(max(1, columns.count)) - 4)
            t.addTableColumn(c)
        }
        t.headerView = columns.count > 1 || !(columns.first ?? "").isEmpty ? NSTableHeaderView() : nil
        return true
    }

    /// setRows (addRows appends): columns, then the rows' cells flat.
    func setRows(_ a: [ShellValue], append: Bool = false) -> Bool {
        guard let n = a.first?.int, n > 0, (a.count - 1) % Int(n) == 0 else { return false }
        var out: [[String]?] = []
        var k = 1
        while k < a.count {
            out.append(a[k..<k + Int(n)].map { $0.string ?? "\($0)" })
            k += Int(n)
        }
        rows = append ? rows + out : out
        asked = []
        quietly { table?.reloadData() }
        return true
    }

    /// Any SmallInteger may arrive: a count past what a table can show
    /// (the count field's limit) is refused, not allocated.
    func setRowCount(_ n: Int) -> Bool {
        guard n <= 16_777_215 else { return false }
        rows = Array(repeating: nil, count: max(0, n))
        asked = []
        quietly { table?.reloadData() }
        return true
    }

    /// setRowsAt: the first row, the columns, then cells flat.
    func setRowsAt(_ a: [ShellValue]) -> Bool {
        guard a.count >= 2, let first = a[0].int, let n = a[1].int, n > 0, (a.count - 2) % Int(n) == 0 else { return false }
        var r = Int(first) - 1
        var k = 2
        while k < a.count, r < rows.count {
            if r >= 0 { rows[r] = a[k..<k + Int(n)].map { $0.string ?? "\($0)" } }
            r += 1
            k += Int(n)
        }
        quietly { table?.reloadData() }
        return true
    }

    func quietly(_ f: () -> Void) {
        let q = quiet
        quiet = true
        f()
        quiet = q
    }

    func numberOfRows(in t: NSTableView) -> Int { rows.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let col = Int(c?.identifier.rawValue ?? "0") ?? 0
        let f = (t.makeView(withIdentifier: NSUserInterfaceItemIdentifier("cell"), owner: nil) as? NSTextField) ?? {
            let x = NSTextField(labelWithString: "")
            x.identifier = NSUserInterfaceItemIdentifier("cell")
            x.lineBreakMode = .byTruncatingTail
            return x
        }()
        if row < rows.count, let r = rows[row] {
            f.stringValue = col < r.count ? r[col] : ""
        } else {
            f.stringValue = "…"
            let first = row / TableSource.page * TableSource.page + 1
            if !asked.contains(first) {
                asked.insert(first)
                post?(ShellEvent(kind: .expand, target: handle, value: .int(Int64(first)), timeNs: ShellVM.now()))
            }
        }
        return f
    }

    func tableViewSelectionDidChange(_ n: Notification) {
        guard !quiet, let t = table else { return }
        post?(ShellEvent(kind: .selectionChanged, target: handle, value: .int(Int64(t.selectedRow + 1)), timeNs: eventTime()))
    }

    @objc func doubleClicked(_ t: NSTableView) {
        guard t.clickedRow >= 0 else { return }
        post?(ShellEvent(kind: .doubleClick, target: handle, value: .int(Int64(t.clickedRow + 1)), timeNs: eventTime()))
    }

    func select(_ row: Int) {
        guard let t = table else { return }
        quietly {
            if row >= 1 && row <= rows.count {
                t.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
                t.scrollRowToVisible(row - 1)
            } else {
                t.deselectAll(nil)
            }
        }
    }
}

/// A window's toolbar: items the image added, chosen as menu events.
@MainActor final class ToolbarHost: NSObject, NSToolbarDelegate {
    let handle: Int
    let toolbar: NSToolbar
    var items: [(id: Int, title: String)] = []
    var post: ((ShellEvent) -> Void)?

    init(handle: Int) {
        self.handle = handle
        toolbar = NSToolbar(identifier: "kajo-toolbar-\(handle)")
        super.init()
        toolbar.delegate = self
        toolbar.displayMode = .labelOnly
    }

    func add(_ id: Int, _ title: String) {
        items.append((id, title))
        toolbar.insertItem(withItemIdentifier: NSToolbarItem.Identifier("\(id)"), at: toolbar.items.count)
    }

    func toolbar(_ t: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar f: Bool) -> NSToolbarItem? {
        guard let n = Int(id.rawValue), let it = items.first(where: { $0.id == n }) else { return nil }
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = it.title
        item.paletteLabel = it.title
        item.isBordered = true
        item.title = it.title
        item.tag = n
        item.target = self
        item.action = #selector(chosen(_:))
        return item
    }

    func toolbarAllowedItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { items.map { .init("\($0.id)") } }
    func toolbarDefaultItemIdentifiers(_ t: NSToolbar) -> [NSToolbarItem.Identifier] { [] }

    @objc func chosen(_ i: NSToolbarItem) {
        post?(ShellEvent(kind: .menu, target: handle, value: .int(Int64(i.tag)), timeNs: eventTime()))
    }
}

/// A menu's items, chosen as menu events.
@MainActor final class MenuHost: NSObject {
    let handle: Int
    let menu = NSMenu()
    var post: ((ShellEvent) -> Void)?

    init(handle: Int) {
        self.handle = handle
        super.init()
        menu.autoenablesItems = false
    }

    func add(_ id: Int, _ title: String, _ key: String) {
        var equivalent = ""
        var mask: NSEvent.ModifierFlags = []
        if !key.isEmpty {
            let parts = key.split(separator: "-").map(String.init)
            for p in parts.dropLast() {
                switch p {
                case "cmd": mask.insert(.command)
                case "shift": mask.insert(.shift)
                case "alt": mask.insert(.option)
                case "ctrl": mask.insert(.control)
                default: break
                }
            }
            equivalent = parts.last ?? ""
        }
        let item = NSMenuItem(title: title, action: #selector(chosen(_:)), keyEquivalent: equivalent)
        item.keyEquivalentModifierMask = mask
        item.tag = id
        item.target = self
        menu.addItem(item)
    }

    @objc func chosen(_ i: NSMenuItem) {
        post?(ShellEvent(kind: .menu, target: handle, value: .int(Int64(i.tag)), timeNs: eventTime()))
    }
}

/// The time the event being handled happened (AGENTS.md: never when it was
/// posted), else now.
@MainActor func eventTime() -> UInt64 { NSApp.currentEvent.map { UInt64($0.timestamp * 1e9) } ?? ShellVM.now() }

extension MacPlatform: NSTextViewDelegate {
    /// The second round's kinds (nil: not one of them).
    func make9c(_ kind: String, _ h: Int) -> Entry? {
        let post: (ShellEvent) -> Void = { [weak self] e in self?.eventHandler?(e) }
        switch kind {
        case "textView":
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let size = scroll.contentSize
            let t = KajoTextView(frame: NSRect(x: 0, y: 0, width: size.width, height: size.height))
            t.minSize = NSSize(width: 0, height: size.height)
            t.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            t.isVerticallyResizable = true
            t.isHorizontallyResizable = false
            t.autoresizingMask = [.width]
            t.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
            t.textContainer?.widthTracksTextView = true
            t.isEditable = false
            t.isRichText = false
            t.allowsUndo = true
            t.isAutomaticQuoteSubstitutionEnabled = false
            t.isAutomaticDashSubstitutionEnabled = false
            t.isAutomaticTextReplacementEnabled = false
            t.isAutomaticSpellingCorrectionEnabled = false
            t.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            t.typingAttributes = [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor]
            t.handle = h
            t.delegate = self
            t.onKey = { h, k in post(ShellEvent(kind: .key, target: h, value: .string(k), timeNs: eventTime())) }
            t.onDraw = { [weak self] h in self?.textDrawn?(h) }
            scroll.documentView = t
            return Entry(kind: kind, view: scroll, object: t)
        case "outline":
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let o = NSOutlineView()
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("0"))
            c.resizingMask = .autoresizingMask
            o.addTableColumn(c)
            o.outlineTableColumn = c
            o.headerView = nil
            o.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            let src = OutlineSource(handle: h)
            src.outline = o
            src.post = post
            o.dataSource = src
            o.delegate = src
            o.target = src
            o.doubleAction = #selector(OutlineSource.doubleClicked(_:))
            scroll.documentView = o
            return Entry(kind: kind, view: scroll, object: src)
        case "table":
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            let t = NSTableView()
            t.usesAlternatingRowBackgroundColors = true
            t.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
            let src = TableSource(handle: h)
            src.table = t
            src.post = post
            t.dataSource = src
            t.delegate = src
            t.target = src
            t.doubleAction = #selector(TableSource.doubleClicked(_:))
            scroll.documentView = t
            return Entry(kind: kind, view: scroll, object: src)
        case "split":
            let s = NSSplitView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            s.isVertical = true
            s.dividerStyle = .thin
            return Entry(kind: kind, view: s)
        case "scroll":
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            scroll.hasVerticalScroller = true
            scroll.documentView = FlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 200))
            return Entry(kind: kind, view: scroll)
        case "toolbar":
            let t = ToolbarHost(handle: h)
            t.post = post
            return Entry(kind: kind, view: NSView(), object: t)
        case "menu":
            let m = MenuHost(handle: h)
            m.post = post
            return Entry(kind: kind, view: NSView(), object: m)
        default:
            return nil
        }
    }

    func kajoText(_ e: Entry) -> KajoTextView? { e.object as? KajoTextView }

    /// A view of the second round's kinds added to another.
    func add9c(_ parent: Entry, _ child: Entry) -> Bool {
        if let s = parent.view as? NSSplitView {
            s.addArrangedSubview(child.view)
            return true
        }
        if parent.kind == "scroll", let doc = (parent.view as? NSScrollView)?.documentView {
            doc.addSubview(child.view)
            return true
        }
        return false
    }

    func set9c(_ e: Entry, _ k: String, _ v: ShellValue) -> Bool? {
        switch k {
        case "editable":
            guard let t = kajoText(e) else { return nil }
            t.isEditable = v == .bool(true)
            t.isSelectable = true
        case "keys":
            guard let t = kajoText(e) else { return nil }
            t.keys = Set((v.string ?? "").split(separator: " ").map(String.init))
        case "text" where kajoText(e) != nil:
            let t = kajoText(e)!
            t.string = v.string ?? "\(v)"
            t.textStorage?.setAttributes([.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor],
                                         range: NSRange(location: 0, length: (t.string as NSString).length))
        case "vertical":
            guard let s = e.view as? NSSplitView else { return nil }
            s.isVertical = v == .bool(true)
        case "contentWidth", "contentHeight":
            guard e.kind == "scroll", let doc = (e.view as? NSScrollView)?.documentView, let d = v.double else { return nil }
            var f = doc.frame
            if k == "contentWidth" { f.size.width = d } else { f.size.height = d }
            doc.frame = f
        case "autoresize":
            var m: NSView.AutoresizingMask = []
            for w in (v.string ?? "").split(separator: " ") {
                switch w {
                case "width": m.insert(.width)
                case "height": m.insert(.height)
                case "left": m.insert(.minXMargin)
                case "top": m.insert(.minYMargin)
                case "right": m.insert(.maxXMargin)
                case "bottom": m.insert(.maxYMargin)
                default: break
                }
            }
            e.view.autoresizingMask = m
        case "title" where e.kind == "menu":
            (e.object as? MenuHost)?.menu.title = v.string ?? ""
        default:
            return nil
        }
        return true
    }

    func get9c(_ e: Entry, _ k: String) -> ShellValue? {
        switch k {
        case "selection":
            guard let t = kajoText(e) else { return nil }
            let r = TextOffsets.byteRange(t.string, t.selectedRange())
            return .string("\(r.start) \(r.stop)")
        case "editable":
            return kajoText(e).map { .bool($0.isEditable) }
        case "text" where kajoText(e) != nil:
            return .string(kajoText(e)!.string)
        case "selected":
            if let o = e.object as? OutlineSource { return .int(Int64(o.selectedId)) }
            if let t = e.object as? TableSource { return .int(Int64((t.table?.selectedRow ?? -1) + 1)) }
            return nil
        default:
            return nil
        }
    }

    func call9c(_ e: Entry, _ m: String, _ a: [ShellValue]) -> ShellValue? {
        switch (m, e.object) {
        case ("appendLine", let t as KajoTextView):
            let line = a.first?.string ?? ""
            t.textStorage?.append(NSAttributedString(string: t.string.isEmpty ? line : "\n" + line,
                                                     attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular), .foregroundColor: NSColor.textColor]))
            t.scrollToEndOfDocument(nil)
        case ("clear", let t as KajoTextView):
            t.string = ""
        case ("select", let t as KajoTextView):
            guard a.count == 2, let s = a[0].int, let x = a[1].int, let r = TextOffsets.nsRange(t.string, start: Int(s), stop: Int(x)) else { return nil }
            t.setSelectedRange(r)
        case ("scrollTo", let t as KajoTextView):
            guard let s = a.first?.int, let r = TextOffsets.nsRange(t.string, start: Int(s), stop: Int(s) - 1) else { return nil }
            t.scrollRangeToVisible(r)
        case ("focus", let t as KajoTextView):
            t.window?.makeFirstResponder(t)
        case ("setStyles", let t as KajoTextView):
            guard a.count % 3 == 0, let storage = t.textStorage else { return nil }
            var triples: [(Int64?, Int64?, String?)] = []
            var k = 0
            while k + 2 < a.count { triples.append((a[k].int, a[k + 1].int, a[k + 2].string)); k += 3 }
            let text = t.string
            let all = NSRange(location: 0, length: (text as NSString).length)
            let plain = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            storage.beginEditing()
            storage.setAttributes([.font: plain, .foregroundColor: NSColor.textColor], range: all)
            for (r, s) in TextOffsets.styles(text, triples) {
                switch s {
                case .bold: storage.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold), range: r)
                case .color(let c): storage.addAttribute(.foregroundColor, value: editorColor(c), range: r)
                case .background(let c): storage.addAttribute(.backgroundColor, value: c == "highlight" ? editorColor(c) : editorColor(c).withAlphaComponent(0.3), range: r)
                }
            }
            storage.endEditing()
        case ("setChildren", let o as OutlineSource), ("addChildren", let o as OutlineSource):
            guard o.setChildren(a, append: m == "addChildren") else { return nil }
        case ("setTree", let o as OutlineSource), ("addTree", let o as OutlineSource):
            guard o.setTree(a, append: m == "addTree") else { return nil }
        case ("expand", let o as OutlineSource):
            guard let id = a.first?.int, let i = o.items[Int(id)] else { return nil }
            o.outline?.expandItem(i)
        case ("expandAll", let o as OutlineSource):
            o.outline?.expandItem(nil, expandChildren: true)
        case ("select", let o as OutlineSource):
            o.select(Int(a.first?.int ?? 0))
        case ("setColumns", let t as TableSource):
            guard t.setColumns(a) else { return nil }
        case ("setRows", let t as TableSource), ("addRows", let t as TableSource):
            guard t.setRows(a, append: m == "addRows") else { return nil }
        case ("setRowCount", let t as TableSource):
            guard t.setRowCount(Int(a.first?.int ?? 0)) else { return nil }
        case ("setRowsAt", let t as TableSource):
            guard t.setRowsAt(a) else { return nil }
        case ("selectRow", let t as TableSource):
            t.select(Int(a.first?.int ?? 0))
        case ("setPosition", _):
            guard let s = e.view as? NSSplitView, a.count == 2, let i = a[0].int, let p = a[1].double,
                  i >= 1, i < s.subviews.count else { return nil }
            s.setPosition(p, ofDividerAt: Int(i) - 1)
        case ("addItem", let t as ToolbarHost):
            guard a.count == 2, let id = a[0].int else { return nil }
            t.add(Int(id), a[1].string ?? "")
        case ("addItem", let m as MenuHost):
            guard a.count == 3, let id = a[0].int else { return nil }
            m.add(Int(id), a[1].string ?? "", a[2].string ?? "")
        case ("addSubmenu", let m as MenuHost):
            guard let h = a.first?.int, let sub = entries[Int(h)]?.object as? MenuHost else { return nil }
            let item = NSMenuItem(title: sub.menu.title, action: nil, keyEquivalent: "")
            item.submenu = sub.menu
            m.menu.addItem(item)
        case ("install", let m as MenuHost):
            let bar = NSApp.mainMenu ?? {
                let b = NSMenu()
                let app = NSMenuItem()
                app.submenu = NSMenu()
                app.submenu?.addItem(NSMenuItem(title: "Quit Kajo", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
                b.addItem(app)
                NSApp.mainMenu = b
                return b
            }()
            let item = NSMenuItem(title: m.menu.title, action: nil, keyEquivalent: "")
            item.submenu = m.menu
            bar.addItem(item)
        case ("setMenu", _):
            guard let h = a.first?.int, let menu = entries[Int(h)]?.object as? MenuHost else { return nil }
            e.view.menu = menu.menu
            (e.view as? NSScrollView)?.documentView?.menu = menu.menu
        case ("setToolbar", _):
            guard let w = e.window, let h = a.first?.int, let t = entries[Int(h)]?.object as? ToolbarHost else { return nil }
            w.toolbar = t.toolbar
            w.toolbarStyle = .expanded
        default:
            return nil
        }
        return .nil
    }

    func editorColor(_ name: String) -> NSColor {
        switch name {
        case "purple": .systemPurple
        case "brown": .systemBrown
        case "teal": .systemTeal
        case "yellow": .systemYellow
        case "highlight": NSColor.systemYellow.withAlphaComponent(0.4)
        default: color(name)
        }
    }

    func textDidChange(_ n: Notification) {
        guard let t = n.object as? KajoTextView else { return }
        eventHandler?(ShellEvent(kind: .textChanged, target: t.handle, timeNs: eventTime()))
    }

    /// The typing measurement: a key typed into the text view `handle` as
    /// the window server would deliver it.
    func typeKey(_ handle: Int, _ text: String) -> Bool {
        guard let e = entries[handle], let t = kajoText(e), let w = t.window else { return false }
        if w.firstResponder !== t { w.makeFirstResponder(t) }
        guard let ev = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: Double(ShellVM.now()) / 1e9,
                                        windowNumber: w.windowNumber, context: nil, characters: text,
                                        charactersIgnoringModifiers: text, isARepeat: false, keyCode: 0) else { return false }
        w.sendEvent(ev)
        return true
    }
}
