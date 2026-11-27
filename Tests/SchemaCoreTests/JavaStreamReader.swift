import Foundation
@testable import SchemaCore

// The reader for Java's object streams. Only the tests use it, to check what `JavaStreamWriter` wrote, so it
// lives with them and not in the app: it was written for streams this code made itself, not for files from
// anywhere, and nothing that ships reads an .asta file.

enum JavaStreamError: LocalizedError {
    case notAStream
    case damaged(String)

    var errorDescription: String? {
        switch self {
        case .notAStream: "This isn't a Java object stream."
        case .damaged(let what): "The object stream is damaged: \(what)."
        }
    }
}

/// Reads a stream back into objects. Classes are made from what the stream itself says about them, so it reads
/// any stream of plain serializable objects, whoever wrote it. Used to check what the writer wrote.
final class JavaStreamReader {
    private let b: [UInt8]
    private var p = 0
    private var handles: [Any] = []
    private(set) var header: [UInt8] = []
    /// Every object in the stream, in the order it was written.
    private(set) var objects: [JObject] = []

    init(_ data: [UInt8], headerLength: Int = 0) throws {
        b = data
        guard b.count >= 4 + headerLength, b[0] == 0xAC, b[1] == 0xED, b[2] == 0, b[3] == 5 else { throw JavaStreamError.notAStream }
        header = Array(b[4..<(4 + headerLength)])
        p = 4 + headerLength
    }

    /// The values written one after another, up to the end or a reset.
    func readAll() throws -> [JValue] {
        var out: [JValue] = []
        while p < b.count {
            if b[p] == JTag.reset { p += 1; handles.removeAll(); continue }
            out.append(try value(UInt8(ascii: "L")))
        }
        return out
    }

    private func need(_ n: Int) throws { if p + n > b.count { throw JavaStreamError.damaged("it ends early") } }
    private func u8() throws -> UInt8 { try need(1); defer { p += 1 }; return b[p] }
    private func u16() throws -> Int { try need(2); defer { p += 2 }; return Int(b[p]) << 8 | Int(b[p + 1]) }
    private func i32() throws -> Int32 {
        try need(4); defer { p += 4 }
        return Int32(bitPattern: UInt32(b[p]) << 24 | UInt32(b[p + 1]) << 16 | UInt32(b[p + 2]) << 8 | UInt32(b[p + 3]))
    }
    private func i64() throws -> Int64 {
        try need(8); defer { p += 8 }
        var v: UInt64 = 0
        for i in 0..<8 { v = v << 8 | UInt64(b[p + i]) }
        return Int64(bitPattern: v)
    }
    private func utf() throws -> String {
        let n = try u16()
        try need(n); defer { p += n }
        return ModifiedUTF8.decode(b[p..<(p + n)])
    }

    private func handle<T>(_ type: T.Type) throws -> T {
        let i = Int(try i32() - JTag.baseHandle)
        guard handles.indices.contains(i), let v = handles[i] as? T else { throw JavaStreamError.damaged("a reference points at nothing") }
        return v
    }

    private func classDesc() throws -> JClass? {
        let tag = try u8()
        switch tag {
        case JTag.null: return nil
        case JTag.reference: return try handle(JClass.self)
        case JTag.classDesc:
            let name = try utf(), uid = try i64()
            let slot = handles.count
            handles.append(0)
            let flags = try u8()
            var fields: [JField] = []
            for _ in 0..<(try u16()) {
                let type = try u8(), fieldName = try utf()
                var signature: String?
                if type == UInt8(ascii: "L") || type == UInt8(ascii: "[") { signature = try value(UInt8(ascii: "L")).string }
                fields.append(JField(type: type, name: fieldName, signature: signature, preset: ""))
            }
            _ = try annotation()
            let c = JClass(name: name, uid: uid, flags: flags, superclass: try classDesc(), fields: fields)
            handles[slot] = c
            return c
        default: throw JavaStreamError.damaged("a class was expected at byte \(p - 1)")
        }
    }

    private func annotation() throws -> [JContent] {
        var out: [JContent] = []
        while true {
            let tag = try u8()
            switch tag {
            case JTag.endBlockData: return out
            case JTag.blockData:
                let n = Int(try u8()); try need(n)
                out.append(.block(Array(b[p..<(p + n)]))); p += n
            case JTag.blockDataLong:
                let n = Int(try i32()); try need(n)
                out.append(.block(Array(b[p..<(p + n)]))); p += n
            default:
                p -= 1
                out.append(.value(try value(UInt8(ascii: "L"))))
            }
        }
    }

    private func value(_ type: UInt8) throws -> JValue {
        switch type {
        case UInt8(ascii: "Z"): return .bool(try u8() != 0)
        case UInt8(ascii: "B"): return .byte(Int8(bitPattern: try u8()))
        case UInt8(ascii: "C"): return .char(UInt16(try u16()))
        case UInt8(ascii: "S"): return .short(Int16(bitPattern: UInt16(try u16())))
        case UInt8(ascii: "I"): return .int(try i32())
        case UInt8(ascii: "J"): return .long(try i64())
        case UInt8(ascii: "F"): return .float(Float(bitPattern: UInt32(bitPattern: try i32())))
        case UInt8(ascii: "D"): return .double(Double(bitPattern: UInt64(bitPattern: try i64())))
        default: break
        }
        let tag = try u8()
        switch tag {
        case JTag.null: return .null
        case JTag.reference:
            let i = Int(try i32() - JTag.baseHandle)
            guard handles.indices.contains(i) else { throw JavaStreamError.damaged("a reference points at nothing") }
            switch handles[i] {
            case let s as String: return .string(s)
            case let o as JObject: return .object(o)
            case let a as JArray: return .array(a)
            default: throw JavaStreamError.damaged("a reference points at a class")
            }
        case JTag.string:
            let s = try utf()
            handles.append(s)
            return .string(s)
        case JTag.longString:
            let n = Int(try i64()); try need(n)
            let s = ModifiedUTF8.decode(b[p..<(p + n)]); p += n
            handles.append(s)
            return .string(s)
        case JTag.array:
            guard let c = try classDesc() else { throw JavaStreamError.damaged("an array without a class") }
            let a = JArray(c, [])
            handles.append(a)
            let n = Int(try i32()), element = a.elementType
            a.items.reserveCapacity(n)
            for _ in 0..<n { a.items.append(try value(element)) }
            return .array(a)
        case JTag.object:
            guard let c = try classDesc() else { throw JavaStreamError.damaged("an object without a class") }
            let o = JObject(c)
            handles.append(o)
            objects.append(o)
            for i in 0..<c.depth {
                let part = c.part(i)
                guard part.flags & JClass.externalizable == 0 else { throw JavaStreamError.damaged("\(part.name) writes itself in a way this reader doesn't know") }
                for (j, f) in part.fields.enumerated() { o.slots[c.offsets[i] + j] = try value(f.type) }
                if part.flags & JClass.writeMethod != 0 {
                    let extra = try annotation()
                    o.annotations[part.name] = extra
                    // Java's collections: what follows the sizes are the elements.
                    if ["java.util.ArrayList", "java.util.HashMap", "java.util.HashSet"].contains(part.name) {
                        o.items = extra.compactMap { if case .value(let v) = $0 { v } else { nil } }
                    }
                }
            }
            return .object(o)
        default:
            throw JavaStreamError.damaged("an unknown mark \(tag) at byte \(p - 1)")
        }
    }
}
