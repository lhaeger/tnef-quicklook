import AppKit
import Foundation

enum HTML {
    static func escape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            default: result.append(character)
            }
        }
        return result
    }

    /// Prepares an HTML mail body for embedding in the preview page: drops
    /// scripts, frames, forms and everything that would load from the network,
    /// and unwraps the document to the content of <body>. Quick Look doesn't run
    /// JavaScript anyway; removing remote resources keeps a preview from
    /// contacting tracking servers.
    static func sanitizeMailBody(_ html: String) -> String {
        var body = html
        let flags: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]

        func replace(_ pattern: String, with template: String = "") {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: flags) else { return }
            body = regex.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: template)
        }

        // whole elements with their content
        replace(#"<(script|iframe|frame|frameset|object|embed|applet|noscript|template)\b.*?</\1\s*>"#)
        replace(#"<!--.*?-->"#)
        // single tags that load or redirect
        replace(#"<(script|iframe|frame|object|embed|link|meta|base|form|input|button)\b[^>]*>"#)
        replace(#"</(form|button)\s*>"#)
        // event handlers
        replace(#"\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#)
        // remote and javascript: URLs in attributes (src, href, background, srcset, poster, ...)
        replace(#"\s(src|srcset|background|poster|href|action|formaction|xlink:href|data)\s*=\s*("\s*(https?:|//|javascript:|file:)[^"]*"|'\s*(https?:|//|javascript:|file:)[^']*'|(https?:|//|javascript:|file:)[^\s>]*)"#)
        // remote CSS: url(http...) and @import
        replace(#"url\(\s*['"]?\s*(https?:|//)[^)]*\)"#, with: "none")
        replace(#"@import[^;]*;"#)

        // keep the content of <body> plus any <style> blocks from <head>
        let styles = matches(#"<style\b[^>]*>.*?</style\s*>"#, in: body).joined()
        if let inner = firstGroup(#"<body\b[^>]*>(.*)</body\s*>"#, in: body) {
            return styles + inner
        }
        replace(#"</?(html|head|body)\b[^>]*>"#)
        return body
    }

    /// Converts an RTF body to an HTML fragment using AppKit's RTF reader.
    /// Each Outlook object placeholder (\objattph) is replaced by the text
    /// `placeholderToken(n)` first, so the caller can put the n-th inline
    /// attachment there. Returns the fragment and the number of placeholders.
    static func fromRTF(_ rtf: Data, placeholderToken: (Int) -> String) -> (html: String, placeholders: Int)? {
        // Latin-1 maps every byte to one character and back, so the RTF bytes survive unchanged.
        guard var source = String(data: rtf, encoding: .isoLatin1),
              let regex = try? NSRegularExpression(pattern: #"\\objattph(?![a-zA-Z])(-?\d+)? ?"#)
        else { return nil }
        let found = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for (number, match) in found.enumerated().reversed() {
            guard let range = Range(match.range, in: source) else { continue }
            source.replaceSubrange(range, with: "\\objattph \(placeholderToken(number))")
        }
        guard let prepared = source.data(using: .isoLatin1), let html = fromRTF(prepared) else { return nil }
        return (html, found.count)
    }

    private static func fromRTF(_ rtf: Data) -> String? {
        guard let text = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf],
                                                 documentAttributes: nil),
              text.length > 0,
              let data = try? text.data(from: NSRange(location: 0, length: text.length),
                                        documentAttributes: [.documentType: NSAttributedString.DocumentType.html]),
              let html = String(data: data, encoding: .utf8)
        else { return nil }
        // AppKit writes absolute colors; drop pure black text so the body follows dark mode.
        var styles = matches(#"<style\b[^>]*>.*?</style\s*>"#, in: html).joined()
            .replacingOccurrences(of: "color: #000000", with: "")
        // AppKit writes RTF point sizes as px, which makes an 11 pt Outlook body look like 11 px.
        if let lengths = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)px\b"#) {
            styles = lengths.stringByReplacingMatches(in: styles, range: NSRange(styles.startIndex..., in: styles), withTemplate: "$1pt")
        }
        let inner = firstGroup(#"<body\b[^>]*>(.*)</body\s*>"#, in: html) ?? html
        return styles + inner
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    private static func firstGroup(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }
}
