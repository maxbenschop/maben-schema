import AppKit
import JavaScriptCore
import SchemaCore
import SwiftUI

/// Scripts: a few lines of JavaScript that read or change the diagram. The script gets the diagram as `diagram`,
/// the same shape as the .mschema file (entities with their attributes, relationships, domains…); what it leaves
/// in `diagram` when it ends becomes the diagram, as one step you can undo. Nothing leaves the app: the script
/// has no files and no network, only the diagram and `log()`.
enum Script {
    struct Outcome {
        var diagram: Diagram?
        var log: [String] = []
        var error: String?
    }

    /// What every script can use beside `diagram`.
    static let prelude = """
    function entity(name) { return diagram.entities.find(function (e) { return e.name.toLowerCase() === String(name).toLowerCase(); }); }
    function attribute(e, name) { return e && e.attributes.find(function (a) { return a.name.toLowerCase() === String(name).toLowerCase(); }); }
    function addEntity(name, lines, x, y) {
        var e = { id: uuid(), name: name, attributes: (lines || []).map(parse), position: { x: x || 80, y: y || 80 } };
        diagram.entities.push(e);
        return e;
    }
    function addAttribute(e, line) { var a = parse(line); e.attributes.push(a); return a; }
    function relate(parent, child, name, kind) {
        var r = { id: uuid(), parent: parent.id, child: child.id, name: name || "", kind: kind || "nonIdentifying" };
        diagram.relationships.push(r);
        return r;
    }
    """

    static func run(_ source: String, on diagram: Diagram) -> Outcome {
        var outcome = Outcome()
        guard let context = JSContext(), let json = try? diagram.encoded(), let text = String(data: json, encoding: .utf8) else {
            outcome.error = "The script couldn’t be started."
            return outcome
        }
        context.exceptionHandler = { _, exception in
            let line = exception?.objectForKeyedSubscript("line").toInt32() ?? 0
            outcome.error = (exception?.toString() ?? "Something went wrong") + (line > 0 ? " (line \(line))" : "")
        }
        let log: @convention(block) (JSValue) -> Void = { value in
            // An object is shown as its JSON, anything else as text.
            let shown = value.isObject ? context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [value, NSNull(), 1]).toString() : value.toString()
            outcome.log.append(shown ?? "")
        }
        let uuid: @convention(block) () -> String = { UUID().uuidString }
        let domains = diagram.domains, types = diagram.dataTypes, fallback = diagram.defaultType
        // A typed line, as on the canvas: "email varchar(255) unique not null".
        let parse: @convention(block) (String) -> Any = { line in
            guard let a = QuickEntry.parse(line, domains: domains, types: types, fallback: fallback), let data = try? JSONEncoder().encode(a),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
            return object
        }
        context.setObject(log, forKeyedSubscript: "log" as NSString)
        context.setObject(uuid, forKeyedSubscript: "uuid" as NSString)
        context.setObject(parse, forKeyedSubscript: "parse" as NSString)
        context.evaluateScript("var console = { log: log }; var diagram = \(text);\n" + prelude)
        context.evaluateScript(source)
        guard outcome.error == nil else { return outcome }
        guard let result = context.evaluateScript("JSON.stringify(diagram)")?.toString(), let data = result.data(using: .utf8) else {
            outcome.error = "The script left nothing in “diagram”."
            return outcome
        }
        do {
            var changed = try JSONDecoder().decode(Diagram.self, from: data)
            changed.version = Diagram.currentVersion
            // A script can leave anything behind, as a file can.
            changed.sanitize()
            changed.normalize()
            outcome.diagram = changed
        } catch {
            outcome.error = "What the script left in “diagram” isn’t a diagram: \(error.localizedDescription)"
        }
        return outcome
    }

    static let examples: [(title: String, source: String)] = [
        ("List every table with its columns", "diagram.entities.forEach(function (e) {\n    log(e.name + \": \" + e.attributes.map(function (a) { return a.name; }).join(\", \"));\n});"),
        ("Add created_at and updated_at to every entity", "diagram.entities.forEach(function (e) {\n    if (!attribute(e, \"created_at\")) addAttribute(e, \"created_at timestamp not null = CURRENT_TIMESTAMP\");\n    if (!attribute(e, \"updated_at\")) addAttribute(e, \"updated_at timestamp\");\n});\nlog(\"Done.\");"),
        ("Make every table name plural", "diagram.entities.forEach(function (e) {\n    var table = e.physicalName || e.name.toLowerCase().replace(/ /g, \"_\");\n    if (!/s$/.test(table)) e.physicalName = table + \"s\";\n});"),
        ("Add an entity and relate it", "var log_entry = addEntity(\"Audit Log\", [\"*id integer auto\", \"what text not null\", \"at timestamp not null\"], 80, 600);\nvar first = diagram.entities[0];\nif (first !== log_entry) relate(first, log_entry, \"is logged in\");"),
        ("Find attributes without a definition", "diagram.entities.forEach(function (e) {\n    e.attributes.filter(function (a) { return !a.definition && !a.foreignKey; }).forEach(function (a) { log(e.name + \".\" + a.name); });\n});"),
    ]
}

extension DiagramStore {
    /// Runs a script on the diagram; what it changed is one step to undo.
    @discardableResult
    func runScript(_ source: String) -> Script.Outcome {
        let outcome = Script.run(source, on: diagram)
        if let changed = outcome.diagram, changed != diagram {
            edit("Run Script") { $0 = changed }
        }
        return outcome
    }
}

/// Diagram › Run Script: type or paste a script, run it, read what it logged.
struct ScriptSheet: View {
    @ObservedObject var store: DiagramStore
    @AppStorage("script.last") private var source = Script.examples[0].source
    @State private var output = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Run a script").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text)
                    Text("JavaScript. The diagram is “diagram”, shaped like the file; what the script leaves in it becomes the diagram, as one step you can undo. log(…) writes below.")
                        .font(.system(size: 12)).foregroundStyle(MB.muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Menu("Examples") {
                    ForEach(Script.examples, id: \.title) { example in
                        Button(example.title) { source = example.source }
                    }
                }
                .fixedSize()
            }
            TextEditor(text: $source)
                .font(MB.mono).scrollContentBackground(.hidden).focused($focused).padding(6)
                .frame(minHeight: 210)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MB.wash(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.line))
                .accessibilityLabel("Script")
            ScrollView {
                Text(output.isEmpty ? "Helpers: entity(name), attribute(entity, name), addEntity(name, lines, x, y), addAttribute(entity, line), relate(parent, child, name, kind), uuid(), log(…)." : output)
                    .font(MB.mono).foregroundStyle(failed ? MB.red : output.isEmpty ? MB.dim : MB.text)
                    .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).padding(8)
            }
            .frame(height: 110)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MB.wash(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MB.line))
            HStack(spacing: 8) {
                Spacer()
                Button("Close") { store.sheet = nil }.buttonStyle(.mbQuiet).keyboardShortcut(.cancelAction)
                Button("Run") {
                    let before = store.diagram
                    let outcome = store.runScript(source)
                    failed = outcome.error != nil
                    var lines = outcome.log
                    if let error = outcome.error { lines.append(error) }
                    else if store.diagram != before { lines.append("The diagram was changed. Undo (⌘Z) takes it back.") }
                    else if lines.isEmpty { lines.append("Ran. Nothing was changed.") }
                    output = lines.joined(separator: "\n")
                }
                .buttonStyle(.mbPrimary).keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(18)
        .frame(width: 640, height: 500)
        .background(MB.card)
        .onAppear { focused = true }
    }
}
