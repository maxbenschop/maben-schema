import AppKit
import SchemaCore
import SwiftUI

// Maben Schema: draw a database. Entities, attributes and relationships on a canvas; the SQL writes itself.
//
//   --demo                      opens the sample diagram (a small web shop) as a new, unsaved document
//   --appearance=light|dark     for this run only
//   --select=<entity name>      selects an entity   --relationship=<n>  selects the nth relationship
//   --sql  --palette  --import  shows the SQL panel, the ⌘K palette, the import sheet
//   --notation=ie|idef1x  --names=logical|physical  --detail=all|keys|namesOnly  --dialect=<name>
//   --no-inspector  --no-sidebar  --empty  --features (a diagram with one of everything, in place of the sample)
//   --snapshot=<file.png> [--size=1360x860]   draws the window into a PNG without showing it, then quits
//   --export=<file.png|pdf|sql|md|csv|xlsx|asta|mschema> [--dark]   writes the sample (or --open=<file>, --from-sql=<file.sql>,
//                               --from-sheet=<file.xlsx|csv>) and quits; --sql-options=drop,quote,after,… sets how the SQL is written;
//                               with --dialect=mysql and --from-sql it rewrites a dump's tables for another database
//   --import-sheet=<file.sql>   opens the import sheet on a file (with --snapshot: a picture of the sheet)
//   --import-file=<file.sql>    reads a SQL file the way dropping it on the canvas does
//   --bench[=tables]            times a large diagram (default 1000 tables): reading, drawing, dragging
//   --inspect=<file.sql>        prints what an import of that file finds (tables, foreign keys, databases)
//   --settings                  shows the Settings window too
//   --verify-update <app> <version>   runs the updater's checks on an app and prints ACCEPTED or REJECTED
//   --selftest                  runs the canvas's editing steps without a window on screen and prints the result

enum Flags {
    static func value(_ name: String) -> String? {
        CommandLine.arguments.first { $0.hasPrefix("--\(name)=") }.map { String($0.dropFirst(name.count + 3)) }
    }
    static func has(_ name: String) -> Bool { CommandLine.arguments.contains("--\(name)") }
    static var bench: Bool { has("bench") || value("bench") != nil }
    static var headless: Bool { value("snapshot") != nil || value("export") != nil || value("print") != nil || value("compare") != nil || value("script") != nil || value("inspect") != nil || has("selftest") || bench }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.current.apply()
        if let a = Flags.value("appearance").flatMap(Appearance.init(rawValue:)) { a.apply() }
        NSApp.mainMenu = MainMenu.build()
        if Flags.headless {
            Headless.run()
        } else if Flags.has("demo") {
            let doc = controller.openUntitled(with: Sample.shop())
            if let store = doc?.store { Headless.applyFlags(to: store) }
            NSApp.activate(ignoringOtherApps: true)
        }
        if Flags.has("settings"), !Flags.headless { SettingsWindowController.shared.show() }
        Updater.shared.start()
    }

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }

    /// Opens Settings, where the result shows, and asks GitHub for the latest release.
    @objc func checkForUpdates(_ sender: Any?) {
        SettingsWindowController.shared.show()
        Updater.shared.check(userInitiated: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A waiting update installs now, so the next launch is the new version.
        if Updater.shared.installOnQuit({ NSApp.reply(toApplicationShouldTerminate: true) }) { return .terminateLater }
        return .terminateNow
    }

    var controller: SchemaDocumentController { NSDocumentController.shared as! SchemaDocumentController }

    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        !Flags.headless && !Flags.has("demo")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    @objc func openSample(_ sender: Any?) {
        // An untouched empty window makes way for the sample.
        let empty = controller.documents.compactMap { $0 as? SchemaDocument }
            .filter { $0.fileURL == nil && !$0.isDocumentEdited && $0.store.diagram.entities.isEmpty }
        controller.openUntitled(with: Sample.shop())
        empty.forEach { $0.close() }
    }

    @objc func setAppearance(_ sender: Any?) {
        guard let raw = (sender as? NSMenuItem)?.representedObject as? String, let a = Appearance(rawValue: raw) else { return }
        Appearance.current = a
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(setAppearance(_:)) {
            item.state = (item.representedObject as? String) == Appearance.current.rawValue ? .on : .off
        }
        return true
    }

    @objc func openIssues(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/maxbenschop/maben-schema/issues")!)
    }

    @objc func openWebsite(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://schema.maben.gg")!)
    }
}

enum MainMenu {
    @MainActor
    static func build() -> NSMenu {
        let main = NSMenu()
        @discardableResult
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            item.submenu = sub
            main.addItem(item)
            return sub
        }
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command, represented: Any? = nil, tag: Int = 0) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.representedObject = represented
            i.tag = tag
            return i
        }
        func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            items.forEach(sub.addItem)
            i.submenu = sub
            return i
        }
        let W = EditorWindowController.self
        let A = AppDelegate.self

        menu("Maben Schema", [
            item("About Maben Schema", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
            .separator(),
            item("Check for Updates…", #selector(A.checkForUpdates(_:)), ""),
            .separator(),
            item("Settings…", #selector(A.showSettings(_:)), ","),
            .separator(),
            item("Hide Maben Schema", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Maben Schema", #selector(NSApplication.terminate(_:)), "q"),
        ])

        let recent = submenu("Open Recent", [item("Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), "")])
        // AppKit fills this menu with recent files once it knows which menu it is.
        let setName = NSSelectorFromString("_setMenuName:")
        if let sub = recent.submenu, sub.responds(to: setName) { sub.perform(setName, with: "NSRecentDocumentsMenu") }
        menu("File", [
            item("New", #selector(NSDocumentController.newDocument(_:)), "n"),
            item("Open…", #selector(NSDocumentController.openDocument(_:)), "o"),
            recent,
            item("Open Sample", #selector(A.openSample(_:)), ""),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
            item("Save…", #selector(NSDocument.save(_:)), "s"),
            item("Duplicate", #selector(NSDocument.duplicate(_:)), "s", [.command, .shift]),
            item("Rename…", #selector(NSDocument.rename(_:)), ""),
            item("Move To…", #selector(NSDocument.move(_:)), ""),
            item("Revert to Saved", #selector(NSDocument.revertToSaved(_:)), ""),
            .separator(),
            item("Import SQL…", #selector(W.importSQL(_:)), "i", [.command, .shift]),
            item("Import Spreadsheet…", #selector(W.importSpreadsheet(_:)), ""),
            item("Compare With…", #selector(W.compareWith(_:)), ""),
            item("Export SQL…", #selector(W.exportSQL(_:)), "e", [.command, .shift]),
            item("Export Image…", #selector(W.exportImage(_:)), "e", [.command, .option]),
            item("Export Data Dictionary…", #selector(W.exportDictionary(_:)), ""),
            item("Export Document…", #selector(W.exportDocument(_:)), ""),
            item("Export for Astah…", #selector(W.exportAstah(_:)), ""),
            .separator(),
            item("Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift]),
            item("Print…", #selector(NSDocument.printDocument(_:)), "p"),
        ])
        menu("Edit", [
            item("Undo", Selector(("undo:")), "z"),
            item("Redo", Selector(("redo:")), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Copy Diagram as Image", #selector(W.copyImage(_:)), "c", [.command, .shift]),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Duplicate", #selector(W.duplicateSelection(_:)), "d"),
            item("Delete", #selector(NSText.delete(_:)), ""),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Copy Colours", #selector(W.copyStyle(_:)), "c", [.command, .option]),
            item("Paste Colours", #selector(W.pasteStyle(_:)), "v", [.command, .option]),
            .separator(),
            item("Find…", #selector(W.showPalette(_:)), "k"),
            item("Find and Replace…", #selector(W.showReplace(_:)), "f", [.command, .option]),
        ])
        menu("Diagram", [
            item("New Entity", #selector(W.newEntity(_:)), "n", [.command, .shift]),
            item("Add Attribute", #selector(W.addAttribute(_:)), "\r", [.command]),
            item("Rename", #selector(W.renameSelection(_:)), "r", [.command]),
            item("New Domain", #selector(W.newDomain(_:)), ""),
            submenu("New Diagram of This Model", [
                item("Empty", #selector(W.newSheet(_:)), "", tag: 0),
                item("With Every Entity", #selector(W.newSheet(_:)), "", tag: 1),
                item("With the Selected Entities", #selector(W.newSheet(_:)), "", tag: 2),
                item("A Copy of This One", #selector(W.newSheet(_:)), "", tag: 3),
            ]),
            item("New Activity Diagram", #selector(W.newActivity(_:)), ""),
            submenu("Add to the Activity Diagram", ActivityNode.Kind.allCases.map { item($0.title, #selector(W.addActivityNode(_:)), "", represented: $0.rawValue) }
                + [.separator(), item("Swimlane", #selector(W.addSwimlane(_:)), "")]),
            item("Rename This Diagram…", #selector(W.renameSheet(_:)), ""),
            item("Delete This Diagram", #selector(W.deleteSheet(_:)), ""),
            item("Next Diagram", #selector(W.nextSheet(_:)), "}", [.command]),
            item("Previous Diagram", #selector(W.previousSheet(_:)), "{", [.command]),
            item("Take Off This Diagram", #selector(W.takeOffDiagram(_:)), ""),
            .separator(),
            submenu("Add", [
                item("Note", #selector(W.addAnnotation(_:)), "", represented: Tool.note.rawValue),
                item("Text", #selector(W.addAnnotation(_:)), "", represented: Tool.text.rawValue),
                .separator(),
                item("Rectangle", #selector(W.addAnnotation(_:)), "", represented: Tool.rectangle.rawValue),
                item("Oval", #selector(W.addAnnotation(_:)), "", represented: Tool.oval.rawValue),
                item("Line", #selector(W.addAnnotation(_:)), "", represented: Tool.line.rawValue),
                item("Arrow", #selector(W.addAnnotation(_:)), "", represented: Tool.arrow.rawValue),
                .separator(),
                item("Drawing by Hand", #selector(W.addAnnotation(_:)), "", represented: Tool.pen.rawValue),
                item("Highlighter", #selector(W.addAnnotation(_:)), "", represented: Tool.highlighter.rawValue),
                .separator(),
                item("Picture…", #selector(W.addPicture(_:)), ""),
            ]),
            .separator(),
            item("Tidy Up", #selector(W.tidyUp(_:)), "l", [.command, .control]),
            submenu("Align", [
                item("Left Edges", #selector(W.alignSelection(_:)), "", tag: 0),
                item("Centres", #selector(W.alignSelection(_:)), "", tag: 1),
                item("Right Edges", #selector(W.alignSelection(_:)), "", tag: 2),
                .separator(),
                item("Top Edges", #selector(W.alignSelection(_:)), "", tag: 3),
                item("Middles", #selector(W.alignSelection(_:)), "", tag: 4),
                item("Bottom Edges", #selector(W.alignSelection(_:)), "", tag: 5),
                .separator(),
                item("Spread Across", #selector(W.alignSelection(_:)), "", tag: 6),
                item("Spread Down", #selector(W.alignSelection(_:)), "", tag: 7),
                .separator(),
                item("Make the Same Width", #selector(W.sameWidth(_:)), ""),
            ]),
            item("Bring to Front", #selector(W.bringToFront(_:)), "]", [.command, .shift]),
            item("Send to Back", #selector(W.sendToBack(_:)), "[", [.command, .shift]),
            item("Run Script…", #selector(W.runScript(_:)), "r", [.command, .option]),
            submenu("Lines", [
                item("Hop Over Each Other Where They Cross", #selector(W.toggleLineJumps(_:)), ""),
                item("Find Every Line’s Way Again", #selector(W.rerouteAll(_:)), ""),
            ]),
            .separator(),
            submenu("Notation", [
                item("Crow’s Foot (IE)", #selector(W.setNotation(_:)), "", represented: Notation.ie.rawValue),
                item("IDEF1X", #selector(W.setNotation(_:)), "", represented: Notation.idef1x.rawValue),
            ]),
            submenu("Names", [
                item("Logical", #selector(W.setNames(_:)), "", represented: NameDisplay.logical.rawValue),
                item("Physical", #selector(W.setNames(_:)), "", represented: NameDisplay.physical.rawValue),
            ]),
            submenu("Detail", [
                item("Everything", #selector(W.setDetail(_:)), "", represented: DetailLevel.all.rawValue),
                item("Keys Only", #selector(W.setDetail(_:)), "", represented: DetailLevel.keys.rawValue),
                item("Names Only", #selector(W.setDetail(_:)), "", represented: DetailLevel.namesOnly.rawValue),
            ]),
            submenu("Database", Dialect.allCases.map { item($0.title, #selector(W.setDialect(_:)), "", represented: $0.rawValue) }),
        ])
        menu("View", [
            item("Zoom In", #selector(W.zoomIn(_:)), "+"),
            item("Zoom Out", #selector(W.zoomOut(_:)), "-"),
            item("Actual Size", #selector(W.zoomActual(_:)), "0"),
            item("Zoom to Fit", #selector(W.zoomToFit(_:)), "1"),
            .separator(),
            item("Hide Entity List", #selector(W.toggleSidebar(_:)), "s", [.command, .control]),
            item("Hide Inspector", #selector(W.toggleInspector(_:)), "i", [.command, .option]),
            item("Show SQL", #selector(W.toggleSQL(_:)), "s", [.command, .option]),
            item("Show Map", #selector(W.toggleMap(_:)), "m", [.command, .option]),
            item("Show Grid", #selector(W.toggleGrid(_:)), "'"),
            item("Snap to Grid", #selector(W.toggleSnap(_:)), "'", [.command, .shift]),
            submenu("Appearance", Appearance.allCases.map { item($0.title, #selector(A.setAppearance(_:)), "", represented: $0.rawValue) }),
            .separator(),
            item("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]),
        ])
        let window = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
            item("Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), ""),
        ])
        NSApp.windowsMenu = window
        menu("Help", [
            item("Maben Schema Website", #selector(A.openWebsite(_:)), ""),
            item("Report a Problem…", #selector(A.openIssues(_:)), ""),
        ])
        return main
    }
}

/// Runs without showing anything: pictures of the window for checking a change, exports, and the editing self-test.
@MainActor
enum Headless {
    static func run() {
        var diagram = Flags.has("empty") ? Diagram() : Flags.has("features") ? Sample.features() : Sample.shop()
        if let path = Flags.value("open") {
            do { diagram = try Diagram.decode(Data(contentsOf: URL(fileURLWithPath: path))) } catch { fail("Couldn't open \(path): \(error.localizedDescription)") }
        }
        if let path = Flags.value("from-sql") {
            do { diagram = try SQLImport.parse(contentsOf: URL(fileURLWithPath: path)).diagram } catch { fail("Couldn't read \(path): \(error.localizedDescription)") }
        }
        if let path = Flags.value("from-sheet") {
            do { diagram = try SheetImport.parse(contentsOf: URL(fileURLWithPath: path)).diagram } catch { fail("Couldn't read \(path): \(error.localizedDescription)") }
        }
        if let v = Flags.value("dialect").flatMap(Dialect.init(rawValue:)) { diagram.dialect = v }
        // --sql-options=drop,quote,after,nokeys,noindexes,ifnotexists,names,nocomments: how the SQL is written.
        if let list = Flags.value("sql-options") {
            for word in list.split(separator: ",") {
                switch word {
                case "drop": diagram.sql.dropTables = true
                case "quote": diagram.sql.quoteNames = true
                case "after": diagram.sql.foreignKeys = .afterTables
                case "nokeys": diagram.sql.foreignKeys = .none
                case "noindexes": diagram.sql.indexes = false
                case "ifnotexists": diagram.sql.ifNotExists = true
                case "names": diagram.sql.comments = .name
                case "nocomments": diagram.sql.comments = .none
                default: fail("Unknown SQL option: \(word)")
                }
            }
        }
        // How it is drawn counts for an export too: a picture, or a file that keeps the notation.
        if let v = Flags.value("notation").flatMap(Notation.init(rawValue:)) { diagram.display.notation = v }
        if let v = Flags.value("names").flatMap(NameDisplay.init(rawValue:)) { diagram.display.names = v }
        if let v = Flags.value("detail").flatMap(DetailLevel.init(rawValue:)) { diagram.display.level = v }
        // --only-activities: the activity diagrams without the model, as a file that has nothing else.
        if Flags.has("only-activities") {
            var bare = Diagram()
            bare.activities = diagram.activities
            diagram = bare
        }
        // --activity[=name]: shows an activity diagram (the first, or the one with that name), so a picture or a
        // snapshot is of that one. A file without any gets an empty one.
        if Flags.has("activity") || Flags.value("activity") != nil {
            let name = Flags.value("activity")?.lowercased() ?? ""
            if let found = diagram.activities.first(where: { name.isEmpty || $0.name.lowercased() == name }) { diagram.activity = found.id }
            else { diagram.addActivity(named: name.isEmpty ? nil : Flags.value("activity")) }
        }
        // --script=<file.js>: runs a script on the diagram before anything else is done with it, and prints what it logged.
        if let path = Flags.value("script") {
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { fail("Couldn't read \(path)") }
            let outcome = Script.run(source, on: diagram)
            outcome.log.forEach { print($0) }
            if let error = outcome.error { fail(error) }
            if let changed = outcome.diagram { diagram = changed }
            if Flags.value("export") == nil, Flags.value("snapshot") == nil, Flags.value("print") == nil, Flags.value("compare") == nil { exit(0) }
        }
        // --compare=<file>: prints how the diagram differs from another (a .mschema, .sql, .xlsx or .csv), and quits.
        if let path = Flags.value("compare") {
            do {
                let url = URL(fileURLWithPath: path)
                let other = url.pathExtension == schemaExtension ? try Diagram.decode(Data(contentsOf: url))
                    : ["xlsx", "csv"].contains(url.pathExtension.lowercased()) ? try SheetImport.parse(contentsOf: url).diagram : try SQLImport.parse(contentsOf: url).diagram
                let diff = DiagramDiff.compare(other, diagram)
                for c in diff.changes { print("\(c.kind == .added ? "+" : c.kind == .removed ? "-" : "~") \(c.subject)\(c.details.isEmpty ? "" : ": " + c.details.joined(separator: "; "))") }
                print("\(diff.count(.added)) only here, \(diff.count(.removed)) only in \(url.lastPathComponent), \(diff.count(.changed)) different")
                exit(0)
            } catch { fail("Couldn't read \(path): \(error.localizedDescription)") }
        }
        if let path = Flags.value("inspect") { inspect(path) }
        if let path = Flags.value("print") { printed(diagram, to: path) }
        if let path = Flags.value("export") { export(diagram, to: path) }
        guard let doc = (NSDocumentController.shared as? SchemaDocumentController)?.openUntitled(with: diagram, display: false),
              let window = doc.windowControllers.first?.window else { fail("No window") }
        let size = (Flags.value("size") ?? "1360x860").split(separator: "x").compactMap { Double($0) }
        window.setFrame(NSRect(x: 0, y: 0, width: size.first ?? 1360, height: size.last ?? 860), display: false)
        // On screen in name only: fully transparent, behind everything, never active.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.orderBack(nil)
        applyFlags(to: doc.store)
        after(0.7) {
            if Flags.has("selftest") { SelfTest.run(doc.store); return }
            if Flags.bench { SelfTest.bench(doc.store, tables: Flags.value("bench").flatMap(Int.init) ?? 1000); return }
            doc.store.zoomToFit()
            // --edit=<entity>: with the line for a new attribute open, as while typing.
            if let name = Flags.value("edit"), let e = doc.store.diagram.entities.first(where: { $0.name.lowercased() == name.lowercased() }) {
                doc.store.canvas?.beginEdit(.newAttribute(entity: e.id))
                doc.store.canvas?.typeIntoEditor(Flags.value("typed") ?? "")
            }
            after(0.5) {
                // An open sheet is its own window: draw that instead. --settings: the Settings window.
                var shown = window.attachedSheet ?? window
                if Flags.has("settings"), let settings = SettingsWindowController.shared.window {
                    settings.alphaValue = 0
                    settings.orderBack(nil)
                    settings.layoutIfNeeded()
                    shown = settings
                }
                guard let path = Flags.value("snapshot"), let view = shown.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fail("Nothing to draw") }
                view.cacheDisplay(in: view.bounds, to: rep)
                do { try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path)) } catch { fail("\(error)") }
                print("wrote \(path)")
                exit(0)
            }
        }
    }

    static func after(_ seconds: Double, _ work: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { MainActor.assumeIsolated(work) }
    }

    static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(1)
    }

    static func applyFlags(to store: DiagramStore) {
        if let v = Flags.value("notation").flatMap(Notation.init(rawValue:)) { store.edit("") { $0.display.notation = v } }
        if let v = Flags.value("names").flatMap(NameDisplay.init(rawValue:)) { store.edit("") { $0.display.names = v } }
        if let v = Flags.value("detail").flatMap(DetailLevel.init(rawValue:)) { store.edit("") { $0.display.level = v } }
        if let v = Flags.value("dialect").flatMap(Dialect.init(rawValue:)) { store.edit("") { $0.dialect = v } }
        if Flags.has("no-inspector") { store.showInspector = false }
        if Flags.has("no-sidebar") { store.showSidebar = false }
        if Flags.has("sql") { store.showSQL = true }
        if Flags.has("palette") { store.palette = true }
        if Flags.has("import") { store.sheet = .importSQL }
        if let path = Flags.value("import-file") { store.importFile(URL(fileURLWithPath: path)) }
        if let path = Flags.value("import-sheet") { store.sheetFile = URL(fileURLWithPath: path); store.sheet = .importSQL }
        if let name = Flags.value("select") {
            let ids = name.split(separator: ",").compactMap { n in store.diagram.entities.first { $0.name.lowercased() == n.lowercased() }?.id }
            if !ids.isEmpty { store.selection = .entities(Set(ids)) }
            // On an activity diagram the names are those of its nodes and swimlanes.
            if let shown = store.diagram.shownActivity {
                let wanted = Set(name.split(separator: ",").map { $0.lowercased() })
                store.activityParts = Set(shown.nodes.filter { wanted.contains($0.name.lowercased()) }.map(\.id) + shown.lanes.filter { wanted.contains($0.name.lowercased()) }.map(\.id))
            }
        }
        // --arrow=n: the nth arrow of the activity diagram being shown.
        if let n = Flags.value("arrow").flatMap(Int.init), let flows = store.diagram.shownActivity?.flows, flows.indices.contains(n) { store.activityParts = [flows[n].id] }
        if let n = Flags.value("relationship").flatMap(Int.init), store.diagram.relationships.indices.contains(n) {
            store.selection = .relationship(store.diagram.relationships[n].id)
        }
        if let name = Flags.value("domain"), let d = store.diagram.domain(named: name) { store.selection = .domain(d.id) }
        store.undoManager?.removeAllActions()
    }

    /// `--inspect=<file.sql>`: what an import of that file would find, in numbers.
    static func inspect(_ path: String) -> Never {
        let start = Date()
        do {
            let r = try SQLImport.parse(contentsOf: URL(fileURLWithPath: path))
            let size = ByteCountFormatter.string(fromByteCount: Int64(r.bytes), countStyle: .file)
            print("\(r.tables) tables, \(r.foreignKeys) foreign keys, read \(size) in \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
            for g in r.groups { print("  \(g.name.isEmpty ? "(no database)" : g.name): \(g.entities.count) tables") }
            for s in r.skipped { print("  left as a plain column: \(s)") }
            let problems = r.diagram.problems()
            print("  \(problems.count) problems" + (problems.isEmpty ? "" : ": " + problems.prefix(5).map(\.message).joined(separator: " | ")))
        } catch { fail("\(error.localizedDescription)") }
        exit(0)
    }

    /// `--print=<file.pdf>`: what File › Print puts on paper, saved as a PDF without a print panel.
    static func printed(_ diagram: Diagram, to path: String) -> Never {
        let shown: any Drawing = diagram.shownActivity.map { ActivityScene($0) } ?? Scene(diagram)
        let view = Picture.PrintView(scene: shown, title: "Diagram", fit: !Flags.has("tiled"), marks: true)
        let info = NSPrintInfo()
        info.orientation = view.area.width > view.area.height * 1.15 ? .landscape : .portrait
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = URL(fileURLWithPath: path)
        view.layout(for: info)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run() else { fail("Printing to \(path) didn't work") }
        print("wrote \(path)")
        exit(0)
    }

    static func export(_ diagram: Diagram, to path: String) -> Never {
        let url = URL(fileURLWithPath: path)
        let scene = Scene(diagram)
        let dark = Flags.has("dark")
        do {
            switch url.pathExtension.lowercased() {
            case "png", "jpg", "pdf", "svg":
                // --scale=1…4: how fine a PNG or JPEG is.
                let format = ImageFormat(rawValue: url.pathExtension.lowercased()) ?? .png
                let scale = CGFloat(min(4, max(1, Flags.value("scale").flatMap(Int.init) ?? 2)))
                let shown: any Drawing = diagram.shownActivity.map { ActivityScene($0) } ?? scene
                try (Picture.data(shown, format: format, dark: dark, transparent: Flags.has("transparent"), scale: scale) ?? Data()).write(to: url)
            case "html": try DocumentExport.html(for: diagram, scene: scene, title: "Diagram").write(to: url, atomically: true, encoding: .utf8)
            // --print=<file.pdf> [--tiled]: what File › Print puts on paper, as a PDF.
            case "sql": try SQLExport.script(for: diagram).write(to: url, atomically: true, encoding: .utf8)
            case "md": try Report.markdown(for: diagram, title: "Diagram").write(to: url, atomically: true, encoding: .utf8)
            case "csv": try Report.csv(for: diagram).write(to: url, atomically: true, encoding: .utf8)
            case "xlsx": try Report.workbook(for: diagram).xlsx().write(to: url)
            case AstaExport.fileExtension:
                try AstaExport.data(for: diagram, layout: scene.astaLayout, others: Scene.astaOthers(of: diagram), activities: ActivityScene.layouts(of: diagram)).write(to: url)
            // What Astah should show after opening that file (see Resources/astah).
            case "astalist": try AstaExport.manifest(for: diagram).write(to: url, atomically: true, encoding: .utf8)
            case schemaExtension: try diagram.encoded().write(to: url)
            default: fail("Unknown file type: \(url.pathExtension)")
            }
        } catch { fail("\(error)") }
        print("wrote \(path)")
        exit(0)
    }
}

Updater.verifyIfRequested()   // --verify-update <app> <version>: prints the result and exits

MainActor.assumeIsolated {
    let app = NSApplication.shared
    // The first document controller made is the one the app uses.
    _ = SchemaDocumentController()
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(Flags.headless ? .accessory : .regular)
    withExtendedLifetime(delegate) { app.run() }
}
