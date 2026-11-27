import XCTest
@testable import SchemaCore

/// Putting an update in the app's place: what it must be signed as, the swap when the folder can be written to,
/// and the command an administrator runs when it can't. Done here on folders that stand in for the apps.
final class UpdateInstallTests: XCTestCase {
    private var folder: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        folder = fm.temporaryDirectory.appendingPathComponent("MabenSchemaTests-\(UUID().uuidString)")
        try fm.createDirectory(at: folder.appendingPathComponent("Applications"), withIntermediateDirectories: true)
        try fm.createDirectory(at: folder.appendingPathComponent("Download"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: folder)
    }

    private var target: URL { folder.appendingPathComponent("Applications/Maben Schema.app") }
    private var staged: URL { folder.appendingPathComponent("Applications/" + UpdateInstall.stagedName) }
    private var old: URL { folder.appendingPathComponent("Applications/" + UpdateInstall.oldName) }

    /// A folder that stands in for an app, with a file that says which one it is.
    @discardableResult
    private func app(at url: URL, saying text: String) throws -> URL {
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try text.write(to: url.appendingPathComponent("Contents/which.txt"), atomically: true, encoding: .utf8)
        return url
    }

    private func which(_ url: URL) -> String? { try? String(contentsOf: url.appendingPathComponent("Contents/which.txt"), encoding: .utf8) }
    private func remove(_ url: URL) { try? fm.removeItem(at: url) }
    private var besideTheApp: [String] { ((try? fm.contentsOfDirectory(atPath: target.deletingLastPathComponent().path)) ?? []).sorted() }

    func testTheRequirement() {
        XCTAssertEqual(UpdateInstall.requirement(),
                       "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
                       + " and certificate leaf[subject.OU] = \"NJTYRVLSA8\" and identifier \"gg.maben.schema\" and notarized")
        XCTAssertTrue(UpdateInstall.requirement(teamID: "TEAM", bundleID: "an.other").contains("certificate leaf[subject.OU] = \"TEAM\" and identifier \"an.other\" and notarized"))
    }

    // MARK: The folder can be written to

    func testTheNewAppTakesTheOldOnesPlace() throws {
        try app(at: target, saying: "old")
        let new = try app(at: folder.appendingPathComponent("Download/Maben Schema.app"), saying: "new")
        var checked: [URL] = [], discarded: [URL] = []
        try UpdateInstall.swap(target: target, with: new, verify: { url in
            checked.append(url)
            XCTAssertEqual(self.which(url), "new")
            XCTAssertEqual(self.which(self.target), "old", "while the copy is checked the app is still the old one")
        }, discard: { url in
            discarded.append(url)
            XCTAssertEqual(self.which(url), "old")
            self.remove(url)
        })
        XCTAssertEqual(which(target), "new")
        XCTAssertEqual(checked.map(\.lastPathComponent), [UpdateInstall.stagedName], "what is checked is the copy next to the app, not what was downloaded")
        XCTAssertEqual(checked.first?.deletingLastPathComponent().path, target.deletingLastPathComponent().path)
        XCTAssertEqual(discarded.map(\.lastPathComponent), [UpdateInstall.oldName], "the old one is thrown away only now")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"])
        XCTAssertEqual(which(new), "new", "the download is left as it was")
    }

    func testAnUpdateThatFailsItsCheckChangesNothing() throws {
        try app(at: target, saying: "old")
        let new = try app(at: folder.appendingPathComponent("Download/Maben Schema.app"), saying: "not ours")
        XCTAssertThrowsError(try UpdateInstall.swap(target: target, with: new, verify: { _ in throw UpdateInstall.Failure("The update isn't signed by Maben. It was not installed.") },
                                                    discard: { _ in XCTFail("nothing to throw away") })) { error in
            XCTAssertEqual(error as? UpdateInstall.Failure, UpdateInstall.Failure("The update isn't signed by Maben. It was not installed."))
        }
        XCTAssertEqual(which(target), "old")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"], "the copy is gone")
    }

    /// A copy that was changed between the download's check and the install is what the second check is for.
    func testWhatIsCheckedIsWhatIsInstalled() throws {
        try app(at: target, saying: "old")
        let new = try app(at: folder.appendingPathComponent("Download/Maben Schema.app"), saying: "new")
        try UpdateInstall.swap(target: target, with: new, verify: { staged in
            // Whoever changes the download now is too late: the copy is already made.
            try "changed after the copy".write(to: new.appendingPathComponent("Contents/which.txt"), atomically: true, encoding: .utf8)
            XCTAssertEqual(self.which(staged), "new")
        }, discard: remove)
        XCTAssertEqual(which(target), "new")
    }

    func testTheOldAppComesBackWhenTheNewOneCannotTakeItsPlace() throws {
        try app(at: target, saying: "old")
        let new = try app(at: folder.appendingPathComponent("Download/Maben Schema.app"), saying: "new")
        var moves: [(String, String)] = []
        XCTAssertThrowsError(try UpdateInstall.swap(target: target, with: new, verify: { _ in }, move: { from, to in
            moves.append((from.lastPathComponent, to.lastPathComponent))
            // The second rename, the copy into the app's place, fails.
            if moves.count == 2 { throw CocoaError(.fileWriteNoPermission) }
            try FileManager.default.moveItem(at: from, to: to)
        }, discard: { _ in XCTFail("the old app must not be thrown away") })) { error in
            XCTAssertTrue((error as? UpdateInstall.Failure)?.message.hasPrefix("Couldn’t install the update: ") == true, "\(error)")
        }
        XCTAssertEqual(moves.map(\.0), ["Maben Schema.app", UpdateInstall.stagedName, UpdateInstall.oldName])
        XCTAssertEqual(moves.map(\.1), [UpdateInstall.oldName, "Maben Schema.app", "Maben Schema.app"])
        XCTAssertEqual(which(target), "old", "the app is back where it was")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"])

        // The first rename fails: nothing was moved, nothing is left.
        XCTAssertThrowsError(try UpdateInstall.swap(target: target, with: new, verify: { _ in }, move: { _, _ in throw CocoaError(.fileWriteNoPermission) },
                                                    discard: { _ in XCTFail("the old app must not be thrown away") }))
        XCTAssertEqual(which(target), "old")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"])
    }

    func testWhatAnEarlierTryLeftBehindIsNotInTheWay() throws {
        try app(at: target, saying: "old")
        try app(at: staged, saying: "half a copy from last time")
        try app(at: old, saying: "an old one from last time")
        let new = try app(at: folder.appendingPathComponent("Download/Maben Schema.app"), saying: "new")
        try UpdateInstall.swap(target: target, with: new, verify: { XCTAssertEqual(self.which($0), "new") }, discard: remove)
        XCTAssertEqual(which(target), "new")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"])

        // No app to replace, or no update to put there: nothing happens to what is there.
        remove(target)
        XCTAssertThrowsError(try UpdateInstall.swap(target: target, with: new, verify: { _ in }, discard: remove))
        XCTAssertEqual(besideTheApp, [])
        try app(at: target, saying: "old")
        XCTAssertThrowsError(try UpdateInstall.swap(target: target, with: folder.appendingPathComponent("Download/Nothing.app"), verify: { _ in XCTFail("nothing to check") }, discard: remove))
        XCTAssertEqual(which(target), "old")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"])
    }

    func testLeftoversAreTakenAwayWhenTheAppStarts() throws {
        try app(at: target, saying: "the app")
        try app(at: staged, saying: "half a copy")
        try app(at: old, saying: "an old one")
        try fm.createDirectory(at: folder.appendingPathComponent("Applications/" + UpdateInstall.stagingPrefix + "ABCD-1234"), withIntermediateDirectories: true)
        try app(at: folder.appendingPathComponent("Applications/Other.app"), saying: "someone else's")
        try app(at: folder.appendingPathComponent("Applications/.Maben Schema.updates-are-not-this"), saying: "not ours either")
        UpdateInstall.cleanUp(beside: target)
        XCTAssertEqual(besideTheApp, [".Maben Schema.updates-are-not-this", "Maben Schema.app", "Other.app"])
        XCTAssertEqual(which(target), "the app")
        // Without the app there, nothing is touched: the old one may be all there is.
        remove(target)
        try app(at: old, saying: "an old one")
        UpdateInstall.cleanUp(beside: target)
        XCTAssertEqual(which(old), "an old one")
    }

    // MARK: The folder can't be written to: the administrator's command

    func testTheCommandAnAdministratorRuns() {
        let staging = "/Applications/" + UpdateInstall.stagingPrefix + "ABCD"
        let command = UpdateInstall.rootCommand(newApp: "/tmp/Update/Maben Schema.app", target: "/Applications/Maben Schema.app", staging: staging,
                                                requirement: UpdateInstall.requirement(), version: "1.2")
        // In this order: a folder of root's own, the copy, who owns it, no set-user-ID bits, the three checks on
        // the copy (signature, Gatekeeper, version), and only then the two renames.
        XCTAssertEqual(command, """
        T='/Applications/Maben Schema.app'
        D='/Applications/.Maben Schema.update.ABCD'
        S="$D"/'Maben Schema.app'
        fail() { /bin/rm -rf "$D"; exit 1; }
        /bin/mkdir -m 700 "$D" || exit 1
        /usr/bin/ditto '/tmp/Update/Maben Schema.app' "$S" || fail
        /usr/sbin/chown -R "$(/usr/bin/stat -f %u:%g "$T")" "$S" || fail
        /bin/chmod -R ug-s "$S" || fail
        /usr/bin/codesign --verify --deep --strict -R='anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "NJTYRVLSA8" and identifier "gg.maben.schema" and notarized' "$S" || fail
        /usr/sbin/spctl --assess --type execute "$S" || fail
        [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$S/Contents/Info.plist")" = '1.2' ] || fail
        /bin/mv "$T" "$D/old.app" || fail
        /bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" && /bin/rm -rf "$D"; exit 1; }
        /bin/rm -rf "$D"
        exit 0
        """)
    }

    func testEveryValueInTheCommandIsQuoted() throws {
        XCTAssertEqual(UpdateInstall.quoted("it's"), "'it'\\''s'")
        XCTAssertEqual(UpdateInstall.quoted("a b"), "'a b'")
        // Paths and a version made to run something of their own: run by a real shell, nothing of theirs runs.
        let mark = folder.appendingPathComponent("ran")
        let evil = "x'; /usr/bin/touch '\(mark.path)'; echo '$(/usr/bin/touch \(mark.path))`/usr/bin/touch \(mark.path)`\" \\"
        let command = UpdateInstall.rootCommand(newApp: folder.appendingPathComponent(evil).path, target: folder.appendingPathComponent("Applications/" + evil).path,
                                                staging: folder.appendingPathComponent("Applications/.stage " + evil).path, requirement: evil, version: evil)
        XCTAssertNotEqual(shell(command), 0)
        XCTAssertFalse(fm.fileExists(atPath: mark.path), "nothing in a value was run")
        XCTAssertTrue(command.contains("T=" + UpdateInstall.quoted(folder.appendingPathComponent("Applications/" + evil).path) + "\n"))
        XCTAssertTrue(command.contains("-R=" + UpdateInstall.quoted(evil) + " \"$S\""))
        XCTAssertTrue(command.contains("= " + UpdateInstall.quoted(evil) + " ]"))
        // And the same when the command goes into AppleScript: a string, with its line ends written out.
        let script = UpdateInstall.appleScript(running: "echo \"a\\b\"\nexit 0", prompt: "say \"hi\"")
        XCTAssertEqual(script, "do shell script \"echo \\\"a\\\\b\\\"\\nexit 0\" with prompt \"say \\\"hi\\\"\" with administrator privileges")
        XCTAssertEqual(UpdateInstall.appleScriptString("a\tb\rc\" & do shell script \"id"), "\"a\\tb\\rc\\\" & do shell script \\\"id\"")
        XCTAssertFalse(UpdateInstall.appleScript(running: command, prompt: "p").contains("\n"), "one line of script, whatever the command holds")
    }

    private func run(_ tool: String, _ arguments: [String]) -> (status: Int32, said: String) {
        let p = Process(), pipe = Pipe()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = arguments
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let said = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The command as AppleScript hands it to the shell (`do shell script`, here without the administrator part,
    /// so nobody is asked for a password): every line of it arrives as a line, and what is quoted stays quoted.
    func testTheCommandSurvivesAppleScript() throws {
        let lines = "A='it'\\''s \"quoted\" \\ $HOME'\nB=\"two words\"\n/bin/echo \"$A|$B\"\nexit 0"
        let script = UpdateInstall.appleScript(running: lines, prompt: "p")
        let suffix = " with prompt \"p\" with administrator privileges"
        XCTAssertTrue(script.hasSuffix(suffix))
        let result = run("/usr/bin/osascript", ["-e", String(script.dropLast(suffix.count))])
        try XCTSkipIf(result.status != 0 && result.said.isEmpty, "osascript can't run here")
        XCTAssertEqual(result.said, "it's \"quoted\" \\ $HOME|two words")
    }

    /// The whole command on the released app, when this Mac has it installed: run by /bin/sh as the user running
    /// the tests, in folders of the test's own. Checked, swapped, cleaned up; and refused for the wrong version, a
    /// copy that was changed after it was signed, and one that carries a set-user-ID bit it lost on the way in.
    func testTheCommandInstallsARealRelease() throws {
        let installed = URL(fileURLWithPath: "/Applications/Maben Schema.app")
        let check = ["--verify", "--deep", "--strict", "-R=" + UpdateInstall.requirement(), installed.path]
        try XCTSkipUnless(fm.fileExists(atPath: installed.path) && run("/usr/bin/codesign", check).status == 0, "no released Maben Schema in /Applications")
        let version = run("/usr/libexec/PlistBuddy", ["-c", "Print :CFBundleShortVersionString", installed.appendingPathComponent("Contents/Info.plist").path]).said
        let new = folder.appendingPathComponent("Download/Maben Schema.app")
        XCTAssertEqual(run("/usr/bin/ditto", [installed.path, new.path]).status, 0)
        func command(_ token: String, version: String) -> String {
            UpdateInstall.rootCommand(newApp: new.path, target: target.path, staging: folder.appendingPathComponent("Applications/" + UpdateInstall.stagingPrefix + token).path,
                                      requirement: UpdateInstall.requirement(), version: version)
        }

        try app(at: target, saying: "old")
        XCTAssertNotEqual(shell(command("T1", version: version + ".1")), 0, "the right app under the wrong version")
        XCTAssertEqual(which(target), "old")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"])

        // A set-user-ID bit on the download doesn't come along (and doesn't break the signature either).
        let binary = "Contents/MacOS/Schema"
        try fm.setAttributes([.posixPermissions: 0o6755], ofItemAtPath: new.appendingPathComponent(binary).path)
        XCTAssertEqual(shell(command("T2", version: version)), 0)
        XCTAssertNil(which(target), "the released app is in place")
        XCTAssertEqual(run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R=" + UpdateInstall.requirement(), target.path]).status, 0)
        XCTAssertEqual((try fm.attributesOfItem(atPath: target.appendingPathComponent(binary).path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"])

        // Changed after it was signed: refused, and the app that is there stays.
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: new.appendingPathComponent(binary).path)
        try "extra".write(to: new.appendingPathComponent("Contents/Resources/extra.txt"), atomically: true, encoding: .utf8)
        remove(target)
        try app(at: target, saying: "old")
        XCTAssertNotEqual(shell(command("T3", version: version)), 0)
        XCTAssertEqual(which(target), "old")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"])
    }

    private func shell(_ command: String) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", command]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    /// The command itself, run here by /bin/sh as the user running the tests, on folders that stand in for the
    /// apps. An update that isn't signed by us fails its check, so this is the way out every failure takes.
    func testTheCommandLeavesTheAppAloneWhenTheUpdateFailsItsCheck() throws {
        try app(at: target, saying: "old")
        let new = try app(at: folder.appendingPathComponent("Download/Maben Schema.app"), saying: "not ours")
        try "<plist version=\"1.0\"><dict><key>CFBundleShortVersionString</key><string>1.2</string></dict></plist>"
            .write(to: new.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let staging = folder.appendingPathComponent("Applications/" + UpdateInstall.stagingPrefix + "TEST")
        let command = UpdateInstall.rootCommand(newApp: new.path, target: target.path, staging: staging.path, requirement: UpdateInstall.requirement(), version: "1.2")
        XCTAssertNotEqual(shell(command), 0, "an app that isn't signed by us is not installed")
        XCTAssertEqual(which(target), "old")
        XCTAssertEqual(besideTheApp, ["Maben Schema.app"], "its folder is removed again")

        // The folder is already there (someone made it first, to get at what goes into it): refused before anything.
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        try "theirs".write(to: staging.appendingPathComponent("planted"), atomically: true, encoding: .utf8)
        XCTAssertNotEqual(shell(command), 0)
        XCTAssertEqual(which(target), "old")
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: staging.path), ["planted"], "nothing was copied into a folder someone else made, and it isn't removed")

        // And the folder it makes is for its owner only, from the moment it is there.
        remove(staging)
        XCTAssertEqual(shell("/bin/mkdir -m 700 '\(staging.path)'"), 0)
        XCTAssertEqual((try fm.attributesOfItem(atPath: staging.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }
}
