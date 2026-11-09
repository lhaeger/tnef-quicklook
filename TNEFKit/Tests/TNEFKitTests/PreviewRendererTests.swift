import AppKit
import Foundation
import Testing
import TNEFKit
@testable import TNEFRender

private func render(_ name: String) throws -> RenderedPreview {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return PreviewRenderer().render(try TNEFParser.parse(try Data(contentsOf: url)), fileName: "winmail.dat")
}

@Suite struct PreviewRendererTests {
    @Test func headerAndAttachments() throws {
        let page = try render("basic.dat")
        #expect(page.title == "Quarterly report – Übersicht")
        #expect(page.html.contains("<h1>Quarterly report – Übersicht</h1>"))
        #expect(page.html.contains("Grüße &amp; Übersicht.txt"))
        #expect(page.html.contains("2 attachments"))
        #expect(page.html.contains("src=\"cid:tnef-image-1\""))
        #expect(page.resources["tnef-image-1"]?.contentType == .png)
    }

    @Test func rtfBodyBecomesHTML() throws {
        let page = try render("rtf-only.dat")
        #expect(page.html.contains("Hello Lothar"))
        #expect(page.html.contains("Grüße"))
        #expect(page.html.contains("No attachments"))
    }

    @Test func htmlBodyIsSanitized() throws {
        let page = try render("html.dat")
        #expect(page.html.contains("see <b>attached</b> sheet."))
        #expect(!page.html.contains("tracker.example.com"))
        #expect(!page.html.contains("<script"))
        #expect(!page.html.contains("alert(1)"))
        #expect(!page.html.contains("https://example.com"))
    }

    @Test func oleImageGetsThumbnail() throws {
        let page = try render("ole.dat")
        #expect(page.html.contains("Untitled Attachment.bmp"))
        #expect(page.resources["tnef-image-0"] != nil)
    }

    @Test func sanitizerRemovesDangerousMarkup() {
        let dirty = """
        <html><head><style>p{color:red;background:url(http://x.test/a.png)}</style><link rel=stylesheet href="http://x.test/s.css"></head>
        <body onload="evil()"><p onclick='x()'>Hi</p><img src='https://x.test/p.gif'><img src="cid:logo">
        <iframe src="http://x.test"></iframe><a href="javascript:alert(1)">a</a><form action="http://x.test"><input name=q></form></body></html>
        """
        let clean = HTML.sanitizeMailBody(dirty)
        #expect(!clean.contains("x.test"))
        #expect(!clean.contains("onclick"))
        #expect(!clean.contains("iframe"))
        #expect(!clean.contains("javascript:"))
        #expect(!clean.contains("<input"))
        #expect(clean.contains("<p>Hi</p>"))
        #expect(clean.contains("src=\"cid:logo\""))
        #expect(clean.contains("p{color:red;"))
    }

    @Test func escaping() {
        #expect(HTML.escape("<a href=\"x\">'&'</a>") == "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;")
    }
}

@Suite struct InlinePictureTests {
    @Test func parserReadsRenderingPosition() throws {
        let url = try #require(Bundle.module.url(forResource: "ole.dat", withExtension: nil, subdirectory: "Fixtures"))
        let message = try TNEFParser.parse(try Data(contentsOf: url))
        #expect(message.attachments.map(\.renderingPosition) == [24, nil])
    }

    @Test func pictureIsPlacedAtPlaceholder() throws {
        let page = try render("ole.dat")
        let body = try #require(page.html.range(of: "<section id=\"tnef-body\">").map { String(page.html[$0.upperBound...]) })
        let before = try #require(body.range(of: "Before the picture:"))
        let image = try #require(body.range(of: "<img class=\"tnef-inline\" src=\"cid:tnef-image-0\""))
        let after = try #require(body.range(of: "After the picture."))
        #expect(before.upperBound < image.lowerBound && image.upperBound < after.lowerBound)
        #expect(!page.html.contains("PLACEHOLDER"))
    }

    @Test func inlinePictureIsNotRepeatedInList() throws {
        let page = try render("ole.dat")
        #expect(page.html.contains("shown in message"))
        #expect(!page.html.contains("class=\"tnef-image\""))
    }

    @Test func unmatchedPlaceholdersAreRemoved() throws {
        let rtf = Data("{\\rtf1\\ansi A{\\objattph  }B{\\objattph  }C}".utf8)
        let converted = try #require(HTML.fromRTF(rtf, placeholderToken: { "TOKEN\($0)X" }))
        #expect(converted.placeholders == 2)
        #expect(converted.html.contains("TOKEN0X") && converted.html.contains("TOKEN1X"))

        var message = TNEFMessage()
        message.rtfBody = rtf
        let page = PreviewRenderer().render(message, fileName: "winmail.dat")
        #expect(!page.html.contains("PLACEHOLDER"))
    }
}

@Suite struct SizingTests {
    @Test func rtfFontSizesStayInPoints() throws {
        let page = try render("rtf-only.dat")
        let body = try #require(page.html.components(separatedBy: "<section id=\"tnef-body\">").last)
        #expect(body.range(of: #"font: [0-9.]+pt"#, options: .regularExpression) != nil)
        #expect(body.range(of: #"[0-9.]+px"#, options: .regularExpression) == nil)
    }

    private func png(width: Int, height: Int, dpi: Double) throws -> Data {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = NSSize(width: Double(width) * 72 / dpi, height: Double(height) * 72 / dpi)
        return try #require(bitmap.representation(using: .png, properties: [:]))
    }

    private func shownWidth(dpi: Double) throws -> String? {
        var message = TNEFMessage()
        message.attachments = [TNEFAttachment(fileName: "picture.png", data: try png(width: 600, height: 100, dpi: dpi))]
        let html = PreviewRenderer().render(message, fileName: "winmail.dat").html
        let match = try #require(html.range(of: #"class="tnef-image" src="cid:[^"]+" width="[0-9]+""#, options: .regularExpression))
        return html[match].components(separatedBy: "width=\"").last?.replacingOccurrences(of: "\"", with: "")
    }

    @Test func retinaImagesShowAtPointSize() throws {
        #expect(try shownWidth(dpi: 144) == "300")
    }

    @Test func normalImagesShowAtPixelSize() throws {
        #expect(try shownWidth(dpi: 72) == "600")
        #expect(try shownWidth(dpi: 96) == "600") // Windows' normal resolution
    }
}
