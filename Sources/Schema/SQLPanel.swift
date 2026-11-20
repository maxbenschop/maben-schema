import AppKit
import SchemaCore
import SwiftUI
import UniformTypeIdentifiers

/// The SQL for the diagram, always up to date, under the canvas. Select an entity and its table lights up.
struct SQLPanel: View {
    @ObservedObject var store: DiagramStore
    @State private var copied = false
    @State private var dragStart: CGFloat?

    /// The selected entities, or for a selected relationship the entity that holds its foreign key.
    private var highlighted: Set<UUID> {
        if let r = store.selection.relationship, let child = store.diagram.relationship(r)?.child { return [child] }
        return store.selection.entityIDs
    }

    var body: some View {
        VStack(spacing: 0) {
            // The top edge drags to resize.
            Rectangle().fill(MB.line).frame(height: 1)
                .overlay(Color.clear.frame(height: 9).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                        .onChanged { g in
                            if dragStart == nil { dragStart = store.sqlHeight }
                            store.sqlHeight = min(640, max(120, (dragStart ?? 250) - g.translation.height))
                        }
                        .onEnded { _ in dragStart = nil })
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } })
            HStack(spacing: 8) {
                Text("SQL").font(.system(size: 12, weight: .semibold)).foregroundStyle(MB.text)
                MBSegmented(options: Dialect.allCases, selection: Binding(get: { store.diagram.dialect }, set: { v in store.edit("Change Database") { $0.dialect = v } }), label: \.title)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(store.sqlText, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
                }
                .buttonStyle(.mbQuiet)
                Button("Save…") { NSApp.sendAction(#selector(EditorWindowController.exportSQL(_:)), to: nil, from: nil) }.buttonStyle(.mbQuiet)
                MBIconButton(symbol: "xmark", help: "Hide the SQL (⌥⌘S)") { store.showSQL = false }
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 40)
            .background(MB.bar)
            Hairline()
            SQLTextView(sections: store.sqlSections, highlighted: highlighted)
        }
        .background(MB.bg)
    }
}

/// Read-only, coloured SQL. The statements of the selected entities get a soft background and scroll into view.
struct SQLTextView: NSViewRepresentable {
    let sections: [SQLExport.Section]
    let highlighted: Set<UUID>

    final class Coordinator {
        var sections: [SQLExport.Section] = []
        var highlighted: Set<UUID> = []
        var appearance: String = ""
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasHorizontalScroller = true
        let text = scroll.documentView as! NSTextView
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 10, height: 10)
        text.isHorizontallyResizable = true
        text.textContainer?.widthTracksTextView = false
        text.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        text.setAccessibilityLabel("SQL")
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let text = scroll.documentView as? NSTextView else { return }
        let c = context.coordinator
        let appearance = scroll.effectiveAppearance.name.rawValue
        guard c.sections != sections || c.highlighted != highlighted || c.appearance != appearance else { return }
        let selectionChanged = c.highlighted != highlighted
        c.sections = sections
        c.highlighted = highlighted
        c.appearance = appearance

        let out = NSMutableAttributedString()
        var firstHighlight: NSRange?
        for (i, section) in sections.enumerated() {
            let piece = Self.colour(section.text)
            if let e = section.entity, highlighted.contains(e) {
                piece.addAttribute(.backgroundColor, value: MB.nsAccentInk.withAlphaComponent(0.13), range: NSRange(location: 0, length: piece.length))
                if firstHighlight == nil { firstHighlight = NSRange(location: out.length, length: piece.length) }
            }
            out.append(piece)
            out.append(NSAttributedString(string: i < sections.count - 1 ? "\n\n" : "\n", attributes: [.font: MB.nsMono]))
        }
        text.textStorage?.setAttributedString(out)
        if selectionChanged, let range = firstHighlight {
            DispatchQueue.main.async { text.scrollRangeToVisible(range) }
        }
    }

    static let keywords: Set<String> = [
        "CREATE", "TABLE", "ALTER", "ADD", "CONSTRAINT", "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "NOT", "NULL", "UNIQUE", "DEFAULT", "ON",
        "DELETE", "UPDATE", "CASCADE", "RESTRICT", "SET", "NO", "ACTION", "GENERATED", "ALWAYS", "AS", "IDENTITY", "AUTO_INCREMENT", "AUTOINCREMENT",
    ]

    /// Keywords in the accent, comments and punctuation dim, strings green.
    static func colour(_ sql: String) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(string: sql, attributes: [.font: MB.nsMono, .foregroundColor: MB.nsText])
        let ns = sql as NSString
        var i = 0
        func isWord(_ c: unichar) -> Bool { (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 }
        while i < ns.length {
            let c = ns.character(at: i)
            if c == 45, i + 1 < ns.length, ns.character(at: i + 1) == 45 {          // -- comment
                var j = i
                while j < ns.length, ns.character(at: j) != 10 { j += 1 }
                out.addAttribute(.foregroundColor, value: MB.nsDim, range: NSRange(location: i, length: j - i))
                i = j
            } else if c == 39 {                                                        // 'string'
                var j = i + 1
                while j < ns.length, ns.character(at: j) != 39 { j += 1 }
                out.addAttribute(.foregroundColor, value: MB.nsGreen, range: NSRange(location: i, length: min(ns.length, j + 1) - i))
                i = j + 1
            } else if isWord(c) {
                var j = i
                while j < ns.length, isWord(ns.character(at: j)) { j += 1 }
                let range = NSRange(location: i, length: j - i)
                let word = ns.substring(with: range)
                if keywords.contains(word) { out.addAttribute(.foregroundColor, value: MB.nsAccentInk, range: range) }
                else if word == word.uppercased(), word.first?.isLetter == true { out.addAttribute(.foregroundColor, value: MB.nsMuted, range: range) }
                i = j
            } else {
                if c == 40 || c == 41 || c == 44 || c == 59 { out.addAttribute(.foregroundColor, value: MB.nsDim, range: NSRange(location: i, length: 1)) }
                i += 1
            }
        }
        return out
    }
}

/// Paste or open CREATE TABLE statements; see what was found before anything changes.
///
/// Reading happens in the background and only looks at table definitions, so a dump of hundreds of megabytes
/// is fine: its rows are stepped over, and never put in the text box.
struct ImportSheet: View {
    @ObservedObject var store: DiagramStore
    @State private var sql = ""
    @State private var replace = false
    @State private var result: SQLImport.Result?
    @State private var working = false
    /// The text `result` belongs to, so it isn't read twice.
    @State private var parsedText = ""
    @State private var file: FileInfo?
    @FocusState private var focused: Bool

    private struct FileInfo: Equatable {
        var name: String
        var bytes: Int
        /// Its table definitions are too long to show in the box; they are imported all the same.
        var tooLong = false
        var size: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
    }

    /// More than this isn't put in the text box.
    private static let showLimit = 300_000

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Import SQL").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                Text("Paste CREATE TABLE statements, or choose a file: a whole dump is fine, only its table definitions are read. Tables become entities and foreign keys become relationships.")
                    .font(.system(size: 12)).foregroundStyle(MB.muted).fixedSize(horizontal: false, vertical: true)
            }
            Group {
                if let file, file.tooLong {
                    VStack(spacing: 6) {
                        Image(systemName: "doc.text").font(.system(size: 22)).foregroundStyle(MB.dim)
                        Text(file.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(MB.text)
                        Text("Its table definitions are too long to show here. They are all imported.")
                            .font(.system(size: 12)).foregroundStyle(MB.dim)
                        Button("Paste Text Instead") { self.file = nil; result = nil; parsedText = ""; sql = "" }.buttonStyle(.mbQuiet).padding(.top, 4)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TextEditor(text: $sql)
                        .font(MB.mono)
                        .scrollContentBackground(.hidden)
                        .focused($focused)
                        .padding(6)
                        .overlay(alignment: .topLeading) {
                            if sql.isEmpty {
                                Text("CREATE TABLE customer (\n    id INTEGER PRIMARY KEY,\n    email VARCHAR(255) NOT NULL\n);")
                                    .font(MB.mono).foregroundStyle(MB.dim.opacity(0.6)).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                            }
                        }
                        .accessibilityLabel("SQL to import")
                }
            }
            .frame(minHeight: 240)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MB.wash(0.05)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.line))

            status.font(.system(size: 12)).frame(minHeight: 16, alignment: .topLeading)

            HStack(spacing: 8) {
                Button("Choose a File…") { chooseFile() }.buttonStyle(.mbQuiet)
                if !store.diagram.entities.isEmpty {
                    Toggle("Replace what’s in the diagram", isOn: $replace).toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(MB.muted)
                }
                Spacer()
                Button("Cancel") { store.sheet = nil }.buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button("Import") {
                    if let result { store.importResult(result, replace: replace) }
                    store.sheet = nil
                }
                .buttonStyle(.mbPrimary).keyboardShortcut(.defaultAction).disabled(working || (result?.tables ?? 0) == 0)
            }
        }
        .padding(18)
        .frame(width: 640, height: 480)
        .background(MB.card)
        .onAppear {
            focused = true
            if let url = store.sheetFile {
                store.sheetFile = nil
                read(url)
                return
            }
            // SQL already on the clipboard is most likely what you came to import. A huge clipboard is left alone.
            if let s = store.pasteboard.string(forType: .string), s.utf8.count < 2_000_000, s.range(of: "create table", options: .caseInsensitive) != nil { sql = s }
        }
        // Typing: read it a moment after the last key, off the main thread.
        .task(id: sql) {
            guard sql != parsedText else { return }
            if sql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if file?.tooLong != true { result = nil; parsedText = sql }
                return
            }
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let text = sql
            working = true
            let found = await Task.detached(priority: .userInitiated) { SQLImport.parse(text, isCancelled: { Task.isCancelled }) }.value
            guard !Task.isCancelled else { return }
            result = found
            parsedText = text
            file = nil
            working = false
        }
    }

    @ViewBuilder private var status: some View {
        if working {
            HStack(spacing: 7) {
                ProgressView().controlSize(.small)
                Text(file.map { "Reading \($0.name) (\($0.size))…" } ?? "Reading…").foregroundStyle(MB.muted)
            }
        } else if let result {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: result.tables > 0 ? "checkmark.circle.fill" : "questionmark.circle.fill")
                        .foregroundStyle(result.tables > 0 ? MB.green : MB.orange)
                    Text(summary(result)).foregroundStyle(MB.text)
                }
                if result.tables > 0, result.bytes > result.statements.utf8.count + 2_000 {
                    Text("Only the table definitions are read. The rows of data\(file.map { " in the file (\($0.size))" } ?? "") are skipped.").foregroundStyle(MB.dim)
                }
                ForEach(result.skipped.prefix(3), id: \.self) { s in
                    Text("Left as a plain column: \(s).").foregroundStyle(MB.dim).lineLimit(1)
                }
                if result.skipped.count > 3 { Text("…and \(result.skipped.count - 3) more.").foregroundStyle(MB.dim) }
            }
        } else {
            Text(" ")
        }
    }

    private func summary(_ r: SQLImport.Result) -> String {
        guard r.tables > 0 else { return file.map { "No CREATE TABLE statements in \($0.name)." } ?? "No CREATE TABLE statements found yet." }
        let tables = "\(r.tables.formatted()) \(r.tables == 1 ? "table" : "tables")"
        let keys = "\(r.foreignKeys.formatted()) \(r.foreignKeys == 1 ? "foreign key" : "foreign keys")"
        return "Found \(tables) and \(keys)" + (file.map { " in \($0.name)." } ?? ".")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .plainText]
        panel.message = "Choose a SQL file. A full dump is fine."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        read(url)
    }

    private func read(_ url: URL) {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        file = FileInfo(name: url.lastPathComponent, bytes: bytes)
        working = true
        result = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SQLImport.Result, Error> in
                Result { try SQLImport.parse(contentsOf: url) }
            }.value
            working = false
            switch outcome {
            case .failure(let error):
                file = nil
                showError(error, in: store.window, title: "Couldn’t read \(url.lastPathComponent)")
            case .success(let found):
                result = found
                // Show what was read, not the file: the definitions without the data.
                if found.statements.utf8.count <= Self.showLimit {
                    parsedText = found.statements
                    sql = found.statements
                } else {
                    file?.tooLong = true
                    parsedText = ""
                    sql = ""
                }
            }
        }
    }
}
