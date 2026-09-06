"""An isolated TLS origin for the real native routing experiment."""
import asyncio
from pathlib import Path
import sys
from hypercorn.asyncio import serve
from hypercorn.config import Config


async def application(scope, receive, send):
    if scope["type"] != "http":
        return
    while (await receive()).get("more_body"):
        pass
    await send({"type": "http.response.start", "status": 200, "headers": [
        (b"content-length", b"2"), (b"x-upstream-protocol", scope["http_version"].encode())]})
    await send({"type": "http.response.body", "body": b"ok"})


if __name__ == "__main__":
    directory = Path(sys.argv[1])
    config = Config()
    config.bind = ["0.0.0.0:" + sys.argv[2]]
    config.certfile = str(directory / "upstream.pem")
    config.keyfile = str(directory / "upstream.key")
    config.alpn_protocols = ["h2", "http/1.1"]
    config.accesslog = config.errorlog = None
    asyncio.run(serve(application, config))
