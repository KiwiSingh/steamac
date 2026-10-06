#!/usr/bin/env python3
"""Send a real Steam discovery broadcast; print actual status replies (no VM/disk access).

Run on the Mac or another machine on the same IPv4 subnet:
  python3 scripts/test/remote-play-discovery.py --bind 192.168.1.10 --broadcast 192.168.1.255
The ephemeral source port avoids competing with Steam/launcher UDP 27036.
"""
import argparse
import secrets
import socket
import struct
import time

MAGIC = bytes.fromhex("ffffffff214c5fa0")


def varint(value):
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def fields(data):
    offset = 0

    def number():
        nonlocal offset
        value = 0
        for shift in range(0, 70, 7):
            byte = data[offset]
            offset += 1
            if shift == 63 and byte > 1:
                raise ValueError("overflow")
            value |= (byte & 127) << shift
            if not byte & 128:
                return value
        raise ValueError("varint")

    result = {}
    while offset < len(data):
        key = number()
        wire = key & 7
        if key >> 3 == 0:
            raise ValueError("field zero")
        if wire == 0:
            value = number()
        else:
            size = {1: 8, 5: 4}.get(wire)
            if wire == 2:
                size = number()
            if size is None or size > len(data) - offset:
                raise ValueError("length/wire type")
            value = data[offset:offset + size]
            offset += size
        result.setdefault(key >> 3, []).append(value)
    return result


def status(packet):
    if len(packet) < 16 or packet[:8] != MAGIC:
        return None
    header_size = struct.unpack_from("<I", packet, 8)[0]
    if header_size > len(packet) - 16:
        raise ValueError("header size")
    header = fields(packet[12:12 + header_size])
    body_offset = 12 + header_size
    body_size = struct.unpack_from("<I", packet, body_offset)[0]
    if body_size != len(packet) - body_offset - 4:
        raise ValueError("body size")
    if header.get(2, [0])[-1] != 1:
        return None
    return header, fields(packet[body_offset + 4:])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bind", default="0.0.0.0", help="source LAN IPv4 address")
    parser.add_argument("--expect-host", help="ignore other Steam hosts; require this reply source IPv4")
    parser.add_argument("--broadcast", default="255.255.255.255")
    parser.add_argument("--timeout", type=float, default=20)
    args = parser.parse_args()
    header = b"\x08" + varint(secrets.randbits(64)) + b"\x10\x00"
    body = b"\x08\x01"
    packet = MAGIC + struct.pack("<I", len(header)) + header + struct.pack("<I", len(body)) + body
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        sock.bind((args.bind, 0))
        sock.settimeout(1)
        destination = (args.broadcast, 27036)
        print(f"discovery source={sock.getsockname()} destination={destination} bytes={packet.hex()}", flush=True)
        deadline = time.monotonic() + args.timeout
        next_send = 0
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now >= next_send:
                sock.sendto(packet, destination)
                next_send = now + 3
            try:
                reply, sender = sock.recvfrom(65535)
            except socket.timeout:
                continue
            if args.expect_host and sender[0] != args.expect_host:
                continue
            try:
                decoded = status(reply)
            except (ValueError, IndexError, struct.error):
                continue
            if decoded is None:
                continue
            reply_header, reply_body = decoded
            hostname = reply_body.get(4, [b""])[-1].decode("utf-8", "replace")
            addresses = [value.decode("utf-8", "replace") for value in reply_body.get(20, [])]
            print(f"status sender={sender} client_id={reply_header.get(1)} hostname={hostname!r} "
                  f"connect_port={reply_body.get(3)} ip_addresses={addresses} users={len(reply_body.get(9, []))}", flush=True)
            print(f"reply bytes={reply.hex()}", flush=True)
            return 0
        print("No Steam status reply. Check Remote Play, login state, Local Network permission and firewall.", flush=True)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
