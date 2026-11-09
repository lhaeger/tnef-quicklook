import Foundation

public enum TNEFError: Error, Equatable, CustomStringConvertible {
    /// The data does not start with the TNEF signature 0x223E9F78.
    case notTNEF
    /// A structure claims more bytes than the input has left.
    case truncated(offset: Int, needed: Int)
    /// A structure is present but its content can't be interpreted.
    case invalid(String)

    public var description: String {
        switch self {
        case .notTNEF: "not a TNEF (winmail.dat) file"
        case let .truncated(offset, needed): "data truncated at offset \(offset) (needed \(needed) more bytes)"
        case let .invalid(reason): "invalid TNEF data: \(reason)"
        }
    }
}

public struct TNEFAttachment: Sendable, Equatable {
    /// Best available file name: long file name, display name, then the 8.3 title.
    public var fileName: String
    public var mimeType: String?
    public var contentID: String?
    public var data: Data
    /// True when the attachment is an embedded Outlook message rather than a file.
    public var isEmbeddedMessage: Bool

    public init(fileName: String, mimeType: String? = nil, contentID: String? = nil, data: Data, isEmbeddedMessage: Bool = false) {
        self.fileName = fileName
        self.mimeType = mimeType
        self.contentID = contentID
        self.data = data
        self.isEmbeddedMessage = isEmbeddedMessage
    }
}

public struct TNEFMessage: Sendable, Equatable {
    public var subject: String?
    public var sender: String?
    public var dateSent: Date?
    public var messageClass: String?
    /// HTML body (PR_BODY_HTML / PR_HTML), decoded to text.
    public var htmlBody: String?
    /// Decompressed RTF body (PR_RTF_COMPRESSED).
    public var rtfBody: Data?
    /// Plain text body (PR_BODY or the legacy attBody attribute).
    public var plainBody: String?
    public var attachments: [TNEFAttachment] = []
    /// Problems that did not stop parsing, such as checksum mismatches or truncation.
    public var warnings: [String] = []

    public init() {}
}
