"""Bounded IPv6 neighbour discovery over Linux packet sockets; no route changes."""
import ipaddress
import selectors
import socket
import struct
import time


def checksum(data):
    if len(data) % 2:
        data += b"\0"
    total = sum(struct.unpack("!%dH" % (len(data) // 2), data))
    while total >> 16:
        total = (total & 0xffff) + (total >> 16)
    return (~total) & 0xffff


def pseudo(source, destination, body):
    return source + destination + struct.pack("!I3xB", len(body), 58) + body


def solicitation(source, hardware, target):
    src = socket.inet_pton(socket.AF_INET6, source)
    dst = socket.inet_pton(socket.AF_INET6, target)
    multicast = bytes.fromhex("ff0200000000000000000001ff") + dst[-3:]
    mac = bytes.fromhex(hardware.replace(":", ""))
    body = struct.pack("!BBHI", 135, 0, 0, 0) + dst + b"\x01\x01" + mac
    body = body[:2] + struct.pack("!H", checksum(pseudo(src, multicast, body))) + body[4:]
    return (b"\x33\x33\xff" + dst[-3:] + mac + b"\x86\xdd" +
            struct.pack("!IHBB16s16s", 6 << 28, len(body), 58, 255, src, multicast) + body)


def advertisement(packet, targets, destination, source):
    if len(packet) < 86 or packet[12:14] != b"\x86\xdd":
        return None
    hardware = packet[6:12]
    if (packet[:6] != bytes.fromhex(destination.replace(":", "")) or hardware[0] & 1
            or hardware == bytes(6) or packet[14] >> 4 != 6 or packet[20:22] != b"\x3a\xff"):
        return None
    src, dst = packet[22:38], packet[38:54]
    length = struct.unpack("!H", packet[18:20])[0]
    if dst != socket.inet_pton(socket.AF_INET6, source) or length < 32 or len(packet) < 54 + length:
        return None
    origin = ipaddress.IPv6Address(src)
    if origin.is_unspecified or origin.is_multicast:
        return None
    body = packet[54:54 + length]
    if body[:2] != b"\x88\x00" or body[4] & 0xc0 != 0x40 or checksum(pseudo(src, dst, body)):
        return None
    target = str(ipaddress.IPv6Address(body[8:24]))
    if target not in targets:
        return None
    offset, links = 24, []
    while offset < len(body):
        if offset + 2 > len(body) or body[offset + 1] == 0:
            return None
        size = body[offset + 1] * 8
        if offset + size > len(body):
            return None
        if body[offset] == 2:
            if size != 8:
                return None
            links.append(body[offset + 2:offset + 8])
        offset += size
    return (target, hardware.hex(":")) if links == [hardware] else None


def observe(interfaces, targets):
    if not targets or not interfaces:
        return []
    sockets, results = [], []
    try:
        with selectors.DefaultSelector() as selector:
            for interface, source, hardware in interfaces:
                connection = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x86dd))
                sockets.append(connection)
                connection.bind((interface, 0))
                connection.setblocking(False)
                selector.register(connection, selectors.EVENT_READ, (source, hardware))
                for target in targets:
                    try:
                        connection.send(solicitation(source, hardware, target))
                    except BlockingIOError:
                        pass
            deadline, packets = time.monotonic() + 0.35, 0
            while (remaining := deadline - time.monotonic()) > 0:
                for key, _ in selector.select(remaining):
                    try:
                        packet = key.fileobj.recv(65536)
                    except BlockingIOError:
                        continue
                    packets += 1
                    if packets > 4096 or len(results) > 256:
                        raise ValueError("local_response_too_large")
                    source, hardware = key.data
                    result = advertisement(packet, targets, hardware, source)
                    if result is not None:
                        results.append(result)
        return results
    finally:
        for connection in sockets:
            connection.close()
