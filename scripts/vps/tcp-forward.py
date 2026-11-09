#!/usr/bin/env python3
"""Minimal TCP forwarder: LISTEN_HOST:LISTEN_PORT -> TARGET_HOST:TARGET_PORT.

Why: Hermes 0.23 Webapp binds only loopback or a wildcard. On a shared host the site's Caddy runs
in Docker and reaches the host via the bridge IP (172.17.0.1). This forwards the bridge address to
the loopback Webapp without exposing it on the public interface. Sign-in stays enforced by Hermes
(webapp.public_url engages the dashboard basic-auth gate even for loopback peers).

Usage: tcp-forward.py 172.17.0.1:9120 127.0.0.1:9120
"""
import asyncio
import sys


async def pipe(reader, writer):
    try:
        while data := await reader.read(65536):
            writer.write(data)
            await writer.drain()
    except (ConnectionError, asyncio.CancelledError):
        pass
    finally:
        try:
            writer.close()
        except Exception:
            pass


async def main(listen, target):
    lhost, lport = listen.rsplit(":", 1)
    thost, tport = target.rsplit(":", 1)

    async def handle(cr, cw):
        try:
            tr, tw = await asyncio.open_connection(thost, int(tport))
        except OSError:
            cw.close()
            return
        await asyncio.gather(pipe(cr, tw), pipe(tr, cw))

    server = await asyncio.start_server(handle, lhost, int(lport))
    print(f"forwarding {listen} -> {target}", flush=True)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    asyncio.run(main(sys.argv[1], sys.argv[2]))
