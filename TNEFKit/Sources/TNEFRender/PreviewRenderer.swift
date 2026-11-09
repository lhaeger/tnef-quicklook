import AppKit
import Foundation
import ImageIO
import TNEFKit
import UniformTypeIdentifiers

/// HTML page plus the resources it references with `cid:` URLs. The Quick Look
/// extension turns `resources` into QLPreviewReply attachments.
public struct RenderedPreview {
    public struct Resource {
        public let data: Data
        public let contentType: UTType
    }

    public var title: String
    public var html: String
    public var resources: [String: Resource]
}

public struct PreviewRenderer {
    /// Larger images are shown as an icon instead of being decoded.
    var maxImageBytes = 50 * 1024 * 1024
    var maxThumbnails = 30
    var thumbnailPixelSize = 1200

    public init() {}

    public func render(_ message: TNEFMessage, fileName: String) -> RenderedPreview {
        var resources: [String: RenderedPreview.Resource] = [:]
        let title = message.subject.flatMap { $0.isEmpty ? nil : $0 } ?? fileName

        var html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>\(Self.css)</style></head><body>"
        html += "<header id=\"tnef-header\"><h1>\(HTML.escape(title))</h1><dl>"
        if let sender = message.sender {
            html += "<dt>From</dt><dd>\(HTML.escape(sender))</dd>"
        }
        if let date = message.dateSent {
            html += "<dt>Sent</dt><dd>\(HTML.escape(date.formatted(date: .long, time: .shortened)))</dd>"
        }
        html += "<dt>File</dt><dd>\(HTML.escape(fileName))</dd></dl></header>"

        html += attachmentsSection(message.attachments, resources: &resources)
        html += bodySection(message, resources: &resources)

        if !message.warnings.isEmpty {
            html += "<footer id=\"tnef-warnings\"><p>Parts of this file could not be read:</p><ul>"
            html += message.warnings.map { "<li>\(HTML.escape($0))</li>" }.joined()
            html += "</ul></footer>"
        }
        html += "</body></html>"
        return RenderedPreview(title: title, html: html, resources: resources)
    }

    // MARK: Attachments

    private func attachmentsSection(_ attachments: [TNEFAttachment], resources: inout [String: RenderedPreview.Resource]) -> String {
        guard !attachments.isEmpty else {
            return "<section id=\"tnef-attachments\"><p class=\"tnef-none\">No attachments</p></section>"
        }
        let count = attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments"
        var html = "<section id=\"tnef-attachments\"><h2>\(count)</h2><ul>"
        var thumbnails = 0
        for (index, attachment) in attachments.enumerated() {
            let type = Self.contentType(of: attachment)
            let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
            let kind = attachment.isEmbeddedMessage ? "Embedded message" : (type.localizedDescription ?? attachment.mimeType ?? "File")

            var picture = ""
            if thumbnails < maxThumbnails, type.conforms(to: .image), attachment.data.count <= maxImageBytes,
               let png = thumbnail(attachment.data) {
                let key = "tnef-image-\(index)"
                resources[key] = .init(data: png.data, contentType: .png)
                let width = min(png.width, 860)
                picture = "<img class=\"tnef-image\" src=\"cid:\(key)\" width=\"\(width)\" alt=\"\">"
                thumbnails += 1
            }

            let iconKey = "tnef-icon-\(type.identifier)"
            if resources[iconKey] == nil, let icon = icon(for: type) {
                resources[iconKey] = .init(data: icon, contentType: .png)
            }
            let iconTag = resources[iconKey] == nil ? "" : "<img class=\"tnef-icon\" src=\"cid:\(HTML.escape(iconKey))\" width=\"32\" height=\"32\" alt=\"\">"

            html += "<li>\(iconTag)<span class=\"tnef-name\">\(HTML.escape(attachment.fileName))</span>"
            html += "<span class=\"tnef-meta\">\(HTML.escape(kind)) · \(size)</span>\(picture)</li>"
        }
        return html + "</ul></section>"
    }

    static func contentType(of attachment: TNEFAttachment) -> UTType {
        if let detected = FileSniffer.detect(attachment.data), let type = UTType(mimeType: detected.mimeType) {
            return type
        }
        let fileExtension = (attachment.fileName as NSString).pathExtension
        if !fileExtension.isEmpty, let type = UTType(filenameExtension: fileExtension) { return type }
        if let mime = attachment.mimeType, let type = UTType(mimeType: mime) { return type }
        return .data
    }

    private func thumbnail(_ data: Data) -> (data: Data, width: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (output as Data, image.width)
    }

    private func icon(for type: UTType) -> Data? {
        let image = NSWorkspace.shared.icon(for: type)
        guard let rep = image.bestRepresentation(for: NSRect(x: 0, y: 0, width: 64, height: 64), context: nil, hints: nil) else {
            return nil
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                      samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        guard let bitmap else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        rep.draw(in: NSRect(x: 0, y: 0, width: 64, height: 64))
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }

    // MARK: Body

    private func bodySection(_ message: TNEFMessage, resources: inout [String: RenderedPreview.Resource]) -> String {
        var html = "<section id=\"tnef-body\">"
        if let body = message.htmlBody {
            // Inline images referenced as cid:<content-id> resolve to the attachment itself.
            for attachment in message.attachments {
                guard let id = attachment.contentID, resources[id] == nil, attachment.data.count <= maxImageBytes else { continue }
                let type = Self.contentType(of: attachment)
                if type.conforms(to: .image) { resources[id] = .init(data: attachment.data, contentType: type) }
            }
            html += HTML.sanitizeMailBody(body)
        } else if let rtf = message.rtfBody, let converted = HTML.fromRTF(rtf) {
            html += converted
        } else if let plain = message.plainBody, !plain.isEmpty {
            html += "<pre>\(HTML.escape(plain))</pre>"
        } else {
            html += "<p class=\"tnef-none\">No message text</p>"
        }
        return html + "</section>"
    }

    static let css = """
    :root { color-scheme: light dark; --muted: #6e6e73; --line: #d2d2d7; --card: #f5f5f7; }
    @media (prefers-color-scheme: dark) { :root { --muted: #98989d; --line: #3a3a3c; --card: #1c1c1e; } }
    body { font: 13px -apple-system, system-ui, sans-serif; margin: 0; padding: 16px 20px; }
    #tnef-header h1 { font-size: 17px; margin: 0 0 6px; }
    #tnef-header dl { display: grid; grid-template-columns: max-content 1fr; gap: 2px 10px; margin: 0; color: var(--muted); }
    #tnef-header dt { font-weight: 600; } #tnef-header dd { margin: 0; overflow-wrap: anywhere; }
    #tnef-attachments { margin: 14px 0; padding: 10px 12px; background: var(--card); border-radius: 8px; }
    #tnef-attachments h2 { font-size: 12px; text-transform: uppercase; letter-spacing: .04em; color: var(--muted); margin: 0 0 8px; }
    #tnef-attachments ul { list-style: none; margin: 0; padding: 0; }
    #tnef-attachments li { display: grid; grid-template-columns: 36px 1fr; column-gap: 8px; align-items: center; padding: 4px 0; }
    #tnef-attachments li + li { border-top: 1px solid var(--line); }
    .tnef-icon { grid-row: span 2; } .tnef-name { font-weight: 600; overflow-wrap: anywhere; }
    .tnef-meta { color: var(--muted); font-size: 12px; }
    .tnef-image { grid-column: 1 / -1; max-width: 100%; height: auto; margin: 6px 0; border: 1px solid var(--line); border-radius: 4px; }
    .tnef-none { color: var(--muted); margin: 0; }
    #tnef-body { border-top: 1px solid var(--line); padding-top: 12px; overflow-wrap: anywhere; }
    #tnef-body pre { white-space: pre-wrap; font: inherit; }
    #tnef-warnings { margin-top: 16px; color: var(--muted); font-size: 11px; }
    """
}
