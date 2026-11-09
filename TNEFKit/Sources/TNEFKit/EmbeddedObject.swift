/// Pulls the useful payload out of an OLE object attachment (attach method 6).
/// Outlook stores pictures pasted into rich-text mail this way; the picture
/// sits in the "CONTENTS" stream. Files inserted as objects are "Package"
/// objects whose "\u{1}Ole10Native" stream carries the original name and data.
enum EmbeddedObject {
    struct Payload: Equatable {
        var fileName: String?
        var data: [UInt8]
    }

    static func extract(_ bytes: [UInt8]) throws -> Payload? {
        let file = try CompoundFile(bytes)
        if let native = try file.stream(named: "\u{1}Ole10Native") {
            return parseNative(native)
        }
        if let contents = try file.stream(named: "CONTENTS"), !contents.isEmpty {
            return Payload(fileName: nil, data: contents)
        }
        if let package = try file.stream(named: "Package"), !package.isEmpty {
            return Payload(fileName: nil, data: package)
        }
        return nil
    }

    /// Ole10Native: total size, 2 unknown bytes, label, source path, 4 unknown
    /// bytes, temp path (length-prefixed), data (length-prefixed).
    static func parseNative(_ bytes: [UInt8]) -> Payload {
        var reader = ByteReader(bytes)
        do {
            _ = try reader.u32()
            _ = try reader.u16()
            let label = try reader.cString()
            _ = try reader.cString() // source path
            try reader.skip(4)
            let tempPathLength = try reader.length()
            try reader.skip(tempPathLength)
            let dataLength = try reader.length()
            let data = try reader.read(dataLength)
            let name = FileNames.sanitize(TextDecoding.decode(label, codepage: TextDecoding.defaultCodepage))
            return Payload(fileName: name.isEmpty ? nil : name, data: data)
        } catch {
            // Unknown layout: everything after the size prefix is the payload.
            return Payload(fileName: nil, data: Array(bytes.dropFirst(4)))
        }
    }
}

/// Recognises common file types by their first bytes.
public enum FileSniffer {
    public static func detect(_ data: some Collection<UInt8>) -> (mimeType: String, fileExtension: String)? {
        let head = Array(data.prefix(48))
        func starts(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            head.count >= offset + signature.count && Array(head[offset..<(offset + signature.count)]) == signature
        }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return ("image/png", "png") }
        if starts([0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
        if starts(Array("GIF8".utf8)) { return ("image/gif", "gif") }
        if starts(Array("BM".utf8)), head.count >= 14 { return ("image/bmp", "bmp") }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A]) { return ("image/tiff", "tif") }
        if starts([0x01, 0x00, 0x00, 0x00]), starts(Array(" EMF".utf8), at: 40) { return ("image/emf", "emf") }
        if starts([0xD7, 0xCD, 0xC6, 0x9A]) { return ("image/wmf", "wmf") }
        if starts(Array("%PDF-".utf8)) { return ("application/pdf", "pdf") }
        return nil
    }
}

extension ByteReader {
    /// Reads bytes up to and including a NUL terminator; returns them without the NUL.
    mutating func cString() throws -> [UInt8] {
        var result: [UInt8] = []
        while true {
            let byte = try u8()
            if byte == 0 { return result }
            result.append(byte)
        }
    }
}
