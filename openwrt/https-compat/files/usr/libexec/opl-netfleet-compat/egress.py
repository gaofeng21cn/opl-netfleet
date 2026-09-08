"""Apply the gateway's port allocation policy only to this engine's sockets."""

import socket
import struct


class Egress:
    def __init__(self):
        self.value = None

    def configure(self, policy):
        ports = policy.get("port_range") if isinstance(policy, dict) else None
        if ports is None:
            self.value = None
            return
        if (not isinstance(ports, list) or len(ports) != 2 or
                not all(type(port) is int for port in ports) or not 1 <= ports[0] < ports[1] <= 65535):
            raise ValueError("invalid_egress_port_range")
        value = struct.pack("I", (ports[1] << 16) | ports[0])
        if value != self.value:
            for family in (socket.AF_INET, socket.AF_INET6):
                with socket.socket(family, socket.SOCK_STREAM) as sock:
                    sock.setsockopt(socket.IPPROTO_IP, 51, value)
                    if sock.getsockopt(socket.IPPROTO_IP, 51, 4) != value:
                        raise ValueError("egress_port_range_unsupported")
            self.value = value

    def audit(self, event, args):
        # Python emits this before connect(), including asyncio and TLS bypass sockets.
        if event == "socket.connect" and self.value is not None:
            sock = args[0]
            if sock.family in (socket.AF_INET, socket.AF_INET6) and sock.type == socket.SOCK_STREAM:
                sock.setsockopt(socket.IPPROTO_IP, 51, self.value)
