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
    /// Settings › Files: the version before a save is kept beside the file, with "~" after its name.
    override var keepBackupFile: Bool { UserDefaults.standard.bool(forKey: "files.backup") }
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

    /// File › Print: the diagram on paper. The two choices under the print panel are remembered.
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let (scene, title) = MainActor.assumeIsolated { (Scene(store.diagram), store.title) }
        let defaults = UserDefaults.standard
        let view = Picture.PrintView(scene: scene, title: title, fit: defaults.object(forKey: "print.fit") as? Bool ?? true, marks: defaults.object(forKey: "print.marks") as? Bool ?? true)
        let info = printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: printSettings)
        info.horizontalPagination = .automatic
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        // A diagram is usually wider than it is tall.
        if view.area.width > view.area.height * 1.15, printSettings[.orientation] == nil, defaults.object(forKey: "print.orientationSet") == nil { info.orientation = .landscape }
        view.layout(for: info)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = title
        operation.printPanel.options.formUnion([.showsOrientation, .showsPaperSize, .showsScaling, .showsPreview])
        operation.printPanel.addAccessoryController(PrintOptions(view: view))
        return operation
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

    @objc func newSheet(_ sender: Any?) {
        let kinds: [DiagramStore.NewSheet] = [.empty, .everything, .selection, .copy]
        guard let tag = (sender as? NSMenuItem)?.tag, kinds.indices.contains(tag) else { return }
        store.newSheet(kinds[tag])
    }
    @objc func renameSheet(_ sender: Any?) { store.renameSheet(store.diagram.sheetID) }
    @objc func deleteSheet(_ sender: Any?) { store.removeSheet(store.diagram.sheetID) }
    @objc func nextSheet(_ sender: Any?) { store.stepSheet(1) }
    @objc func previousSheet(_ sender: Any?) { store.stepSheet(-1) }
    @objc func takeOffDiagram(_ sender: Any?) { store.takeOffDiagram() }

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
        case #selector(newSheet(_:)): return item.tag != 2 || !store.selection.entityIDs.isEmpty
        case #selector(deleteSheet(_:)), #selector(nextSheet(_:)), #selector(previousSheet(_:)): return d.hasSeveralSheets
        case #selector(takeOffDiagram(_:)): return !store.selection.entityIDs.isEmpty
        case #selector(copyStyle(_:)): return store.canCopyStyle
        case #selector(pasteStyle(_:)): return store.canPasteStyle
        case #selector(toggleLineJumps(_:)): item.state = d.display.lineJumps ? .on : .off
        case #selector(rerouteAll(_:)): return d.relationships.contains { !$0.waypoints.isEmpty }
        case #selector(toggleMap(_:)): item.title = UserDefaults.standard.bool(forKey: "showMap") ? "Hide Map" : "Show Map"
        case #selector(toggleGrid(_:)): item.title = Grid.show ? "Hide Grid" : "Show Grid"
        case #selector(toggleSnap(_:)): item.state = Grid.snaps ? .on : .off
        case #selector(showReplace(_:)): return !d.entities.isEmpty
        case #selector(tidyUp(_:)), #selector(exportSQL(_:)), #selector(exportImage(_:)), #selector(copyImage(_:)), #selector(exportDictionary(_:)), #selector(exportDocument(_:)),
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
    @objc func importSpreadsheet(_ sender: Any?) { store.chooseSheet() }
    @objc func compareWith(_ sender: Any?) { store.chooseComparison() }
    @objc func runScript(_ sender: Any?) { store.sheet = .script }

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

    /// PNG, JPEG, PDF or SVG; light or dark, with or without a background, and for the two made of dots how fine.
    @objc func exportImage(_ sender: Any?) {
        let options = ImageOptionsView()
        let scene = Scene(store.diagram)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = baseName + "." + options.format.rawValue
        panel.allowedContentTypes = [options.format.type]
        panel.canCreateDirectories = true
        panel.accessoryView = options
        options.formatChanged = { [weak panel] format in
            panel?.allowedContentTypes = [format.type]
        }
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            let data = Picture.data(scene, format: options.format, dark: options.dark, transparent: options.transparent, scale: options.scale)
            do { try (data ?? Data()).write(to: url) } catch { showError(error, in: window, title: "Couldn’t save \(url.lastPathComponent)") }
        }
    }

    /// The whole diagram as one document to read: the picture, then every entity with its attributes, the
    /// relationships and the domains. As a web page (.html), or for a word processor (.rtf, without the picture).
    @objc func exportDocument(_ sender: Any?) {
        let d = store.diagram
        let scene = Scene(d)
        let title = baseName
        save(baseName + ".html", types: [.html, .rtf]) { url in
            let rtf = url.pathExtension.lowercased() == "rtf"
            let html = DocumentExport.html(for: d, scene: rtf ? nil : scene, title: title)
            if rtf {
                guard let text = NSAttributedString(html: Data(html.utf8), options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil),
                      let data = text.rtf(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                try data.write(to: url)
            } else {
                try html.write(to: url, atomically: true, encoding: .utf8)
            }
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
        // Excel by default; .md or .csv when the name is given that ending.
        save(baseName + " data dictionary.xlsx", types: [UTType(filenameExtension: "xlsx") ?? .data, UTType(filenameExtension: "md") ?? .plainText, .commaSeparatedText]) { url in
            switch url.pathExtension.lowercased() {
            case "csv": try Report.csv(for: d).write(to: url, atomically: true, encoding: .utf8)
            case "md": try Report.markdown(for: d, title: title).write(to: url, atomically: true, encoding: .utf8)
            default: try Report.workbook(for: d).xlsx().write(to: url)
            }
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
            try AstaExport.data(for: d, layout: layout, options: options, others: Scene.astaOthers(of: d)).write(to: url)
        }
    }
}

/// The kinds of picture a diagram can be saved as.
enum ImageFormat: String, CaseIterable {
    case png, jpg, pdf, svg

    var type: UTType {
        switch self {
        case .png: .png
        case .jpg: .jpeg
        case .pdf: .pdf
        case .svg: .svg
        }
    }
    var title: String {
        switch self {
        case .png: "PNG (picture)"
        case .jpg: "JPEG (picture, smaller)"
        case .pdf: "PDF (sharp at any size)"
        case .svg: "SVG (shapes and text, for the web)"
        }
    }
    /// Made of dots, so how fine matters.
    var isBitmap: Bool { self == .png || self == .jpg }
}

extension Picture {
    static func data(_ scene: Scene, format: ImageFormat, dark: Bool, transparent: Bool, scale: CGFloat = 2) -> Data? {
        switch format {
        case .png: png(scene, dark: dark, transparent: transparent, scale: scale)
        case .jpg: jpeg(scene, dark: dark, scale: scale)
        case .pdf: pdf(scene, dark: dark, transparent: transparent)
        case .svg: Data(SVG.document(scene, dark: dark, transparent: transparent).utf8)
        }
    }
}

/// The two choices under the print panel: on one page or at its own size, and the title, date and page number.
final class PrintOptions: NSViewController, NSPrintPanelAccessorizing {
    private let printed: Picture.PrintView
    private let fit = NSButton(checkboxWithTitle: "Fit on one page", target: nil, action: nil)
    private let marks = NSButton(checkboxWithTitle: "Title, date and page number in the margins", target: nil, action: nil)

    init(view: Picture.PrintView) {
        printed = view
        super.init(nibName: nil, bundle: nil)
        title = "Maben Schema"
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        fit.state = printed.fit ? .on : .off
        marks.state = printed.marks ? .on : .off
        for button in [fit, marks] { button.target = self; button.action = #selector(changed) }
        let stack = NSStackView(views: [fit, marks])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        view = stack
    }

    @objc private func changed() {
        willChangeValue(forKey: "layoutVersion")
        printed.fit = fit.state == .on
        printed.marks = marks.state == .on
        UserDefaults.standard.set(printed.fit, forKey: "print.fit")
        UserDefaults.standard.set(printed.marks, forKey: "print.marks")
        if let info = representedObject as? NSPrintInfo { printed.layout(for: info) }
        printed.needsDisplay = true
        didChangeValue(forKey: "layoutVersion")
    }

    /// Changing either choice changes what the preview shows.
    @objc dynamic var layoutVersion: Int { 0 }
    func keyPathsForValuesAffectingPreview() -> Set<String> { ["layoutVersion"] }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Pages", .itemDescription: printed.fit ? "Fitted on one page" : "At its own size, over as many pages as it takes"]]
    }
}

/// The choices under the save panel for a picture.
final class ImageOptionsView: NSView {
    private let formats = NSPopUpButton()
    private let look = NSPopUpButton()
    private let fineness = NSPopUpButton()
    private let background = NSButton(checkboxWithTitle: "Transparent background", target: nil, action: nil)
    var formatChanged: ((ImageFormat) -> Void)?

    var format: ImageFormat { ImageFormat.allCases[max(0, formats.indexOfSelectedItem)] }
    var dark: Bool { look.indexOfSelectedItem == 1 }
    var transparent: Bool { background.state == .on && format != .jpg }
    /// 1× is one dot per point (72 a inch); 2× is what a Retina screen shows.
    var scale: CGFloat { CGFloat(fineness.indexOfSelectedItem + 1) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 640, height: 44))
        formats.addItems(withTitles: ImageFormat.allCases.map(\.title))
        look.addItems(withTitles: ["Light", "Dark"])
        fineness.addItems(withTitles: ["1× (72 dpi)", "2× (144 dpi)", "3× (216 dpi)", "4× (288 dpi)"])
        let defaults = UserDefaults.standard
        fineness.selectItem(at: min(3, max(0, (defaults.object(forKey: "image.scale") as? Int ?? 2) - 1)))
        if let saved = defaults.string(forKey: "image.format"), let i = ImageFormat.allCases.firstIndex(where: { $0.rawValue == saved }) { formats.selectItem(at: i) }
        formats.target = self
        formats.action = #selector(changed)
        fineness.target = self
        fineness.action = #selector(changed)
        fineness.isEnabled = format.isBitmap
        let format = formats
        let stack = NSStackView(views: [NSTextField(labelWithString: "Format:"), format, fineness, NSTextField(labelWithString: "Look:"), look, background])
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

    @objc private func changed() {
        fineness.isEnabled = format.isBitmap
        background.isEnabled = format != .jpg
        UserDefaults.standard.set(format.rawValue, forKey: "image.format")
        UserDefaults.standard.set(fineness.indexOfSelectedItem + 1, forKey: "image.scale")
        formatChanged?(format)
    }
}
