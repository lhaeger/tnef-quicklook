import CoreFoundation
import Foundation

enum TextDecoding {
    static let defaultCodepage = 1252

    /// Decodes 8-bit text in the given Windows code page. Falls back to
    /// Windows-1252 and finally ISO Latin-1, which accepts every byte, so this
    /// never fails.
    static func decode(_ bytes: [UInt8], codepage: Int) -> String {
        let data = Data(bytes)
        for encoding in [encoding(forCodepage: codepage), .windowsCP1252, .isoLatin1].compactMap({ $0 }) {
            if let text = String(data: data, encoding: encoding) { return trimNul(text) }
        }
        return trimNul(String(decoding: bytes, as: UTF8.self))
    }

    static func utf16LE(_ bytes: [UInt8]) -> String {
        trimNul(String(data: Data(bytes), encoding: .utf16LittleEndian) ?? "")
    }

    /// Strict UTF-8 first (HTML bodies are usually UTF-8), then the message code page.
    static func decodePreferringUTF8(_ bytes: [UInt8], codepage: Int) -> String {
        if let text = String(data: Data(bytes), encoding: .utf8) { return trimNul(text) }
        return decode(bytes, codepage: codepage)
    }

    static func encoding(forCodepage codepage: Int) -> String.Encoding? {
        if codepage == 65001 { return .utf8 }
        let cfEncoding = CFStringConvertWindowsCodepageToEncoding(UInt32(truncatingIfNeeded: codepage))
        guard cfEncoding != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
    }

    /// Strings in TNEF are NUL-terminated; cut at the first NUL.
    static func trimNul(_ text: String) -> String {
        if let index = text.firstIndex(of: "\0") { return String(text[..<index]) }
        return text
    }
}
