[Versión en español](README.es.md)

# A Docker-to-host bridge for hardware-accelerated ffmpeg on Android

Jellyfin runs great in Docker on almost anything — except when the only hardware video encoder
available lives behind an ABI your container can't reach at all. That's exactly the situation on
Android: real hardware encode is right there in the same kernel as your container, and yet a
completely normal Jellyfin-in-Docker setup has no way to touch it, no matter how you compile
ffmpeg. This is the three-piece bridge that gets around that, without moving Jellyfin out of
Docker at all.

Developed and validated on a phone repurposed as a small home media server — an Android device
with an Exynos SoC, running the workload in Termux — but nothing here is specific to that chip.
Any Android device exposing hardware `AMediaCodec` encode through Termux should work the same way.

## The problem

On Android, hardware video encode/decode is exposed through `AMediaCodec`, part of the Android
NDK, implemented in `libmediandk.so`. That library is built against **bionic**, Android's C
library. A normal Docker container — Debian, Alpine, whatever — runs a userland built against
**glibc** or **musl**. A binary linked against glibc/musl cannot `dlopen()` a bionic `.so`, full
stop, regardless of who built it or what flags were used. FFmpeg compiled with
`--enable-mediacodec` inside a standard Docker container therefore has no way to reach the
hardware encoder that's sitting right there in the same kernel.

The only way to actually reach `AMediaCodec` is to run a real Android/Termux userland (bionic)
directly on the device, outside of Docker. Which raises the obvious question: does that mean
Jellyfin itself has to leave Docker?

**No.** Jellyfin is a .NET server with zero ABI dependency on Android — it only ever invokes
`ffmpeg` as an external process via a command line and a configured binary path. The ABI mismatch
is entirely a property of the *ffmpeg binary*, not of Jellyfin. So Jellyfin can stay exactly where
it is — same container, same config, same libraries, same everything — and only the thing standing
in for "ffmpeg" needs to change.

## The design

Three pieces:

1. **`bridge-client.pl`** (inside the container) — a small script you point Jellyfin's `--ffmpeg`
   flag at instead of a real ffmpeg binary. From Jellyfin's point of view, this *is* ffmpeg: it
   takes the same argv, it streams stdout/stderr back live, it exits with the same code a real
   ffmpeg process would. Written in Perl specifically because most minimal container images ship
   Perl's core `IO::Socket`/`IO::Select` for free, letting this run with zero extra packages
   installed into the image.
2. **`bridge-daemon.py`** (on the real host) — a small, persistent daemon listening only on your
   container network's bridge/gateway address (never your LAN). It receives a job (an argv list)
   from the client, translates any container-internal path in that argv to the real host path
   backing the same bind mount, and spawns the wrapper as a child process.
3. **`wrapper-ffmpeg.sh`** (on the real host) — rewrites the *encoder* argument only (`-c:v
   libx264` → `-c:v h264_mediacodec`, and the HEVC equivalent), strips a handful of options that
   are meaningless to a hardware encoder (`-preset`, `-crf`, etc.), and hands everything else to a
   real, hardware-capable ffmpeg build unchanged.

Input and output files live on the same filesystem the daemon can already see (the same bind
mounts your container uses, just from the host side), so the only thing that actually crosses the
client/daemon boundary is a short argv and a live stdout/stderr text stream — never the media
bytes themselves. That's what makes this fast and simple: no video data is ever proxied.

## Three design constraints that matter if you build on this

These weren't obvious going in, and getting either one wrong produces symptoms that look
completely unrelated to the actual cause.

### 1. Decode must always stay software

It's tempting to hand `-hwaccel mediacodec` to the *decoder* too, once you've confirmed the
encoder side works. Don't. Hardware decode via `AMediaCodec` expects a real Android app context —
a `SurfaceTexture`/`ANativeWindow` backed by an actual `Activity` and a GPU-composited window. A
headless process (Termux, or any similarly headless container) has none of that. The result isn't
a clean error — it's a hard hang. The decoder call blocks indefinitely and **ignores SIGTERM**;
only SIGKILL actually stops it. This is an architectural limitation of the platform, not a
compile-time flag you can fix — `--disable-decoder=h264_mediacodec` at ffmpeg build time is a real
safeguard worth adding, but it only prevents the mistake, it doesn't unlock anything.

The wrapper above encodes this as a hard rule: it only ever rewrites the *encoder* (`-c:v`), and
defensively strips any `-hwaccel *mediacodec*` it sees on the way in, regardless of where it might
have come from. Decode is always the normal software path. Encode is the only place hardware
acceleration is used.

Real-world hardware encoders also reject or hang on some inputs outright (resolution, profile, bit
depth, and so on can all trigger this) — not every file is compatible with every device's encoder.
The wrapper handles this with a bounded wait for the muxer's output to actually start appearing on
disk: if nothing shows up within a short window, it kills the hardware attempt (SIGTERM, then
SIGKILL if that's ignored) and transparently retries with a pure software encode — so a single
incompatible file degrades to software-speed, not to a broken stream.

### 2. The stdout/stderr relay must be non-blocking, or it deadlocks everything

This one is subtler and took real production debugging to actually pin down.

The client script (`bridge-client.pl`) needs to write ffmpeg's stdout and stderr back to *its own*
stdout/stderr, because Jellyfin is watching those streams the same way it would watch a real
ffmpeg process's output (mainly stderr, to know encoding is progressing and the process hasn't
gone unresponsive). The naive implementation just does `print STDOUT $payload` and
`print STDERR $payload` as data arrives.

That's a blocking write. And here's the trap: for a real Jellyfin transcode job, **Jellyfin does
not read the wrapped process's stdout at all** — it only reads stderr. If the client script ever
writes anything of size to stdout, nothing is on the other end of that pipe to drain it. The OS
pipe buffer fills up (typically 64KB on Linux) almost immediately, and the next `print STDOUT`
call blocks — not for a moment, but *forever*, since nobody is ever going to read from that pipe.

Once that write blocks, the client script's main loop stops entirely — it can't get back around to
reading more data from the daemon's socket. That backpressures the daemon's own send calls, which
backpressures the real ffmpeg process running on the host (its own stdout/stderr pipes to the
daemon fill up next), and the *entire* pipeline seizes. From the outside this looks exactly like a
mysteriously hung transcode: the real ffmpeg process is still alive, still burning CPU on its
already-buffered work, but no further progress is ever visible and no output is ever delivered to
the end client — all triggered by an output stream nobody even needed in the first place.

The fix: make both stdout and stderr writes on the client side **non-blocking**
(`fcntl(..., O_NONBLOCK)`), and route them through a small bounded, in-memory buffer per stream
instead of writing directly. Each iteration of the main loop opportunistically flushes whatever it
can without blocking; if a destination is full, the write simply doesn't happen that iteration —
the socket-draining loop is never held up by it, and if the buffer is ever full, the oldest data is
quietly dropped rather than grown without bound. A full or completely absent downstream reader now
just means "nothing gets through," never "everything stalls forever."

The invariant to hold onto, if you're building anything similar: **a slow or entirely absent
downstream consumer must never be able to block your process from continuing to drain its upstream
input.** Any relay loop that violates this is one quiet reader away from a full deadlock.

### 3. Boot-time scripts don't inherit your interactive shell's `PATH` — use absolute paths

This one cost real downtime to track down, and the symptom pointed nowhere near the actual cause.

If you run the daemon (or its restart-on-crash wrapper) via a boot mechanism that escalates
privilege in a fresh shell — a `su`/`sudo` wrapper, a systemd unit with its own minimal
environment, an init script — that shell does **not** inherit the `PATH` your normal interactive
session has. A restart loop that launches the daemon with a bare `python3` (relying on it being
resolvable on `PATH`, which is true in every interactive shell you'd test it from) will fail with
"command not found" on every single boot, even though it works perfectly every time you run it by
hand. The restart loop then does exactly what it's designed to do — retries immediately, forever —
which turns one missing binary into a tight crash-loop rather than an obvious one-line error.

The fix is mechanical: use the absolute path to the interpreter (or binary) in anything a
boot-time script launches — `/path/to/python3`, not `python3`. Don't rely on `PATH` being set up
the way it is in the shell you're testing from; boot-time execution contexts routinely aren't.

A related, secondary risk worth guarding against regardless: if the daemon and the container that
depends on it both start from the same boot sequence, there's no inherent guarantee the daemon has
bound its listening socket before the container's own startup-time capability check reaches it.
Having the container-management code wait, bounded, for the daemon's port to be listening before a
cold start is cheap insurance against that race, on top of getting the `PATH` issue right.

## What's genuinely reusable here vs. what's specific to your setup

The protocol, the path-translation mechanism, the hang-detection logic, and the non-blocking relay
fix are all general and should work as-is for any "Jellyfin-in-Docker, hardware encoder outside
the container's reach" situation — not just Android/mediacodec. Swap the encoder names in
`wrapper-ffmpeg.sh` and this same three-piece shape works for, say, a VAAPI device node your
container can't see, or any other host-side hardware capability your container runtime can't pass
through directly.

What you'll need to fill in for your own deployment (all via environment variables, documented
inline in each file — nothing needs to be hand-edited in the scripts themselves):

- `BRIDGE_BIND_ADDR` / `BRIDGE_PORT` — your container network's gateway address and a port of your
  choosing.
- `BRIDGE_MEDIA_HOST_PATH` / `BRIDGE_CONFIG_HOST_PATH` / `BRIDGE_CACHE_HOST_PATH` — the real host
  paths backing your container's `/media`, `/config`, and `/cache` bind mounts (add more
  `PATH_MAP` entries in `bridge-daemon.py` if you have additional mounts).
- `BRIDGE_WRAPPER_PATH` / `REAL_FFMPEG` — where the wrapper script and your real,
  hardware-capable ffmpeg binary actually live on the host.

## Setup sketch

1. On the host (Termux or otherwise), install an ffmpeg build with hardware mediacodec support
   compiled in, and drop `wrapper-ffmpeg.sh` + `bridge-daemon.py` somewhere on it.
2. Set the environment variables above to match your actual bind-mount paths and container
   network, then run `bridge-daemon.py` as a long-lived process (a simple restart-on-crash loop
   around it is cheap insurance).
3. Bake `bridge-client.pl` into your Jellyfin container image (or bind-mount it in), and point
   Jellyfin's `--ffmpeg` startup flag (or the equivalent env var for your deployment) at it instead
   of the real ffmpeg binary.
4. Restart the container. Jellyfin now transcodes through your host's hardware encoder — with an
   automatic, transparent fallback to software for anything the hardware can't handle.
