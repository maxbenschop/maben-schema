import Foundation

// An .asta file is a ZIP with one entry, `EntityStore`: a stream in Java's object serialization format (the
// "Java Object Serialization Specification", chapter 6). This file is that format and nothing about Astah:
// objects with the fields their classes declare, written so that Java reads them back.

/// A value a field or an array slot holds.
indirect enum JValue {
    case null
    case bool(Bool)
    case byte(Int8)
    case char(UInt16)
    case short(Int16)
    case int(Int32)
    case long(Int64)
    case float(Float)
    case double(Double)
    case string(String)
    case object(JObject)
    case array(JArray)

    var object: JObject? {
        if case .object(let o) = self { return o }
        return nil
    }
    var string: String? {
        if case .string(let s) = self { return s }
        return nil
    }
    var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// What a class writes after its fields when it has a `writeObject` of its own: raw bytes and objects, in turn.
enum JContent {
    case block([UInt8])
    case value(JValue)
}

struct JField {
    /// `B C D F I J S Z` for the primitives, `L` for an object, `[` for an array.
    let type: UInt8
    let name: String
    /// The field's type as Java writes it (`Ljava/util/List;`), for `L` and `[`.
    let signature: String?
    /// What the field holds in a file Astah saved, as written in `AstaClasses.table`.
    let preset: String
}

/// A class descriptor: what the stream says about a class before the first object of it.
final class JClass {
    let name: String
    let uid: Int64
    let flags: UInt8
    let superclass: JClass?
    let fields: [JField]
    /// The classes above this one, the topmost first.
    let ancestors: [JClass]
    /// Where each class in the chain (the ancestors, then this one) keeps its fields in an object's `slots`.
    let offsets: [Int]
    let slotCount: Int
    /// The last part of the name: `EREntityImp` for `JP.co.esm.caddies.er.EREntityImp`.
    let shortName: String
    private let slotByName: [String: Int]

    static let serializable: UInt8 = 0x02
    static let writeMethod: UInt8 = 0x01
    static let externalizable: UInt8 = 0x04

    init(name: String, uid: Int64, flags: UInt8, superclass: JClass?, fields: [JField]) {
        self.name = name
        shortName = String(name.split(separator: ".").last ?? Substring(name))
        self.uid = uid
        self.flags = flags
        self.superclass = superclass
        self.fields = fields
        ancestors = superclass.map { $0.ancestors + [$0] } ?? []
        let base = superclass?.slotCount ?? 0
        offsets = (superclass?.offsets ?? []) + [base]
        // A name declared again further down hides nothing here: the first, topmost declaration keeps it,
        // which is the field Astah reads (the ones below it are left empty).
        var byName = superclass?.slotByName ?? [:]
        for (i, f) in fields.enumerated() where byName[f.name] == nil { byName[f.name] = base + i }
        slotByName = byName
        slotCount = base + fields.count
    }

    /// How many classes write fields for an object of this class: the ancestors and this one.
    var depth: Int { ancestors.count + 1 }

    /// The class at a place in the chain, the topmost at 0: the order their fields are written in.
    func part(_ index: Int) -> JClass { index < ancestors.count ? ancestors[index] : self }

    func slot(_ field: String) -> Int? { slotByName[field] }

    func slot(_ field: String, declaredIn short: String) -> Int? {
        for i in 0..<depth where part(i).shortName == short {
            if let j = part(i).fields.firstIndex(where: { $0.name == field }) { return offsets[i] + j }
        }
        return nil
    }

    func isKind(of short: String) -> Bool { (0..<depth).contains { part($0).shortName == short } }
}

final class JObject {
    let cls: JClass
    var slots: [JValue]
    /// Extra data per class that writes its own (keyed by the class's full name).
    var annotations: [String: [JContent]] = [:]
    /// The elements, for `java.util.ArrayList` and `java.util.HashSet`; keys and values in turn for `java.util.HashMap`.
    var items: [JValue] = []

    init(_ cls: JClass) {
        self.cls = cls
        slots = [JValue](repeating: .null, count: cls.slotCount)
    }

    subscript(field: String) -> JValue {
        get { cls.slot(field).map { slots[$0] } ?? .null }
        set {
            guard let i = cls.slot(field) else { preconditionFailure("\(cls.name) has no field \(field)") }
            slots[i] = newValue
        }
    }

    func set(_ field: String, in short: String, _ value: JValue) {
        guard let i = cls.slot(field, declaredIn: short) else { preconditionFailure("\(short) has no field \(field)") }
        slots[i] = value
    }

    func get(_ field: String, in short: String) -> JValue {
        cls.slot(field, declaredIn: short).map { slots[$0] } ?? .null
    }

    /// Lets go of everything these objects point at. A model points back at itself all over (an entity at its
    /// attributes, each attribute at its entity), so without this it would never be freed.
    static func dismantle(_ objects: [JObject]) {
        for o in objects {
            o.slots = []
            o.items = []
            o.annotations = [:]
        }
    }
}

final class JArray {
    let cls: JClass
    var items: [JValue]

    init(_ cls: JClass, _ items: [JValue]) {
        self.cls = cls
        self.items = items
    }

    /// The type code of the elements: the second character of the array class's name (`[L…;`, `[I`).
    var elementType: UInt8 { Array(cls.name.utf8).dropFirst().first ?? UInt8(ascii: "L") }
}

enum JTag {
    static let null: UInt8 = 0x70, reference: UInt8 = 0x71, classDesc: UInt8 = 0x72, object: UInt8 = 0x73, string: UInt8 = 0x74
    static let array: UInt8 = 0x75, classRef: UInt8 = 0x76, blockData: UInt8 = 0x77, endBlockData: UInt8 = 0x78, reset: UInt8 = 0x79
    static let blockDataLong: UInt8 = 0x7A, longString: UInt8 = 0x7C
    static let baseHandle: Int32 = 0x7E0000
}

/// Java's own flavour of UTF-8: NUL takes two bytes, and a character outside the 16-bit range is written as its
/// two UTF-16 halves, three bytes each.
enum ModifiedUTF8 {
    static func encode(_ s: String) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count)
        for u in s.utf16 {
            switch u {
            case 0x0001...0x007F: out.append(UInt8(u))
            case 0x0000, 0x0080...0x07FF:
                out.append(0xC0 | UInt8(u >> 6))
                out.append(0x80 | UInt8(u & 0x3F))
            default:
                out.append(0xE0 | UInt8(u >> 12))
                out.append(0x80 | UInt8((u >> 6) & 0x3F))
                out.append(0x80 | UInt8(u & 0x3F))
            }
        }
        return out
    }

    static func decode(_ bytes: ArraySlice<UInt8>) -> String {
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count)
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let b = bytes[i]
            if b < 0x80 {
                units.append(UInt16(b)); i += 1
            } else if b & 0xE0 == 0xC0, i + 1 < bytes.endIndex {
                units.append(UInt16(b & 0x1F) << 6 | UInt16(bytes[i + 1] & 0x3F)); i += 2
            } else if i + 2 < bytes.endIndex {
                units.append(UInt16(b & 0x0F) << 12 | UInt16(bytes[i + 1] & 0x3F) << 6 | UInt16(bytes[i + 2] & 0x3F)); i += 3
            } else {
                break
            }
        }
        return String(decoding: units, as: UTF16.self)
    }
}

// MARK: Writing

/// Writes values as one stream. Nothing here calls itself: a diagram of a thousand tables is one long chain of
/// objects pointing at objects, far deeper than a thread's stack.
struct JavaStreamWriter {
    private(set) var bytes: [UInt8] = []
    private var objectHandles: [ObjectIdentifier: Int32] = [:]
    private var stringHandles: [String: Int32] = [:]
    private var next: Int32 = JTag.baseHandle

    private enum Step {
        case value(JValue, UInt8)
        case content(JContent)
        case classDesc(JClass?)
        case handle(ObjectIdentifier)
        case byte(UInt8)
        case fields(JObject, Int)
    }

    /// `header`: bytes that go straight after the stream's own four (Astah puts four of its own there).
    init(header: [UInt8] = []) {
        bytes = [0xAC, 0xED, 0x00, 0x05] + header
    }

    mutating func write(_ value: JValue) { run([.value(value, UInt8(ascii: "L"))]) }

    /// Ends what was written so far: handles start again, as Java's `reset()` does.
    mutating func reset() {
        bytes.append(JTag.reset)
        objectHandles.removeAll()
        stringHandles.removeAll()
        next = JTag.baseHandle
    }

    private mutating func newHandle() -> Int32 {
        defer { next += 1 }
        return next
    }

    private mutating func u16(_ v: Int) { bytes.append(UInt8(v >> 8 & 0xFF)); bytes.append(UInt8(v & 0xFF)) }
    private mutating func i32(_ v: Int32) {
        bytes.append(UInt8(truncatingIfNeeded: v >> 24)); bytes.append(UInt8(truncatingIfNeeded: v >> 16))
        bytes.append(UInt8(truncatingIfNeeded: v >> 8)); bytes.append(UInt8(truncatingIfNeeded: v))
    }
    private mutating func i64(_ v: Int64) { i32(Int32(truncatingIfNeeded: v >> 32)); i32(Int32(truncatingIfNeeded: v)) }
    private mutating func utf(_ s: String) { let b = ModifiedUTF8.encode(s); u16(b.count); bytes.append(contentsOf: b) }

    private mutating func reference(_ handle: Int32) { bytes.append(JTag.reference); i32(handle) }

    private mutating func string(_ s: String) {
        if let h = stringHandles[s] { reference(h); return }
        let encoded = ModifiedUTF8.encode(s)
        if encoded.count <= 0xFFFF {
            bytes.append(JTag.string)
            stringHandles[s] = newHandle()
            u16(encoded.count)
        } else {
            bytes.append(JTag.longString)
            stringHandles[s] = newHandle()
            i64(Int64(encoded.count))
        }
        bytes.append(contentsOf: encoded)
    }

    private mutating func block(_ data: [UInt8]) {
        var rest = data[...]
        repeat {
            let piece = rest.prefix(1024 * 1024)
            rest = rest.dropFirst(piece.count)
            if piece.count < 256 {
                bytes.append(JTag.blockData); bytes.append(UInt8(piece.count))
            } else {
                bytes.append(JTag.blockDataLong); i32(Int32(piece.count))
            }
            bytes.append(contentsOf: piece)
        } while !rest.isEmpty
    }

    private mutating func run(_ start: [Step]) {
        // What is still to write, the next thing last: whatever an object holds goes on top of what follows it.
        var stack = Array(start.reversed())
        while let step = stack.popLast() {
            switch step {
            case .byte(let b):
                bytes.append(b)
            case .handle(let id):
                objectHandles[id] = newHandle()
            case .content(.block(let data)):
                block(data)
            case .content(.value(let v)):
                stack.append(.value(v, UInt8(ascii: "L")))
            case .classDesc(nil):
                bytes.append(JTag.null)
            case .classDesc(let c?):
                if let h = objectHandles[ObjectIdentifier(c)] { reference(h); continue }
                bytes.append(JTag.classDesc)
                utf(c.name)
                i64(c.uid)
                objectHandles[ObjectIdentifier(c)] = newHandle()
                bytes.append(c.flags)
                u16(c.fields.count)
                for f in c.fields {
                    bytes.append(f.type)
                    utf(f.name)
                    if let signature = f.signature { string(signature) }
                }
                bytes.append(JTag.endBlockData)
                stack.append(.classDesc(c.superclass))
            case .fields(let o, let index):
                let c = o.cls.part(index)
                let base = o.cls.offsets[index]
                guard c.flags & JClass.writeMethod != 0 else {
                    for i in c.fields.indices.reversed() { stack.append(.value(o.slots[base + i], c.fields[i].type)) }
                    continue
                }
                let own = Self.contents(of: o, for: c)
                stack.append(.byte(JTag.endBlockData))
                for extra in own.annotation.reversed() { stack.append(.content(extra)) }
                for i in c.fields.indices.reversed() { stack.append(.value(own.fields?[i] ?? o.slots[base + i], c.fields[i].type)) }
            case .value(let v, let type):
                switch v {
                case .bool(let b): bytes.append(b ? 1 : 0)
                case .byte(let b): bytes.append(UInt8(bitPattern: b))
                case .char(let c): u16(Int(c))
                case .short(let s): u16(Int(UInt16(bitPattern: s)))
                case .int(let i): i32(i)
                case .long(let l): i64(l)
                case .float(let f): i32(Int32(bitPattern: f.bitPattern))
                case .double(let d): i64(Int64(bitPattern: d.bitPattern))
                case .null:
                    // An empty primitive field is its zero.
                    switch type {
                    case UInt8(ascii: "Z"), UInt8(ascii: "B"): bytes.append(0)
                    case UInt8(ascii: "C"), UInt8(ascii: "S"): u16(0)
                    case UInt8(ascii: "I"), UInt8(ascii: "F"): i32(0)
                    case UInt8(ascii: "J"), UInt8(ascii: "D"): i64(0)
                    default: bytes.append(JTag.null)
                    }
                case .string(let s):
                    string(s)
                case .array(let a):
                    if let h = objectHandles[ObjectIdentifier(a)] { reference(h); continue }
                    bytes.append(JTag.array)
                    // The length goes after the handle is taken.
                    let element = a.elementType
                    for item in a.items.reversed() { stack.append(.value(item, element)) }
                    stack.append(.value(.int(Int32(a.items.count)), UInt8(ascii: "I")))
                    stack.append(.handle(ObjectIdentifier(a)))
                    stack.append(.classDesc(a.cls))
                case .object(let o):
                    if let h = objectHandles[ObjectIdentifier(o)] { reference(h); continue }
                    bytes.append(JTag.object)
                    for i in (0..<o.cls.depth).reversed() { stack.append(.fields(o, i)) }
                    stack.append(.handle(ObjectIdentifier(o)))
                    stack.append(.classDesc(o.cls))
                }
            }
        }
    }

    /// What Java's own collections write: their size as a field, then their elements after it.
    private static func contents(of o: JObject, for c: JClass) -> (fields: [JValue]?, annotation: [JContent]) {
        func be(_ v: Int32) -> [UInt8] { [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: v >> Int32($0)) } }
        switch c.name {
        case "java.util.ArrayList":
            let n = Int32(o.items.count)
            return ([.int(n)], [.block(be(n))] + o.items.map { JContent.value($0) })
        case "java.util.HashMap":
            let n = o.items.count / 2
            var buckets = 16
            while Double(buckets) * 0.75 < Double(n) { buckets *= 2 }
            return ([.float(0.75), .int(Int32(Double(buckets) * 0.75))],
                    [.block(be(Int32(buckets)) + be(Int32(n)))] + o.items.map { JContent.value($0) })
        case "java.util.HashSet":
            let n = o.items.count
            var buckets = 16
            while Double(buckets) * 0.75 < Double(n) { buckets *= 2 }
            return (nil, [.block(be(Int32(buckets)) + be(Int32(bitPattern: Float(0.75).bitPattern)) + be(Int32(n)))] + o.items.map { JContent.value($0) })
        default:
            return (nil, o.annotations[c.name] ?? [])
        }
    }
}
