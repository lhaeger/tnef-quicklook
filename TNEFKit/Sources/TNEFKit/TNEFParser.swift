import Foundation

/// Parser for TNEF streams (winmail.dat, application/ms-tnef) following MS-OXTNEF.
public enum TNEFParser {
    static let signature: UInt32 = 0x223E_9F78

    enum Level {
        static let message: UInt8 = 1
        static let attachment: UInt8 = 2
    }

    enum Attribute {
        static let from: UInt32 = 0x0000_8000
        static let subject: UInt32 = 0x0001_8004
        static let dateSent: UInt32 = 0x0003_8005
        static let body: UInt32 = 0x0002_800C
        static let messageProperties: UInt32 = 0x0006_9003
        static let oemCodepage: UInt32 = 0x0006_9007
        static let messageClass: UInt32 = 0x0007_8008
        static let attachRenderData: UInt32 = 0x0006_9002
        static let attachTitle: UInt32 = 0x0001_8010
        static let attachData: UInt32 = 0x0006_800F
        static let attachment: UInt32 = 0x0006_9005
    }

    /// Cheap check of the first four bytes.
    public static func looksLikeTNEF(_ data: Data) -> Bool {
        var reader = ByteReader(Array(data.prefix(4)))
        return (try? reader.u32()) == signature
    }

    /// Parses a TNEF stream. Throws `TNEFError.notTNEF` when the signature is
    /// missing. Damage after the header (truncation, bad checksums, unreadable
    /// property streams) does not throw; whatever was readable is returned and
    /// the problem is listed in `warnings`.
    public static func parse(_ data: Data) throws -> TNEFMessage {
        var reader = ByteReader([UInt8](data))
        guard (try? reader.u32()) == signature else { throw TNEFError.notTNEF }
        _ = try reader.u16() // legacy key, unused

        var state = ParseState()
        while !reader.isAtEnd {
            do {
                try readAttribute(&reader, into: &state)
            } catch {
                state.warn("stopped reading: \(error)")
                break
            }
        }
        return state.finish()
    }

    private static func readAttribute(_ reader: inout ByteReader, into state: inout ParseState) throws {
        let level = try reader.u8()
        let id = try reader.u32()
        let length = try reader.length()
        let data = try reader.read(length)
        let checksum = try reader.u16()
        let computed = UInt16(truncatingIfNeeded: data.reduce(0) { $0 &+ UInt32($1) })
        if checksum != computed {
            state.warn(String(format: "checksum mismatch in attribute 0x%08X", id))
        }

        switch (level, id) {
        case (Level.message, Attribute.subject): state.subject = data
        case (Level.message, Attribute.from): state.from = data
        case (Level.message, Attribute.dateSent): state.dateSent = data
        case (Level.message, Attribute.body): state.legacyBody = data
        case (Level.message, Attribute.messageClass): state.messageClass = data
        case (Level.message, Attribute.oemCodepage):
            var codepageReader = ByteReader(data)
            if let codepage = try? codepageReader.u32(), codepage != 0 { state.codepage = Int(codepage) }
        case (Level.message, Attribute.messageProperties):
            state.messageProperties = state.parseProperties(data, context: "message properties")
        case (Level.attachment, Attribute.attachRenderData):
            // RENDDATA: type (2 bytes), position (4 bytes), width, height, flags
            var renderData = ByteReader(data, offset: 2)
            state.attachments.append(PendingAttachment(renderPosition: try? renderData.u32()))
        case (Level.attachment, Attribute.attachTitle):
            state.updateCurrentAttachment { $0.title = data }
        case (Level.attachment, Attribute.attachData):
            state.updateCurrentAttachment { $0.data = data }
        case (Level.attachment, Attribute.attachment):
            let properties = state.parseProperties(data, context: "attachment properties")
            state.updateCurrentAttachment { $0.properties = properties }
        default:
            break // other attributes are not needed for a preview
        }
    }
}

private struct PendingAttachment {
    var title: [UInt8]?
    var data: [UInt8]?
    var properties = MAPIPropertyList()
    var renderPosition: UInt32?
}

private struct ParseState {
    var codepage = TextDecoding.defaultCodepage
    var subject: [UInt8]?
    var from: [UInt8]?
    var dateSent: [UInt8]?
    var legacyBody: [UInt8]?
    var messageClass: [UInt8]?
    var messageProperties = MAPIPropertyList()
    var attachments: [PendingAttachment] = []
    var warnings: [String] = []

    mutating func warn(_ message: String) {
        // A badly damaged file could produce one warning per attribute; keep the list readable.
        if warnings.count < 20 { warnings.append(message) }
    }

    mutating func parseProperties(_ data: [UInt8], context: String) -> MAPIPropertyList {
        let (list, error) = MAPIPropertyList.parse(data)
        if let error { warn("\(context): \(error)") }
        return list
    }

    /// Attachment attributes belong to the attachment opened by the last
    /// attAttachRenddata. Some writers omit it for the first attachment.
    mutating func updateCurrentAttachment(_ change: (inout PendingAttachment) -> Void) {
        if attachments.isEmpty { attachments.append(PendingAttachment()) }
        change(&attachments[attachments.count - 1])
    }

    mutating func finish() -> TNEFMessage {
        var message = TNEFMessage()
        let properties = messageProperties

        message.subject = properties.string(MAPIPropertyID.subject, codepage: codepage)
            ?? subject.map { TextDecoding.decode($0, codepage: codepage) }
        message.sender = senderFromProperties(properties) ?? from.flatMap(senderFromTriple)
        message.dateSent = properties.date(MAPIPropertyID.clientSubmitTime) ?? dateSent.flatMap(Self.dateFromDTR)
        message.messageClass = messageClass.map { TextDecoding.decode($0, codepage: codepage) }

        message.htmlBody = htmlBody(properties)
        if let compressed = properties.bytes(MAPIPropertyID.rtfCompressed) {
            do {
                message.rtfBody = Data(try CompressedRTF.decompress(compressed))
            } catch {
                warn("RTF body: \(error)")
            }
        }
        message.plainBody = properties.string(MAPIPropertyID.body, codepage: codepage)
            ?? legacyBody.map { TextDecoding.decode($0, codepage: codepage) }

        for (index, pending) in attachments.enumerated() {
            message.attachments.append(makeAttachment(pending, number: index + 1))
        }
        message.warnings = warnings
        return message
    }

    private func htmlBody(_ properties: MAPIPropertyList) -> String? {
        switch properties.first(MAPIPropertyID.bodyHTML) {
        case let .unicode(text):
            return TextDecoding.trimNul(text)
        case let .bytes(data):
            let htmlCodepage = properties.integer(MAPIPropertyID.internetCodepage).map(Int.init) ?? codepage
            return TextDecoding.decodePreferringUTF8(data, codepage: htmlCodepage)
        default:
            return nil
        }
    }

    private func senderFromProperties(_ properties: MAPIPropertyList) -> String? {
        let name = properties.string(MAPIPropertyID.sentRepresentingName, codepage: codepage)
            ?? properties.string(MAPIPropertyID.senderName, codepage: codepage)
        let address = properties.string(MAPIPropertyID.senderEmailAddress, codepage: codepage)
        return Self.formatSender(name: name, address: address)
    }

    /// attFrom holds a TRP structure: id, size, name length, address length, name, address.
    private func senderFromTriple(_ data: [UInt8]) -> String? {
        var reader = ByteReader(data)
        guard (try? reader.u16()) != nil, (try? reader.u16()) != nil,
              let nameLength = try? reader.u16(), let addressLength = try? reader.u16(),
              let name = try? reader.read(Int(nameLength))
        else { return nil }
        // the address follows the name, padded to a 4-byte boundary
        let address = (try? reader.align4()).flatMap { try? reader.read(Int(addressLength)) }
        return Self.formatSender(
            name: TextDecoding.decode(name, codepage: codepage),
            address: address.map { TextDecoding.decode($0, codepage: codepage) }
        )
    }

    static func formatSender(name: String?, address: String?) -> String? {
        let name = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        var address = address?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let current = address, current.uppercased().hasPrefix("SMTP:") {
            address = String(current.dropFirst(5))
        }
        // Exchange-internal addresses (EX:/o=...) mean nothing to the reader.
        if let current = address, !current.contains("@") { address = nil }
        switch (name, address) {
        case let (name?, address?) where name != address: return "\(name) <\(address)>"
        case let (name?, _): return name
        case let (nil, address?): return address
        default: return nil
        }
    }

    /// DTR: year, month, day, hour, minute, second, weekday (UInt16 each).
    static func dateFromDTR(_ data: [UInt8]) -> Date? {
        var reader = ByteReader(data)
        guard let parts = try? (0..<6).map({ _ in Int(try reader.u16()) }) else { return nil }
        var components = DateComponents()
        (components.year, components.month, components.day) = (parts[0], parts[1], parts[2])
        (components.hour, components.minute, components.second) = (parts[3], parts[4], parts[5])
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)
    }

    private mutating func makeAttachment(_ pending: PendingAttachment, number: Int) -> TNEFAttachment {
        let properties = pending.properties
        let isEmbedded = properties.integer(MAPIPropertyID.attachMethod) == attachMethodEmbeddedMessage

        var data = pending.data ?? []
        if pending.data == nil,
           let property = properties.properties.first(where: { !$0.isNamed && $0.id == MAPIPropertyID.attachDataObject }),
           case let .bytes(bytes)? = property.values.first {
            // PT_OBJECT values start with the 16-byte interface id
            data = property.type == MAPIPropertyType.object ? Array(bytes.dropFirst(16)) : bytes
        }

        let candidates = [
            properties.string(MAPIPropertyID.attachLongFilename, codepage: codepage),
            properties.string(MAPIPropertyID.attachFilename, codepage: codepage),
            properties.string(MAPIPropertyID.displayName, codepage: codepage),
            pending.title.map { TextDecoding.decode($0, codepage: codepage) },
        ]
        var name = candidates.lazy.compactMap { $0.map(FileNames.sanitize)?.nilIfEmpty }.first
            ?? "attachment-\(number)"
        var mimeType = properties.string(MAPIPropertyID.attachMimeTag, codepage: codepage)?.nilIfEmpty

        if properties.integer(MAPIPropertyID.attachMethod) == attachMethodOLE {
            (name, mimeType, data) = unwrapOLEObject(name: name, data: data)
        }

        // 0xFFFFFFFF (-1 as a signed MAPI long) means "not rendered in the body".
        let position = properties.integer(MAPIPropertyID.renderingPosition).map { Int(UInt32(truncatingIfNeeded: $0)) }
            ?? pending.renderPosition.map(Int.init)
        let renderingPosition = position == 0xFFFF_FFFF ? nil : position

        return TNEFAttachment(
            fileName: name,
            mimeType: mimeType,
            contentID: properties.string(MAPIPropertyID.attachContentID, codepage: codepage)?.nilIfEmpty,
            data: Data(data),
            isEmbeddedMessage: isEmbedded,
            renderingPosition: renderingPosition
        )
    }

    /// Replaces an OLE container with the picture or file inside it. If that
    /// isn't possible the container is kept, so nothing is lost.
    private mutating func unwrapOLEObject(name: String, data: [UInt8]) -> (String, String?, [UInt8]) {
        let fallback = (name, Optional("application/x-oleobject"), data)
        guard CompoundFile.isCompoundFile(data) else { return fallback }
        let payload: EmbeddedObject.Payload?
        do {
            payload = try EmbeddedObject.extract(data)
        } catch {
            warn("OLE object \"\(name)\": \(error)")
            return fallback
        }
        guard let payload else { return fallback }

        let detected = FileSniffer.detect(payload.data)
        var newName = payload.fileName ?? name
        if let detected, (newName as NSString).pathExtension.isEmpty {
            newName += ".\(detected.fileExtension)"
        }
        return (newName, detected?.mimeType, payload.data)
    }
}

enum FileNames {
    /// Keeps only the last path component and removes characters that are
    /// unsafe in file names.
    static func sanitize(_ name: String) -> String {
        let lastComponent = name.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        let cleaned = lastComponent.unicodeScalars
            .filter { $0.value >= 0x20 && $0 != ":" }
            .map(String.init).joined()
            .trimmingCharacters(in: .whitespaces)
        return cleaned == "." || cleaned == ".." ? "" : cleaned
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
