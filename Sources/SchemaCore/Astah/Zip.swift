import Compression
import Foundation

/// The little of ZIP an .asta file and a workbook need: a few entries, deflated. Written here, and read back from
/// files that come from anywhere.
enum Zip {
    struct Entry {
        var name: String
        var data: [UInt8]
    }

    enum ZipError: LocalizedError {
        case notAZip
        case damaged
        /// More entries, or more in them once unpacked, than `Limits` allows.
        case tooLarge

        var errorDescription: String? {
            switch self {
            case .notAZip: "This isn't a ZIP file."
            case .damaged: "The ZIP file is damaged."
            case .tooLarge: "The ZIP file holds more than can be read."
            }
        }
    }

    /// How much of an archive is read. A ZIP says itself how large its entries are, and a few thousand bytes can
    /// unpack to gigabytes, so what it says is not believed: unpacking stops at these.
    struct Limits {
        var entries = 4096
        /// One entry, unpacked.
        var entrySize = 64 << 20
        /// Every entry that is read, unpacked, together.
        var totalSize = 192 << 20
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

    /// The entries of an archive, read from the local headers one after another. `wanted`: the names to unpack;
    /// the others are stepped over. Every number in the file is checked against the file before it is used.
    static func entries(of data: Data, limits: Limits = Limits(), wanted: (String) -> Bool = { _ in true }) throws -> [Entry] {
        let b = [UInt8](data)
        var p = 0
        var out: [Entry] = []
        var seen = 0, total = 0
        // Read where the file has them; nil past its end.
        func u16(_ at: Int) -> Int? { at >= 0 && at + 2 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 : nil }
        func u32(_ at: Int) -> Int? {
            at >= 0 && at + 4 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 : nil
        }
        guard u32(0) == 0x0403_4B50, b.count >= 30 else { throw ZipError.notAZip }
        // The sizes of entries that only say them afterwards, from the list at the end; read once, when first needed.
        var directory: [String: (packed: Int, size: Int)]?
        while p + 30 <= b.count, u32(p) == 0x0403_4B50 {
            seen += 1
            guard seen <= limits.entries else { throw ZipError.tooLarge }
            guard let flags = u16(p + 6), let method = u16(p + 8), var packed = u32(p + 18), var size = u32(p + 22),
                  let nameLength = u16(p + 26), let extra = u16(p + 28) else { throw ZipError.damaged }
            let start = p + 30 + nameLength + extra
            guard start <= b.count else { throw ZipError.damaged }
            let name = String(decoding: b[(p + 30)..<(p + 30 + nameLength)], as: UTF8.self)
            let late = flags & 0x08 != 0
            if late {
                // The sizes come after the data (Java writes it this way): take them from the central directory.
                if directory == nil { directory = central(b) }
                guard let found = directory?[name] else { throw ZipError.damaged }
                (packed, size) = found
            }
            guard packed <= b.count - start else { throw ZipError.damaged }
            let end = start + packed
            if wanted(name) {
                let room = min(limits.entrySize, limits.totalSize - total)
                switch method {
                case 0:
                    guard packed <= room else { throw ZipError.tooLarge }
                    out.append(Entry(name: name, data: Array(b[start..<end])))
                case 8:
                    let plain = try inflate(b[start..<end], limit: room)
                    // What it unpacks to is what counts; an entry that says something else is damaged.
                    guard plain.count == size else { throw ZipError.damaged }
                    out.append(Entry(name: name, data: plain))
                default: throw ZipError.damaged
                }
                total += out[out.count - 1].data.count
            }
            p = end
            // The sizes again, with or without a mark of their own in front.
            if late { p += u32(p) == 0x0807_4B50 ? 16 : 12 }
        }
        return out
    }

    /// The central directory: every entry's name with its packed and unpacked size. Found from the record at the
    /// end of the file and read in one pass. Empty when the file has none that can be read.
    private static func central(_ b: [UInt8]) -> [String: (packed: Int, size: Int)] {
        func u16(_ at: Int) -> Int? { at >= 0 && at + 2 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 : nil }
        func u32(_ at: Int) -> Int? {
            at >= 0 && at + 4 <= b.count ? Int(b[at]) | Int(b[at + 1]) << 8 | Int(b[at + 2]) << 16 | Int(b[at + 3]) << 24 : nil
        }
        // The end record is the last 22 bytes, or earlier by the length of a comment (65,535 at most).
        var end = b.count - 22
        let earliest = max(0, b.count - 22 - 0xFFFF)
        while end >= earliest, u32(end) != 0x0605_4B50 { end -= 1 }
        guard end >= earliest, end >= 0, let count = u16(end + 10), var p = u32(end + 16) else { return [:] }
        var out: [String: (packed: Int, size: Int)] = [:]
        for _ in 0..<count {
            guard u32(p) == 0x0201_4B50, let packed = u32(p + 20), let size = u32(p + 24),
                  let n = u16(p + 28), let extra = u16(p + 30), let comment = u16(p + 32), p + 46 + n <= b.count else { break }
            let name = String(decoding: b[(p + 46)..<(p + 46 + n)], as: UTF8.self)
            // The first of a name is the one the local headers are matched with.
            if out[name] == nil { out[name] = (packed, size) }
            p += 46 + n + extra + comment
        }
        return out
    }

    // MARK: Deflate, CRC and the date

    static func deflate(_ data: [UInt8]) -> [UInt8]? {
        guard !data.isEmpty else { return [] }
        var out = [UInt8](repeating: 0, count: data.count + 64)
        let n = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_ZLIB)
        return n > 0 ? Array(out[..<n]) : nil
    }

    /// Unpacks deflated bytes a piece at a time, and stops with `tooLarge` as soon as there is more than `limit`:
    /// nothing is set aside on the word of the file.
    static func inflate(_ data: ArraySlice<UInt8>, limit: Int) throws -> [UInt8] {
        guard !data.isEmpty else { return [] }
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { throw ZipError.damaged }
        defer { compression_stream_destroy(stream) }
        let piece = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: piece)
        var out: [UInt8] = []
        return try data.withUnsafeBufferPointer { source -> [UInt8] in
            guard let from = source.baseAddress else { return [] }
            stream.pointee.src_ptr = from
            stream.pointee.src_size = source.count
            while true {
                let status: compression_status = buffer.withUnsafeMutableBufferPointer { room in
                    stream.pointee.dst_ptr = room.baseAddress!
                    stream.pointee.dst_size = piece
                    return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                }
                let made = piece - stream.pointee.dst_size
                guard made <= limit - out.count else { throw ZipError.tooLarge }
                out.append(contentsOf: buffer[..<made])
                if status == COMPRESSION_STATUS_END { return out }
                // Not at its end, yet nothing left to read and nothing made: it was cut short.
                guard status == COMPRESSION_STATUS_OK, made > 0 || stream.pointee.src_size > 0 else { throw ZipError.damaged }
            }
        }
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
