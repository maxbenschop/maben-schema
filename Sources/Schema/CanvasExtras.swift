import AppKit
import Combine
import SchemaCore
import SwiftUI

/// The tools at the top of the canvas: the pointer, and one for each thing you can put on the canvas that isn't
/// part of the model. Pick one, then click or drag on the canvas; it goes back to the pointer by itself.
struct ToolStrip: View {
    @ObservedObject var store: DiagramStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tool.allCases, id: \.self) { tool in
                MBIconButton(symbol: tool.symbol, help: help(tool), active: store.tool == tool) {
                    // A note and a line of text appear at once, ready to type in.
                    store.tool = store.tool == tool ? .pointer : tool
                }
                if tool == .pointer || tool == .text || tool == .arrow { Hairline(vertical: true).frame(height: 16).padding(.horizontal, 2) }
            }
            Hairline(vertical: true).frame(height: 16).padding(.horizontal, 2)
            MBIconButton(symbol: "photo", help: "Put a picture on the canvas") { store.chooseImage() }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MB.card))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(MB.line))
    }

    private func help(_ tool: Tool) -> String {
        switch tool {
        case .pointer: "Select and move (esc)"
        case .note, .text: "\(tool.title): click where it goes"
        case .pen, .highlighter: "\(tool.title): draw on the canvas"
        default: "\(tool.title): drag it out on the canvas"
        }
    }
}

/// A small picture of the whole diagram, with the part you are looking at marked. Click or drag in it to go there.
struct MiniMap: NSViewRepresentable {
    let store: DiagramStore

    func makeNSView(context: Context) -> MapView { MapView(store: store) }
    func updateNSView(_ view: MapView, context: Context) { view.needsDisplay = true }

    final class MapView: NSView {
        let store: DiagramStore
        private var watching: AnyCancellable?

        init(store: DiagramStore) {
            self.store = store
            super.init(frame: .zero)
            setAccessibilityLabel("Map of the diagram")
            watching = store.objectWillChange.sink { [weak self] _ in DispatchQueue.main.async { self?.needsDisplay = true } }
        }

        required init?(coder: NSCoder) { fatalError() }
        override var isFlipped: Bool { true }

        /// Everything there is, with what you are looking at, and how that maps into this view.
        private var mapping: (area: CGRect, scale: CGFloat, origin: CGPoint)? {
            guard let canvas = store.canvas else { return nil }
            var area = store.scene.bounds() ?? .zero
            area = area.union(canvas.visibleCanvas).insetBy(dx: -20, dy: -20)
            guard area.width > 0, area.height > 0 else { return nil }
            let scale = min((bounds.width - 8) / area.width, (bounds.height - 8) / area.height)
            let origin = CGPoint(x: (bounds.width - area.width * scale) / 2 - area.minX * scale, y: (bounds.height - area.height * scale) / 2 - area.minY * scale)
            return (area, scale, origin)
        }

        override func draw(_ dirtyRect: NSRect) {
            guard let ctx = NSGraphicsContext.current?.cgContext, let m = mapping, let canvas = store.canvas else { return }
            func place(_ r: CGRect) -> CGRect { CGRect(x: r.minX * m.scale + m.origin.x, y: r.minY * m.scale + m.origin.y, width: r.width * m.scale, height: r.height * m.scale) }
            let scene = store.scene
            ctx.setLineWidth(0.75)
            ctx.setStrokeColor(MB.nsWire.withAlphaComponent(0.7).cgColor)
            for link in scene.links.prefix(2000) {
                guard let first = link.points.first else { continue }
                ctx.move(to: place(CGRect(origin: first, size: .zero)).origin)
                for p in link.points.dropFirst() { ctx.addLine(to: place(CGRect(origin: p, size: .zero)).origin) }
            }
            ctx.strokePath()
            for box in scene.boxes {
                let tint = NSColor(hex: box.entity.style.fill) ?? box.entity.color.nsColor ?? NSColor(hex: scene.diagram.typeColor(of: box.entity) ?? "")
                ctx.setFillColor((tint?.withAlphaComponent(0.75) ?? MB.nsDim.withAlphaComponent(0.55)).cgColor)
                ctx.fill(place(box.frame))
            }
            ctx.setFillColor(MB.nsAccentInk.withAlphaComponent(0.12).cgColor)
            ctx.setStrokeColor(MB.nsAccentInk.cgColor)
            ctx.setLineWidth(1.25)
            let view = place(canvas.visibleCanvas).intersection(bounds.insetBy(dx: 1, dy: 1))
            ctx.fill(view)
            ctx.stroke(view)
        }

        private func go(_ event: NSEvent) {
            guard let m = mapping else { return }
            let p = convert(event.locationInWindow, from: nil)
            store.canvas?.centre(on: CGPoint(x: (p.x - m.origin.x) / m.scale, y: (p.y - m.origin.y) / m.scale))
            needsDisplay = true
        }

        override func mouseDown(with event: NSEvent) { go(event) }
        override func mouseDragged(with event: NSEvent) { go(event) }
    }
}

/// Find a text in the names (and definitions) and put another in its place, everywhere at once.
struct ReplaceSheet: View {
    @ObservedObject var store: DiagramStore
    @State private var options = DiagramStore.Replacement()
    @FocusState private var focused: Bool

    var body: some View {
        let found = store.replace(options, apply: false)
        VStack(alignment: .leading, spacing: 12) {
            Text("Find and replace").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
            VStack(alignment: .leading, spacing: 8) {
                MBField(placeholder: "Find", text: $options.find).focused($focused)
                MBField(placeholder: "Replace with", text: $options.with)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("In the names of entities, attributes, relationships and domains", isOn: $options.names)
                Toggle("In table and column names you set yourself", isOn: $options.databaseNames)
                Toggle("In definitions and notes", isOn: $options.definitions)
                Toggle("Capitals must match", isOn: $options.matchCase)
            }
            .toggleStyle(.checkbox).font(.system(size: 12.5)).foregroundStyle(MB.muted)
            HStack(spacing: 8) {
                Text(options.find.isEmpty ? " " : found == 0 ? "Not found." : "Found in \(found) \(found == 1 ? "place" : "places").")
                    .font(.system(size: 12)).foregroundStyle(found == 0 && !options.find.isEmpty ? MB.orange : MB.dim)
                Spacer()
                Button("Close") { store.sheet = nil }.buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button("Replace All") {
                    store.replace(options, apply: true)
                    store.sheet = nil
                }
                .buttonStyle(.mbPrimary).keyboardShortcut(.defaultAction).disabled(found == 0)
            }
        }
        .padding(18)
        .frame(width: 480)
        .background(MB.card)
        .onAppear { focused = true }
    }
}

/// The inspector for a note, a line of text, a shape, a drawing or a picture.
struct AnnotationInspector: View {
    @ObservedObject var store: DiagramStore
    let annotation: Annotation

    private func set(_ name: String, _ change: @escaping (inout Annotation) -> Void) {
        let id = annotation.id
        store.edit(name, coalesce: "\(name)\(id)") { $0.update(annotation: id, change) }
    }

    private static let sizes: [Double] = [0, 10, 14, 18, 24]
    private static func sizeTitle(_ size: Double) -> String { size == 0 ? "Usual" : "\(Int(size))" }
    private var size: Binding<Double> {
        Binding(get: { annotation.size }, set: { v in set("Change Size") { $0.size = v } })
    }
    private var text: Binding<String> {
        Binding(get: { annotation.text }, set: { v in set("Change Text") { $0.text = v } })
    }

    private var title: String {
        switch annotation.kind {
        case .note: "Note"
        case .text: "Text"
        case .rectangle: "Rectangle"
        case .oval: "Oval"
        case .line: "Line"
        case .arrow: "Arrow"
        case .freehand: "Drawing"
        case .highlighter: "Highlighter"
        case .image: "Picture"
        }
    }

    var body: some View {
        let a = annotation
        let hasText = a.kind.hasFrame && a.kind != .image
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ON THE CANVAS").font(.system(size: 10.5, weight: .semibold)).tracking(0.5).foregroundStyle(MB.dim)
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
            }
            .padding(.horizontal, 14).padding(.top, 14)
            Text("Not part of the model: it isn’t in the SQL.").font(.system(size: 12)).foregroundStyle(MB.dim).padding(.horizontal, 14).padding(.top, 3)
            VStack(alignment: .leading, spacing: 10) {
                if hasText {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.kind == .note || a.kind == .text ? "Text" : "Label").font(.system(size: 11.5)).foregroundStyle(MB.muted)
                        TextField("", text: text, axis: .vertical)
                            .textFieldStyle(.plain).font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(2...10)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Size of the text").font(.system(size: 11.5)).foregroundStyle(MB.muted)
                        MBSegmented(options: Self.sizes, selection: size, label: Self.sizeTitle, stretch: true)
                    }
                }
                if a.kind.hasFrame, a.kind != .image {
                    HexColorPicker(label: "Fill", hex: a.style.fill) { v in set("Change Colour") { $0.style.fill = v } }
                }
                if a.kind != .image, a.kind != .text {
                    HexColorPicker(label: a.kind.hasFrame ? "Border" : "Colour", hex: a.style.line) { v in set("Change Colour") { $0.style.line = v } }
                }
                if hasText {
                    HexColorPicker(label: "Text", hex: a.style.text) { v in set("Change Colour") { $0.style.text = v } }
                }
                if a.kind == .note {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("About").font(.system(size: 11.5)).foregroundStyle(MB.muted)
                        Menu {
                            Button("Nothing in particular") { set("Change Note") { $0.entity = nil; $0.attribute = nil } }
                            Divider()
                            ForEach(store.diagram.entities.sorted { $0.name < $1.name }) { e in
                                Menu(e.name) {
                                    Button("\(e.name) itself") { set("Change Note") { $0.entity = e.id; $0.attribute = nil } }
                                    Divider()
                                    ForEach(e.attributes) { attribute in
                                        Button(attribute.name) { set("Change Note") { $0.entity = e.id; $0.attribute = attribute.id } }
                                    }
                                }
                            }
                        } label: {
                            HStack {
                                Text(about).font(.system(size: 12.5)).foregroundStyle(MB.text).lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(MB.dim)
                            }
                            .padding(.horizontal, 9).frame(height: 28)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MB.wash(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(MB.line))
                            .contentShape(Rectangle())
                        }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        Text("A thin line is drawn from the note to what it is about.").font(.system(size: 11.5)).foregroundStyle(MB.dim)
                    }
                }
                HStack(spacing: 8) {
                    Button("To Front") { store.restack(toFront: true) }.buttonStyle(.mbQuiet)
                    Button("To Back") { store.restack(toFront: false) }.buttonStyle(.mbQuiet)
                }
                HStack(spacing: 8) {
                    Button("Duplicate") { store.duplicateSelection() }.buttonStyle(.mbQuiet)
                    Button("Delete") { store.deleteSelection() }.buttonStyle(.mbDanger)
                }
            }
            .padding(.horizontal, 14).padding(.top, 16)
        }
    }

    private var about: String {
        guard let id = annotation.entity, let e = store.diagram.entity(id) else { return "Nothing in particular" }
        if let a = annotation.attribute, let attribute = e.attributes.first(where: { $0.id == a }) { return "\(e.name).\(attribute.name)" }
        return e.name
    }
}
