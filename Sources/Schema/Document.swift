import AppKit
import SchemaCore
import SwiftUI
import UniformTypeIdentifiers

let schemaTypeName = "gg.maben.schema.diagram"
let schemaExtension = "mschema"

/// One diagram file (.mschema): readable JSON. Saves by itself as you work, like any Mac document.
final class SchemaDocument: NSDocument {
    let store: DiagramStore

    override init() {
        // A new diagram starts with the notation and database from Settings; a file brings its own.
        store = MainActor.assumeIsolated { DiagramStore(diagram: Preferences.newDiagram()) }
        super.init()
        let manager = undoManager
        MainActor.assumeIsolated { store.undoManager = manager }
    }

    override class var autosavesInPlace: Bool { true }
    override class var readableTypes: [String] { [schemaTypeName] }
    override class var writableTypes: [String] { [schemaTypeName] }
    override class func isNativeType(_ type: String) -> Bool { type == schemaTypeName }
    override func fileNameExtension(forType typeName: String, saveOperation: NSDocument.SaveOperationType) -> String? { schemaExtension }
    override func writableTypes(for saveOperation: NSDocument.SaveOperationType) -> [String] { [schemaTypeName] }

    override func makeWindowControllers() {
        MainActor.assumeIsolated {
            addWindowController(EditorWindowController(store: store))
        }
    }

    override func data(ofType typeName: String) throws -> Data {
        try MainActor.assumeIsolated { try store.diagram.encoded() }
    }

    override func read(from data: Data, ofType typeName: String) throws {
        let diagram = try Diagram.decode(data)
        MainActor.assumeIsolated { store.load(diagram) }
    }
}

/// Knows the one document type, also when the app runs outside its bundle (no Info.plist), as the tests do.
final class SchemaDocumentController: NSDocumentController {
    override var defaultType: String? { schemaTypeName }
    override var documentClassNames: [String] { [NSStringFromClass(SchemaDocument.self)] }
    override func documentClass(forType typeName: String) -> AnyClass? { SchemaDocument.self }
    override func typeForContents(of url: URL) throws -> String { schemaTypeName }
    override func displayName(forType typeName: String) -> String? { "Maben Schema Diagram" }

    /// Opening a file takes the place of the empty, untouched window the app started with.
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool,
                               completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        let pristine = documents.compactMap { $0 as? SchemaDocument }.filter { doc in
            doc.fileURL == nil && !doc.isDocumentEdited && MainActor.assumeIsolated { doc.store.diagram.entities.isEmpty }
        }
        super.openDocument(withContentsOf: url, display: displayDocument) { document, already, error in
            if document != nil, error == nil { pristine.filter { $0 !== document }.forEach { $0.close() } }
            completionHandler(document, already, error)
        }
    }

    /// A new, unsaved document that starts with a diagram in it (the sample, or a test's).
    @MainActor
    @discardableResult
    func openUntitled(with diagram: Diagram, display: Bool = true) -> SchemaDocument? {
        guard let doc = try? makeUntitledDocument(ofType: schemaTypeName) as? SchemaDocument else { return nil }
        doc.store.load(diagram)
        addDocument(doc)
        doc.makeWindowControllers()
        if display { doc.showWindows() }
        return doc
    }
}

/// The window around one diagram, and the menu commands that act on it.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    let store: DiagramStore

    init(store: DiagramStore) {
        self.store = store
        // First time: most of the screen, as Maben Study does. After that, where you left it.
        let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1512, height: 944)
        let size = NSSize(width: min(1600, max(980, screen.width * 0.86)), height: min(1000, max(640, screen.height * 0.86)))
        let window = makeMabenWindow(size: size)
        window.minSize = NSSize(width: 760, height: 480)
        window.tabbingMode = .disallowed
        window.appearance = Appearance.current.nsAppearance
        super.init(window: window)
        store.window = window
        window.delegate = self
        let host = NSHostingController(rootView: EditorView(store: store))
        host.sizingOptions = []
        window.contentViewController = host
        if !window.setFrameUsingName("MabenSchemaEditor") {
            window.setContentSize(size)
            window.center()
        }
        window.setFrameAutosaveName("MabenSchemaEditor")
        shouldCascadeWindows = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let canvas = self.store.canvas else { return }
            self.window?.makeFirstResponder(canvas)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { document?.undoManager ?? store.undoManager }

    // The title bar is ours, so the name and the "Edited" mark are passed on to it.
    override func synchronizeWindowTitleWithDocumentName() {
        super.synchronizeWindowTitleWithDocumentName()
        // Without the extension, whatever Finder is set to show.
        let name = (document as? NSDocument)?.displayName ?? "Untitled"
        store.title = name.hasSuffix("." + schemaExtension) ? String(name.dropLast(schemaExtension.count + 1)) : name
    }

    override func setDocumentEdited(_ dirtyFlag: Bool) {
        super.setDocumentEdited(dirtyFlag)
        store.edited = dirtyFlag
    }

    // MARK: Diagram menu

    @objc func newEntity(_ sender: Any?) { store.newEntity() }
    @objc func addAttribute(_ sender: Any?) {
        guard let e = store.selection.singleEntity else { return }
        store.canvas?.beginEdit(.newAttribute(entity: e))
    }
    @objc func renameSelection(_ sender: Any?) {
        if let e = store.selection.singleEntity { store.canvas?.beginEdit(.entityName(e)) }
        else if let r = store.selection.relationship { store.canvas?.beginEdit(.relationshipName(r)) }
    }
    @objc func newDomain(_ sender: Any?) { store.newDomain() }
    @objc func duplicateSelection(_ sender: Any?) { store.duplicateSelection() }
    @objc func tidyUp(_ sender: Any?) { store.tidyUp() }
    @objc func alignSelection(_ sender: Any?) {
        let all: [Alignment] = [.left, .centre, .right, .top, .middle, .bottom, .spreadAcross, .spreadDown]
        guard let tag = (sender as? NSMenuItem)?.tag, all.indices.contains(tag) else { return }
        store.align(all[tag])
    }
    @objc func setNotation(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let v = Notation(rawValue: raw) else { return }
        store.edit("Change Notation") { $0.display.notation = v }
    }
    @objc func setNames(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let v = NameDisplay(rawValue: raw) else { return }
        store.edit("Change Names") { $0.display.names = v }
    }
    @objc func setDetail(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let v = DetailLevel(rawValue: raw) else { return }
        store.edit("Change Detail") { $0.display.level = v }
    }
    @objc func setDialect(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let v = Dialect(rawValue: raw) else { return }
        store.edit("Change Database") { $0.dialect = v }
    }

    @objc func addAnnotation(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let tool = Tool(rawValue: raw) else { return }
        // A note or a line of text appears at once; the others are drawn on the canvas with the pointer.
        if tool == .note || tool == .text { store.newNote(tool == .note ? .note : .text) } else { store.tool = tool }
    }
    @objc func addPicture(_ sender: Any?) { store.chooseImage() }
    @objc func sameWidth(_ sender: Any?) { store.sameWidth() }
    @objc func bringToFront(_ sender: Any?) { store.restack(toFront: true) }
    @objc func sendToBack(_ sender: Any?) { store.restack(toFront: false) }
    @objc func toggleLineJumps(_ sender: Any?) { store.edit("Change Lines") { $0.display.lineJumps.toggle() } }
    @objc func rerouteAll(_ sender: Any?) { store.rerouteAll() }
    @objc func copyStyle(_ sender: Any?) { store.copyStyle() }
    @objc func pasteStyle(_ sender: Any?) { store.pasteStyle() }
    @objc func showReplace(_ sender: Any?) { store.sheet = .replace }
    @objc func toggleMap(_ sender: Any?) { UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: "showMap"), forKey: "showMap") }
    @objc func toggleGrid(_ sender: Any?) { Grid.show.toggle() }
    @objc func toggleSnap(_ sender: Any?) { Grid.snaps.toggle() }

    // MARK: View menu

    @objc func toggleSidebar(_ sender: Any?) { store.showSidebar.toggle() }
    @objc func toggleInspector(_ sender: Any?) { store.showInspector.toggle() }
    @objc func toggleSQL(_ sender: Any?) { store.showSQL.toggle() }
    @objc func showPalette(_ sender: Any?) { store.palette.toggle() }
    @objc func zoomIn(_ sender: Any?) { store.canvas?.zoomIn() }
    @objc func zoomOut(_ sender: Any?) { store.canvas?.zoomOut() }
    @objc func zoomActual(_ sender: Any?) { store.canvas?.zoomActual() }
    @objc func zoomToFit(_ sender: Any?) { store.canvas?.zoomToFit() }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        let d = store.diagram
        switch item.action {
        case #selector(addAttribute(_:)): return store.selection.singleEntity != nil
        case #selector(renameSelection(_:)): return store.selection.singleEntity != nil || store.selection.relationship != nil
        case #selector(duplicateSelection(_:)): return !store.selection.entityIDs.isEmpty || !store.selectedAnnotations.isEmpty
        case #selector(alignSelection(_:)), #selector(sameWidth(_:)): return store.selection.entityIDs.count > 1
        case #selector(bringToFront(_:)), #selector(sendToBack(_:)): return store.canArrange
        case #selector(copyStyle(_:)): return store.canCopyStyle
        case #selector(pasteStyle(_:)): return store.canPasteStyle
        case #selector(toggleLineJumps(_:)): item.state = d.display.lineJumps ? .on : .off
        case #selector(rerouteAll(_:)): return d.relationships.contains { !$0.waypoints.isEmpty }
        case #selector(toggleMap(_:)): item.title = UserDefaults.standard.bool(forKey: "showMap") ? "Hide Map" : "Show Map"
        case #selector(toggleGrid(_:)): item.title = Grid.show ? "Hide Grid" : "Show Grid"
        case #selector(toggleSnap(_:)): item.state = Grid.snaps ? .on : .off
        case #selector(showReplace(_:)): return !d.entities.isEmpty
        case #selector(tidyUp(_:)), #selector(exportSQL(_:)), #selector(exportImage(_:)), #selector(copyImage(_:)), #selector(exportDictionary(_:)),
             #selector(exportAstah(_:)):
            return !d.entities.isEmpty
        case #selector(setNotation(_:)): item.state = (item.representedObject as? String) == d.display.notation.rawValue ? .on : .off
        case #selector(setNames(_:)): item.state = (item.representedObject as? String) == d.display.names.rawValue ? .on : .off
        case #selector(setDetail(_:)): item.state = (item.representedObject as? String) == d.display.level.rawValue ? .on : .off
        case #selector(setDialect(_:)): item.state = (item.representedObject as? String) == d.dialect.rawValue ? .on : .off
        case #selector(toggleSidebar(_:)): item.title = store.showSidebar ? "Hide Entity List" : "Show Entity List"
        case #selector(toggleInspector(_:)): item.title = store.showInspector ? "Hide Inspector" : "Show Inspector"
        case #selector(toggleSQL(_:)): item.title = store.showSQL ? "Hide SQL" : "Show SQL"
        default: break
        }
        return true
    }

    // MARK: Import and export

    @objc func importSQL(_ sender: Any?) { store.sheet = .importSQL }

    fileprivate var baseName: String {
        (document?.displayName ?? "diagram").replacingOccurrences(of: ".\(schemaExtension)", with: "")
    }

    fileprivate func save(_ name: String, types: [UTType], accessory: NSView? = nil, write: @escaping (URL) throws -> Void) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = types
        panel.canCreateDirectories = true
        panel.accessoryView = accessory
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            do { try write(url) } catch { showError(error, in: window, title: "Couldn’t save \(url.lastPathComponent)") }
        }
    }

    @objc func exportSQL(_ sender: Any?) {
        let sql = store.sqlText
        save(baseName + ".sql", types: [UTType(filenameExtension: "sql") ?? .plainText]) { try sql.write(to: $0, atomically: true, encoding: .utf8) }
    }

    /// PNG or PDF by the file's extension; light or dark, with or without a background.
    @objc func exportImage(_ sender: Any?) {
        let options = ImageOptionsView()
        let scene = Scene(store.diagram)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = baseName + ".png"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.accessoryView = options
        options.formatChanged = { [weak panel] pdf in
            panel?.allowedContentTypes = [pdf ? .pdf : .png]
        }
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let data = options.pdf ? Picture.pdf(scene, dark: options.dark, transparent: options.transparent)
                                   : Picture.png(scene, dark: options.dark, transparent: options.transparent)
            do { try (data ?? Data()).write(to: url) } catch { showError(error, in: window, title: "Couldn’t save \(url.lastPathComponent)") }
        }
    }

    /// The diagram on the clipboard, as it looks now: pastes into Pages, Word, Keynote, Slack.
    @objc func copyImage(_ sender: Any?) {
        let scene = Scene(store.diagram)
        let dark = window?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setData(Picture.pdf(scene, dark: dark, transparent: false), forType: .pdf)
        if let png = Picture.png(scene, dark: dark, transparent: false) { pb.setData(png, forType: .png) }
    }

    @objc func exportDictionary(_ sender: Any?) {
        let d = store.diagram
        let title = baseName
        save(baseName + " data dictionary.md", types: [UTType(filenameExtension: "md") ?? .plainText, .commaSeparatedText]) { url in
            let text = url.pathExtension.lowercased() == "csv" ? Report.csv(for: d) : Report.markdown(for: d, title: title)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}

extension EditorWindowController {
    /// The diagram as an Astah Professional project: the same entities, keys, relationships, places and lines.
    @objc func exportAstah(_ sender: Any?) {
        let d = store.diagram
        let layout = Scene(d).astaLayout
        var options = AstaExport.Options()
        options.diagramName = baseName
        save(baseName + "." + AstaExport.fileExtension, types: [UTType(filenameExtension: AstaExport.fileExtension) ?? .data]) { url in
            try AstaExport.data(for: d, layout: layout, options: options).write(to: url)
        }
    }
}

/// The choices under the save panel for a picture.
final class ImageOptionsView: NSView {
    private let format = NSPopUpButton()
    private let look = NSPopUpButton()
    private let background = NSButton(checkboxWithTitle: "Transparent background", target: nil, action: nil)
    var formatChanged: ((Bool) -> Void)?

    var pdf: Bool { format.indexOfSelectedItem == 1 }
    var dark: Bool { look.indexOfSelectedItem == 1 }
    var transparent: Bool { background.state == .on }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 44))
        format.addItems(withTitles: ["PNG (picture, 2×)", "PDF (sharp at any size)"])
        look.addItems(withTitles: ["Light", "Dark"])
        format.target = self
        format.action = #selector(changed)
        let stack = NSStackView(views: [NSTextField(labelWithString: "Format:"), format, NSTextField(labelWithString: "Look:"), look, background])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor, constant: 24),
            heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func changed() { formatChanged?(pdf) }
}
