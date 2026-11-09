import Foundation

/// One value of a MAPI property as stored in a TNEF property stream (MS-OXTNEF 2.1.3.4).
enum MAPIValue: Equatable {
    case integer(Int64)
    case boolean(Bool)
    case double(Double)
    case time(Date)
    /// PT_STRING8 (still in the message code page), PT_BINARY, PT_OBJECT and PT_CLSID.
    case bytes([UInt8])
    case unicode(String)
}

struct MAPIProperty: Equatable {
    let type: UInt16
    let id: UInt16
    /// Named properties (id >= 0x8000) are parsed so they can be skipped, but never used.
    let isNamed: Bool
    let values: [MAPIValue]
}

enum MAPIPropertyType {
    static let null: UInt16 = 0x0001
    static let short: UInt16 = 0x0002
    static let long: UInt16 = 0x0003
    static let float: UInt16 = 0x0004
    static let double: UInt16 = 0x0005
    static let currency: UInt16 = 0x0006
    static let appTime: UInt16 = 0x0007
    static let error: UInt16 = 0x000A
    static let boolean: UInt16 = 0x000B
    static let object: UInt16 = 0x000D
    static let int64: UInt16 = 0x0014
    static let string8: UInt16 = 0x001E
    static let unicode: UInt16 = 0x001F
    static let sysTime: UInt16 = 0x0040
    static let clsid: UInt16 = 0x0048
    static let binary: UInt16 = 0x0102
    static let multiValueFlag: UInt16 = 0x1000
}

enum MAPIPropertyID {
    static let subject: UInt16 = 0x0037
    static let clientSubmitTime: UInt16 = 0x0039
    static let sentRepresentingName: UInt16 = 0x0042
    static let senderName: UInt16 = 0x0C1A
    static let senderEmailAddress: UInt16 = 0x0C1F
    static let body: UInt16 = 0x1000
    static let rtfCompressed: UInt16 = 0x1009
    static let bodyHTML: UInt16 = 0x1013
    static let displayName: UInt16 = 0x3001
    static let attachDataObject: UInt16 = 0x3701
    static let attachFilename: UInt16 = 0x3704
    static let attachMethod: UInt16 = 0x3705
    static let attachLongFilename: UInt16 = 0x3707
    static let attachMimeTag: UInt16 = 0x370E
    static let attachContentID: UInt16 = 0x3712
    static let internetCodepage: UInt16 = 0x3FDE
}

/// Attachment method value for an embedded Outlook message (PidTagAttachMethod).
let attachMethodEmbeddedMessage: Int64 = 5
/// Attachment method value for an OLE object (PidTagAttachMethod).
let attachMethodOLE: Int64 = 6

struct MAPIPropertyList {
    var properties: [MAPIProperty] = []

    /// Parses a property stream. Stops at the first property it can't read and
    /// returns what it has so far, together with the error that stopped it.
    static func parse(_ bytes: [UInt8]) -> (MAPIPropertyList, TNEFError?) {
        var list = MAPIPropertyList()
        var reader = ByteReader(bytes)
        do {
            let count = try reader.u32()
            for _ in 0..<count {
                list.properties.append(try parseProperty(&reader))
            }
            return (list, nil)
        } catch let error as TNEFError {
            return (list, error)
        } catch {
            return (list, .invalid("\(error)"))
        }
    }

    private static func parseProperty(_ reader: inout ByteReader) throws -> MAPIProperty {
        let rawType = try reader.u16()
        let id = try reader.u16()
        let isNamed = id >= 0x8000
        if isNamed {
            try reader.skip(16) // property set GUID
            let kind = try reader.u32()
            switch kind {
            case 0: try reader.skip(4) // numeric id
            case 1:
                let nameLength = try reader.length()
                try reader.skip(nameLength)
                try reader.align4()
            default: throw TNEFError.invalid("unknown named property kind \(kind)")
            }
        }

        let isMultiValued = rawType & MAPIPropertyType.multiValueFlag != 0
        let baseType = rawType & ~MAPIPropertyType.multiValueFlag
        let values: [MAPIValue]
        if isVariableLength(baseType) {
            // Variable-length types always carry a value count, multi-valued or not.
            let count = try reader.u32()
            values = try (0..<count).map { _ in try readVariable(baseType, &reader) }
        } else if isMultiValued {
            let count = try reader.u32()
            values = try (0..<count).map { _ in try readFixed(baseType, &reader) }
        } else {
            values = [try readFixed(baseType, &reader)]
        }
        return MAPIProperty(type: baseType, id: id, isNamed: isNamed, values: values)
    }

    private static func isVariableLength(_ type: UInt16) -> Bool {
        [MAPIPropertyType.string8, MAPIPropertyType.unicode, MAPIPropertyType.binary, MAPIPropertyType.object].contains(type)
    }

    private static func readVariable(_ type: UInt16, _ reader: inout ByteReader) throws -> MAPIValue {
        let length = try reader.length()
        let data = try reader.read(length)
        try reader.align4()
        if type == MAPIPropertyType.unicode {
            return .unicode(TextDecoding.utf16LE(data))
        }
        return .bytes(data)
    }

    private static func readFixed(_ type: UInt16, _ reader: inout ByteReader) throws -> MAPIValue {
        switch type {
        case MAPIPropertyType.short:
            let value = try reader.u32() // stored padded to 4 bytes
            return .integer(Int64(Int16(truncatingIfNeeded: value)))
        case MAPIPropertyType.long, MAPIPropertyType.error:
            return .integer(Int64(Int32(bitPattern: try reader.u32())))
        case MAPIPropertyType.boolean:
            return .boolean(try reader.u32() & 0xFFFF != 0)
        case MAPIPropertyType.null, MAPIPropertyType.float:
            try reader.skip(4)
            return .integer(0)
        case MAPIPropertyType.double, MAPIPropertyType.appTime:
            return .double(Double(bitPattern: try reader.u64()))
        case MAPIPropertyType.currency, MAPIPropertyType.int64:
            return .integer(Int64(bitPattern: try reader.u64()))
        case MAPIPropertyType.sysTime:
            return .time(fileTimeToDate(try reader.u64()))
        case MAPIPropertyType.clsid:
            return .bytes(try reader.read(16))
        default:
            throw TNEFError.invalid(String(format: "unsupported MAPI property type 0x%04X", type))
        }
    }

    /// FILETIME counts 100 ns intervals since 1601-01-01 UTC.
    static func fileTimeToDate(_ fileTime: UInt64) -> Date {
        let secondsFrom1601To1970: Double = 11_644_473_600
        return Date(timeIntervalSince1970: Double(fileTime) / 10_000_000 - secondsFrom1601To1970)
    }

    // MARK: Lookup

    func first(_ id: UInt16) -> MAPIValue? {
        properties.first { !$0.isNamed && $0.id == id }?.values.first
    }

    func string(_ id: UInt16, codepage: Int) -> String? {
        switch first(id) {
        case let .unicode(text): return TextDecoding.trimNul(text)
        case let .bytes(data): return TextDecoding.decode(data, codepage: codepage)
        default: return nil
        }
    }

    func bytes(_ id: UInt16) -> [UInt8]? {
        if case let .bytes(data) = first(id) { return data }
        return nil
    }

    func integer(_ id: UInt16) -> Int64? {
        if case let .integer(value) = first(id) { return value }
        return nil
    }

    func date(_ id: UInt16) -> Date? {
        if case let .time(value) = first(id) { return value }
        return nil
    }
}
