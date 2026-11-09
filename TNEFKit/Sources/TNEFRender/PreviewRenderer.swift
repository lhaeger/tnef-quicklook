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
    var thumbnailPixelSize = 1600

    public init() {}

    public func render(_ message: TNEFMessage, fileName: String) -> RenderedPreview {
        var page = Page(renderer: self, attachments: message.attachments)
        let title = message.subject.flatMap { $0.isEmpty ? nil : $0 } ?? fileName

        // The body goes first so the attachment list knows which pictures it already shows.
        let body = page.bodySection(message)
        let attachments = page.attachmentsSection()

        var html = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>\(Self.css)</style></head><body>"
        html += "<header id=\"tnef-header\"><h1>\(HTML.escape(title))</h1>"
        var rows = ""
        if let sender = message.sender { rows += "<dt>From</dt><dd>\(HTML.escape(sender))</dd>" }
        if let date = message.dateSent {
            rows += "<dt>Sent</dt><dd>\(HTML.escape(date.formatted(date: .long, time: .shortened)))</dd>"
        }
        if title != fileName { rows += "<dt>File</dt><dd>\(HTML.escape(fileName))</dd>" }
        if !rows.isEmpty { html += "<dl>\(rows)</dl>" }
        html += "</header>" + attachments + body

        if !message.warnings.isEmpty {
            html += "<footer id=\"tnef-warnings\"><p>Parts of this file could not be read:</p><ul>"
            html += message.warnings.map { "<li>\(HTML.escape($0))</li>" }.joined()
            html += "</ul></footer>"
        }
        html += "</body></html>"
        return RenderedPreview(title: title, html: html, resources: page.resources)
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
    .tnef-inline { max-width: 100%; height: auto; vertical-align: bottom; }
    .tnef-chip { display: inline-flex; align-items: center; gap: 6px; padding: 2px 8px 2px 4px; background: var(--card);
                 border: 1px solid var(--line); border-radius: 6px; font-weight: 600; }
    .tnef-chip img { width: 20px; height: 20px; }
    .tnef-none { color: var(--muted); margin: 0; }
    #tnef-body { border-top: 1px solid var(--line); padding-top: 12px; overflow-wrap: anywhere; }
    #tnef-body pre { white-space: pre-wrap; font: inherit; }
    #tnef-warnings { margin-top: 16px; color: var(--muted); font-size: 11px; }
    """
}

/// State while one page is rendered: resources added so far, thumbnails
/// already made, and which attachments the body shows.
private struct Page {
    let renderer: PreviewRenderer
    let attachments: [TNEFAttachment]
    var resources: [String: RenderedPreview.Resource] = [:]
    /// Indices of attachments the body already shows.
    var shownInBody: Set<Int> = []
    private var thumbnails: [Int: (key: String, width: Int)?] = [:]

    init(renderer: PreviewRenderer, attachments: [TNEFAttachment]) {
        self.renderer = renderer
        self.attachments = attachments
    }

    // MARK: Body

    mutating func bodySection(_ message: TNEFMessage) -> String {
        var html = "<section id=\"tnef-body\">"
        if let body = message.htmlBody {
            html += htmlBody(body)
        } else if let rtf = message.rtfBody, let converted = rtfBody(rtf) {
            html += converted
        } else if let plain = message.plainBody, !plain.isEmpty {
            html += "<pre>\(HTML.escape(plain))</pre>"
        } else {
            html += "<p class=\"tnef-none\">No message text</p>"
        }
        return html + "</section>"
    }

    /// HTML bodies place their pictures themselves with cid: URLs; those
    /// resolve to the attachment with the matching content id.
    private mutating func htmlBody(_ body: String) -> String {
        let sanitized = HTML.sanitizeMailBody(body)
        for (index, attachment) in attachments.enumerated() {
            guard let id = attachment.contentID, sanitized.contains("cid:\(id)"), resources[id] == nil,
                  attachment.data.count <= renderer.maxImageBytes
            else { continue }
            let type = PreviewRenderer.contentType(of: attachment)
            guard type.conforms(to: .image) else { continue }
            resources[id] = .init(data: attachment.data, contentType: type)
            shownInBody.insert(index)
        }
        return sanitized
    }

    /// RTF bodies mark each picture's place with \objattph. The n-th
    /// placeholder belongs to the n-th attachment by rendering position.
    private mutating func rtfBody(_ rtf: Data) -> String? {
        let token = { (number: Int) in "TNEFOBJECT\(number)PLACEHOLDER" }
        guard let converted = HTML.fromRTF(rtf, placeholderToken: token) else { return nil }

        let placed = attachments.indices
            .filter { attachments[$0].renderingPosition != nil }
            .sorted { (attachments[$0].renderingPosition!, $0) < (attachments[$1].renderingPosition!, $1) }

        var html = converted.html
        for number in 0..<converted.placeholders {
            var replacement = ""
            if number < placed.count, html.contains(token(number)) {
                replacement = inlineMarkup(for: placed[number])
                shownInBody.insert(placed[number])
            }
            html = html.replacingOccurrences(of: token(number), with: replacement)
        }
        return html
    }

    private mutating func inlineMarkup(for index: Int) -> String {
        if let image = thumbnail(for: index) {
            return "<img class=\"tnef-inline\" src=\"cid:\(image.key)\" width=\"\(min(image.width, 860))\" alt=\"\">"
        }
        let attachment = attachments[index]
        let icon = iconKey(for: PreviewRenderer.contentType(of: attachment))
            .map { "<img src=\"cid:\(HTML.escape($0))\" alt=\"\">" } ?? ""
        return "<span class=\"tnef-chip\">\(icon)\(HTML.escape(attachment.fileName))</span>"
    }

    // MARK: Attachments

    mutating func attachmentsSection() -> String {
        guard !attachments.isEmpty else {
            return "<section id=\"tnef-attachments\"><p class=\"tnef-none\">No attachments</p></section>"
        }
        let count = attachments.count == 1 ? "1 attachment" : "\(attachments.count) attachments"
        var html = "<section id=\"tnef-attachments\"><h2>\(count)</h2><ul>"
        for (index, attachment) in attachments.enumerated() {
            let type = PreviewRenderer.contentType(of: attachment)
            let size = ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)
            var meta = attachment.isEmbeddedMessage ? "Embedded message" : (type.localizedDescription ?? attachment.mimeType ?? "File")
            meta += " · \(size)"

            var picture = ""
            if shownInBody.contains(index) {
                meta += " · shown in message"
            } else if let image = thumbnail(for: index) {
                picture = "<img class=\"tnef-image\" src=\"cid:\(image.key)\" width=\"\(min(image.width, 860))\" alt=\"\">"
            }

            let iconTag = iconKey(for: type)
                .map { "<img class=\"tnef-icon\" src=\"cid:\(HTML.escape($0))\" width=\"32\" height=\"32\" alt=\"\">" } ?? ""
            html += "<li>\(iconTag)<span class=\"tnef-name\">\(HTML.escape(attachment.fileName))</span>"
            html += "<span class=\"tnef-meta\">\(HTML.escape(meta))</span>\(picture)</li>"
        }
        return html + "</ul></section>"
    }

    // MARK: Images

    /// PNG thumbnail of an image attachment, made once and shared by the body and the list.
    private mutating func thumbnail(for index: Int) -> (key: String, width: Int)? {
        if let cached = thumbnails[index] { return cached }
        var result: (key: String, width: Int)?
        let attachment = attachments[index]
        let made = thumbnails.values.compactMap { $0 }.count
        if made < renderer.maxThumbnails,
           PreviewRenderer.contentType(of: attachment).conforms(to: .image),
           attachment.data.count <= renderer.maxImageBytes,
           let png = Self.makeThumbnail(attachment.data, maxPixelSize: renderer.thumbnailPixelSize) {
            let key = "tnef-image-\(index)"
            resources[key] = .init(data: png.data, contentType: .png)
            result = (key, png.displayWidth)
        }
        thumbnails[index] = .some(result)
        return result
    }

    private mutating func iconKey(for type: UTType) -> String? {
        let key = "tnef-icon-\(type.identifier)"
        if resources[key] != nil { return key }
        guard let icon = Self.makeIcon(for: type) else { return nil }
        resources[key] = .init(data: icon, contentType: .png)
        return key
    }

    /// PNG version of an image, at most `maxPixelSize` on the long side, and the
    /// width in CSS pixels to show it at: an image saved at 144 dpi or more (a
    /// Retina screenshot) is shown at its point size instead of its pixel size.
    private static func makeThumbnail(_ data: Data, maxPixelSize: Int) -> (data: Data, displayWidth: Int)? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any] ?? [:]
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let dpi = properties[kCGImagePropertyDPIWidth] as? Double ?? 72
        // Windows stores 96 dpi for normal-size images, so only 144 dpi and up counts as high resolution.
        let scale = dpi >= 144 ? dpi / 72 : 1
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        let displayWidth = pixelWidth > 0 ? Int((Double(pixelWidth) / scale).rounded()) : image.width
        return (output as Data, displayWidth)
    }

    private static func makeIcon(for type: UTType) -> Data? {
        let image = NSWorkspace.shared.icon(for: type)
        let rect = NSRect(x: 0, y: 0, width: 64, height: 64)
        guard let rep = image.bestRepresentation(for: rect, context: nil, hints: nil),
              let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64, bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        rep.draw(in: rect)
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
