import Compression
import Foundation

/// The little of ZIP an .asta file needs: one or a few entries, deflated.
enum Zip {
    struct Entry {
        var name: String
        var data: [UInt8]
    }

    enum ZipError: LocalizedError {
        case notAZip
        case damaged

        var errorDescription: String? {
            switch self {
            case .notAZip: "This isn't a ZIP file."
            case .damaged: "The ZIP file is damaged."
            }
        }
    }

    static func archive(_ entries: [Entry], date: Date = Date()) -> Data {
        var out: [UInt8] = []
        var directory: [UInt8] = []
        let (time, day) = dosTime(date)
        func u16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] }
        func u32(_ v: UInt32) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 24 & 0xFF)] }
        for e in entries {
            let name = Array(e.name.utf8)
            let packed = deflate(e.data)
            // Stored as it is when squeezing doesn't help (or didn't work).
            let method = packed != nil && packed!.count < e.data.count ? 8 : 0
            let body = method == 8 ? packed! : e.data
            let crc = crc32(e.data)
            let offset = UInt32(out.count)
            // Bit 11: the name is UTF-8.
            let common = u16(20) + u16(0x0800) + u16(method) + u16(time) + u16(day) + u32(crc) + u32(UInt32(body.count)) + u32(UInt32(e.data.count))
                + u16(name.count) + u16(0)
            out += u32(0x0403_4B50) + common + name + body
            directory += u32(0x0201_4B50) + u16(20) + common + u16(0) + u16(0) + u16(0) + u32(0) + u32(offset) + name
        }
        let start = UInt32(out.count)
        out += directory
        out += u32(0x0605_4B50) + u16(0) + u16(0) + u16(entries.count) + u16(entries.count) + u32(UInt32(directory.count)) + u32(start) + u16(0)
        return Data(out)
    }

    /// The entries of an archive, read from the local headers one after another.
    static func entries(of data: Data) throws -> [Entry] {
        let b = [UInt8](data)
        var p = 0
        var out: [Entry] = []
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        guard b.count >= 30, u32(0) == 0x0403_4B50 else { throw ZipError.notAZip }
        while p + 30 <= b.count, u32(p) == 0x0403_4B50 {
            let flags = u16(p + 6), method = u16(p + 8)
            var packed = u32(p + 18), size = u32(p + 22)
            let nameLength = u16(p + 26), extra = u16(p + 28)
            let start = p + 30 + nameLength + extra
            guard start <= b.count else { throw ZipError.damaged }
            let name = String(decoding: b[(p + 30)..<(p + 30 + nameLength)], as: UTF8.self)
            if flags & 0x08 != 0 {
                // The sizes come after the data (Java writes it this way): take them from the central directory.
                guard let found = central(b, name: name) else { throw ZipError.damaged }
                (packed, size) = found
            }
            guard start + packed <= b.count else { throw ZipError.damaged }
            let body = Array(b[start..<(start + packed)])
            switch method {
            case 0: out.append(Entry(name: name, data: body))
            case 8:
                guard let plain = inflate(body, size: size) else { throw ZipError.damaged }
                out.append(Entry(name: name, data: plain))
            default: throw ZipError.damaged
            }
            p = start + packed
            if flags & 0x08 != 0 { p += u32(p) == 0x0807_4B50 ? 16 : 12 }
        }
        return out
    }

    private static func central(_ b: [UInt8], name: String) -> (packed: Int, size: Int)? {
        func u16(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 }
        func u32(_ at: Int) -> Int { Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 }
        var p = 0
        let wanted = Array(name.utf8)
        while p + 46 <= b.count {
            if u32(p) == 0x0201_4B50 {
                let n = u16(p + 28)
                if p + 46 + n <= b.count, Array(b[(p + 46)..<(p + 46 + n)]) == wanted { return (u32(p + 20), u32(p + 24)) }
                p += 46 + n + u16(p + 30) + u16(p + 32)
            } else {
                p += 1
            }
        }
        return nil
    }

    // MARK: Deflate, CRC and the date

    static func deflate(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: data.count + 64)
        let n = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_ZLIB)
        return n > 0 ? Array(out[..<n]) : nil
    }

    static func inflate(_ data: [UInt8], size: Int) -> [UInt8]? {
        guard size > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: size)
        let n = compression_decode_buffer(&out, size, data, data.count, nil, COMPRESSION_ZLIB)
        return n == size ? out : nil
    }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data { c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func dosTime(_ date: Date) -> (time: Int, day: Int) {
        let c = Calendar(identifier: .gregorian).dateComponents(in: TimeZone.current, from: date)
        let year = max(1980, min(2107, c.year ?? 1980))
        return ((c.hour ?? 0) << 11 | (c.minute ?? 0) << 5 | (c.second ?? 0) / 2, (year - 1980) << 9 | (c.month ?? 1) << 5 | (c.day ?? 1))
    }
}
