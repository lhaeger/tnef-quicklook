import Foundation
import TNEFKit

// Writes the attachments (and body) of a winmail.dat into a directory, the same
// way `tnef -C <dir> --save-body` does, so the two can be compared.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: tnef-extract <winmail.dat> <output-dir>\n".utf8))
    exit(2)
}

do {
    let input = URL(fileURLWithPath: arguments[1])
    let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
    let message = try TNEFParser.parse(try Data(contentsOf: input))
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    for attachment in message.attachments {
        try attachment.data.write(to: output.appendingPathComponent(attachment.fileName), options: .withoutOverwriting)
    }
    if let html = message.htmlBody {
        try Data(html.utf8).write(to: output.appendingPathComponent("message.html"), options: .withoutOverwriting)
    } else if let rtf = message.rtfBody {
        try rtf.write(to: output.appendingPathComponent("message.rtf"), options: .withoutOverwriting)
    } else if let plain = message.plainBody {
        try Data(plain.utf8).write(to: output.appendingPathComponent("message.txt"), options: .withoutOverwriting)
    }

    print("subject: \(message.subject ?? "-")")
    print("sender:  \(message.sender ?? "-")")
    print("date:    \(message.dateSent.map { ISO8601DateFormatter().string(from: $0) } ?? "-")")
    for attachment in message.attachments {
        let kind = attachment.isEmbeddedMessage ? "embedded message" : (attachment.mimeType ?? "unknown type")
        print("attachment: \(attachment.fileName) (\(attachment.data.count) bytes, \(kind))")
    }
    for warning in message.warnings { print("warning: \(warning)") }
} catch {
    FileHandle.standardError.write(Data("tnef-extract: \(error)\n".utf8))
    exit(1)
}
