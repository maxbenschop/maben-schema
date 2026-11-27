import Foundation

/// Putting a downloaded update in the app's place. Kept here, without the app around it, so it is tested: what
/// the new app must be signed as, the swap when the app's folder can be written to, and the one command that
/// runs as an administrator when it can't.
public enum UpdateInstall {
    public static let teamID = "NJTYRVLSA8"
    public static let bundleID = "gg.maben.schema"
    public static let appName = "Maben Schema.app"
    /// The new copy while it is checked, next to the app it will replace, and the old one while they change places.
    public static let stagedName = ".Maben Schema.update.app"
    public static let oldName = ".Maben Schema.old.app"
    /// The start of the folder the administrator's command makes for the same, with something random after it.
    public static let stagingPrefix = ".Maben Schema.update."

    /// What an update has to be signed as, in the words `codesign -R` and the Security framework both read:
    /// a Developer ID application certificate (not a development or an App Store one), of our team, with our
    /// bundle id, and notarized by Apple whatever this Mac's own Gatekeeper setting is. The app checks an update
    /// against this, and the administrator's command checks its own copy against the same text.
    public static func requirement(teamID: String = teamID, bundleID: String = bundleID) -> String {
        "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists"
            + " and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
            + " and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(bundleID)\" and notarized"
    }

    public struct Failure: LocalizedError, Equatable {
        public let message: String
        public init(_ message: String) { self.message = message }
        public var errorDescription: String? { message }
    }

    // MARK: When the app's folder can be written to

    /// Puts `newApp` in `target`'s place. The new app is copied next to the target under a hidden name, and
    /// `verify` is run on that copy: what was checked is what is installed, not what it was copied from. Then the
    /// two change places with two renames: the target steps aside, the copy takes its name. If the second rename
    /// doesn't work the old one goes back. Only when the new one is in place does the old one go to the Trash.
    /// After any failure the target is there, untouched, and the copy is gone.
    /// `move` and `discard` are how files are renamed and thrown away; a test passes its own to make one fail.
    public static func swap(target: URL, with newApp: URL, verify: (URL) throws -> Void,
                            move: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) },
                            discard: (URL) -> Void = UpdateInstall.discard) throws {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        let staged = folder.appendingPathComponent(stagedName), old = folder.appendingPathComponent(oldName)
        guard fm.fileExists(atPath: target.path) else { throw Failure("Couldn’t install the update: the app isn’t where it was.") }
        // Whatever an earlier try left behind.
        try? fm.removeItem(at: staged)
        try? fm.removeItem(at: old)
        do {
            try fm.copyItem(at: newApp, to: staged)
            try verify(staged)
        } catch {
            try? fm.removeItem(at: staged)
            throw error as? Failure ?? Failure("Couldn’t install the update: \(error.localizedDescription)")
        }
        do {
            try move(target, old)
        } catch {
            try? fm.removeItem(at: staged)
            throw Failure("Couldn’t install the update: \(error.localizedDescription)")
        }
        do {
            try move(staged, target)
        } catch {
            // Put the old one back before saying so. If even that fails, it is still there under its hidden name.
            let restored = (try? move(old, target)) != nil
            try? fm.removeItem(at: staged)
            throw Failure(restored ? "Couldn’t install the update: \(error.localizedDescription)"
                          : "Couldn’t install the update, and the app is now called “\(oldName)” in its folder. Rename it back to “\(target.lastPathComponent)”.")
        }
        discard(old)
    }

    /// To the Trash, so it can be put back by hand; deleted when that doesn't work. It gets a name without the
    /// leading dot first: the Finder doesn't show a hidden item in the Trash, which would then look empty and full
    /// at the same time.
    public static func discard(_ url: URL) {
        let fm = FileManager.default
        var item = url
        let visible = url.deletingLastPathComponent().appendingPathComponent(previousName(for: url))
        if visible.lastPathComponent != url.lastPathComponent, (try? fm.moveItem(at: url, to: visible)) != nil { item = visible }
        if (try? fm.trashItem(at: item, resultingItemURL: nil)) == nil { try? fm.removeItem(at: item) }
    }

    /// `.Maben Schema.old.app` becomes `Maben Schema (previous version).app`; any other name stays as it is.
    static func previousName(for old: URL) -> String {
        var name = old.deletingPathExtension().lastPathComponent
        guard name.hasPrefix("."), name.hasSuffix(".old") else { return old.lastPathComponent }
        name.removeFirst(); name.removeLast(4)
        return name + " (previous version)." + old.pathExtension
    }

    /// Takes away what an install that was cut short left next to the app. Called when the app starts.
    public static func cleanUp(beside target: URL) {
        let fm = FileManager.default
        let folder = target.deletingLastPathComponent()
        guard fm.fileExists(atPath: target.path) else { return }
        for name in (try? fm.contentsOfDirectory(atPath: folder.path)) ?? [] where name == oldName || name.hasPrefix(stagingPrefix) {
            // The administrator's folder is root's own and stays if this can't remove it; it is empty or holds a copy nobody can open.
            try? fm.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: When it can't: one command, run as an administrator

    /// A value inside single quotes for the shell: nothing in it is read as anything but itself.
    public static func quoted(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The command that installs an update into a folder only an administrator can write to. It runs as root, so
    /// it trusts nothing it was handed: what this app checked proves nothing to root, since the download is in a
    /// folder the user's other processes can write to. So root copies it into a folder of its own next to the app
    /// (made by root, for root only from the moment it exists, and refused if it is already there), checks that
    /// copy itself (signature, Gatekeeper, version), and only then lets it change places with the app, with two
    /// renames. If anything fails the folder is removed and the app is as it was.
    /// `staging`: the folder to make, next to the target; its name must be new every time. Every value is quoted
    /// for the shell. The same steps in the same order as Maben Awake's (`Updater.rootInstallCommand` there).
    public static func rootCommand(newApp: String, target: String, staging: String, requirement: String, version: String) -> String {
        let q = quoted
        return [
            "T=\(q(target))",
            "D=\(q(staging))",
            "S=\"$D\"/\(q(appName))",
            #"fail() { /bin/rm -rf "$D"; exit 1; }"#,
            // Not `fail`: a folder that was already there isn't ours to remove.
            #"/bin/mkdir -m 700 "$D" || exit 1"#,
            #"/usr/bin/ditto \#(q(newApp)) "$S" || fail"#,
            // The new app belongs to whoever owned the old one, so who can change the app stays who it was, and
            // it brings no set-user-ID bit of its own making: root's ditto keeps mode bits, and a signature
            // doesn't seal them.
            #"/usr/sbin/chown -R "$(/usr/bin/stat -f %u:%g "$T")" "$S" || fail"#,
            #"/bin/chmod -R ug-s "$S" || fail"#,
            #"/usr/bin/codesign --verify --deep --strict -R=\#(q(requirement)) "$S" || fail"#,
            #"/usr/sbin/spctl --assess --type execute "$S" || fail"#,
            #"[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$S/Contents/Info.plist")" = \#(q(version)) ] || fail"#,
            #"/bin/mv "$T" "$D/old.app" || fail"#,
            // The old one goes back before the folder goes; if it can't, it stays in the folder rather than be lost.
            #"/bin/mv "$S" "$T" || { /bin/mv "$D/old.app" "$T" && /bin/rm -rf "$D"; exit 1; }"#,
            #"/bin/rm -rf "$D""#,
            "exit 0",
        ].joined(separator: "\n")
    }

    /// The AppleScript that runs a shell command as an administrator, asking for the password once.
    public static func appleScript(running command: String, prompt: String) -> String {
        "do shell script \(appleScriptString(command)) with prompt \(appleScriptString(prompt)) with administrator privileges"
    }

    /// Text as an AppleScript string, quotes included: nothing in it can end the string and go on as script.
    public static func appleScriptString(_ s: String) -> String {
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(c)
            }
        }
        return out + "\""
    }
}
