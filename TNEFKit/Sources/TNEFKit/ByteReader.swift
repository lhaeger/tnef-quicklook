/// Bounds-checked little-endian reader. Every read throws instead of trapping,
/// so malformed input can never crash the Quick Look extension.
struct ByteReader {
    let bytes: [UInt8]
    private(set) var offset: Int

    init(_ bytes: [UInt8], offset: Int = 0) {
        self.bytes = bytes
        self.offset = offset
    }

    var remaining: Int { bytes.count - offset }
    var isAtEnd: Bool { offset >= bytes.count }

    private func require(_ count: Int) throws {
        guard count >= 0, count <= remaining else {
            throw TNEFError.truncated(offset: offset, needed: count)
        }
    }

    mutating func u8() throws -> UInt8 {
        try require(1)
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func u16() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    mutating func u16BigEndian() throws -> UInt16 {
        try require(2)
        defer { offset += 2 }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    mutating func u32() throws -> UInt32 {
        try require(4)
        defer { offset += 4 }
        var value: UInt32 = 0
        for index in 0..<4 { value |= UInt32(bytes[offset + index]) << (8 * index) }
        return value
    }

    mutating func u64() throws -> UInt64 {
        try require(8)
        defer { offset += 8 }
        var value: UInt64 = 0
        for index in 0..<8 { value |= UInt64(bytes[offset + index]) << (8 * index) }
        return value
    }

    mutating func read(_ count: Int) throws -> [UInt8] {
        try require(count)
        defer { offset += count }
        return Array(bytes[offset..<offset + count])
    }

    /// Reads a 32-bit length and checks it against the remaining input before
    /// it is used, so a corrupt length can't trigger a huge allocation.
    mutating func length() throws -> Int {
        let value = Int(try u32())
        try require(value)
        return value
    }

    mutating func skip(_ count: Int) throws {
        try require(count)
        offset += count
    }

    mutating func align4(relativeTo start: Int = 0) throws {
        let misalignment = (offset - start) % 4
        if misalignment != 0 { try skip(4 - misalignment) }
    }
}
