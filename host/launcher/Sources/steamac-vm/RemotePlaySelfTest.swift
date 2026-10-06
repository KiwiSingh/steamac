import Darwin
import Foundation

enum RemotePlaySelfTest {
    static func run() -> Never {
        var failures = 0, checks = 0
        func check(_ success: Bool, _ name: String) {
            checks += 1
            if !success { failures += 1 }
            print("remote-play selftest: \(success ? "PASS" : "FAIL") \(name)")
        }
        let header = Data([0x08, 0x7b, 0x10, 1, 0x18, 0x2a])
        func string(_ field: UInt64, _ text: String) -> Data {
            var data = RemotePlayPacket.varint(field << 3 | 2)
            let value = Data(text.utf8)
            data.append(RemotePlayPacket.varint(UInt64(value.count))); data.append(value)
            return data
        }
        var body = Data([0x08, 1, 0x18, 0x9c, 0xd3, 1]) // connect_port = 27036
        body.append(string(4, "SteamOS"))
        body.append(string(20, "192.168.127.2"))
        body.append(string(20, "fe80::1234"))
        body.append(string(21, "203.0.113.1"))
        let unknown = Data([0xa8, 0x06, 0xff, 0x01]) // future varint field 101
        body.append(unknown)
        let wire = RemotePlayPacket.envelope(header: header, body: body)
        let packet = RemotePlayPacket(wire)
        check(packet?.type == 1, "decode real remote-client framing")
        let rewritten = packet.map { $0.advertised(on: "10.20.30.40") }.flatMap(RemotePlayPacket.init)
        check(rewritten?.header == header, "preserve identity and message type")
        let fields = rewritten.flatMap { RemotePlayPacket.fields($0.body) } ?? []
        let addresses = fields.filter { $0.number == 20 || $0.number == 21 }.map {
            String(decoding: rewritten!.body.subdata(in: $0.value), as: UTF8.self)
        }
        check(addresses == ["10.20.30.40", "10.20.30.40"], "replace all guest/public addresses with Mac LAN address")
        check(fields.first { $0.number == 3 }?.integer == 27036, "retain same-port TCP control forward")
        check(rewritten?.body.suffix(unknown.count) == unknown, "preserve unknown fields")
        let legacy = RemotePlayPacket(RemotePlayPacket.envelope(header: header, body: Data([0x18, 0x9c, 0xd3, 1])))!
        let legacyRewrite = RemotePlayPacket(legacy.advertised(on: "10.20.30.40"))!
        check(RemotePlayPacket.fields(legacyRewrite.body)?.contains { $0.number == 20 } == true,
              "add host address for older status schema")
        let discovery = RemotePlayPacket.discovery(clientID: UInt64.max, sequence: 1)
        check(RemotePlayPacket(discovery)?.advertised(on: "10.20.30.40") == discovery,
              "leave client discovery untouched")
        check(RemotePlayPacket(Data(wire.dropLast())) == nil, "reject truncated body")
        var badLength = wire; badLength[8] = 0xff; badLength[9] = 0xff
        check(RemotePlayPacket(badLength) == nil, "reject oversized header length")
        var badMagic = wire; badMagic[0] = 0
        check(RemotePlayPacket(badMagic) == nil, "reject non-Steam datagrams")
        check(RemotePlayPacket.fields(Data([8] + [UInt8](repeating: 0xff, count: 10))) == nil,
              "reject overflowing protobuf varint")
        check(RemotePlayPacket.fields(Data([0x22, 0xff, 0xff, 0x7f])) == nil,
              "reject oversized protobuf string")
        check(RemotePlayPacket.fields(Data([0])) == nil, "reject protobuf field zero")
        print("remote-play selftest: \(checks) checks, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
