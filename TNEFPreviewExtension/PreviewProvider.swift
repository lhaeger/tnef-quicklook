import Foundation
import QuickLookUI
import UniformTypeIdentifiers

final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let size = (try? request.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        let html = "<html><body><h1>TNEF preview works</h1><p>\(request.fileURL.lastPathComponent), \(size) bytes</p></body></html>"
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 800, height: 600)) { _ in
            Data(html.utf8)
        }
    }
}
