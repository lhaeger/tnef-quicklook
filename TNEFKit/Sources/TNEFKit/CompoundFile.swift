/// Minimal read-only reader for Compound File Binary files (MS-CFB), the
/// container Outlook uses for OLE objects inside TNEF. It only supports what is
/// needed to read a named stream; every structure is bounds-checked and chain
/// walks are limited, so a damaged file throws instead of looping or trapping.
struct CompoundFile {
    static let signature: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]

    private static let endOfChain: UInt32 = 0xFFFF_FFFE
    private static let freeSector: UInt32 = 0xFFFF_FFFF
    private static let noStream: UInt32 = 0xFFFF_FFFF

    struct Entry {
        let name: String
        let type: UInt8   // 1 storage, 2 stream, 5 root
        let startSector: UInt32
        let size: UInt64
    }

    private let bytes: [UInt8]
    private let sectorSize: Int
    private let miniSectorSize: Int
    private let miniStreamCutoff: UInt64
    private let fat: [UInt32]
    private let miniFAT: [UInt32]
    private let miniStream: [UInt8]
    let entries: [Entry]

    static func isCompoundFile(_ bytes: [UInt8]) -> Bool {
        bytes.starts(with: signature)
    }

    init(_ bytes: [UInt8]) throws {
        guard Self.isCompoundFile(bytes), bytes.count >= 512 else {
            throw TNEFError.invalid("not a compound file")
        }
        self.bytes = bytes
        var header = ByteReader(bytes, offset: 0x1E)
        let sectorShift = try header.u16()
        let miniSectorShift = try header.u16()
        guard sectorShift == 9 || sectorShift == 12, miniSectorShift == 6 else {
            throw TNEFError.invalid("unsupported compound file sector size")
        }
        sectorSize = 1 << Int(sectorShift)
        miniSectorSize = 1 << Int(miniSectorShift)

        header = ByteReader(bytes, offset: 0x2C)
        let fatSectorCount = Int(try header.u32())
        let firstDirectorySector = try header.u32()
        _ = try header.u32() // transaction signature
        miniStreamCutoff = UInt64(try header.u32())
        let firstMiniFATSector = try header.u32()
        _ = try header.u32() // mini FAT sector count
        var difatSector = try header.u32()
        _ = try header.u32() // DIFAT sector count

        // FAT sector locations: 109 in the header, the rest in a DIFAT chain.
        var fatSectors: [UInt32] = []
        for _ in 0..<109 { fatSectors.append(try header.u32()) }
        let maxSectors = bytes.count / sectorSize
        var difatHops = 0
        while difatSector < Self.endOfChain, fatSectors.count < fatSectorCount + 109 {
            difatHops += 1
            guard difatHops <= maxSectors else { throw TNEFError.invalid("compound file DIFAT loop") }
            var reader = ByteReader(bytes, offset: try Self.offset(of: difatSector, sectorSize: sectorSize, in: bytes))
            for _ in 0..<(sectorSize / 4 - 1) { fatSectors.append(try reader.u32()) }
            difatSector = try reader.u32()
        }

        var fat: [UInt32] = []
        for sector in fatSectors.prefix(fatSectorCount) where sector < Self.endOfChain {
            var reader = ByteReader(bytes, offset: try Self.offset(of: sector, sectorSize: sectorSize, in: bytes))
            for _ in 0..<(sectorSize / 4) { fat.append(try reader.u32()) }
        }
        self.fat = fat

        let directory = try Self.readChain(from: firstDirectorySector, fat: fat, sectorSize: sectorSize, in: bytes)
        var entries: [Entry] = []
        var reader = ByteReader(directory)
        while reader.remaining >= 128 {
            let raw = try reader.read(128)
            var fields = ByteReader(raw, offset: 64)
            let nameLength = min(Int(try fields.u16()), 64)
            let type = try fields.u8()
            fields = ByteReader(raw, offset: 116)
            let start = try fields.u32()
            let size = try fields.u64() & (sectorSize == 512 ? 0xFFFF_FFFF : .max)
            let name = TextDecoding.utf16LE(Array(raw.prefix(max(0, nameLength - 2))))
            entries.append(Entry(name: name, type: type, startSector: start, size: size))
        }
        self.entries = entries

        guard let root = entries.first, root.type == 5 else {
            throw TNEFError.invalid("compound file without root entry")
        }
        if root.startSector < Self.endOfChain {
            let stream = try Self.readChain(from: root.startSector, fat: fat, sectorSize: sectorSize, in: bytes)
            miniStream = Array(stream.prefix(Int(clamping: root.size)))
            let miniFATBytes = firstMiniFATSector < Self.endOfChain
                ? try Self.readChain(from: firstMiniFATSector, fat: fat, sectorSize: sectorSize, in: bytes) : []
            var miniFATReader = ByteReader(miniFATBytes)
            var miniFAT: [UInt32] = []
            while miniFATReader.remaining >= 4 { miniFAT.append(try miniFATReader.u32()) }
            self.miniFAT = miniFAT
        } else {
            miniStream = []
            miniFAT = []
        }
    }

    /// Contents of the first stream with this name (case-insensitive).
    func stream(named name: String) throws -> [UInt8]? {
        guard let entry = entries.first(where: { $0.type == 2 && $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
            return nil
        }
        let size = Int(clamping: entry.size)
        guard size > 0 else { return [] }
        if entry.size < miniStreamCutoff {
            let data = try Self.readChain(from: entry.startSector, fat: miniFAT, sectorSize: miniSectorSize, in: miniStream, headerSectors: 0)
            guard data.count >= size else { throw TNEFError.invalid("compound file mini stream too short") }
            return Array(data.prefix(size))
        }
        let data = try Self.readChain(from: entry.startSector, fat: fat, sectorSize: sectorSize, in: bytes)
        guard data.count >= size else { throw TNEFError.invalid("compound file stream too short") }
        return Array(data.prefix(size))
    }

    private static func offset(of sector: UInt32, sectorSize: Int, in bytes: [UInt8], headerSectors: Int = 1) throws -> Int {
        let offset = (Int(sector) + headerSectors) * sectorSize
        guard offset >= 0, offset + sectorSize <= bytes.count else {
            throw TNEFError.invalid("compound file sector \(sector) out of range")
        }
        return offset
    }

    /// Concatenates the sectors of a chain. `headerSectors` is 1 for the main
    /// file (sector 0 starts after the 512-byte header) and 0 for the mini stream.
    private static func readChain(from start: UInt32, fat: [UInt32], sectorSize: Int, in bytes: [UInt8], headerSectors: Int = 1) throws -> [UInt8] {
        var result: [UInt8] = []
        var sector = start
        var hops = 0
        while sector < endOfChain {
            hops += 1
            guard hops <= fat.count, Int(sector) < fat.count else {
                throw TNEFError.invalid("compound file chain broken at sector \(sector)")
            }
            let offset = try offset(of: sector, sectorSize: sectorSize, in: bytes, headerSectors: headerSectors)
            result += bytes[offset..<(offset + sectorSize)]
            sector = fat[Int(sector)]
        }
        return result
    }
}
