import CZstd
import Foundation

/// Minimal read-only squashfs 4.0 reader for RAUC bundles: regular files in the root directory,
/// zstd-compressed (Valve's bundles) or uncompressed blocks. In-memory (bundles are ~2 MB).
struct Squashfs {
    private let image: [UInt8]
    private let blockSize: Int
    private let inodeTable: Int
    private let dirTable: Int
    private let fragTable: Int
    private let fragCount: Int
    private let rootInode: UInt64

    init(_ image: [UInt8]) throws {
        guard image.count >= 96, Squashfs.u32(image, 0) == 0x7371_7368 else { throw OptionError("squashfs: bad magic") }
        guard Squashfs.u16(image, 28) == 4 else { throw OptionError("squashfs: version \(Squashfs.u16(image, 28)) != 4") }
        let compression = Squashfs.u16(image, 20)
        guard compression == 6 else { throw OptionError("squashfs: compression id \(compression) unsupported (zstd = 6)") }
        self.image = image
        blockSize = Int(Squashfs.u32(image, 12))
        fragCount = Int(Squashfs.u32(image, 16))
        rootInode = Squashfs.u64(image, 32)
        inodeTable = Int(Squashfs.u64(image, 64))
        dirTable = Int(Squashfs.u64(image, 72))
        fragTable = Int(Squashfs.u64(image, 80))
        let bytesUsed = Squashfs.u64(image, 40)
        guard bytesUsed <= UInt64(image.count), blockSize >= 4096, blockSize <= 1 << 20,
              inodeTable < image.count, dirTable < image.count else { throw OptionError("squashfs: bad superblock") }
    }

    /// Names of the regular files in the root directory.
    func rootFiles() throws -> [String] { try rootEntries().map(\.name) }

    /// Contents of a regular file in the root directory.
    func file(_ name: String) throws -> [UInt8] {
        guard let e = try rootEntries().first(where: { $0.name == name }) else { throw OptionError("squashfs: no \(name)") }
        var r = MetaReader(fs: self, block: inodeTable + Int(e.inode >> 16), offset: Int(e.inode & 0xffff))
        let h = try r.read(16)
        let type = Squashfs.u16(h, 0)
        var start: UInt64, size: UInt64, frag: UInt32, fragOffset: UInt32
        switch type {
        case 2:
            let b = try r.read(16)
            start = UInt64(Squashfs.u32(b, 0)); frag = Squashfs.u32(b, 4); fragOffset = Squashfs.u32(b, 8); size = UInt64(Squashfs.u32(b, 12))
        case 9:
            let b = try r.read(40)
            start = Squashfs.u64(b, 0); size = Squashfs.u64(b, 8); frag = Squashfs.u32(b, 28); fragOffset = Squashfs.u32(b, 32)
        default:
            throw OptionError("squashfs: \(name) is not a regular file (inode type \(type))")
        }
        let hasFrag = frag != 0xFFFF_FFFF
        let full = Int(size) / blockSize
        let nBlocks = hasFrag ? full : (Int(size) + blockSize - 1) / blockSize
        let sizes = try r.read(4 * nBlocks)
        var out: [UInt8] = []
        out.reserveCapacity(Int(size))
        var pos = Int(start)
        for i in 0..<nBlocks {
            let word = Squashfs.u32(sizes, 4 * i)
            let want = min(blockSize, Int(size) - out.count)
            if word == 0 {
                out += [UInt8](repeating: 0, count: want)
                continue
            }
            let len = Int(word & 0x00FF_FFFF)
            let block = try data(at: pos, length: len, compressed: word & (1 << 24) == 0, capacity: blockSize)
            guard block.count >= want else { throw OptionError("squashfs: short data block in \(name)") }
            out += block[0..<want]
            pos += len
        }
        if hasFrag {
            let fragment = try self.fragment(Int(frag))
            let tail = Int(size) - out.count
            guard Int(fragOffset) + tail <= fragment.count else { throw OptionError("squashfs: fragment overrun in \(name)") }
            out += fragment[Int(fragOffset)..<(Int(fragOffset) + tail)]
        }
        guard out.count == Int(size) else { throw OptionError("squashfs: \(name) size mismatch") }
        return out
    }

    // MARK: internals

    private struct DirEntry { let name: String; let inode: UInt64; let type: UInt16 }

    private func rootEntries() throws -> [DirEntry] {
        var r = MetaReader(fs: self, block: inodeTable + Int(rootInode >> 16), offset: Int(rootInode & 0xffff))
        let h = try r.read(16)
        var startBlock: Int, listing: Int, offset: Int
        switch Squashfs.u16(h, 0) {
        case 1:
            let b = try r.read(16)
            startBlock = Int(Squashfs.u32(b, 0)); listing = Int(Squashfs.u16(b, 8)); offset = Int(Squashfs.u16(b, 10))
        case 8:
            let b = try r.read(24)
            listing = Int(Squashfs.u32(b, 4)); startBlock = Int(Squashfs.u32(b, 8)); offset = Int(Squashfs.u16(b, 18))
        default:
            throw OptionError("squashfs: root inode is not a directory")
        }
        // file_size counts 3 extra bytes ("." and "..").
        var remaining = listing - 3
        var d = MetaReader(fs: self, block: dirTable + startBlock, offset: offset)
        var entries: [DirEntry] = []
        while remaining >= 12 {
            let hdr = try d.read(12)
            remaining -= 12
            let count = Int(Squashfs.u32(hdr, 0)) + 1
            let inodeBlock = UInt64(Squashfs.u32(hdr, 4))
            for _ in 0..<count {
                let e = try d.read(8)
                let nameLen = Int(Squashfs.u16(e, 6)) + 1
                let name = String(decoding: try d.read(nameLen), as: UTF8.self)
                remaining -= 8 + nameLen
                entries.append(DirEntry(name: name, inode: inodeBlock << 16 | UInt64(Squashfs.u16(e, 0)), type: Squashfs.u16(e, 4)))
            }
        }
        return entries.filter { $0.type == 2 }
    }

    private func fragment(_ index: Int) throws -> [UInt8] {
        guard index < fragCount else { throw OptionError("squashfs: fragment \(index) out of range") }
        let blockPtr = Int(Squashfs.u64(image, fragTable + 8 * (index / 512)))
        var r = MetaReader(fs: self, block: blockPtr, offset: (index % 512) * 16)
        let e = try r.read(16)
        let word = Squashfs.u32(e, 8)
        return try data(at: Int(Squashfs.u64(e, 0)), length: Int(word & 0x00FF_FFFF), compressed: word & (1 << 24) == 0,
                        capacity: blockSize)
    }

    private func data(at pos: Int, length: Int, compressed: Bool, capacity: Int) throws -> [UInt8] {
        guard pos >= 0, length >= 0, pos + length <= image.count else { throw OptionError("squashfs: block outside the image") }
        guard compressed else { return Array(image[pos..<(pos + length)]) }
        var out = [UInt8](repeating: 0, count: capacity)
        let n = out.withUnsafeMutableBytes { dst in
            image.withUnsafeBytes { src in czstd_decompress(dst.baseAddress, capacity, src.baseAddress! + pos, length) }
        }
        guard n >= 0 else { throw OptionError("squashfs: zstd error at \(pos)") }
        out.removeSubrange(n...)
        return out
    }

    /// Metadata block at absolute `pos`: (decompressed bytes, position of the next block).
    fileprivate func metaBlock(_ pos: Int) throws -> ([UInt8], Int) {
        guard pos + 2 <= image.count else { throw OptionError("squashfs: metadata outside the image") }
        let h = Squashfs.u16(image, pos)
        let len = Int(h & 0x7fff)
        return (try data(at: pos + 2, length: len, compressed: h & 0x8000 == 0, capacity: 8192), pos + 2 + len)
    }

    /// Sequential reader over consecutive metadata blocks.
    private struct MetaReader {
        let fs: Squashfs
        var next: Int
        var buf: [UInt8] = []
        var pos = 0

        init(fs: Squashfs, block: Int, offset: Int) {
            self.fs = fs
            next = block
            pos = offset
        }

        mutating func read(_ n: Int) throws -> [UInt8] {
            if buf.isEmpty {
                (buf, next) = try fs.metaBlock(next)
            }
            var out: [UInt8] = []
            out.reserveCapacity(n)
            while out.count < n {
                if pos >= buf.count {
                    pos -= buf.count
                    (buf, next) = try fs.metaBlock(next)
                    continue
                }
                let take = min(n - out.count, buf.count - pos)
                out += buf[pos..<(pos + take)]
                pos += take
            }
            return out
        }
    }

    static func u16(_ a: [UInt8], _ o: Int) -> UInt16 { UInt16(a[o]) | UInt16(a[o + 1]) << 8 }
    static func u32(_ a: [UInt8], _ o: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(a[o + $1]) << (8 * $1) } }
    static func u64(_ a: [UInt8], _ o: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(a[o + $1]) << (8 * $1) } }
}
