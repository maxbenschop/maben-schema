import AppKit
import SchemaCore
import Combine
import Security

/// True for the built app, false for `swift run` and tests.
let isBundled = Bundle.main.bundleURL.pathExtension == "app"

/// Updates from GitHub Releases (github.com/maxbenschop/maben-schema), the same way Maben Awake and Maben Sweep do.
///
/// 1. Check: ask the GitHub API for the latest release (drafts and pre-releases are never "latest").
///    Its tag `vX.Y.Z` is the version and its text the release notes. At start, every 6 hours, after
///    waking if the last check is over 6 hours old, and when you press Check now. This is the only
///    network request the app makes.
/// 2. Download `Maben-Schema.zip` from that release (and from nowhere but this repository's releases on
///    github.com) to a temporary folder.
/// 3. Verify before touching anything: the app inside must be signed with the Developer ID of team
///    NJTYRVLSA8 with this bundle ID, notarized by Apple (Gatekeeper accepts it), and the announced version.
/// 4. Install: a copy is put next to the app and checked once more (what is checked is what is installed),
///    then the two change places and the old one goes to the Trash. See `UpdateInstall`.
///
/// An automatic install never restarts the app under your hands: it waits until no diagram is open
/// (an untouched empty window doesn't count), or runs as you quit (then the new version is simply there
/// next time). That is looked at again right before the app is replaced and right before it restarts, so a
/// diagram started while the update was coming in isn't lost either.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    typealias Release = ReleaseFeed.Release
    typealias Failure = UpdateInstall.Failure

    enum State: Equatable {
        case idle
        case checking
        case upToDate(checked: Date)
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        /// The new version is in the app's place; this one runs on until it is quit or restarted.
        case installed(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published var autoCheck: Bool { didSet { defaults.set(autoCheck, forKey: "updates.autoCheck"); schedule() } }
    @Published var autoInstall: Bool { didSet { defaults.set(autoInstall, forKey: "updates.autoInstall") } }

    nonisolated static let teamID = UpdateInstall.teamID
    nonisolated static let bundleID = UpdateInstall.bundleID

    /// Why an install runs, which decides whether the app may restart at the end of it.
    private enum Reason {
        /// By itself: only while no diagram is open.
        case automatic
        /// The Update button: saved diagrams come back, and the unsaved ones were asked about.
        case button
        /// As the app quits: nothing restarts.
        case quit
    }

    private let defaults = UserDefaults.standard
    private var timer: Timer?
    private var lastCheck: Date?
    private var wakeObserver: NSObjectProtocol?
    private var downloadObservation: NSKeyValueObservation?
    private var download: URLSessionDownloadTask?
    /// Set while the app waits to quit for an install: called when it is done, whatever the outcome.
    private var afterInstall: (() -> Void)?
    private var quitting = false
    private var reason = Reason.automatic
    /// The never-saved diagrams that were there when you chose "Update anyway".
    private var accepted: Set<ObjectIdentifier> = []
    /// A downloaded and checked update that waits for its moment: no diagram open, the button, or quitting.
    private var staged: (release: Release, app: URL, work: URL)?
    /// True from just before the app is replaced until that is done. Nothing stops the app in between.
    private var swapping = false
    /// Goes up when an install is given up, so what is still on its way in is dropped when it arrives.
    private var attempt = 0

    var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    var available: Release? {
        switch state {
        case .available(let r), .downloading(let r, _), .installing(let r): r
        default: nil
        }
    }

    /// Updates only install over a copy in an Applications folder (not a dev build or a translocated download).
    var canInstall: Bool {
        let path = Bundle.main.bundlePath
        return isBundled && !path.contains("/AppTranslocation/")
            && (path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/"))
    }

    /// The demo, the development copies and the runs without a window never check or install.
    private var live: Bool { isBundled && !CommandLine.arguments.contains("--demo") && !Flags.headless }

    private init() {
        // On by default, as in Maben Awake and Maben Sweep.
        autoCheck = defaults.object(forKey: "updates.autoCheck") as? Bool ?? true
        autoInstall = defaults.object(forKey: "updates.autoInstall") as? Bool ?? true
    }

    /// Call once at launch. Does nothing for a copy that isn't a real app (`swift run`, tests, demo).
    func start() {
        guard live else { return }
        if canInstall {
            // What an install that was cut short left next to the app.
            let app = Bundle.main.bundleURL
            DispatchQueue.global(qos: .utility).async { UpdateInstall.cleanUp(beside: app) }
        }
        schedule()
        if autoCheck {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.check(userInitiated: false) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkAfterWake() }
        }
    }

    private func checkAfterWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self, self.autoCheck else { return }
            if let lastCheck = self.lastCheck, Date().timeIntervalSince(lastCheck) < 6 * 3600 { return }
            self.check(userInitiated: false)
        }
    }

    private func schedule() {
        timer?.invalidate()
        guard autoCheck, live else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check(userInitiated: false) }
        }
    }

    // MARK: Check

    func check(userInitiated: Bool) {
        switch state {
        case .checking, .downloading, .installing, .installed: return
        default: break
        }
        state = .checking
        var request = URLRequest(url: ReleaseFeed.url, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MabenSchema/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let release = data.flatMap { ReleaseFeed.parse($0) }
            Task { @MainActor in
                if let error {
                    self.fail(userInitiated ? "Couldn't reach GitHub: \(error.localizedDescription)" : nil)
                } else if status != 200 || release == nil {
                    self.fail(userInitiated ? "GitHub didn't return a release (HTTP \(status))." : nil)
                } else if let release, ReleaseFeed.isNewer(release.version, than: self.currentVersion) {
                    self.lastCheck = Date()
                    self.state = .available(release)
                    if self.autoInstall { self.installWhenQuiet() }
                } else {
                    self.lastCheck = Date()
                    self.state = .upToDate(checked: Date())
                }
            }
        }.resume()
    }

    private func fail(_ message: String?) {
        state = message.map { .failed($0) } ?? .idle
    }

    // MARK: Install

    /// The open diagrams, without the untouched empty window the app starts with.
    private var openDiagrams: [SchemaDocument] {
        NSDocumentController.shared.documents.compactMap { $0 as? SchemaDocument }
            .filter { $0.fileURL != nil || $0.isDocumentEdited || !$0.store.diagram.entities.isEmpty || !$0.store.diagram.activities.isEmpty }
    }

    /// The open diagrams that have no file to come back from after a restart.
    private var unsavedDiagrams: [SchemaDocument] { openDiagrams.filter { $0.fileURL == nil } }

    /// Whether the app may be replaced and restarted now, for the reason this install runs.
    private var mayRestart: Bool {
        switch reason {
        case .automatic: openDiagrams.isEmpty
        case .button: unsavedDiagrams.allSatisfy { accepted.contains(ObjectIdentifier($0)) }
        case .quit: true
        }
    }

    /// Automatic install: only while no diagram is open, so nothing you are looking at is lost.
    private func installWhenQuiet() {
        guard canInstall else { return }
        if openDiagrams.isEmpty {
            install(.automatic)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self] in
                guard let self, case .available = self.state, self.autoInstall else { return }
                self.installWhenQuiet()
            }
        }
    }

    /// As the app quits. An install that is replacing the app is waited for, however long it takes; one that is
    /// still coming in gets 45 seconds and is then given up, before anything of the app was touched; a waiting
    /// update is installed now, without restarting. Returns false when there is nothing to wait for; otherwise
    /// `done` is called when the app can quit.
    func holdQuit(_ done: @escaping @MainActor @Sendable () -> Void) -> Bool {
        let busy: Bool
        switch state {
        case .downloading, .installing: busy = true
        default: busy = false
        }
        var waiting = false
        if case .available = state { waiting = canInstall && (autoInstall || staged != nil) }
        guard swapping || busy || waiting else { return false }
        // Never from inside this call: the app is told it may quit only after it was told to wait.
        afterInstall = { Task { @MainActor in done() } }
        quitting = true
        if !swapping {
            reason = .quit
            // Never keep the app from quitting for a download: give up after 45 seconds. Not once the app is
            // being replaced: that is seconds of work, and stopping halfway is the one thing that must not happen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in self?.giveUp() }
            if !busy { install(.quit) }
        }
        return true
    }

    /// Drops an install that hasn't started replacing the app yet, and lets a waiting quit go on.
    private func giveUp() {
        guard !swapping else { return }
        attempt += 1
        download?.cancel()
        download = nil
        if case .downloading(let r, _) = state { state = .available(r) }
        if case .installing(let r) = state { state = .available(r) }
        finished()
    }

    /// The Update button. Saved diagrams are saved once more and come back after the restart. A diagram that
    /// has never been saved has no file to come back from, so it asks first when there is one.
    func update() {
        guard confirmLosingUnsaved() else { return }
        install(.button)
    }

    /// The Restart button, when the new version is in place and this one is still running.
    func restart() {
        guard case .installed = state, confirmLosingUnsaved() else { return }
        relaunch()
    }

    private func confirmLosingUnsaved() -> Bool {
        let unsaved = unsavedDiagrams
        accepted = Set(unsaved.map { ObjectIdentifier($0) })
        guard !unsaved.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1 ? "Update with an unsaved diagram?" : "Update with \(unsaved.count) unsaved diagrams?"
        alert.informativeText = "Maben Schema restarts to update. \(unsaved.map(\.displayName).joined(separator: ", ")) \(unsaved.count == 1 ? "has" : "have") never been saved and would be lost. Save first (⌘S), or update anyway."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Update anyway").hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }

    /// Downloads and checks the update (unless one is waiting, checked already), then puts it in place.
    private func install(_ why: Reason) {
        guard let release = available, canInstall else { finished(); return }
        if case .downloading = state { return }
        if case .installing = state { return }
        reason = why
        if let staged, staged.release == release, FileManager.default.fileExists(atPath: staged.app.path) {
            place()
            return
        }
        dropStaged()
        // The feed was checked when it was read; the address is looked at once more where it is used.
        guard ReleaseFeed.isDownload(release.zip) else {
            state = .failed("The update isn’t on GitHub where it should be. It was not installed.")
            finished()
            return
        }
        attempt += 1
        let mine = attempt
        state = .downloading(release, progress: 0)
        let task = URLSession.shared.downloadTask(with: release.zip) { location, response, error in
            // The temporary file is deleted when this returns, so move it first.
            var kept: URL?
            if let location {
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent("MabenSchema-\(UUID().uuidString).zip")
                if (try? FileManager.default.moveItem(at: location, to: dest)) != nil { kept = dest }
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            Task { @MainActor in
                guard mine == self.attempt else {
                    if let kept { try? FileManager.default.removeItem(at: kept) }
                    return
                }
                self.download = nil
                guard let kept, error == nil, status == 200 else {
                    if let kept { try? FileManager.default.removeItem(at: kept) }
                    self.state = .failed("The download failed\(error.map { ": \($0.localizedDescription)" } ?? " (HTTP \(status)).")")
                    self.finished()
                    return
                }
                self.state = .installing(release)
                Task.detached { await self.prepare(zip: kept, release: release, attempt: mine) }
            }
        }
        downloadObservation = task.progress.observe(\.fractionCompleted) { progress, _ in
            let value = progress.fractionCompleted
            Task { @MainActor in
                if case .downloading(let r, _) = self.state { self.state = .downloading(r, progress: value) }
            }
        }
        download = task
        task.resume()
    }

    /// Unpacks the download and checks the app in it. Runs off the main thread. A bad update stops here, before
    /// anything of the app is touched and before anyone is asked for a password.
    private nonisolated func prepare(zip: URL, release: Release, attempt mine: Int) async {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("MabenSchemaUpdate-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: zip) }
        do {
            try fm.createDirectory(at: work, withIntermediateDirectories: true)
            guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path]) == 0 else { throw Failure("Couldn't unpack the update.") }
            guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" })
            else { throw Failure("The update doesn't contain an app.") }
            try Self.verify(newApp, expectedVersion: release.version)
            await MainActor.run {
                guard mine == self.attempt else { try? FileManager.default.removeItem(at: work); return }
                self.staged = (release, newApp, work)
                self.place()
            }
        } catch {
            try? fm.removeItem(at: work)
            let message = (error as? Failure)?.message ?? error.localizedDescription
            await MainActor.run {
                guard mine == self.attempt else { return }
                self.state = .failed(message)
                self.finished()
            }
        }
    }

    /// Puts the waiting, checked update in the app's place, if this is still the moment for it.
    private func place() {
        guard let staged, !swapping else { return }
        // Looked at again here, not only when the download started: a diagram may have been opened since.
        guard mayRestart else {
            state = .available(staged.release)
            let asked = reason == .button
            finished()
            // The button: ask about the new unsaved diagram. By itself: wait until none is open, or for the quit.
            if asked { update() } else if autoInstall { installWhenQuiet() }
            return
        }
        swapping = true
        state = .installing(staged.release)
        let target = Bundle.main.bundleURL, app = staged.app, version = staged.release.version
        Task.detached {
            let failure: String?
            do {
                try Self.replace(target, with: app, version: version)
                failure = nil
            } catch {
                failure = (error as? Failure)?.message ?? error.localizedDescription
            }
            await MainActor.run { self.placed(failure) }
        }
    }

    private func placed(_ failure: String?) {
        swapping = false
        let release = staged?.release
        dropStaged()
        if let failure {
            state = .failed(failure)
            finished()
            return
        }
        guard let release else { finished(); return }
        // And once more before restarting: replacing the app can take a while (a password is asked for when the
        // app was installed by an administrator), and the new version is just as much there without a restart.
        if quitting || !mayRestart {
            state = .installed(release)
            finished()
        } else {
            relaunch()
        }
    }

    private func dropStaged() {
        if let staged { try? FileManager.default.removeItem(at: staged.work) }
        staged = nil
    }

    /// Lets a waiting quit go on (once).
    private func finished() {
        let done = afterInstall
        afterInstall = nil
        done?()
    }

    /// The downloaded app must be ours, notarized, and the version we expect.
    nonisolated static func verify(_ app: URL, expectedVersion: String) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw Failure("The update isn't a valid app.")
        }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(UpdateInstall.requirement() as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw Failure("Couldn't check the update's signature.")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else {
            throw Failure("The update isn't signed by Maben. It was not installed.")
        }
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) == 0 else {
            throw Failure("The update isn't notarized by Apple. It was not installed.")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist"))
        guard (info?["CFBundleShortVersionString"] as? String) == expectedVersion else {
            throw Failure("The update's version doesn't match the release.")
        }
    }

    /// Swaps the app bundle (see `UpdateInstall`). The copy that goes in is checked where it will be installed
    /// from: by this app when it can write to the folder, by the administrator's command when it can't.
    nonisolated static func replace(_ target: URL, with newApp: URL, version: String) throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        if fm.isWritableFile(atPath: folder.path) && fm.isWritableFile(atPath: target.path) {
            try UpdateInstall.swap(target: target, with: newApp, verify: { try verify($0, expectedVersion: version) })
        } else {
            // Installed by an administrator: ask for the password once.
            let staging = folder.appendingPathComponent(UpdateInstall.stagingPrefix + UUID().uuidString).path
            let command = UpdateInstall.rootCommand(newApp: newApp.path, target: target.path, staging: staging,
                                                    requirement: UpdateInstall.requirement(), version: version)
            let script = UpdateInstall.appleScript(running: command, prompt: "Maben Schema wants to install an update.")
            let (status, said) = runAndListen("/usr/bin/osascript", ["-e", script])
            guard status == 0 else {
                // -128: the password wasn't given.
                throw Failure(said.contains("-128") ? "The update was not installed (no administrator password)." : "The update couldn’t be installed. The app is as it was.")
            }
        }
    }

    /// Opens the new version a second after this one quits, with the diagrams that were open. They are
    /// saved first, so nothing drawn since the last save is lost.
    private func relaunch() {
        let saved = openDiagrams.filter { $0.fileURL != nil }
        for document in saved where document.isDocumentEdited {
            if let url = document.fileURL { try? document.write(to: url, ofType: schemaTypeName) }
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        // open -a <app> <files…>; with no files it just opens the app.
        p.arguments = ["-c", "sleep 1; app=\"$0\"; if [ $# -gt 0 ]; then /usr/bin/open -a \"$app\" \"$@\"; else /usr/bin/open \"$app\"; fi",
                       Bundle.main.bundlePath] + saved.compactMap { $0.fileURL?.path }
        try? p.run()
        exit(0)
    }

    @discardableResult
    nonisolated static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// The same, with what the tool said when it failed.
    nonisolated static func runAndListen(_ tool: String, _ args: [String]) -> (status: Int32, said: String) {
        let p = Process()
        let pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "") }
        let said = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: said, as: UTF8.self))
    }

    /// `Schema --verify-update <app> <version>`: runs the updater's checks on an app and prints the result.
    nonisolated static func verifyIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--verify-update"), i + 2 < args.count else { return }
        do {
            try verify(URL(fileURLWithPath: args[i + 1]), expectedVersion: args[i + 2])
            print("ACCEPTED")
        } catch {
            print("REJECTED: \((error as? Failure)?.message ?? "\(error)")")
        }
        exit(0)
    }
}
