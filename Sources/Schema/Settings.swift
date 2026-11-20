import AppKit
import SchemaCore
import SwiftUI

/// What the app remembers between launches, apart from the diagrams themselves.
enum Preferences {
    private static var d: UserDefaults { .standard }

    /// How a new diagram is drawn. Each diagram keeps its own choice after that.
    static var notation: Notation {
        get { Notation(rawValue: d.string(forKey: "new.notation") ?? "") ?? .ie }
        set { d.set(newValue.rawValue, forKey: "new.notation") }
    }

    /// The database a new diagram writes SQL for.
    static var dialect: Dialect {
        get { Dialect(rawValue: d.string(forKey: "new.dialect") ?? "") ?? .postgres }
        set { d.set(newValue.rawValue, forKey: "new.dialect") }
    }

    /// A new, empty diagram with the choices from Settings.
    static func newDiagram() -> Diagram {
        var diagram = Diagram()
        diagram.display.notation = notation
        diagram.dialect = dialect
        return diagram
    }
}

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let size = NSSize(width: 560, height: 430)
        let window = makeMabenWindow(size: size, resizable: false)
        window.title = "Settings"
        super.init(window: window)
        let host = NSHostingController(rootView: SettingsView())
        host.sizingOptions = []
        window.contentViewController = host
        if !window.setFrameUsingName("MabenSchemaSettings") {
            window.setContentSize(size)
            window.center()
        }
        window.setFrameAutosaveName("MabenSchemaSettings")
    }

    required init?(coder: NSCoder) { fatalError() }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SettingsView: View {
    @State private var appearance = Appearance.current
    @State private var notation = Preferences.notation
    @State private var dialect = Preferences.dialect
    @AppStorage("showHints") private var showHints = true
    @ObservedObject private var updater = Updater.shared
    @State private var showNotes = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.system(size: 15, weight: .semibold)).foregroundStyle(MB.text).padding(.leading, 64)
            row("Appearance") {
                MBSegmented(options: Appearance.allCases, selection: $appearance) { $0.title }
                    .onChange(of: appearance) { _, a in Appearance.current = a }
            }
            row("New diagrams") {
                VStack(alignment: .leading, spacing: 8) {
                    MBSegmented(options: Notation.allCases, selection: $notation) { $0 == .ie ? "Crow’s foot" : "IDEF1X" }
                        .onChange(of: notation) { _, v in Preferences.notation = v }
                    Picker("", selection: $dialect) {
                        ForEach(Dialect.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 180)
                    .onChange(of: dialect) { _, v in Preferences.dialect = v }
                    Text("The notation and the database a new diagram starts with. Each diagram keeps its own after that.")
                        .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            row("Canvas") {
                Toggle("Show hints at the bottom of the canvas", isOn: $showHints).toggleStyle(.checkbox)
            }
            row("Updates") {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text(updateTitle).fontWeight(.medium)
                        updateButtons
                    }
                    Text(updateDetail).font(.system(size: 11.5)).foregroundStyle(updateFailed ? MB.orange : MB.dim)
                        .fixedSize(horizontal: false, vertical: true)
                    Toggle("Check for updates automatically", isOn: $updater.autoCheck).toggleStyle(.checkbox)
                    Toggle("Install updates automatically", isOn: $updater.autoInstall).toggleStyle(.checkbox)
                        .disabled(!updater.autoCheck)
                    Text("Checking asks GitHub for the latest release at start and every 6 hours; it is the only thing the app sends anywhere. An update installs when no diagram is open, or as you quit, after its Maben signature and Apple’s notarization are checked.")
                        .font(.system(size: 11.5)).foregroundStyle(MB.dim).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .font(.system(size: 12.5))
        .foregroundStyle(MB.text)
        .padding(.horizontal, 24).padding(.top, 14).padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(MB.bg)
        .tint(MB.accent)
        .ignoresSafeArea()
    }

    // Version, the Update button and what the last check found (as in Maben Base, Awake and Sweep).
    private var updateTitle: String {
        if let r = updater.available { return "Version \(r.version) is available" }
        return isBundled ? "Maben Schema \(updater.currentVersion)" : "Development copy"
    }

    private var updateFailed: Bool {
        if case .failed = updater.state { return true }
        return false
    }

    private var updateDetail: String {
        switch updater.state {
        case .idle: return isBundled ? "Not checked yet." : "Updates only work in the installed app."
        case .checking: return "Checking GitHub…"
        case .upToDate(let date): return "Up to date. Checked \(date.formatted(.relative(presentation: .named)))."
        case .available: return updater.canInstall ? "Installs in a few seconds, then restarts with the same diagrams open." : "Move the app to Applications to update."
        case .downloading(_, let p): return "Downloading… \(Int(p * 100))%"
        case .installing: return "Installing. Maben Schema restarts in a moment."
        case .failed(let message): return message
        }
    }

    @ViewBuilder private var updateButtons: some View {
        switch updater.state {
        case .available(let release):
            Button("What’s new") { showNotes.toggle() }
                .buttonStyle(.mbQuiet)
                .popover(isPresented: $showNotes, arrowEdge: .bottom) { ReleaseNotes(release: release) }
            Button("Update") { updater.update() }.buttonStyle(.mbPrimary).disabled(!updater.canInstall)
        case .checking, .downloading, .installing:
            ProgressView().controlSize(.small)
        default:
            Button("Check now") { updater.check(userInitiated: true) }.buttonStyle(.mbQuiet).disabled(!isBundled)
        }
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Text(label).foregroundStyle(MB.muted).frame(width: 110, alignment: .trailing)
            content()
        }
    }
}

/// The notes of a waiting release, from its GitHub page.
private struct ReleaseNotes: View {
    let release: Updater.Release
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Maben Schema \(release.version)").font(.system(size: 13, weight: .semibold))
            ScrollView {
                Text((try? AttributedString(markdown: release.notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                     ?? AttributedString(release.notes))
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            Link("Open on GitHub", destination: release.page).font(.system(size: 12))
        }
        .frame(width: 320)
        .padding(16)
    }
}
