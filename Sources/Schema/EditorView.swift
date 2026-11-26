import AppKit
import SchemaCore
import SwiftUI

/// One diagram's window: title bar, entity list, canvas, inspector, and the SQL underneath.
struct EditorView: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        VStack(spacing: 0) {
            TitleBar(store: store)
            Hairline()
            HStack(spacing: 0) {
                if store.showSidebar {
                    Sidebar(store: store).frame(width: 240).background(MB.sidebar)
                    Hairline(vertical: true)
                }
                VStack(spacing: 0) {
                    CanvasArea(store: store)
                    if store.showSQL {
                        SQLPanel(store: store).frame(height: store.sqlHeight)
                    }
                }
                .frame(maxWidth: .infinity)
                if store.showInspector {
                    Hairline(vertical: true)
                    Inspector(store: store).frame(width: 300).background(MB.sidebar)
                }
            }
        }
        .background(MB.bg)
        .tint(MB.accent)
        .ignoresSafeArea()
        .overlay {
            if store.palette { PaletteView(store: store) }
        }
        .sheet(item: $store.sheet) { sheet in
            switch sheet {
            case .importSQL: ImportSheet(store: store).tint(MB.accent)
            case .addDomains: AddDomainsSheet(store: store).tint(MB.accent)
            case .replace: ReplaceSheet(store: store).tint(MB.accent)
            }
        }
    }
}

/// 52 pt bar across the window: room for the window buttons, the file's name, and the few things you reach for most.
struct TitleBar: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 72, height: 1)
            MBIconButton(symbol: "sidebar.left", help: "Show or hide the entity list (⌃⌘S)") { store.showSidebar.toggle() }
            HStack(spacing: 8) {
                Text(store.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(MB.text).lineLimit(1)
                if store.edited { Text("Edited").font(.system(size: 12)).foregroundStyle(MB.dim) }
            }
            .padding(.leading, 6)
            .layoutPriority(1)
            Spacer(minLength: 12)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { notation; names }
                notation
                EmptyView()
            }
            Button { store.newEntity() } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                    Text("Entity")
                }
            }
            .buttonStyle(.mbPrimary)
            .help("New entity (⇧⌘N). Or double-click the canvas.")
            .padding(.leading, 4)
            MBIconButton(symbol: "magnifyingglass", help: "Find an entity or a command (⌘K)") { store.palette = true }
            MBIconButton(symbol: "chevron.left.forwardslash.chevron.right", help: "Show or hide the SQL (⌥⌘S)", active: store.showSQL) { store.showSQL.toggle() }
            MBIconButton(symbol: "sidebar.right", help: "Show or hide the inspector (⌥⌘I)") { store.showInspector.toggle() }
        }
        .padding(.trailing, 10)
        .frame(height: 52)
        .background(MB.bar)
    }

    private var notation: some View {
        MBSegmented(options: Notation.allCases, selection: Binding(get: { store.diagram.display.notation },
                                                                   set: { v in store.edit("Change Notation") { $0.display.notation = v } }),
                    label: { $0 == .ie ? "Crow’s foot" : "IDEF1X" })
            .help("How relationships are drawn")
    }

    private var names: some View {
        MBSegmented(options: NameDisplay.allCases, selection: Binding(get: { store.diagram.display.names },
                                                                      set: { v in store.edit("Change Names") { $0.display.names = v } }),
                    label: { $0 == .logical ? "Logical" : "Physical" })
            .help("Readable names, or the table and column names")
    }
}

// MARK: Canvas with what floats on it

struct CanvasArea: View {
    @ObservedObject var store: DiagramStore
    @State private var showProblems = false
    @AppStorage("showHints") private var showHints = true
    @AppStorage("showMap") private var showMap = false

    var body: some View {
        ZStack {
            CanvasRepresentable(store: store)
            if store.diagram.entities.isEmpty, store.diagram.annotations.isEmpty, store.tool == .pointer { Welcome(store: store) }
        }
        .overlay(alignment: .topLeading) { ToolStrip(store: store).padding(12) }
        .overlay(alignment: .topTrailing) {
            if showMap, !store.diagram.entities.isEmpty {
                MiniMap(store: store)
                    .frame(width: 200, height: 140)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MB.card.opacity(0.94)))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MB.line))
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .padding(12)
            }
        }
        .overlay(alignment: .bottomLeading) { zoomControl.padding(12) }
        .overlay(alignment: .bottomTrailing) { problemsChip.padding(12) }
        .overlay(alignment: .top) {
            if let busy = store.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(1)
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(Capsule().fill(MB.card))
                .overlay(Capsule().strokeBorder(MB.lineStrong))
                .padding(.top, 14)
            }
        }
        .overlay(alignment: .bottom) {
            if showHints, !store.diagram.entities.isEmpty { hint.padding(.bottom, 14).allowsHitTesting(false) }
        }
        .clipped()
    }

    private var zoomControl: some View {
        HStack(spacing: 0) {
            MBIconButton(symbol: "minus", help: "Zoom out (⌘−)") { store.canvas?.zoomOut() }
            Button { store.canvas?.zoomActual() } label: {
                Text("\(Int((store.zoom * 100).rounded()))%")
                    .font(.system(size: 11.5, weight: .medium)).monospacedDigit()
                    .foregroundStyle(MB.muted).frame(width: 44, height: 26).contentShape(Rectangle())
            }
            .buttonStyle(.plain).help("Actual size (⌘0)")
            MBIconButton(symbol: "plus", help: "Zoom in (⌘+)") { store.canvas?.zoomIn() }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, 2)
            MBIconButton(symbol: "arrow.up.left.and.arrow.down.right", help: "Zoom to fit (⌘1)") { store.canvas?.zoomToFit() }
            MBIconButton(symbol: "map", help: "Show or hide the map of the whole diagram (⌥⌘M)", active: showMap) { showMap.toggle() }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MB.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MB.line))
    }

    @ViewBuilder private var problemsChip: some View {
        let problems = store.problems
        if !problems.isEmpty {
            let errors = problems.filter { $0.severity == .error }.count
            Button { showProblems.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: errors > 0 ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(errors > 0 ? MB.red : MB.orange)
                    Text("\(problems.count) \(problems.count == 1 ? "problem" : "problems")")
                        .font(.system(size: 11.5, weight: .medium)).foregroundStyle(MB.muted)
                }
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MB.card))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MB.line))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("What would go wrong when this becomes a database")
            .popover(isPresented: $showProblems, arrowEdge: .top) {
                ProblemList(store: store) { showProblems = false }
            }
        }
    }

    private var toolHint: String {
        switch store.tool {
        case .note, .text: return "Click where the \(store.tool.title.lowercased()) goes"
        case .pen, .highlighter: return "Draw on the canvas"
        default: return "Drag the \(store.tool.title.lowercased()) out on the canvas"
        }
    }

    /// One quiet line that says what you can do with what's selected.
    private var hint: some View {
        HStack(spacing: 6) {
            if store.tool != .pointer {
                Text(toolHint)
                Text("·").foregroundStyle(MB.dim)
                MBKey(text: "esc"); Text("back to the pointer")
            } else if !store.selectedAnnotations.isEmpty, store.selection.entityIDs.isEmpty {
                MBKey(text: "↩"); Text("type in it")
                Text("·").foregroundStyle(MB.dim)
                Text("drag a corner to resize it")
            } else {
            switch store.selection {
            case .entities(let ids) where ids.count == 1:
                MBKey(text: "↩"); Text("add an attribute")
                Text("·").foregroundStyle(MB.dim)
                Text("drag a dot to another entity to relate them")
            case .entities:
                Text("Right-click to align or tidy up")
                Text("·").foregroundStyle(MB.dim)
                MBKey(text: "⌫"); Text("delete")
            case .relationship:
                MBKey(text: "↩"); Text("name it")
                Text("·").foregroundStyle(MB.dim)
                Text("drag the line to bend it")
                Text("·").foregroundStyle(MB.dim)
                Text("right-click to change its kind")
            default:
                Text("Double-click the canvas for a new entity")
                Text("·").foregroundStyle(MB.dim)
                MBKey(text: "⌘K"); Text("find")
            }
            }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(MB.dim)
        .padding(.horizontal, 12).frame(height: 30)
        .background(Capsule().fill(MB.card.opacity(0.92)))
        .overlay(Capsule().strokeBorder(MB.line))
    }
}

struct ProblemList: View {
    @ObservedObject var store: DiagramStore
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(store.problems) { p in
                Button {
                    if let e = p.entity { store.select(entity: e) } else if let r = p.relationship { store.selection = .relationship(r) }
                    store.showInspector = true
                    close()
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: p.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 11)).foregroundStyle(p.severity == .error ? MB.red : MB.orange)
                        Text(p.message).font(.system(size: 12.5)).foregroundStyle(MB.text).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 6)
        .frame(width: 340)
    }
}

/// The empty canvas: what to do first.
struct Welcome: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 14) {
                GateMark().fill(MB.accent.opacity(0.9)).frame(width: 44, height: 37)
                Text("Double-click anywhere to add an entity").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                VStack(alignment: .leading, spacing: 8) {
                    row("↩", "after a name: type its attributes, one per line")
                    row("•", "drag a dot from one entity to another to relate them")
                    row("⌘V", "paste CREATE TABLE statements to draw them")
                    row("⌘K", "find an entity or a command")
                }
            }
            .allowsHitTesting(false)
            HStack(spacing: 8) {
                Button("New Entity") { store.newEntity() }.buttonStyle(.mbPrimary)
                Button("Open the Sample") { NSApp.sendAction(#selector(AppDelegate.openSample(_:)), to: nil, from: nil) }.buttonStyle(.mbQuiet)
                Button("Import SQL…") { store.sheet = .importSQL }.buttonStyle(.mbQuiet)
            }
        }
    }

    private func row(_ key: String, _ text: String) -> some View {
        HStack(spacing: 10) {
            MBKey(text: key).frame(width: 36, alignment: .trailing)
            Text(text).font(.system(size: 12.5)).foregroundStyle(MB.muted)
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @ObservedObject var store: DiagramStore
    @State private var filter = ""

    private var entities: [Entity] {
        let q = filter.lowercased()
        return store.diagram.entities
            .filter { q.isEmpty || $0.name.lowercased().contains(q) || $0.tableName.contains(q) || $0.attributes.contains { $0.name.lowercased().contains(q) } }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            MBSearchField(placeholder: "Filter", text: $filter).padding(10)
            Hairline()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    header("Entities", count: store.diagram.entities.count, help: "New entity (⇧⌘N)") { store.newEntity() }
                    // Entities with a group are listed under it; the rest come first.
                    let groups = Dictionary(grouping: entities, by: \.package)
                    ForEach(groups[""] ?? []) { e in
                        EntityRow(store: store, entity: e)
                    }
                    ForEach(groups.keys.filter { !$0.isEmpty }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }, id: \.self) { group in
                        Button { store.selection = .entities(Set((groups[group] ?? []).map(\.id))) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder").font(.system(size: 10)).foregroundStyle(MB.dim)
                                Text(group).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(MB.muted).lineLimit(1)
                                Spacer()
                            }
                            .padding(.leading, 14).padding(.trailing, 8).frame(height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Select every entity in \(group)")
                        ForEach(groups[group] ?? []) { e in
                            EntityRow(store: store, entity: e).padding(.leading, 10)
                        }
                    }
                    if store.diagram.entities.isEmpty {
                        Text("None yet").font(.system(size: 12)).foregroundStyle(MB.dim).padding(.horizontal, 14).padding(.vertical, 6)
                    } else if entities.isEmpty {
                        Text("Nothing matches").font(.system(size: 12)).foregroundStyle(MB.dim).padding(.horizontal, 14).padding(.vertical, 6)
                    }
                    header("Domains", count: store.diagram.domains.count, help: "New domain: a type with a name, to reuse") { store.newDomain() }
                        .padding(.top, 10)
                    // A domain under another is listed under it, a step in.
                    ForEach(store.diagram.domains.filter { $0.parent == nil || store.diagram.domain($0.parent!) == nil }) { d in
                        DomainRow(store: store, domain: d)
                        ForEach(store.diagram.domains.filter { store.diagram.ancestors(of: $0).contains { $0.id == d.id } }) { child in
                            DomainRow(store: store, domain: child).padding(.leading, CGFloat(store.diagram.ancestors(of: child).count) * 10)
                        }
                    }
                    if store.diagram.domains.isEmpty {
                        Text("A domain is a type with a name, such as email = VARCHAR(255). Use the name as an attribute’s type.")
                            .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 14).padding(.vertical, 6)
                    }
                }
                .padding(.bottom, 10)
            }
            Hairline()
            HStack {
                MBWordmark(size: 13)
                Spacer()
            }
            .padding(.horizontal, 14).frame(height: 38)
        }
    }

    private func header(_ title: String, count: Int, help: String, add: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(MB.dim)
            if count > 0 { Text("\(count)").font(.system(size: 10.5, weight: .medium)).monospacedDigit().foregroundStyle(MB.dim.opacity(0.7)) }
            Spacer()
            MBIconButton(symbol: "plus", help: help, action: add)
        }
        .padding(.leading, 14).padding(.trailing, 6).frame(height: 32)
    }
}

struct EntityRow: View {
    @ObservedObject var store: DiagramStore
    let entity: Entity
    @State private var hovering = false

    var body: some View {
        let selected = store.selection.entityIDs.contains(entity.id)
        Button {
            store.select(entity: entity.id)
        } label: {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(entity.color.nsColor.map { Color(nsColor: $0) } ?? MB.dim.opacity(0.55))
                    .frame(width: 9, height: 9)
                Text(store.diagram.entityName(entity).isEmpty ? "Untitled" : store.diagram.entityName(entity))
                    .font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(1)
                Spacer(minLength: 4)
                Text("\(entity.attributes.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(MB.dim)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? MB.selected : hovering ? MB.hover : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel("\(entity.name), \(entity.attributes.count) attributes")
        .contextMenu {
            Button("Rename") { store.select(entity: entity.id); store.canvas?.beginEdit(.entityName(entity.id)) }
            Button("Add Attribute") { store.select(entity: entity.id); store.canvas?.beginEdit(.newAttribute(entity: entity.id)) }
            Button("Duplicate") { store.selection = .entities([entity.id]); store.duplicateSelection() }
            Divider()
            Button("Delete", role: .destructive) { store.selection = .entities([entity.id]); store.deleteSelection() }
        }
    }
}

struct DomainRow: View {
    @ObservedObject var store: DiagramStore
    let domain: Domain
    @State private var hovering = false

    var body: some View {
        let selected = store.selection.domain == domain.id
        Button {
            store.selection = .domain(domain.id)
            store.showInspector = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "textformat.abc").font(.system(size: 10)).foregroundStyle(MB.accentInk).frame(width: 12)
                Text(domain.name).font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(1)
                Spacer(minLength: 4)
                Text(store.diagram.resolvedType(domain.name)).font(.system(size: 11)).foregroundStyle(MB.dim).lineLimit(1)
            }
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? MB.selected : hovering ? MB.hover : .clear))
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("New Domain Under It") { store.newDomain(under: domain.id) }
            Button("Add Several Domains…") { store.sheet = .addDomains }
            Divider()
            Button("Delete", role: .destructive) { store.selection = .domain(domain.id); store.deleteSelection() }
        }
    }
}

// MARK: Find anything (⌘K)

struct PaletteView: View {
    @ObservedObject var store: DiagramStore
    @State private var query = ""
    @State private var index = 0
    @FocusState private var focused: Bool

    private struct Item: Identifiable {
        let id: String
        let title: String
        let detail: String
        let symbol: String
        let action: () -> Void
    }

    private var items: [Item] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let store = self.store
        var list: [Item] = store.diagram.entities.map { e in
            Item(id: e.id.uuidString, title: e.name, detail: "entity · \(e.attributes.count) attributes", symbol: "rectangle.split.3x1") { store.select(entity: e.id) }
        }
        // Attributes too, once you've typed something: "email" finds Customer.
        if !q.isEmpty {
            for e in store.diagram.entities {
                for a in e.attributes where a.name.lowercased().contains(q) || a.columnName.contains(q) {
                    list.append(Item(id: a.id.uuidString, title: "\(e.name).\(a.name)", detail: a.type, symbol: a.isPrimaryKey ? "key" : "minus") {
                        store.select(entity: e.id)
                        store.selectedAttribute = a.id
                    })
                }
            }
        }
        func send(_ selector: Selector) -> () -> Void { { NSApp.sendAction(selector, to: nil, from: nil) } }
        let W = EditorWindowController.self
        let commands: [Item] = [
            Item(id: "c.new", title: "New Entity", detail: "⇧⌘N", symbol: "plus.rectangle") { store.newEntity() },
            Item(id: "c.domain", title: "New Domain", detail: "", symbol: "textformat.abc") { store.newDomain() },
            Item(id: "c.domains", title: "Add Several Domains…", detail: "", symbol: "text.badge.plus") { store.sheet = .addDomains },
            Item(id: "c.tidy", title: "Tidy Up", detail: "⌃⌘L", symbol: "wand.and.stars") { store.tidyUp() },
            Item(id: "c.note", title: "New Note", detail: "", symbol: "note.text") { store.newNote(.note) },
            Item(id: "c.text", title: "New Text", detail: "", symbol: "textformat") { store.newNote(.text) },
            Item(id: "c.picture", title: "Add a Picture…", detail: "", symbol: "photo") { store.chooseImage() },
            Item(id: "c.replace", title: "Find and Replace…", detail: "⌥⌘F", symbol: "arrow.left.arrow.right") { store.sheet = .replace },
            Item(id: "c.jumps", title: store.diagram.display.lineJumps ? "Lines Cross Flat" : "Lines Hop Over Each Other", detail: "lines", symbol: "point.topleft.down.to.point.bottomright.curvepath") {
                store.edit("Change Lines") { $0.display.lineJumps.toggle() }
            },
            Item(id: "c.map", title: "Show or Hide the Map", detail: "⌥⌘M", symbol: "map") { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "showMap"), forKey: "showMap") },
            Item(id: "c.fit", title: "Zoom to Fit", detail: "⌘1", symbol: "arrow.up.left.and.arrow.down.right") { store.canvas?.zoomToFit() },
            Item(id: "c.sql", title: store.showSQL ? "Hide SQL" : "Show SQL", detail: "⌥⌘S", symbol: "chevron.left.forwardslash.chevron.right") { store.showSQL.toggle() },
            Item(id: "c.import", title: "Import SQL…", detail: "⇧⌘I", symbol: "square.and.arrow.down") { store.sheet = .importSQL },
            Item(id: "c.sheet", title: "Import Spreadsheet…", detail: "xlsx, csv", symbol: "tablecells") { store.chooseSheet() },
            Item(id: "c.exportsql", title: "Export SQL…", detail: "⇧⌘E", symbol: "square.and.arrow.up", action: send(#selector(W.exportSQL(_:)))),
            Item(id: "c.exportimg", title: "Export Image…", detail: "⌥⌘E", symbol: "photo", action: send(#selector(W.exportImage(_:)))),
            Item(id: "c.copyimg", title: "Copy Diagram as Image", detail: "⇧⌘C", symbol: "doc.on.doc", action: send(#selector(W.copyImage(_:)))),
            Item(id: "c.dict", title: "Export Data Dictionary…", detail: "xlsx, md, csv", symbol: "tablecells", action: send(#selector(W.exportDictionary(_:)))),
            Item(id: "c.doc", title: "Export Document…", detail: "html, rtf", symbol: "doc.richtext", action: send(#selector(W.exportDocument(_:)))),
            Item(id: "c.print", title: "Print…", detail: "⌘P", symbol: "printer", action: send(#selector(NSDocument.printDocument(_:)))),
            Item(id: "c.astah", title: "Export for Astah…", detail: ".asta", symbol: "square.and.arrow.up.on.square", action: send(#selector(W.exportAstah(_:)))),
            Item(id: "c.notation", title: store.diagram.display.notation == .ie ? "Switch to IDEF1X" : "Switch to Crow’s Foot", detail: "notation", symbol: "arrow.triangle.branch") {
                store.edit("Change Notation") { $0.display.notation = $0.display.notation == .ie ? .idef1x : .ie }
            },
            Item(id: "c.names", title: store.diagram.display.names == .logical ? "Show Physical Names" : "Show Logical Names", detail: "names", symbol: "textformat") {
                store.edit("Change Names") { $0.display.names = $0.display.names == .logical ? .physical : .logical }
            },
        ]
        list += commands
        guard !q.isEmpty else { return list }
        return list.filter { fuzzy($0.title.lowercased(), q) }.sorted { a, b in
            let ap = a.title.lowercased().hasPrefix(q), bp = b.title.lowercased().hasPrefix(q)
            if ap != bp { return ap }
            let ac = a.title.lowercased().contains(q), bc = b.title.lowercased().contains(q)
            return ac != bc ? ac : a.title.count < b.title.count
        }
    }

    private func fuzzy(_ s: String, _ q: String) -> Bool {
        if s.contains(q) { return true }
        var i = s.startIndex
        for c in q {
            guard let found = s[i...].firstIndex(of: c) else { return false }
            i = s.index(after: found)
        }
        return true
    }

    var body: some View {
        let list = items
        ZStack(alignment: .top) {
            MB.scrim.ignoresSafeArea().onTapGesture { store.palette = false }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(MB.dim)
                    TextField("Find an entity, an attribute or a command", text: $query)
                        .textFieldStyle(.plain).font(.system(size: 15)).foregroundStyle(MB.text)
                        .focused($focused)
                        .onSubmit { pick(list) }
                        .onKeyPress(.downArrow) { index = min(index + 1, max(0, list.count - 1)); return .handled }
                        .onKeyPress(.upArrow) { index = max(index - 1, 0); return .handled }
                        .onKeyPress(.escape) { store.palette = false; return .handled }
                }
                .padding(.horizontal, 16).frame(height: 48)
                Hairline()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(list.prefix(200).enumerated()), id: \.element.id) { i, item in
                                HStack(spacing: 10) {
                                    Image(systemName: item.symbol).font(.system(size: 11)).foregroundStyle(i == index ? MB.accentInk : MB.dim).frame(width: 16)
                                    Text(item.title).font(.system(size: 13)).foregroundStyle(MB.text).lineLimit(1)
                                    Spacer()
                                    Text(item.detail).font(.system(size: 11.5)).foregroundStyle(MB.dim)
                                }
                                .padding(.horizontal, 14).frame(height: 32)
                                .background(RoundedRectangle(cornerRadius: 7).fill(i == index ? MB.selected : .clear))
                                .padding(.horizontal, 6)
                                .contentShape(Rectangle())
                                .onTapGesture { index = i; pick(list) }
                                .id(i)
                            }
                            if list.isEmpty {
                                Text("Nothing matches").font(.system(size: 12.5)).foregroundStyle(MB.dim).padding(16)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                    .frame(maxHeight: 340)
                    .onChange(of: index) { _, i in proxy.scrollTo(i) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 12).fill(MB.card))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(MB.lineStrong))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            .frame(width: 560)
            .padding(.top, 90)
        }
        .onAppear { focused = true }
        .onChange(of: query) { _, _ in index = 0 }
    }

    private func pick(_ list: [Item]) {
        guard list.indices.contains(index) else { return }
        let action = list[index].action
        store.palette = false
        action()
    }
}

/// Several domains at once: one per line, typed like an attribute.
struct AddDomainsSheet: View {
    @ObservedObject var store: DiagramStore
    @State private var text = ""
    @FocusState private var focused: Bool

    private var found: [Domain] { store.domains(from: text) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Add several domains").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                Text("One per line: a name and its type. Add not null or = a default after it, and < another domain’s name to put it under that one.")
                    .font(.system(size: 12)).foregroundStyle(MB.muted).fixedSize(horizontal: false, vertical: true)
            }
            TextEditor(text: $text)
                .font(MB.mono).scrollContentBackground(.hidden).focused($focused).padding(6)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text("email varchar(255) not null\nmoney decimal(10,2) = 0\nprice < money")
                            .font(MB.mono).foregroundStyle(MB.dim.opacity(0.6)).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                    }
                }
                .frame(minHeight: 180)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MB.wash(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.line))
                .accessibilityLabel("Domains to add")
            HStack(spacing: 8) {
                Text(found.isEmpty ? " " : "\(found.count) \(found.count == 1 ? "domain" : "domains")").font(.system(size: 12)).foregroundStyle(MB.dim)
                Spacer()
                Button("Cancel") { store.sheet = nil }.buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button("Add") {
                    store.addDomains(found)
                    store.sheet = nil
                }
                .buttonStyle(.mbPrimary).keyboardShortcut(.defaultAction).disabled(found.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 520, height: 360)
        .background(MB.card)
        .onAppear { focused = true }
    }
}
