import AppKit
import SchemaCore
import SwiftUI

/// The panel on the right: everything about what's selected, in one place. Nothing selected: the diagram's own settings.
struct Inspector: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                switch store.selection {
                case .none:
                    DiagramInspector(store: store)
                case .entities(let ids):
                    if ids.count == 1, let e = store.diagram.entity(ids.first!) {
                        EntityInspector(store: store, entity: e)
                    } else {
                        MultiInspector(store: store, count: ids.count)
                    }
                case .relationship(let id):
                    if let r = store.diagram.relationship(id), let p = store.diagram.entity(r.parent), let c = store.diagram.entity(r.child) {
                        RelationshipInspector(store: store, relationship: r, parent: p, child: c)
                    }
                case .domain(let id):
                    if let d = store.diagram.domain(id) { DomainInspector(store: store, domain: d) }
                }
            }
            .padding(.bottom, 16)
        }
    }
}

// MARK: Pieces

private struct Section<Content: View>: View {
    let title: String
    var trailing: String = ""
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(MB.dim)
                Spacer()
                if !trailing.isEmpty { Text(trailing).font(.system(size: 10.5)).foregroundStyle(MB.dim) }
            }
            content
        }
        .padding(.horizontal, 14).padding(.top, 16)
    }
}

private struct Labeled<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11.5)).foregroundStyle(MB.muted)
            content
        }
    }
}

private struct Heading: View {
    let kind: String
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(kind.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(MB.dim)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text).lineLimit(2)
        }
        .padding(.horizontal, 14).padding(.top, 14)
    }
}

/// A few lines of text in the Maben field style.
private struct MBTextArea: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(MB.text)
            .lineLimit(2...6)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
    }
}

private struct MBMenuPicker<Value: Hashable>: View {
    let options: [Value]
    @Binding var selection: Value
    let label: (Value) -> String

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { o in
                Button { selection = o } label: {
                    if o == selection { Label(label(o), systemImage: "checkmark") } else { Text(label(o)) }
                }
            }
        } label: {
            HStack {
                Text(label(selection)).font(.system(size: 12.5)).foregroundStyle(MB.text)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(MB.dim)
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

/// Tags as lines of text, one `name = value` per line.
enum TagText {
    static func text(_ tags: [Tag]) -> String { tags.map { $0.value.isEmpty ? $0.name : "\($0.name) = \($0.value)" }.joined(separator: "\n") }

    static func tags(_ text: String) -> [Tag] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = parts.first, !name.isEmpty else { return nil }
            return Tag(name: name, value: parts.count > 1 ? parts[1] : "")
        }
    }
}

/// A text area that keeps what you type while you type it, and hands it on as tags or lines.
private struct LinesField: View {
    let placeholder: String
    let lines: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        MBTextArea(placeholder: placeholder, text: $text)
            .focused($focused)
            .onAppear { text = lines }
            .onChange(of: lines) { _, new in if !focused { text = new } }
            .onChange(of: text) { _, new in if focused { commit(new) } }
    }
}

/// A colour you pick, kept as `#RRGGBB`; the cross puts it back to none.
struct HexColorPicker: View {
    let label: String
    let hex: String
    let set: (String) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(MB.text)
            Spacer()
            if !hex.isEmpty {
                Button { set("") } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(MB.dim) }
                    .buttonStyle(.plain).help("Back to the usual colour")
            }
            ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: hex) ?? .gray) }, set: { set(NSColor($0).hex) }), supportsOpacity: false)
                .labelsHidden()
                .opacity(hex.isEmpty ? 0.45 : 1)
        }
    }
}

/// A part of the inspector you open when you need it.
private struct More<Content: View>: View {
    let title: String
    var count = 0
    @ViewBuilder var content: Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button { open.toggle() } label: {
                HStack(spacing: 5) {
                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .bold)).foregroundStyle(MB.dim).frame(width: 10)
                    Text(title.uppercased()).font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(MB.dim)
                    Spacer()
                    if count > 0 { Text("\(count)").font(.system(size: 10.5)).foregroundStyle(MB.dim) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content }
        }
        .padding(.horizontal, 14).padding(.top, 16)
    }
}

// MARK: Diagram

struct DiagramInspector: View {
    @ObservedObject var store: DiagramStore
    @AppStorage("showHints") private var showHints = true

    private func display<T>(_ path: WritableKeyPath<DisplayOptions, T>, _ name: String) -> Binding<T> {
        Binding(get: { store.diagram.display[keyPath: path] }, set: { v in store.edit(name) { $0.display[keyPath: path] = v } })
    }

    var body: some View {
        let d = store.diagram
        Heading(kind: "Diagram", title: store.title)
        Text("\(d.entities.count) \(d.entities.count == 1 ? "entity" : "entities") · \(d.relationships.count) \(d.relationships.count == 1 ? "relationship" : "relationships")")
            .font(.system(size: 12)).foregroundStyle(MB.dim).padding(.horizontal, 14).padding(.top, 3)

        Section(title: "Notation") {
            MBSegmented(options: Notation.allCases, selection: display(\.notation, "Change Notation"), label: { $0 == .ie ? "Crow’s foot" : "IDEF1X" }, stretch: true)
            Text(d.display.notation == .ie
                 ? "Crow’s feet show the many side; a bar is one, a circle is zero."
                 : "A dot marks the child. P is one or more, Z is zero or one; a diamond means the parent is optional.")
                .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
        }
        Section(title: "Show") {
            Labeled(label: "Names") {
                MBSegmented(options: NameDisplay.allCases, selection: display(\.names, "Change Names"), label: { $0 == .logical ? "Logical" : "Physical" }, stretch: true)
            }
            Labeled(label: "Detail") {
                MBSegmented(options: DetailLevel.allCases, selection: display(\.level, "Change Detail"),
                            label: { $0 == .all ? "Everything" : $0 == .keys ? "Keys" : "Names" }, stretch: true)
            }
            Toggle("Types", isOn: display(\.showTypes, "Show Types")).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
            Toggle("Not null, unique, auto", isOn: display(\.showConstraints, "Show Constraints")).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
            Toggle("Hints on the canvas", isOn: $showHints).toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5))
        }
        .foregroundStyle(MB.text)
        Section(title: "SQL") {
            Labeled(label: "Database") {
                MBMenuPicker(options: Dialect.allCases, selection: Binding(get: { d.dialect }, set: { v in store.edit("Change Database") { $0.dialect = v } }), label: \.title)
            }
            Button(store.showSQL ? "Hide SQL" : "Show SQL") { store.showSQL.toggle() }.buttonStyle(.mbQuiet)
        }
        More(title: "Entity kinds", count: d.entityTypes.count) { EntityKindsEditor(store: store) }
        More(title: "Data types", count: d.dataTypes.count) { DataTypesEditor(store: store) }
        let problems = store.problems
        if !problems.isEmpty {
            Section(title: "Problems", trailing: "\(problems.count)") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(problems) { p in
                        Button {
                            if let e = p.entity { store.select(entity: e) } else if let r = p.relationship { store.selection = .relationship(r) }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 7) {
                                Image(systemName: p.severity == .error ? "exclamationmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 10.5)).foregroundStyle(p.severity == .error ? MB.red : MB.orange)
                                Text(p.message).font(.system(size: 12)).foregroundStyle(MB.muted).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

/// The kinds an entity can be, each with its colour.
struct EntityKindsEditor: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        let kinds = store.diagram.entityTypes
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(kinds.enumerated()), id: \.offset) { i, kind in
                HStack(spacing: 6) {
                    MBField(placeholder: "Kind", text: Binding(get: { kind.name }, set: { v in
                        store.edit("Rename Kind", coalesce: "kind\(i)") { d in
                            guard d.entityTypes.indices.contains(i) else { return }
                            let old = d.entityTypes[i].name
                            d.entityTypes[i].name = v
                            // Entities of this kind keep it under its new name.
                            for e in d.entities.indices where d.entities[e].kind == old && !old.isEmpty { d.entities[e].kind = v }
                        }
                    }))
                    ColorPicker("", selection: Binding(get: { Color(nsColor: NSColor(hex: kind.color) ?? .gray) }, set: { c in
                        store.edit("Change Kind Colour", coalesce: "kindcolour\(i)") { d in if d.entityTypes.indices.contains(i) { d.entityTypes[i].color = NSColor(c).hex } }
                    }), supportsOpacity: false).labelsHidden()
                    MBIconButton(symbol: "minus", help: "Remove this kind") {
                        store.edit("Remove Kind") { d in if d.entityTypes.indices.contains(i) { d.entityTypes.remove(at: i) } }
                    }
                }
            }
            Button("Add a Kind") {
                store.edit("Add Kind") { d in
                    var name = "Kind", n = 2
                    while d.entityTypes.contains(where: { $0.name == name }) { name = "Kind \(n)"; n += 1 }
                    d.entityTypes.append(EntityType(name: name, color: "#CCCCFF"))
                }
            }
            .buttonStyle(.mbQuiet).disabled(kinds.count >= 9)
            Text("An entity’s kind says what it is (a resource, an event, a summary) and gives it that colour. Up to nine.")
                .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Your own data types, and the type an attribute gets when you type none.
struct DataTypesEditor: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        let types = store.diagram.dataTypes
        VStack(alignment: .leading, spacing: 6) {
            ForEach(types) { type in
                HStack(spacing: 6) {
                    MBField(placeholder: "NAME", text: Binding(get: { type.name }, set: { v in
                        store.edit("Rename Type", coalesce: "type\(type.id)") { d in
                            guard let i = d.dataTypes.firstIndex(where: { $0.id == type.id }) else { return }
                            d.dataTypes[i].name = v.uppercased()
                        }
                    }), mono: true)
                    MBMenuPicker(options: DataType.Rule.allCases, selection: Binding(get: { type.length }, set: { v in
                        store.edit("Change Type") { d in if let i = d.dataTypes.firstIndex(where: { $0.id == type.id }) { d.dataTypes[i].length = v } }
                    }), label: { $0 == .none ? "no length" : $0 == .optional ? "length if you like" : "always a length" })
                    .frame(width: 128)
                    MBIconButton(symbol: "minus", help: "Remove this type") {
                        store.edit("Remove Type") { d in d.dataTypes.removeAll { $0.id == type.id } }
                    }
                }
                if type.length != .none {
                    MBField(placeholder: "Length when none is typed, e.g. 255", text: Binding(get: { type.defaultLength }, set: { v in
                        store.edit("Change Type", coalesce: "typelength\(type.id)") { d in if let i = d.dataTypes.firstIndex(where: { $0.id == type.id }) { d.dataTypes[i].defaultLength = v } }
                    }), mono: true)
                }
            }
            Button("Add a Type") {
                store.edit("Add Type") { d in
                    var name = "MYTYPE", n = 2
                    while d.dataTypes.contains(where: { $0.name == name }) { name = "MYTYPE\(n)"; n += 1 }
                    d.dataTypes.append(DataType(name: name))
                }
            }
            .buttonStyle(.mbQuiet)
            Labeled(label: "Type when none is typed") {
                MBField(placeholder: "VARCHAR(255)", text: Binding(get: { store.diagram.defaultType }, set: { v in
                    store.edit("Change Default Type", coalesce: "defaulttype") { $0.defaultType = v }
                }), mono: true)
            }
            Text("Types of your own show in the type menu and are read when you type them. The type above is what a new attribute gets when you type none and its name doesn’t say.")
                .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Entity

struct EntityInspector: View {
    @ObservedObject var store: DiagramStore
    let entity: Entity
    @State private var newLine = ""
    @FocusState private var addFocused: Bool

    private func bind(_ path: WritableKeyPath<Entity, String>, _ name: String) -> Binding<String> {
        let id = entity.id
        return Binding(get: { store.diagram.entity(id)?[keyPath: path] ?? "" },
                       set: { v in store.edit(name, coalesce: "\(name)\(id)") { $0.update(entity: id) { $0[keyPath: path] = v } } })
    }

    var body: some View {
        Heading(kind: store.diagram.isDependent(entity.id) ? "Dependent entity" : "Entity", title: entity.name.isEmpty ? "Untitled" : entity.name)
        Section(title: "Name") {
            MBField(placeholder: "Name", text: bind(\.name, "Rename Entity"))
            Labeled(label: "Table name") {
                MBField(placeholder: Naming.physical(entity.name), text: bind(\.physicalName, "Change Table Name"), mono: true)
            }
            HStack(spacing: 6) {
                ForEach(EntityColor.allCases, id: \.self) { c in
                    Button {
                        store.edit("Change Colour") { $0.update(entity: entity.id) { $0.color = c } }
                    } label: {
                        ZStack {
                            if let color = c.nsColor { Circle().fill(Color(nsColor: color)) } else {
                                Circle().strokeBorder(MB.dim, lineWidth: 1)
                                Rectangle().fill(MB.dim).frame(width: 12, height: 1).rotationEffect(.degrees(-45))
                            }
                            if entity.color == c { Circle().strokeBorder(MB.text, lineWidth: 2).padding(-3) }
                        }
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(c.title)
                    .accessibilityLabel(c.title)
                }
            }
            .padding(.top, 2).padding(.leading, 3)
            if !store.diagram.entityTypes.isEmpty {
                Labeled(label: "Kind") {
                    MBMenuPicker(options: [""] + store.diagram.entityTypes.map(\.name),
                                 selection: Binding(get: { entity.kind }, set: { v in store.edit("Change Kind") { $0.update(entity: entity.id) { $0.kind = v } } }),
                                 label: { $0.isEmpty ? "None" : $0 })
                }
            }
        }
        Section(title: "Attributes", trailing: "\(entity.attributes.count)") {
            VStack(spacing: 2) {
                ForEach(entity.attributes) { a in
                    AttributeRow(store: store, entityID: entity.id, attribute: a)
                }
            }
            .padding(.horizontal, -6)
            HStack(spacing: 6) {
                Image(systemName: "plus").font(.system(size: 10, weight: .bold)).foregroundStyle(MB.dim)
                TextField("name type, e.g. email varchar(255)", text: $newLine)
                    .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(MB.text)
                    .focused($addFocused)
                    .onSubmit {
                        if store.addAttribute(newLine, to: entity.id) != nil { newLine = "" }
                        addFocused = true
                    }
            }
            .padding(.horizontal, 9).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
            Text("Add pk, unique, not null, auto or = a default after the type. Leave the type out and one is picked from the name.")
                .font(.system(size: 11)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
        }
        Section(title: "Definition") {
            MBTextArea(placeholder: "What this entity is", text: bind(\.definition, "Change Definition"))
        }
        More(title: "Indexes", count: entity.indexes.count) { IndexesEditor(store: store, entity: entity) }
        More(title: "Look") { EntityLook(store: store, entity: entity) }
        More(title: "More names, tags and links", count: entity.tags.count + entity.links.count) {
            Labeled(label: "Group in the entity list") { MBField(placeholder: "none", text: bind(\.package, "Change Group")) }
            Labeled(label: "Other name 1") { MBField(placeholder: "such as the name in another language", text: bind(\.alias1, "Change Other Name")) }
            Labeled(label: "Other name 2") { MBField(placeholder: "", text: bind(\.alias2, "Change Other Name")) }
            Labeled(label: "Tags") {
                LinesField(placeholder: "owner = sales", lines: TagText.text(entity.tags)) { v in
                    store.edit("Change Tags", coalesce: "tags\(entity.id)") { $0.update(entity: entity.id) { $0.tags = TagText.tags(v) } }
                }
            }
            Labeled(label: "Links") {
                LinesField(placeholder: "https://… one per line", lines: entity.links.joined(separator: "\n")) { v in
                    store.edit("Change Links", coalesce: "links\(entity.id)") { $0.update(entity: entity.id) { $0.links = v.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }
                }
            }
            ForEach(entity.links.filter { URL(string: $0)?.scheme != nil }, id: \.self) { link in
                Button(link) { if let url = URL(string: link) { NSWorkspace.shared.open(url) } }
                    .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(MB.accentInk).lineLimit(1)
            }
        }
        let links = store.diagram.relationships(of: entity.id)
        if !links.isEmpty {
            Section(title: "Relationships", trailing: "\(links.count)") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(links) { r in
                        let other = store.diagram.entity(r.parent == entity.id ? r.child : r.parent)
                        Button { store.selection = .relationship(r.id) } label: {
                            HStack(spacing: 7) {
                                Image(systemName: r.kind == .manyToMany ? "arrow.left.arrow.right" : r.parent == entity.id ? "arrow.down.right" : "arrow.up.left")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(MB.dim).frame(width: 14)
                                Text(other?.name ?? "").font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(r.kind == .manyToMany ? "many-to-many" : r.kind == .subtype ? (r.parent == entity.id ? "is a kind of it" : "it is a kind of") : r.parent == entity.id ? "child" : "parent").font(.system(size: 11)).foregroundStyle(MB.dim)
                            }
                            .padding(.horizontal, 6).frame(height: 26).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, -6)
            }
        }
        Section(title: "") {
            Button("Delete Entity") { store.selectedAttribute = nil; store.deleteSelection() }.buttonStyle(.mbDanger)
        }
    }
}

/// The indexes of one entity: which attributes each is over, and whether it is unique.
struct IndexesEditor: View {
    @ObservedObject var store: DiagramStore
    let entity: Entity

    private func change(_ id: UUID, _ name: String, coalesce: Bool = false, _ work: @escaping (inout Index) -> Void) {
        let e = entity.id
        store.edit(name, coalesce: coalesce ? "\(name)\(id)" : nil) { d in
            d.update(entity: e) { entity in
                if let i = entity.indexes.firstIndex(where: { $0.id == id }) { work(&entity.indexes[i]) }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(entity.indexes) { index in
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 5) {
                        MBField(placeholder: "name", text: Binding(get: { index.name }, set: { v in change(index.id, "Rename Index", coalesce: true) { $0.name = v } }), mono: true)
                        MBToggleChip(text: "U", help: "Unique: no two rows may have the same values here", isOn: Binding(get: { index.unique }, set: { v in change(index.id, "Change Index") { $0.unique = v } }))
                        MBIconButton(symbol: "minus", help: "Remove this index") {
                            let e = entity.id
                            store.edit("Remove Index") { $0.update(entity: e) { $0.indexes.removeAll { $0.id == index.id } } }
                        }
                    }
                    Menu {
                        ForEach(entity.attributes) { a in
                            Toggle(a.name, isOn: Binding(get: { index.attributes.contains(a.id) }, set: { on in
                                change(index.id, "Change Index") { if on { if !$0.attributes.contains(a.id) { $0.attributes.append(a.id) } } else { $0.attributes.removeAll { $0 == a.id } } }
                            }))
                        }
                        Divider()
                        Toggle(index.unique ? "Mark as AK on the diagram" : "Mark as IE on the diagram", isOn: Binding(get: { index.shown }, set: { v in change(index.id, "Change Index") { $0.shown = v } }))
                    } label: {
                        HStack {
                            let names = index.attributes.compactMap { id in entity.attributes.first { $0.id == id }?.name }
                            Text(names.isEmpty ? "Choose attributes…" : names.joined(separator: ", ")).font(.system(size: 12)).foregroundStyle(names.isEmpty ? MB.orange : MB.muted).lineLimit(2)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(MB.dim)
                        }
                        .padding(.horizontal, 9).frame(minHeight: 28)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
                        .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .accessibilityLabel("Attributes of \(index.name)")
                }
            }
            HStack(spacing: 8) {
                Button("Add an Index") { store.addIndex(to: entity.id, unique: false) }.buttonStyle(.mbQuiet)
                Button("Add a Unique Index") { store.addIndex(to: entity.id, unique: true) }.buttonStyle(.mbQuiet)
            }
            Text("An index over one or more attributes. A unique one (an alternate key, AK) can be what a relationship points at; one that isn’t (IE) only speeds up finding rows.")
                .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// How one entity is drawn: its own colours, its width, and how much of it shows.
struct EntityLook: View {
    @ObservedObject var store: DiagramStore
    let entity: Entity

    private func set(_ name: String, _ change: @escaping (inout Entity) -> Void) {
        let id = entity.id
        store.edit(name, coalesce: "\(name)\(id)") { $0.update(entity: id, change) }
    }

    // Spelled out, so the compiler has nothing to work out inside the view.
    private static let levels: [DetailLevel?] = [nil, .all, .keys, .namesOnly]

    private static func levelTitle(_ level: DetailLevel?) -> String {
        switch level {
        case nil: "As the rest of the diagram"
        case .all?: "Everything"
        case .keys?: "Keys only"
        case .namesOnly?: "Its name only"
        }
    }

    private var level: Binding<DetailLevel?> {
        Binding(get: { entity.level }, set: { v in set("Change Detail") { $0.level = v } })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HexColorPicker(label: "Fill", hex: entity.style.fill) { v in set("Change Colour") { $0.style.fill = v } }
            HexColorPicker(label: "Border", hex: entity.style.line) { v in set("Change Colour") { $0.style.line = v } }
            HexColorPicker(label: "Text", hex: entity.style.text) { v in set("Change Colour") { $0.style.text = v } }
            Labeled(label: "Shows") {
                MBMenuPicker(options: Self.levels, selection: level, label: Self.levelTitle)
            }
            let hidden = entity.attributes.filter(\.hidden).count
            if hidden > 0 {
                Button("Show its \(hidden) hidden \(hidden == 1 ? "attribute" : "attributes")") {
                    set("Show Attributes") { e in for i in e.attributes.indices { e.attributes[i].hidden = false } }
                }
                .buttonStyle(.mbQuiet)
            }
            if entity.width > 0 {
                Button("Back to its own width") { set("Change Width") { $0.width = 0 } }.buttonStyle(.mbQuiet)
            }
        }
    }
}

/// One attribute: key, name, type, required, and a menu for the rest.
struct AttributeRow: View {
    @ObservedObject var store: DiagramStore
    let entityID: UUID
    let attribute: Attribute
    @State private var hovering = false

    private func set(_ name: String, coalesce: Bool = false, _ change: @escaping (inout Attribute) -> Void) {
        let (e, a) = (entityID, attribute.id)
        store.edit(name, coalesce: coalesce ? "\(name)\(a)" : nil) { $0.update(attribute: a, in: e, change) }
    }

    private func text(_ path: WritableKeyPath<Attribute, String>, _ name: String) -> Binding<String> {
        let (e, a) = (entityID, attribute.id)
        return Binding(get: { store.diagram.entity(e)?.attributes.first { $0.id == a }?[keyPath: path] ?? "" },
                       set: { v in set(name, coalesce: true) { $0[keyPath: path] = v } })
    }

    var body: some View {
        let a = attribute
        let selected = store.selectedAttribute == a.id
        let expanded = store.expandedAttribute == a.id
        let source = store.diagram.source(of: a)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Button { store.togglePrimaryKey(a.id, in: entityID) } label: {
                    Image(systemName: a.isPrimaryKey ? "key.fill" : "key")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(a.isPrimaryKey ? MB.accentInk : MB.dim.opacity(0.6))
                        .frame(width: 20, height: 22).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(a.isForeignKey ? (a.isPrimaryKey ? "Part of the key: the relationship is identifying. Click to make it non-identifying."
                                                       : "Click to make the relationship identifying: this column joins the key.")
                                     : (a.isPrimaryKey ? "Primary key. Click to take it out of the key." : "Click to make this the primary key."))
                .accessibilityLabel("Primary key").accessibilityValue(a.isPrimaryKey ? "on" : "off")

                if a.isForeignKey { MBTag(text: "FK", color: MB.dim).help(source.map { "Copies \($0.parent.name).\($0.column.name)" } ?? "Foreign key") }
                TextField("name", text: Binding(get: { a.name }, set: { v in
                    set("Rename Attribute", coalesce: true) { $0.name = v; $0.physicalName = ""; $0.foreignKey?.followsName = false }
                }))
                .textFieldStyle(.plain).font(.system(size: 12.5, weight: a.isPrimaryKey ? .semibold : .regular)).foregroundStyle(MB.text)
                .frame(minWidth: 60)

                if a.isForeignKey {
                    Text(a.type).font(.system(size: 11.5)).foregroundStyle(MB.dim).lineLimit(1)
                        .help(source.map { "The type follows \($0.parent.name).\($0.column.name)" } ?? "")
                } else {
                    TextField("type", text: text(\.type, "Change Type"))
                        .textFieldStyle(.plain).font(.system(size: 11.5)).foregroundStyle(MB.muted)
                        .multilineTextAlignment(.trailing)
                        .frame(width: min(96, max(44, Metrics.width(a.type.isEmpty ? "type" : a.type, NSFont.systemFont(ofSize: 11.5)) + 10)))
                        .onSubmit { set("Change Type") { if store.diagram.domain(named: $0.type) == nil, !$0.type.isEmpty { $0.type = QuickEntry.canonical($0.type) } } }
                    typeMenu
                }
                MBToggleChip(text: "NN", help: a.isPrimaryKey ? "A key is always required" : a.isForeignKey ? "Set by the relationship: is the parent optional?" : "Required (not null)",
                             isOn: Binding(get: { a.notNull }, set: { v in set("Change Attribute") { $0.notNull = v } }),
                             enabled: !a.isPrimaryKey && !a.isForeignKey)
                moreMenu
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Labeled(label: "Column name") { MBField(placeholder: Naming.physical(a.name), text: text(\.physicalName, "Change Column Name"), mono: true) }
                    if !a.isForeignKey {
                        Labeled(label: "Default") { MBField(placeholder: "none", text: text(\.defaultValue, "Change Default"), mono: true) }
                    }
                    Labeled(label: "Definition") { MBTextArea(placeholder: "What this attribute means", text: text(\.definition, "Change Definition")) }
                    Labeled(label: "Other names") {
                        HStack(spacing: 5) {
                            MBField(placeholder: "1", text: text(\.alias1, "Change Other Name"))
                            MBField(placeholder: "2", text: text(\.alias2, "Change Other Name"))
                        }
                    }
                    Labeled(label: "Tags") {
                        LinesField(placeholder: "name = value", lines: TagText.text(a.tags)) { v in set("Change Tags", coalesce: true) { $0.tags = TagText.tags(v) } }
                    }
                    if let source {
                        Button("Copies \(source.parent.name).\(source.column.name): show the relationship") { store.selection = .relationship(source.relationship.id) }
                            .buttonStyle(.plain).font(.system(size: 11.5)).foregroundStyle(MB.accentInk)
                    }
                }
                .padding(.leading, 25).padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(selected ? MB.selected : hovering ? MB.hover : .clear))
        .onHover { hovering = $0 }
        .simultaneousGesture(TapGesture().onEnded { store.selectedAttribute = a.id })
    }

    private var typeMenu: some View {
        Menu {
            ForEach(QuickEntry.suggestedTypes, id: \.self) { t in
                Button(t) { set("Change Type") { $0.type = t } }
            }
            if !store.diagram.dataTypes.isEmpty {
                Divider()
                ForEach(store.diagram.dataTypes) { t in
                    Button(t.spelled) { set("Change Type") { $0.type = t.spelled } }
                }
            }
            if !store.diagram.domains.isEmpty {
                Divider()
                ForEach(store.diagram.domains) { d in
                    Button("\(d.name)  (\(store.diagram.resolvedType(d.name)))") { set("Change Type") { $0.type = d.name } }
                }
            }
        } label: {
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(MB.dim).frame(width: 14, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Pick a type or a domain")
        .accessibilityLabel("Pick a type")
    }

    private var moreMenu: some View {
        let a = attribute
        return Menu {
            Toggle("Unique", isOn: Binding(get: { a.unique }, set: { v in set("Change Attribute") { $0.unique = v } }))
            if !a.isForeignKey {
                Toggle("Counts up by itself (auto)", isOn: Binding(get: { a.autoIncrement }, set: { v in set("Change Attribute") { $0.autoIncrement = v } }))
            }
            Toggle("Hidden on the Diagram", isOn: Binding(get: { a.hidden }, set: { v in set("Change Attribute") { $0.hidden = v } }))
            Button(store.expandedAttribute == a.id ? "Hide Details" : "Column Name, Default, Definition, Tags…") {
                store.expandedAttribute = store.expandedAttribute == a.id ? nil : a.id
            }
            Divider()
            Button("Move Up") { store.moveAttribute(a.id, in: entityID, by: -1) }
            Button("Move Down") { store.moveAttribute(a.id, in: entityID, by: 1) }
            Divider()
            if let fk = a.foreignKey {
                Button("Show Its Relationship") { store.selection = .relationship(fk.relationship) }
            } else {
                Button("Delete Attribute", role: .destructive) { store.deleteAttribute(a.id, in: entityID) }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(MB.dim).frame(width: 20, height: 22).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More: unique, default, definition, move, delete")
        .accessibilityLabel("More for \(a.name)")
    }
}

// MARK: Relationship

struct RelationshipInspector: View {
    @ObservedObject var store: DiagramStore
    let relationship: Relationship
    let parent: Entity
    let child: Entity

    private func set(_ name: String, coalesce: Bool = false, _ change: @escaping (inout Relationship) -> Void) {
        let id = relationship.id
        store.edit(name, coalesce: coalesce ? "\(name)\(id)" : nil) { $0.update(relationship: id, change) }
    }

    private func text(_ path: WritableKeyPath<Relationship, String>, _ name: String) -> Binding<String> {
        let id = relationship.id
        return Binding(get: { store.diagram.relationship(id)?[keyPath: path] ?? "" }, set: { v in set(name, coalesce: true) { $0[keyPath: path] = v } })
    }

    private var kindNote: String {
        switch relationship.kind {
        case .identifying: "\(child.name) can’t exist without \(parent.name): \(parent.name)’s key becomes part of \(child.name)’s key."
        case .nonIdentifying: "\(child.name) points at \(parent.name) with an ordinary column. \(child.name) keeps its own key."
        case .manyToMany: "Many on both sides. Neither entity gets a column; the SQL gets a table \(parent.tableName)_\(child.tableName) in between."
        case .subtype: "\(child.name) is a kind of \(parent.name): it has \(parent.name)’s key as its own, and its own attributes on top."
        }
    }

    private static func kindTitle(_ k: RelationshipKind) -> String {
        switch k {
        case .identifying: "Identifying"
        case .nonIdentifying: "Non-identifying"
        case .manyToMany: "Many-to-many"
        case .subtype: "Subtype (is a kind of)"
        }
    }

    // The choices that can also be "none", spelled out: their options, what each is called, and where it is kept.
    private var discriminators: [UUID?] {
        var out: [UUID?] = [nil]
        for a in parent.attributes { out.append(a.id) }
        return out
    }

    private func discriminatorTitle(_ id: UUID?) -> String {
        guard let id, let a = parent.attributes.first(where: { $0.id == id }) else { return "Nothing" }
        return a.name
    }

    private var discriminator: Binding<UUID?> {
        Binding(get: { relationship.discriminator }, set: { v in set("Change Subtype") { $0.discriminator = v } })
    }

    private var keys: [UUID?] {
        var out: [UUID?] = [nil]
        for index in parent.indexes where index.unique && !index.attributes.isEmpty { out.append(index.id) }
        return out
    }

    private func keyTitle(_ id: UUID?) -> String {
        guard let id, let index = parent.indexes.first(where: { $0.id == id }) else { return "\(parent.name)’s primary key" }
        return "the unique index \(index.name)"
    }

    private var key: Binding<UUID?> {
        Binding(get: { relationship.parentIndex }, set: { v in set("Change Foreign Key") { $0.parentIndex = v } })
    }

    private var lowerText: Binding<String> {
        Binding(get: { "\(relationship.childLower)" }, set: { v in set("Change Cardinality", coalesce: true) { $0.childLower = max(0, Int(v) ?? 0) } })
    }

    private var upperText: Binding<String> {
        Binding(get: { relationship.childUpper <= 0 ? "" : "\(relationship.childUpper)" },
                set: { v in set("Change Cardinality", coalesce: true) { $0.childUpper = max(0, Int(v) ?? 0) } })
    }

    /// The five ways to say how many, the last one a number of your own.
    private static func countTitle(_ c: Cardinality, _ child: String) -> String {
        switch c {
        case .zeroOrMore: "zero or more \(child)"
        case .oneOrMore: "one or more \(child)"
        case .zeroOrOne: "zero or one \(child)"
        case .exactlyOne: "exactly one \(child)"
        case .counted: "a number of \(child)…"
        }
    }

    var body: some View {
        let r = relationship
        let own = r.parent == r.child
        Heading(kind: r.kind == .subtype ? "Subtype" : "Relationship", title: "\(parent.name) → \(child.name)")
        Text(Report.sentence(r, parent: parent, child: child))
            .font(.system(size: 12)).foregroundStyle(MB.muted).fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 14).padding(.top, 4)

        Section(title: "Kind") {
            MBMenuPicker(options: own ? [RelationshipKind.nonIdentifying, .manyToMany] : RelationshipKind.allCases,
                         selection: Binding(get: { r.kind }, set: { v in set("Change Relationship") { $0.kind = v } }),
                         label: Self.kindTitle)
            Text(kindNote).font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
        }
        if r.kind == .subtype {
            Section(title: "Kinds") {
                Labeled(label: "Told apart by") {
                    MBMenuPicker(options: discriminators, selection: discriminator, label: discriminatorTitle)
                }
                Toggle("Every \(parent.name) is one of its kinds", isOn: Binding(get: { r.complete }, set: { v in set("Change Subtype") { $0.complete = v } }))
                    .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5)).foregroundStyle(MB.text)
                Text("The attribute of \(parent.name) that says which kind a row is, such as a type column. Complete (two lines under the circle): there are no other kinds than the ones drawn.")
                    .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
            }
        } else if r.kind != .manyToMany {
            Section(title: "How many") {
                Labeled(label: "One \(parent.name) has") {
                    MBMenuPicker(options: Cardinality.allCases, selection: Binding(get: { r.childCardinality }, set: { v in set("Change Cardinality") { $0.childCardinality = v } }),
                                 label: { Self.countTitle($0, child.name) })
                }
                if r.childCardinality == .counted {
                    HStack(spacing: 6) {
                        Text("at least").font(.system(size: 12)).foregroundStyle(MB.muted)
                        MBField(placeholder: "1", text: lowerText, mono: true).frame(width: 52)
                        Text("at most").font(.system(size: 12)).foregroundStyle(MB.muted)
                        MBField(placeholder: "any", text: upperText, mono: true).frame(width: 52)
                    }
                    Text("Leave “at most” empty for no limit. The same number twice is exactly that many.")
                        .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
                }
                Labeled(label: "Each \(child.name)") {
                    MBMenuPicker(options: r.kind == .identifying ? [false] : [false, true],
                                 selection: Binding(get: { r.parentOptional }, set: { v in set("Change Relationship") { $0.parentOptional = v } }),
                                 label: { $0 ? "may have a \(parent.name) (can be empty)" : "must have a \(parent.name)" })
                }
            }
        }
        Section(title: "Name") {
            MBField(placeholder: "A verb: \(parent.name) … \(child.name)", text: text(\.name, "Name Relationship"))
            if r.kind != .subtype {
                Labeled(label: "Read the other way") {
                    MBField(placeholder: "\(child.name) … \(parent.name)", text: text(\.childName, "Name Relationship"))
                }
            }
        }
        if r.kind != .manyToMany {
            let columns = child.attributes.filter { $0.foreignKey?.relationship == r.id }
            let unique = parent.indexes.filter { $0.unique && !$0.attributes.isEmpty }
            Section(title: "Foreign key", trailing: columns.isEmpty ? "" : "\(columns.count)") {
                if r.kind != .subtype, !unique.isEmpty {
                    Labeled(label: "Points at") {
                        MBMenuPicker(options: keys, selection: key, label: keyTitle)
                    }
                }
                if columns.isEmpty {
                    Text("\(parent.name) has no primary key yet, so there is nothing to copy. Give it one and the column appears in \(child.name).")
                        .font(.system(size: 11.5)).foregroundStyle(MB.orange).fixedSize(horizontal: false, vertical: true)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(columns) { a in
                            HStack(spacing: 6) {
                                Text("\(child.tableName).\(a.columnName)").foregroundStyle(MB.text)
                                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(MB.dim)
                                Text("\(parent.tableName).\(store.diagram.source(of: a)?.column.columnName ?? "")").foregroundStyle(MB.muted)
                            }
                            .font(MB.mono).lineLimit(1)
                        }
                    }
                }
                Labeled(label: "When a \(parent.name) is deleted") {
                    MBMenuPicker(options: ReferentialAction.allCases, selection: Binding(get: { r.onDelete }, set: { v in set("Change Rule") { $0.onDelete = v } }),
                                 label: { Self.actionTitle($0, child: child.name) })
                }
                Labeled(label: "When its key changes") {
                    MBMenuPicker(options: ReferentialAction.allCases, selection: Binding(get: { r.onUpdate }, set: { v in set("Change Rule") { $0.onUpdate = v } }),
                                 label: { Self.actionTitle($0, child: child.name, update: true) })
                }
            }
        }
        More(title: "Line") { RelationshipLook(store: store, relationship: r) }
        More(title: "Definition, constraint name and tags", count: r.tags.count) {
            Labeled(label: "Definition") { MBTextArea(placeholder: "What this relationship means", text: text(\.definition, "Change Definition")) }
            if r.kind != .manyToMany {
                Labeled(label: "Name of the foreign key in the database") { MBField(placeholder: "made from the tables", text: text(\.physicalName, "Change Constraint Name"), mono: true) }
            }
            Labeled(label: "Tags") {
                LinesField(placeholder: "name = value", lines: TagText.text(r.tags)) { v in set("Change Tags", coalesce: true) { $0.tags = TagText.tags(v) } }
            }
        }
        Section(title: "") {
            HStack(spacing: 8) {
                if r.kind == .manyToMany {
                    Button("Turn Into an Entity") {
                        var made: UUID?
                        store.edit("Turn Into an Entity") { made = $0.resolveManyToMany(r.id) }
                        if let made { store.selection = .entities([made]) }
                    }
                    .buttonStyle(.mbQuiet)
                    .help("Replaces this line by an entity in the middle, so you can give it attributes of its own")
                } else if !own {
                    Button("Swap Direction") { store.edit("Swap Direction") { $0.flip(relationship: r.id) } }.buttonStyle(.mbQuiet)
                        .help("Makes \(child.name) the parent: the foreign key moves to \(parent.name)")
                }
                Button("Delete") { store.deleteSelection() }.buttonStyle(.mbDanger)
            }
        }
    }

    static func actionTitle(_ a: ReferentialAction, child: String, update: Bool = false) -> String {
        switch a {
        case .noAction: "Refuse (no action)"
        case .restrict: "Refuse at once (restrict)"
        case .cascade: update ? "Change it in \(child) too (cascade)" : "Delete its \(child) too (cascade)"
        case .setNull: "Empty the column (set null)"
        case .setDefault: "Use the column’s default (set default)"
        }
    }
}

/// How one relationship's line is drawn.
struct RelationshipLook: View {
    @ObservedObject var store: DiagramStore
    let relationship: Relationship

    private func set(_ name: String, _ change: @escaping (inout Relationship) -> Void) {
        let id = relationship.id
        store.edit(name, coalesce: "\(name)\(id)") { $0.update(relationship: id, change) }
    }

    var body: some View {
        let r = relationship
        VStack(alignment: .leading, spacing: 8) {
            Labeled(label: "Shape") {
                MBSegmented(options: LineShape.allCases, selection: Binding(get: { r.shape }, set: { v in set("Change Line") { $0.shape = v } }),
                            label: { $0 == .auto ? "Square" : $0 == .straight ? "Straight" : "Curved" }, stretch: true)
            }
            HexColorPicker(label: "Colour", hex: r.style.line) { v in set("Change Colour") { $0.style.line = v } }
            Toggle("Show its name", isOn: Binding(get: { !r.hideName }, set: { v in set("Change Line") { $0.hideName = !v } }))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5)).foregroundStyle(MB.text)
            Toggle("Show how many", isOn: Binding(get: { !r.hideCardinality }, set: { v in set("Change Line") { $0.hideCardinality = !v } }))
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5)).foregroundStyle(MB.text)
            if !r.waypoints.isEmpty {
                Button("Let the app find the way again") { set("Reroute Line") { $0.waypoints = [] } }.buttonStyle(.mbQuiet)
            }
        }
    }
}

// MARK: Domain, and several entities

struct DomainInspector: View {
    @ObservedObject var store: DiagramStore
    let domain: Domain

    private func bind(_ path: WritableKeyPath<Domain, String>, _ name: String) -> Binding<String> {
        let id = domain.id
        return Binding(get: { store.diagram.domain(id)?[keyPath: path] ?? "" }, set: { v in
            store.edit(name, coalesce: "\(name)\(id)") { d in
                // Attributes that use the domain follow its new name.
                if path == \Domain.name, let old = d.domain(id)?.name, !old.isEmpty {
                    for e in d.entities.indices {
                        for a in d.entities[e].attributes.indices where d.entities[e].attributes[a].type.lowercased() == old.lowercased() {
                            d.entities[e].attributes[a].type = v
                        }
                    }
                }
                d.update(domain: id) { $0[keyPath: path] = v }
            }
        })
    }

    private func parents(_ others: [Domain]) -> [UUID?] {
        var out: [UUID?] = [nil]
        for other in others { out.append(other.id) }
        return out
    }

    private func parentTitle(_ id: UUID?) -> String {
        guard let id, let found = store.diagram.domain(id) else { return "Nothing" }
        return found.name
    }

    private var parent: Binding<UUID?> {
        let id = domain.id
        return Binding(get: { store.diagram.domain(id)?.parent }, set: { v in store.edit("Change Domain") { $0.update(domain: id) { $0.parent = v } } })
    }

    private var required: Binding<Bool> {
        let id = domain.id
        return Binding(get: { store.diagram.domain(id)?.notNull ?? false }, set: { v in store.edit("Change Domain") { $0.update(domain: id) { $0.notNull = v } } })
    }

    /// Every attribute whose type is this domain, with its entity.
    private var users: [(Entity, Attribute)] {
        var out: [(Entity, Attribute)] = []
        let name = domain.name.lowercased()
        for e in store.diagram.entities {
            for a in e.attributes where !a.isForeignKey && a.type.lowercased() == name { out.append((e, a)) }
        }
        return out
    }

    var body: some View {
        let d = store.diagram
        let users = self.users
        // A domain can't sit under itself or under one of its own children.
        let others = d.domains.filter { other in other.id != domain.id && !d.ancestors(of: other).contains { $0.id == domain.id } }
        Heading(kind: "Domain", title: domain.name.isEmpty ? "Untitled" : domain.name)
        Text(users.isEmpty ? "Not used yet. Type its name as an attribute’s type." : "Used by \(users.count) \(users.count == 1 ? "attribute" : "attributes").")
            .font(.system(size: 12)).foregroundStyle(MB.dim).padding(.horizontal, 14).padding(.top, 3)
        Section(title: "Domain") {
            Labeled(label: "Name") { MBField(placeholder: "email", text: bind(\.name, "Rename Domain")) }
            Labeled(label: "Type") { MBField(placeholder: domain.parent == nil ? "VARCHAR(255)" : "as its parent: \(d.resolvedType(domain.name))", text: bind(\.type, "Change Domain Type"), mono: true) }
            if !others.isEmpty || domain.parent != nil {
                Labeled(label: "A narrower kind of") {
                    MBMenuPicker(options: parents(others), selection: parent, label: parentTitle)
                }
            }
            Labeled(label: "Default") { MBField(placeholder: "none", text: bind(\.defaultValue, "Change Default"), mono: true) }
            Toggle("Required (not null)", isOn: required)
                .toggleStyle(.switch).controlSize(.small).font(.system(size: 12.5)).foregroundStyle(MB.text)
            Labeled(label: "Definition") { MBTextArea(placeholder: "What it is for", text: bind(\.definition, "Change Definition")) }
        }
        if !users.isEmpty {
            Section(title: "Used by", trailing: "\(users.count)") {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(users, id: \.1.id) { e, a in
                        Button {
                            store.select(entity: e.id)
                            store.selectedAttribute = a.id
                        } label: {
                            HStack {
                                Text("\(e.name).\(a.name)").font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 6).frame(height: 24).contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, -6)
            }
        }
        More(title: "More names and tags", count: domain.tags.count) {
            Labeled(label: "Name in the database") { MBField(placeholder: Naming.physical(domain.name), text: bind(\.physicalName, "Change Domain"), mono: true) }
            Labeled(label: "Other name 1") { MBField(placeholder: "", text: bind(\.alias1, "Change Other Name")) }
            Labeled(label: "Other name 2") { MBField(placeholder: "", text: bind(\.alias2, "Change Other Name")) }
            Labeled(label: "Tags") {
                LinesField(placeholder: "name = value", lines: TagText.text(domain.tags)) { v in
                    store.edit("Change Tags", coalesce: "tags\(domain.id)") { $0.update(domain: domain.id) { $0.tags = TagText.tags(v) } }
                }
            }
        }
        Section(title: "") {
            Button("Delete Domain") { store.deleteSelection() }.buttonStyle(.mbDanger)
        }
    }
}

struct MultiInspector: View {
    @ObservedObject var store: DiagramStore
    let count: Int

    var body: some View {
        Heading(kind: "Selection", title: "\(count) entities")
        Section(title: "Align") {
            HStack(spacing: 2) {
                MBIconButton(symbol: "align.horizontal.left", help: "Left edges") { store.align(.left) }
                MBIconButton(symbol: "align.horizontal.center", help: "Centres") { store.align(.centre) }
                MBIconButton(symbol: "align.horizontal.right", help: "Right edges") { store.align(.right) }
                MBIconButton(symbol: "align.vertical.top", help: "Top edges") { store.align(.top) }
                MBIconButton(symbol: "align.vertical.center", help: "Middles") { store.align(.middle) }
                MBIconButton(symbol: "align.vertical.bottom", help: "Bottom edges") { store.align(.bottom) }
            }
            HStack(spacing: 8) {
                Button("Spread Across") { store.align(.spreadAcross) }.buttonStyle(.mbQuiet)
                Button("Spread Down") { store.align(.spreadDown) }.buttonStyle(.mbQuiet)
            }
            Button("Tidy Up Selection") { store.tidyUp() }.buttonStyle(.mbQuiet)
        }
        Section(title: "") {
            HStack(spacing: 8) {
                Button("Duplicate") { store.duplicateSelection() }.buttonStyle(.mbQuiet)
                Button("Delete") { store.deleteSelection() }.buttonStyle(.mbDanger)
            }
        }
    }
}
