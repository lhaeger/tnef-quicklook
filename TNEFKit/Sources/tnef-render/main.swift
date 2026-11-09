import Foundation
import TNEFKit
import TNEFRender

// Writes the Quick Look preview page for a winmail.dat as a standalone HTML
// file (cid: resources inlined as data: URLs) for checking in a browser.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: tnef-render <winmail.dat> <output.html>\n".utf8))
    exit(2)
}

do {
    let input = URL(fileURLWithPath: arguments[1])
    let message = try TNEFParser.parse(try Data(contentsOf: input))
    let page = PreviewRenderer().render(message, fileName: input.lastPathComponent)
    var html = page.html
    for (key, resource) in page.resources {
        let dataURL = "data:\(resource.contentType.preferredMIMEType ?? "application/octet-stream");base64,\(resource.data.base64EncodedString())"
        html = html.replacingOccurrences(of: "cid:\(key)\"", with: "\(dataURL)\"")
    }
    try Data(html.utf8).write(to: URL(fileURLWithPath: arguments[2]))
} catch {
    FileHandle.standardError.write(Data("tnef-render: \(error)\n".utf8))
    exit(1)
}
