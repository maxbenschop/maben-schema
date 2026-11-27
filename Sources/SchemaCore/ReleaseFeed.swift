import Foundation

/// Reading the GitHub "latest release" answer. Kept here, without networking, so it is tested.
public enum ReleaseFeed {
    public static let repository = "maxbenschop/maben-schema"
    public static let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    /// The file in each release that installed copies update from.
    public static let assetName = "Maben-Schema.zip"

    public struct Release: Equatable, Sendable {
        public let version: String
        public let notes: String
        public let zip: URL
        /// The release's page on GitHub, or this repository's releases page when the answer named anything else.
        public let page: URL
    }

    /// Nil for anything that isn't a published release with the update file attached. The answer is believed
    /// only as far as it has to be: the file must be this repository's own release download on github.com, and
    /// the page that is opened in the browser is one on github.com, or else this repository's own releases page.
    /// (What is downloaded is checked again before it is installed; this keeps the app from fetching, or opening,
    /// anything from anywhere else at all.)
    public static func parse(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true,
              let assets = json["assets"] as? [[String: Any]],
              let asset = assets.first(where: { ($0["name"] as? String) == assetName }),
              let zip = (asset["browser_download_url"] as? String).flatMap(URL.init(string:)),
              isDownload(zip)
        else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        // A version is numbers with points between them. It is compared, shown, and checked against the app.
        guard !version.isEmpty, version.split(separator: ".", omittingEmptySubsequences: false)
            .allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy { ("0"..."9").contains($0) } }) else { return nil }
        let page = (json["html_url"] as? String).flatMap(URL.init(string:)).flatMap { isGitHubPage($0) ? $0 : nil } ?? releasesPage
        return Release(version: version, notes: (json["body"] as? String) ?? "", zip: zip, page: page)
    }

    public static let releasesPage = URL(string: "https://github.com/\(repository)/releases")!

    /// `https://github.com/<this repository>/releases/download/…`, and nothing that only looks like it.
    public static func isDownload(_ url: URL) -> Bool {
        isGitHubPage(url) && url.path.hasPrefix("/\(repository)/releases/download/") && !url.pathComponents.contains(".")
    }

    /// An `https` address on github.com itself: no other host, no name or password in front, no port but the
    /// usual one, no `..` on the way. The same check as Maben Awake's.
    public static func isGitHubPage(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com" && url.user == nil && url.password == nil
            && (url.port ?? 443) == 443 && !url.pathComponents.contains("..")
    }

    /// The notes of a release, with its Markdown shown as text with marks (bold, code, links). A link stays a
    /// link only when it goes to an `https` address; any other is the words it was on, and nothing to click.
    public static func formatted(notes: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(notes)
        }
        let unsafe = text.runs.filter { run in run.link.map { $0.scheme?.lowercased() != "https" || ($0.host ?? "").isEmpty } ?? false }.map(\.range)
        for range in unsafe { text[range].link = nil }
        return text
    }

    /// Numeric comparison of dotted versions: 1.10 > 1.9, 1.0.1 > 1.0.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
