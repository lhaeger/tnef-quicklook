import Foundation
import QuickLookUI
import TNEFKit
import TNEFRender
import UniformTypeIdentifiers

/// Quick Look preview for winmail.dat (TNEF). macOS maps every .dat file to
/// com.microsoft.tnef, so most files this sees are not TNEF at all. Those are
/// rejected after reading four bytes, and Quick Look shows its default view.
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    /// Larger files are left to Quick Look's default view.
    private let maxFileSize = 150 * 1024 * 1024

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL
        try checkSignature(of: url)

        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maxFileSize else {
            throw TNEFError.invalid("file too large for preview (\(size) bytes)")
        }

        let message = try TNEFParser.parse(try Data(contentsOf: url, options: .mappedIfSafe))
        let page = PreviewRenderer().render(message, fileName: url.lastPathComponent)

        let reply = QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 900, height: 700)) { reply in
            reply.stringEncoding = .utf8
            reply.attachments = page.resources.mapValues {
                QLPreviewReplyAttachment(data: $0.data, contentType: $0.contentType)
            }
            return Data(page.html.utf8)
        }
        reply.title = page.title
        return reply
    }

    private func checkSignature(of url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 4) ?? Data()
        guard TNEFParser.looksLikeTNEF(head) else { throw TNEFError.notTNEF }
    }
}
