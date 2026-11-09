import Foundation
import Testing
@testable import TNEFKit

private func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
}

@Suite struct TNEFParserTests {
    @Test func basicMessageHeaderFields() throws {
        let message = try TNEFParser.parse(try fixture("basic.dat"))
        #expect(message.subject == "Quarterly report – Übersicht")
        #expect(message.messageClass == "IPM.Microsoft Mail.Note")
        let expected = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"),
                                      year: 2026, month: 11, day: 9, hour: 14, minute: 30, second: 5).date
        #expect(message.dateSent == expected)
        #expect(message.warnings.isEmpty)
    }

    @Test func basicMessageAttachments() throws {
        let message = try TNEFParser.parse(try fixture("basic.dat"))
        #expect(message.attachments.map(\.fileName) == ["Grüße & Übersicht.txt", "chart.png"])
        #expect(message.attachments.map(\.mimeType) == ["text/plain", "image/png"])
        #expect(message.attachments[0].data == Data("Hallo Welt – äöü\n".utf8))
        #expect(message.attachments[1].data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(message.attachments[1].data.count == 79)
    }

    @Test func compressedRTFBodyMatchesSource() throws {
        let message = try TNEFParser.parse(try fixture("basic.dat"))
        #expect(message.rtfBody == (try fixture("rtf-body.rtf")))
        #expect(message.htmlBody == nil)
    }

    @Test func htmlAndUnicodeBodies() throws {
        let message = try TNEFParser.parse(try fixture("html.dat"))
        #expect(message.htmlBody?.contains("see <b>attached</b> sheet.") == true)
        #expect(message.plainBody == "Hi, see attached sheet.")
        #expect(message.attachments.map(\.fileName) == ["sheet.csv"])
        #expect(message.attachments[0].data == Data("a,b\n1,2\n".utf8))
    }

    @Test func rtfOnlyMessageWithLegacyBody() throws {
        let message = try TNEFParser.parse(try fixture("rtf-only.dat"))
        #expect(message.attachments.isEmpty)
        #expect(message.rtfBody != nil)
        #expect(message.plainBody == "Plain legacy body")
    }

    @Test func rejectsNonTNEFData() {
        #expect(throws: TNEFError.notTNEF) { try TNEFParser.parse(Data("hello world".utf8)) }
        #expect(throws: TNEFError.notTNEF) { try TNEFParser.parse(Data()) }
        #expect(!TNEFParser.looksLikeTNEF(Data([0x00, 0x01])))
        #expect(TNEFParser.looksLikeTNEF(Data([0x78, 0x9F, 0x3E, 0x22])))
    }

    @Test func everyTruncationIsHandled() throws {
        let data = try fixture("basic.dat")
        // Every prefix must either be rejected or give a partial result; never trap.
        for length in 0..<data.count {
            _ = try? TNEFParser.parse(data.prefix(length))
        }
        // A cut inside the last attribute is reported.
        let cut = try TNEFParser.parse(data.prefix(data.count - 3))
        #expect(cut.warnings.contains { $0.contains("truncated") })
    }

    @Test func corruptedBytesAreHandled() throws {
        let original = [UInt8](try fixture("basic.dat"))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var damaged = original
            for _ in 0..<Int.random(in: 1...8, using: &generator) {
                damaged[Int.random(in: 6..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try? TNEFParser.parse(Data(damaged))
        }
    }

    @Test func checksumMismatchIsAWarningOnly() throws {
        var bytes = [UInt8](try fixture("html.dat"))
        bytes[bytes.count - 1] ^= 0xFF // last byte belongs to the final attribute's checksum
        let message = try TNEFParser.parse(Data(bytes))
        #expect(message.attachments.count == 1)
        #expect(message.warnings.contains { $0.contains("checksum") })
    }
}

@Suite struct CompressedRTFTests {
    @Test func uncompressedVariant() throws {
        let raw = Array("{\\rtf1 plain}".utf8)
        var input: [UInt8] = []
        for value in [UInt32(raw.count + 12), UInt32(raw.count), CompressedRTF.uncompressedMagic, 0] {
            input += withUnsafeBytes(of: value.littleEndian, Array.init)
        }
        input += raw
        #expect(try CompressedRTF.decompress(input) == raw)
    }

    @Test func badChecksumIsRejected() throws {
        var input: [UInt8] = []
        for value in [UInt32(13), UInt32(1), CompressedRTF.compressedMagic, 0xDEAD_BEEF] {
            input += withUnsafeBytes(of: value.littleEndian, Array.init)
        }
        input.append(0)
        #expect(throws: TNEFError.self) { try CompressedRTF.decompress(input) }
    }

    @Test func checksumMatchesSpecExample() {
        // CRC of "123456789" with initial value 0 and no final xor (value from the Python fixture generator).
        #expect(CompressedRTF.checksum(Array("123456789".utf8)) == 0x2DFD_2D88)
    }
}

@Suite struct TextDecodingTests {
    @Test func windows1252() {
        #expect(TextDecoding.decode([0x96, 0x80, 0x00, 0x41], codepage: 1252) == "–€")
    }

    @Test func otherCodepages() {
        #expect(TextDecoding.decode([0xC0, 0xE0], codepage: 1251) == "Аа")
        #expect(TextDecoding.decode(Array("ü".utf8), codepage: 65001) == "ü")
    }

    @Test func unknownCodepageFallsBack() {
        #expect(TextDecoding.decode([0x41, 0xE4], codepage: 99999) == "Aä")
    }

    @Test func fileNamesAreSanitized() {
        #expect(FileNames.sanitize("C:\\temp\\..\\report.pdf") == "report.pdf")
        #expect(FileNames.sanitize("../../etc/passwd") == "passwd")
        #expect(FileNames.sanitize("..") == "")
    }
}

@Suite struct EmbeddedObjectTests {
    @Test func pictureObjectIsUnwrapped() throws {
        let message = try TNEFParser.parse(try fixture("ole.dat"))
        let picture = try #require(message.attachments.first)
        #expect(picture.fileName == "Untitled Attachment.bmp")
        #expect(picture.mimeType == "image/bmp")
        #expect(picture.data.starts(with: Array("BM".utf8)))
        #expect(picture.data.count == 4854)
        #expect(message.warnings.isEmpty)
    }

    @Test func packageObjectKeepsOriginalName() throws {
        let message = try TNEFParser.parse(try fixture("ole.dat"))
        let package = try #require(message.attachments.last)
        #expect(package.fileName == "notes.txt")
        #expect(package.data == Data("embedded notes\n".utf8))
    }

    @Test func damagedContainerIsKeptAsIs() throws {
        var bytes = [UInt8](try fixture("ole.dat"))
        // Point the first attachment's directory sector far outside the file.
        let containerStart = try #require(bytes.firstRange(of: CompoundFile.signature)?.lowerBound)
        bytes.replaceSubrange((containerStart + 0x30)..<(containerStart + 0x34), with: [0x00, 0x00, 0x00, 0x7F])
        let message = try TNEFParser.parse(Data(bytes))
        let first = try #require(message.attachments.first)
        #expect(first.mimeType == "application/x-oleobject")
        #expect(first.data.starts(with: CompoundFile.signature))
        #expect(message.warnings.contains { $0.contains("OLE object") })
    }

    @Test func corruptedContainersNeverTrap() throws {
        let original = [UInt8](try fixture("ole.dat"))
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<2000 {
            var damaged = original
            for _ in 0..<Int.random(in: 1...6, using: &generator) {
                damaged[Int.random(in: 6..<damaged.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
            }
            _ = try? TNEFParser.parse(Data(damaged))
        }
    }

    @Test func sniffsCommonTypes() {
        #expect(FileSniffer.detect([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])?.fileExtension == "png")
        #expect(FileSniffer.detect([0xFF, 0xD8, 0xFF, 0xE0])?.mimeType == "image/jpeg")
        #expect(FileSniffer.detect(Array("%PDF-1.7".utf8))?.fileExtension == "pdf")
        #expect(FileSniffer.detect(Array("hello".utf8)) == nil)
    }
}
