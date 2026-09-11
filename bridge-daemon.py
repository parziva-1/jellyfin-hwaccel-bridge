#!/usr/bin/env python3
"""
Host-side bridge daemon. Runs on the Android/Termux host (or any host with a
real, capable ffmpeg build) and listens ONLY on the address that your
container network's gateway/bridge interface uses - never on 0.0.0.0 - so it
is reachable from containers on that network but never exposed to your LAN.

Reuses your argv-rewrite wrapper unchanged by spawning it as a child process
(see wrapper-ffmpeg.sh in this same project) - no rewrite logic duplicated
here, the daemon's only job is transport + path translation.

Protocol (one TCP connection per job):
  client -> daemon: 4-byte big-endian length + JSON {"argv": [...]}
  daemon -> client: repeated frames: 1-byte type + 4-byte big-endian length + payload
      type 1 = stdout chunk
      type 2 = stderr chunk
      type 3 = exit code (4-byte signed big-endian), then connection closes
  client -> daemon (anytime after the job starts): raw bytes containing "KILL"
      requests a graceful stop; an EOF/disconnect on that same read is treated
      identically (the client dying to an untrappable SIGKILL must still stop
      the real ffmpeg process on the host - this is the hard safety requirement).

Configuration is entirely via environment variables (see the block below) -
there is nothing in this file that needs editing for your own deployment.
"""
import json
import os
import socket
import struct
import subprocess
import threading
import time

# BRIDGE_BIND_ADDR must be the IP your container runtime's bridge network
# gateway uses on the HOST side (e.g. `docker network inspect <network>` ->
# .IPAM.Config[].Gateway). 172.17.0.1 is Docker's out-of-the-box default
# bridge network gateway - override this if you're using a custom network
# (`docker network create ...`), which is common and will have a different
# gateway IP. Never bind this to 0.0.0.0 - it would make the daemon (and the
# real ffmpeg process it can spawn on your host) reachable from your LAN.
HOST = os.environ.get("BRIDGE_BIND_ADDR", "172.17.0.1")
PORT = int(os.environ.get("BRIDGE_PORT", "9919"))

# Path to the argv-rewrite wrapper script (wrapper-ffmpeg.sh) on this host.
WRAPPER = os.environ.get("BRIDGE_WRAPPER_PATH", "/opt/bridge/wrapper-ffmpeg.sh")
LOG = os.environ.get("BRIDGE_LOG_PATH", "/var/log/bridge-daemon.log")

# Your container only ever knows ITS OWN container-internal mount points - it
# has no concept of host paths. Every -i/-hls_segment_filename/output path
# Jellyfin generates uses one of these container-side prefixes. The real
# ffmpeg process runs on THIS host (spawned by this daemon), so every such
# prefix must be translated to the real host path backing that container
# mount before exec. Longest-prefix-first so a more specific mapping never
# gets shadowed by a shorter one.
#
# These three (/media, /config, /cache) match Jellyfin's own standard Docker
# volume layout (https://jellyfin.org/docs/general/installation/container).
# Add more entries here if your container has additional bind mounts that
# ffmpeg's argv can reference (e.g. multiple separate media libraries).
PATH_MAP = [
    ("/media", os.environ.get("BRIDGE_MEDIA_HOST_PATH", "/path/to/your/media")),
    ("/config", os.environ.get("BRIDGE_CONFIG_HOST_PATH", "/path/to/your/jellyfin/config")),
    ("/cache", os.environ.get("BRIDGE_CACHE_HOST_PATH", "/path/to/your/jellyfin/cache")),
]
PATH_MAP.sort(key=lambda kv: -len(kv[0]))


def translate_path(token):
    # Jellyfin's real ffmpeg invocation prefixes local file paths with a
    # "file:" URI scheme (e.g. "file:/media/movie.mkv") - strip it before
    # matching the container mount prefix, then re-add it so ffmpeg still
    # sees the same URI form it was given, just pointed at the host path.
    uri_prefix = ""
    remainder = token
    if remainder.startswith("file:"):
        uri_prefix = "file:"
        remainder = remainder[len("file:"):]
    for container_prefix, host_prefix in PATH_MAP:
        if remainder == container_prefix or remainder.startswith(container_prefix + "/"):
            return uri_prefix + host_prefix + remainder[len(container_prefix):]
    return token


def translate_argv(argv):
    return [translate_path(a) for a in argv]


def log(msg):
    with open(LOG, "a") as f:
        f.write("%.3f %s\n" % (time.time(), msg))


def send_frame(sock, ftype, payload):
    try:
        sock.sendall(struct.pack(">BI", ftype, len(payload)) + payload)
    except OSError:
        pass


def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            return None
        buf += chunk
    return buf


def pump_stream(proc_stream, sock, ftype, done_event):
    # Straightforward blocking read-and-forward is fine on THIS side: the
    # daemon's TCP send only backpressures if the client stops draining its
    # end of the socket, and the client-side fix (see bridge-client, the
    # container-side counterpart) guarantees it never blocks on its own
    # local stdout/stderr writes long enough to stop reading this socket.
    # That guarantee is what makes a plain blocking sendall() safe here.
    try:
        while True:
            chunk = proc_stream.read(4096)
            if not chunk:
                break
            send_frame(sock, ftype, chunk)
    except (OSError, ValueError):
        pass
    done_event.set()


def watch_control(sock, proc, kill_event):
    # Blocks until the client sends a control message OR disconnects.
    # Both cases must kill the child - this is the untrappable-SIGKILL safety net.
    reason = "unknown"
    try:
        while True:
            data = sock.recv(64)
            if not data:
                reason = "client disconnected"
                break
            if b"KILL" in data:
                reason = "client requested KILL"
                break
    except OSError:
        reason = "socket error"
    kill_event.set()
    log("stopping child: %s" % reason)
    try:
        proc.terminate()
        for _ in range(50):  # 5s grace
            if proc.poll() is not None:
                break
            time.sleep(0.1)
        else:
            log("child ignored SIGTERM, sending SIGKILL")
            proc.kill()
    except Exception as e:
        log("error stopping child: %s" % e)


def enable_aggressive_keepalive(conn):
    # A container that dies abruptly (SIGKILL, netns teardown) does not
    # always deliver a clean TCP FIN/RST - recv() can then block forever,
    # leaving the real ffmpeg process on the host orphaned. TCP keepalive
    # makes the kernel actively probe and fail the socket within a bounded
    # time even with a totally silent, vanished peer.
    conn.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
    try:
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPIDLE, 2)
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPINTVL, 1)
        conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_KEEPCNT, 3)
    except (AttributeError, OSError) as e:
        log("keepalive tuning unavailable, using OS defaults: %s" % e)


def handle_client(conn, addr):
    enable_aggressive_keepalive(conn)
    log("connection from %s" % (addr,))
    length_bytes = recv_exact(conn, 4)
    if not length_bytes:
        conn.close()
        return
    (jlen,) = struct.unpack(">I", length_bytes)
    job_json = recv_exact(conn, jlen)
    if not job_json:
        conn.close()
        return
    job = json.loads(job_json.decode())
    argv = job.get("argv", [])
    argv = translate_argv(argv)
    log("job argv_len=%d" % len(argv))

    proc = subprocess.Popen(
        [WRAPPER] + argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        bufsize=0,
    )

    kill_event = threading.Event()
    ctrl_thread = threading.Thread(target=watch_control, args=(conn, proc, kill_event), daemon=True)
    ctrl_thread.start()

    out_done = threading.Event()
    err_done = threading.Event()
    threading.Thread(target=pump_stream, args=(proc.stdout, conn, 1, out_done), daemon=True).start()
    threading.Thread(target=pump_stream, args=(proc.stderr, conn, 2, err_done), daemon=True).start()

    rc = proc.wait()
    out_done.wait(timeout=2)
    err_done.wait(timeout=2)
    send_frame(conn, 3, struct.pack(">i", rc))
    log("job done rc=%s killed=%s" % (rc, kill_event.is_set()))
    try:
        conn.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    conn.close()


def main():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((HOST, PORT))
    srv.listen(8)
    log("daemon listening on %s:%d (bridge-only, not LAN-reachable)" % (HOST, PORT))
    while True:
        conn, addr = srv.accept()
        threading.Thread(target=handle_client, args=(conn, addr), daemon=True).start()


if __name__ == "__main__":
    main()
