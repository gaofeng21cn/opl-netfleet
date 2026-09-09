"""Bounded on-link IPv6 validation without changing addresses or routing."""
from concurrent.futures import ThreadPoolExecutor
import ipaddress
import socket


def advertisement(packet, targets, destination, source):
    from scapy.layers.inet6 import IPv6, ICMPv6ND_NA, ICMPv6NDOptDstLLAddr, in6_chksum
    from scapy.layers.l2 import Ether

    if not all(packet.haslayer(layer) for layer in (Ether, IPv6, ICMPv6ND_NA, ICMPv6NDOptDstLLAddr)):
        return None
    ip, nd, link = packet[IPv6], packet[ICMPv6ND_NA], packet[ICMPv6NDOptDstLLAddr]
    target = str(ipaddress.IPv6Address(nd.tgt))
    mac = packet[Ether].src.lower()
    if (target not in targets or ip.dst != source or ip.hlim != 255 or ip.nh != 58 or nd.code != 0 or not nd.S or nd.R
            or packet[Ether].dst.lower() != destination.lower() or link.len != 1
            or link.lladdr.lower() != mac or int(mac[:2], 16) & 1 or mac == "00:00:00:00:00:00"
            or in6_chksum(58, nd, bytes(nd)) != 0):
        return None
    return target, mac


def probe(interface, source, hardware, targets):
    # Scapy's L2 socket keeps discovery independent of the router's normal route.
    from scapy.layers.inet6 import IPv6, ICMPv6ND_NS, ICMPv6NDOptSrcLLAddr
    from scapy.layers.l2 import Ether
    from scapy.sendrecv import srp

    packets = []
    for target in targets:
        tail = socket.inet_pton(socket.AF_INET6, target)[-3:]
        multicast = socket.inet_ntop(socket.AF_INET6, bytes.fromhex("ff0200000000000000000001ff") + tail)
        packets.append(Ether(src=hardware, dst="33:33:ff:" + tail.hex(":")) /
                       IPv6(src=source, dst=multicast, hlim=255) / ICMPv6ND_NS(tgt=target) /
                       ICMPv6NDOptSrcLLAddr(lladdr=hardware))
    if not packets:
        return []
    answered, _ = srp(packets, iface=interface, timeout=0.35, inter=0.001, multi=True,
                      verbose=False, promisc=False, type=0x86dd)
    if len(answered) > 256:
        raise ValueError("local_response_too_large")
    return [result for _, packet in answered if (result := advertisement(packet, targets, hardware, source))]


def observe(interfaces, targets):
    if not targets or not interfaces:
        return []
    # Import once before starting workers; Scapy's initial layer registration is shared.
    import scapy.layers.inet6  # noqa: F401
    import scapy.layers.l2  # noqa: F401
    import scapy.sendrecv  # noqa: F401

    if len(interfaces) == 1:
        return probe(*interfaces[0], targets)
    with ThreadPoolExecutor(max_workers=4) as workers:
        return [item for result in workers.map(lambda row: probe(*row, targets), interfaces) for item in result]
