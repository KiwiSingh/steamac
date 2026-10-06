import Foundation

/// Steam's UDP remote-client envelope: magic, LE header length, protobuf header,
/// LE body length, protobuf body. Unknown protobuf fields are preserved byte-for-byte.
/// Schema: SteamDatabase/Protobufs, steammessages_remoteclient_discovery.proto.
struct RemotePlayPacket {
    static let magic: [UInt8] = [0xff, 0xff, 0xff, 0xff, 0x21, 0x4c, 0x5f, 0xa0]
    let header: Data
    let body: Data
    let type: UInt64

    struct Field {
        let number: UInt64
        let wire: UInt64
        let raw: Range<Int>
        let value: Range<Int>
        let integer: UInt64?
    }

    static func fields(_ data: Data) -> [Field]? {
        var result: [Field] = [], offset = 0
        func varint() -> UInt64? {
            var value: UInt64 = 0
            for shift in stride(from: 0, through: 63, by: 7) {
                guard offset < data.count else { return nil }
                let byte = data[offset]; offset += 1
                if shift == 63 && byte > 1 { return nil }
                value |= UInt64(byte & 0x7f) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }
        while offset < data.count {
            let start = offset
            guard let key = varint(), key >> 3 != 0 else { return nil }
            let wire = key & 7
            var valueStart = offset, integer: UInt64?
            switch wire {
            case 0: guard let n = varint() else { return nil }; integer = n
            case 1: guard data.count - offset >= 8 else { return nil }; offset += 8
            case 2:
                guard let length = varint(), length <= UInt64(data.count - offset) else { return nil }
                valueStart = offset; offset += Int(length)
            case 5: guard data.count - offset >= 4 else { return nil }; offset += 4
            default: return nil // groups are not used by Steam's discovery schema
            }
            result.append(Field(number: key >> 3, wire: wire, raw: start..<offset,
                                value: valueStart..<offset, integer: integer))
        }
        return result
    }

    init?(_ data: Data) {
        guard data.count >= 16, data.prefix(8).elementsEqual(Self.magic) else { return nil }
        func length(_ offset: Int) -> Int {
            (0..<4).reduce(0) { $0 | (Int(data[offset + $1]) << ($1 * 8)) }
        }
        let headerLength = length(8)
        guard headerLength <= data.count - 16 else { return nil }
        let bodyOffset = 12 + headerLength
        let bodyLength = length(bodyOffset)
        guard bodyLength == data.count - bodyOffset - 4 else { return nil }
        header = data.subdata(in: 12..<bodyOffset)
        body = data.subdata(in: (bodyOffset + 4)..<data.count)
        guard let fields = Self.fields(header), Self.fields(body) != nil else { return nil }
        let types = fields.filter { $0.number == 2 }
        guard types.allSatisfy({ $0.wire == 0 }), (types.last?.integer ?? 0) <= 16 else { return nil }
        type = types.last?.integer ?? 0
    }

    static func varint(_ number: UInt64) -> Data {
        var n = number, data = Data()
        repeat {
            let byte = UInt8(n & 0x7f); n >>= 7
            data.append(byte | (n == 0 ? 0 : 0x80))
        } while n != 0
        return data
    }

    static func envelope(header: Data, body: Data) -> Data {
        var data = Data(magic)
        func appendLength(_ count: Int) {
            for shift in stride(from: 0, to: 32, by: 8) { data.append(UInt8(truncatingIfNeeded: count >> shift)) }
        }
        appendLength(header.count); data.append(header)
        appendLength(body.count); data.append(body)
        return data
    }

    static func discovery(clientID: UInt64, sequence: UInt64) -> Data {
        var header = Data([0x08]); header.append(varint(clientID)); header.append(contentsOf: [0x10, 0])
        var body = Data([0x08]); body.append(varint(sequence))
        return envelope(header: header, body: body)
    }

    /// Ports are kept unchanged: gvproxy exposes the same TCP/UDP ports on the Mac.
    /// Replace the guest's address list (including IPv6/link-local) with the receiving LAN
    /// interface's IPv4 address. Public-IP hints must not bypass the Mac's forward either.
    func advertised(on address: String) -> Data {
        guard type == 1, let fields = Self.fields(body) else {
            return Self.envelope(header: header, body: body)
        }
        var rewritten = Data(), inserted = false
        func appendAddress(_ field: UInt64) {
            let value = Data(address.utf8)
            rewritten.append(Self.varint(field << 3 | 2))
            rewritten.append(Self.varint(UInt64(value.count))); rewritten.append(value)
        }
        for field in fields {
            if field.number == 20 {
                if !inserted { appendAddress(20); inserted = true }
            } else if field.number == 21 {
                appendAddress(21)
            } else {
                rewritten.append(body.subdata(in: field.raw))
            }
        }
        if !inserted { appendAddress(20) }
        return Self.envelope(header: header, body: rewritten)
    }
}
