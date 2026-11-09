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
