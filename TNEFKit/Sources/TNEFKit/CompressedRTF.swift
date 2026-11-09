/// Decompression of PR_RTF_COMPRESSED as specified in MS-OXRTFCP.
public enum CompressedRTF {
    static let compressedMagic: UInt32 = 0x7546_5A4C   // "LZFu"
    static let uncompressedMagic: UInt32 = 0x414C_454D // "MELA"

    static let prebuffer: [UInt8] = Array((
        "{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman "
            + "\\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New "
            + "RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par "
            + "\\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx"
    ).utf8)

    public static func decompress(_ input: [UInt8]) throws -> [UInt8] {
        var header = ByteReader(input)
        let compressedSize = Int(try header.u32())
        let rawSize = Int(try header.u32())
        let magic = try header.u32()
        let crc = try header.u32()

        // compressedSize counts everything after its own 4 bytes.
        guard compressedSize >= 12, compressedSize + 4 <= input.count else {
            throw TNEFError.invalid("compressed RTF size \(compressedSize) does not match \(input.count) bytes of data")
        }
        let payload = Array(input[16..<(compressedSize + 4)])

        switch magic {
        case uncompressedMagic:
            guard rawSize <= payload.count else {
                throw TNEFError.invalid("uncompressed RTF shorter than its declared size")
            }
            return Array(payload.prefix(rawSize))
        case compressedMagic:
            guard checksum(payload) == crc else {
                throw TNEFError.invalid("compressed RTF checksum mismatch")
            }
            return try inflate(payload, rawSize: rawSize)
        default:
            throw TNEFError.invalid(String(format: "unknown compressed RTF signature 0x%08X", magic))
        }
    }

    private static func inflate(_ payload: [UInt8], rawSize: Int) throws -> [UInt8] {
        var dictionary = [UInt8](repeating: 0, count: 4096)
        dictionary.replaceSubrange(0..<prebuffer.count, with: prebuffer)
        var writePosition = prebuffer.count
        var output: [UInt8] = []
        output.reserveCapacity(rawSize)
        var reader = ByteReader(payload)

        while !reader.isAtEnd {
            let control = try reader.u8()
            for bit in 0..<8 {
                if reader.isAtEnd { break }
                if control & (1 << bit) == 0 {
                    let byte = try reader.u8()
                    output.append(byte)
                    dictionary[writePosition] = byte
                    writePosition = (writePosition + 1) & 0xFFF
                    continue
                }
                let reference = try reader.u16BigEndian()
                let offset = Int(reference >> 4)
                let length = Int(reference & 0xF) + 2
                if offset == writePosition {
                    return Array(output.prefix(rawSize))
                }
                for index in 0..<length {
                    let byte = dictionary[(offset + index) & 0xFFF]
                    output.append(byte)
                    dictionary[writePosition] = byte
                    writePosition = (writePosition + 1) & 0xFFF
                }
            }
        }
        return Array(output.prefix(rawSize))
    }

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xEDB8_8320 : value >> 1 }
        return value
    }

    /// CRC-32 as used by MS-OXRTFCP: initial value 0, no final XOR.
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc
    }
}
