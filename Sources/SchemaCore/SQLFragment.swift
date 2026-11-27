import Foundation

/// The pieces of the script that are written as they were typed: a column's type, its default, and the text of a
/// comment. Names are quoted (`SQLExport.quote`), so whatever is in a name stays a name. These three aren't, so
/// they are checked: a type and a default from a diagram someone else made must not be able to end the statement
/// they are in and start one of their own, and a comment must stay a comment.
enum SQLFragment {
    /// Text for after `--`: on one line, with nothing in it that isn't text. Every kind of line end counts
    /// (return, line feed, the two together, vertical tab, form feed, next line, the Unicode line and paragraph
    /// separators): a database reads what follows any of them as SQL again.
    /// `limit`: for a type or a default that is only shown to say it was left out, which can be any length. A
    /// definition is written whole.
    static func comment(_ s: String, limit: Int? = nil) -> String {
        var out = String.UnicodeScalarView()
        for u in s.split(whereSeparator: \.isNewline).joined(separator: " ").unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: out.append(" ")
            default: out.append(u)
            }
        }
        let text = String(out)
        guard let limit, text.count > limit else { return text }
        return String(text.prefix(limit)) + "…"
    }

    /// Whether a type can be written as it is: words, numbers, lengths in brackets, values in quotes
    /// (`VARCHAR(255)`, `NUMERIC(10,2)`, `TIMESTAMP WITH TIME ZONE`, `ENUM('new','paid')`, `TEXT[]`).
    static func isType(_ s: String, _ dialect: Dialect) -> Bool { wellFormed(s, asType: true, dialect) }

    /// Whether a default can be written as it is: one line, every quote and bracket closed, and nothing outside
    /// quotes that ends a statement or starts a comment (`0`, `'new'`, `now()`, `'{}'::jsonb`, `(1 + 2)`).
    static func isDefault(_ s: String, _ dialect: Dialect) -> Bool { wellFormed(s, asType: false, dialect) }

    /// The engines don't agree on what a quote is, so this only passes text they all read the same way:
    /// - `'…'` and `"…"` are quoted everywhere, with the quote doubled inside. A quote after an odd number of
    ///   backslashes ends the text for one engine and not for another (MySQL, PostgreSQL's `E'…'`): refused.
    /// - A backtick (a name in MySQL and SQLite), `$` (PostgreSQL's `$$…$$`) and a backslash outside quotes
    ///   could open a quote only some engines know: refused.
    /// - `[…]` is a name in SQL Server and SQLite and an array elsewhere, so there no quote may sit inside one.
    /// - `;`, `--`, `/*`, `*/` and `#` outside quotes end the statement or comment out the rest: refused.
    /// - A comma outside brackets would start the next column: refused.
    private static func wellFormed(_ text: String, asType: Bool, _ dialect: Dialect) -> Bool {
        let s = Array(text.unicodeScalars)
        let n = s.count
        let squareIsName = dialect == .sqlserver || dialect == .sqlite
        var open: [Unicode.Scalar] = []
        var i = 0
        func next(_ at: Int) -> Unicode.Scalar? { at + 1 < n ? s[at + 1] : nil }
        for u in s where u != "\t" {
            switch u.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: return false
            default: break
            }
        }
        while i < n {
            let c = s[i]
            switch c {
            case "'", "\"":
                if squareIsName, open.contains("[") { return false }
                var j = i + 1, slashes = 0, closed = false
                while j < n {
                    if s[j] == "\\" { slashes += 1; j += 1; continue }
                    if s[j] == c {
                        if slashes % 2 == 1 { return false }
                        if j + 1 < n, s[j + 1] == c { j += 2; slashes = 0; continue }
                        closed = true
                        break
                    }
                    slashes = 0
                    j += 1
                }
                guard closed else { return false }
                i = j + 1
                continue
            case "(", "[": open.append(c)
            case ")": guard open.popLast() == "(" else { return false }
            case "]": guard open.popLast() == "[" else { return false }
            case "<" where asType: open.append(c)
            case ">" where asType: guard open.popLast() == "<" else { return false }
            case ",": guard !open.isEmpty else { return false }
            case ";", "`", "\\", "$", "#": return false
            case "-":
                if next(i) == "-" { return false }
                // In a type only as the sign of a number: NUMERIC(10,-2).
                if asType, !(next(i).map { $0.properties.numericType != nil } ?? false) { return false }
            case "/":
                if asType || next(i) == "*" { return false }
            case "*":
                if next(i) == "/" { return false }
            default:
                if asType, !(c.properties.isAlphabetic || c.properties.numericType != nil || c == "_" || c == " " || c == "\t" || c == "." || c == "=") { return false }
            }
            i += 1
        }
        return open.isEmpty
    }
}
