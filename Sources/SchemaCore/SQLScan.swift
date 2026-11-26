import Foundation

/// Finds the statements that define structure (CREATE TABLE, ALTER TABLE) in SQL of any size, and steps over
/// everything else without looking inside it. A dump is mostly rows: hundreds of megabytes of INSERT or COPY
/// data around a handful of table definitions. Reading those rows as SQL is what makes an import slow, so
/// this works on the raw bytes and only keeps what the importer needs.
enum SQLScan {
    /// The kept statements, each ending in ";".
    static func structure(in buffer: UnsafeRawBufferPointer, isCancelled: () -> Bool = { false }) -> String {
        let n = buffer.count
        guard n > 0, let base = buffer.baseAddress else { return "" }
        let p = base.assumingMemoryBound(to: UInt8.self)
        // MySQL escapes quotes in text with a backslash and has # comments; the others don't.
        let mysql = looksLikeMySQL(p, min(n, 1 << 18))
        var out: [UInt8] = []
        var i = 0
        var seen = 0
        while i < n {
            i = skipBlank(p, n, i, mysql)
            if i >= n { break }
            // psql's own commands sit on a line of their own, without a ";". \connect switches database.
            if p[i] == 0x5C {
                let lineEnd = endOfLine(p, n, i)
                let line = String(decoding: UnsafeBufferPointer(start: p + i, count: lineEnd - i), as: UTF8.self)
                let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" }).map(String.init)
                if words.count >= 2, words[0] == "\\connect" || words[0] == "\\c" {
                    // \connect shop   or   \connect -reuse-previous=on "dbname='shop'"
                    var name = words.last(where: { !$0.hasPrefix("-") }) ?? ""
                    if let r = name.range(of: "dbname=") { name = String(name[r.upperBound...]) }
                    name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    if !name.isEmpty, name != "-" { out.append(contentsOf: Array("USE \"\(name)\";\n".utf8)) }
                }
                i = lineEnd + 1
                continue
            }
            let start = i
            let kind = classify(p, n, i)
            let end = endOfStatement(p, n, i, mysql)
            if kind == .structure {
                out.append(contentsOf: UnsafeBufferPointer(start: p + start, count: end - start))
                out.append(contentsOf: [0x3B, 0x0A])
            }
            i = end + 1
            // PostgreSQL: COPY … FROM stdin; is followed by the rows themselves, up to a line with just \.
            if kind == .copy, contains(p, start, end, "FROM STDIN") { i = endOfCopyData(p, n, i) }
            seen += 1
            if seen & 31 == 0, isCancelled() { break }
        }
        return String(decoding: out, as: UTF8.self)
    }

    private enum Kind { case structure, copy, other }

    private static func looksLikeMySQL(_ p: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        if memchr(p, 0x60, n) != nil { return true }   // a backtick
        return contains(p, 0, n, "/*!") || contains(p, 0, n, "ENGINE=")
    }

    /// Case-insensitive search for an upper-case ASCII needle in p[from..<to].
    private static func contains(_ p: UnsafePointer<UInt8>, _ from: Int, _ to: Int, _ needle: String) -> Bool {
        let want = Array(needle.utf8)
        guard to - from >= want.count else { return false }
        var i = from
        let last = to - want.count
        while i <= last {
            var j = 0
            while j < want.count {
                var c = p[i + j]
                if c >= 97, c <= 122 { c -= 32 }
                if c != want[j] { break }
                j += 1
            }
            if j == want.count { return true }
            i += 1
        }
        return false
    }

    private static func isSpace(_ c: UInt8) -> Bool { c == 32 || c == 10 || c == 13 || c == 9 || c == 12 }
    private static func isWord(_ c: UInt8) -> Bool { (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95 }

    private static func endOfLine(_ p: UnsafePointer<UInt8>, _ n: Int, _ i: Int) -> Int {
        guard i < n, let q = memchr(p + i, 0x0A, n - i) else { return n }
        return p.distance(to: q.assumingMemoryBound(to: UInt8.self))
    }

    private static func endOfBlockComment(_ p: UnsafePointer<UInt8>, _ n: Int, _ i: Int) -> Int {
        var j = i + 2
        while j < n {
            guard let q = memchr(p + j, 0x2A, n - j) else { return n }
            let k = p.distance(to: q.assumingMemoryBound(to: UInt8.self))
            if k + 1 < n, p[k + 1] == 0x2F { return k + 2 }
            j = k + 1
        }
        return n
    }

    /// Past white space and comments, to where a statement starts.
    private static func skipBlank(_ p: UnsafePointer<UInt8>, _ n: Int, _ start: Int, _ mysql: Bool) -> Int {
        var i = start
        while i < n {
            let c = p[i]
            if isSpace(c) || c == 0x3B { i += 1 }
            else if c == 0x2D, i + 1 < n, p[i + 1] == 0x2D { i = endOfLine(p, n, i) }
            else if c == 0x23, mysql { i = endOfLine(p, n, i) }
            // MySQL's /*!40101 … */ holds real statements, but never a table definition.
            else if c == 0x2F, i + 1 < n, p[i + 1] == 0x2A { i = endOfBlockComment(p, n, i) }
            else if c == 0xEF, i + 2 < n, p[i + 1] == 0xBB, p[i + 2] == 0xBF { i += 3 }   // byte order mark
            else { break }
        }
        return i
    }

    /// The word at i in upper case, and where it ends. Words longer than 16 letters aren't keywords.
    private static func word(_ p: UnsafePointer<UInt8>, _ n: Int, _ start: Int) -> (String, Int) {
        var i = start
        while i < n, isSpace(p[i]) { i += 1 }
        var bytes: [UInt8] = []
        while i < n, isWord(p[i]), bytes.count < 17 {
            let c = p[i]
            bytes.append(c >= 97 && c <= 122 ? c - 32 : c)
            i += 1
        }
        return (String(decoding: bytes, as: UTF8.self), i)
    }

    private static func classify(_ p: UnsafePointer<UInt8>, _ n: Int, _ i: Int) -> Kind {
        let (first, afterFirst) = word(p, n, i)
        switch first {
        case "CREATE":
            var at = afterFirst
            for _ in 0..<6 {
                let (w, next) = word(p, n, at)
                if w == "TABLE" || w == "DATABASE" || w == "SCHEMA" || w == "INDEX" { return .structure }
                guard ["TEMP", "TEMPORARY", "GLOBAL", "LOCAL", "UNLOGGED", "OR", "REPLACE", "FOREIGN", "UNIQUE", "CLUSTERED", "NONCLUSTERED"].contains(w) else { return .other }
                at = next
            }
            return .other
        case "ALTER":
            return word(p, n, afterFirst).0 == "TABLE" ? .structure : .other
        case "USE":
            return .structure
        case "COPY":
            return .copy
        default:
            return .other
        }
    }

    /// Just past a quoted run that opens at i. `doubled`: the quote character written twice stands for itself.
    private static func endOfQuoted(_ p: UnsafePointer<UInt8>, _ n: Int, _ i: Int, _ quote: UInt8, backslash: Bool) -> Int {
        var j = i + 1
        while j < n {
            guard let q = memchr(p + j, Int32(quote), n - j) else { return n }
            let k = p.distance(to: q.assumingMemoryBound(to: UInt8.self))
            if backslash {
                // An odd number of backslashes in front means this quote is escaped.
                var b = k - 1, slashes = 0
                while b > i, p[b] == 0x5C { slashes += 1; b -= 1 }
                if slashes % 2 == 1 { j = k + 1; continue }
            }
            if k + 1 < n, p[k + 1] == quote { j = k + 2; continue }
            return k + 1
        }
        return n
    }

    /// The index of the ";" that ends the statement starting at i (or the end of the text), not fooled by a
    /// ";" inside text, a quoted name, a comment or a $$ … $$ body.
    private static func endOfStatement(_ p: UnsafePointer<UInt8>, _ n: Int, _ start: Int, _ mysql: Bool) -> Int {
        var i = start
        while i < n {
            switch p[i] {
            case 0x3B:
                return i
            case 0x27:   // 'text'; PostgreSQL's E'…' uses backslashes too
                let escapes = mysql || (i > start && (p[i - 1] == 0x45 || p[i - 1] == 0x65))
                i = endOfQuoted(p, n, i, 0x27, backslash: escapes)
            case 0x22:
                i = endOfQuoted(p, n, i, 0x22, backslash: false)
            case 0x60:
                i = endOfQuoted(p, n, i, 0x60, backslash: false)
            case 0x2D where i + 1 < n && p[i + 1] == 0x2D:
                i = endOfLine(p, n, i)
            case 0x23 where mysql:
                i = endOfLine(p, n, i)
            case 0x2F where i + 1 < n && p[i + 1] == 0x2A:
                i = endOfBlockComment(p, n, i)
            case 0x24 where !mysql:   // $tag$ … $tag$
                var j = i + 1
                while j < n, isWord(p[j]) { j += 1 }
                guard j < n, p[j] == 0x24, !(j > i + 1 && p[i + 1] >= 48 && p[i + 1] <= 57) else { i += 1; continue }
                let length = j - i + 1
                var k = j + 1
                var close = n
                while k + length <= n {
                    guard let q = memchr(p + k, 0x24, n - k) else { break }
                    let at = p.distance(to: q.assumingMemoryBound(to: UInt8.self))
                    if at + length <= n, memcmp(p + at, p + i, length) == 0 { close = at + length; break }
                    k = at + 1
                }
                i = close
            default:
                i += 1
            }
        }
        return n
    }

    /// Past the rows after COPY … FROM stdin; to just after the line that holds only "\.".
    private static func endOfCopyData(_ p: UnsafePointer<UInt8>, _ n: Int, _ start: Int) -> Int {
        var i = start
        while i < n {
            let lineEnd = endOfLine(p, n, i)
            var end = lineEnd
            if end > i, p[end - 1] == 0x0D { end -= 1 }
            if end - i == 2, p[i] == 0x5C, p[i + 1] == 0x2E { return min(n, lineEnd + 1) }
            i = lineEnd + 1
        }
        return n
    }
}
