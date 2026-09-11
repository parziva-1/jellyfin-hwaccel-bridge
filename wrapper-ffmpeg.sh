#!/bin/bash
# Argv-rewriting ffmpeg wrapper. This is what the bridge daemon actually
# spawns for every job (see bridge-daemon.py, BRIDGE_WRAPPER_PATH) - it runs
# on the real host, with access to a real, hardware-capable ffmpeg build.
#
# Decode: ALWAYS stays software. Any "-hwaccel ...mediacodec..." is stripped
# defensively (Jellyfin doesn't emit this while its own hardware-acceleration
# setting is "none", but never trust it - see the design notes on why
# hardware DECODE must never be used here).
# Encode: rewrite libx264->h264_mediacodec, libx265->hevc_mediacodec. Strip
# options private to the software x264/x265 encoders
# (-preset/-crf/-x264opts/-x265-params/-tune/-profile:v/-level) and backfill
# -b:v from the existing -maxrate value (mediacodec has no CRF concept).
# Everything else (filters, audio, muxer/HLS args, mapping) passes through
# unchanged. Unrecognized shapes (no libx264/libx265 target) pass through
# untouched to the real ffmpeg.

REAL_FFMPEG="${REAL_FFMPEG:-/usr/bin/ffmpeg}"
LOG="${BRIDGE_WRAPPER_LOG:-/var/log/bridge-wrapper.log}"

args=("$@")
n=${#args[@]}
out=()
target_enc=""
maxrate_val=""

i=0
while [ $i -lt $n ]; do
  case "${args[$i]}" in
    -maxrate*) maxrate_val="${args[$((i+1))]}" ;;
  esac
  i=$((i+1))
done

i=0
while [ $i -lt $n ]; do
  a="${args[$i]}"
  case "$a" in
    -hwaccel)
      nextv="${args[$((i+1))]}"
      case "$nextv" in
        *mediacodec*)
          i=$((i+2)); continue ;;
      esac
      out+=("$a"); i=$((i+1)) ;;
    -codec:v*|-c:v*)
      v="${args[$((i+1))]}"
      case "$v" in
        libx264) out+=("$a" "h264_mediacodec"); target_enc="h264_mediacodec" ;;
        libx265) out+=("$a" "hevc_mediacodec"); target_enc="hevc_mediacodec" ;;
        *)       out+=("$a" "$v") ;;
      esac
      i=$((i+2)) ;;
    -preset*|-crf*|-x264opts*|-x265-params*|-tune*|-profile:v*|-level*)
      if [ -n "$target_enc" ]; then
        i=$((i+2)); continue
      else
        out+=("$a" "${args[$((i+1))]}"); i=$((i+2))
      fi ;;
    *)
      out+=("$a"); i=$((i+1)) ;;
  esac
done

if [ -n "$target_enc" ]; then
  # Force the hardware encoder's input to NV12/limited-range, unconditionally.
  # Many legacy codecs (RV30/RV40, Indeo, Cinepak, old DivX/XviD, Sorenson)
  # decode to plain/full-range YUV420P or other layouts that AMediaCodec
  # hardware encoders declare supported but actually hang or misbehave on -
  # this is a known-unreliable-input-format problem, not a resolution/
  # alignment issue (this is why WebRTC always force-converts to NV12 on its
  # own Android hardware-encode path rather than trusting the capability
  # flag). format=nv12 auto-inserts an swscale conversion that normalizes
  # ANY source layout; setrange=tv re-tags it limited-range afterward, since
  # hardware encoders generally assume BT.601/709 limited range and some
  # legacy decoders output full-range instead. Software encode (the
  # fallback path, using $args unmodified) already handles arbitrary input
  # formats fine and is deliberately left untouched.
  vf_idx=-1
  j=0
  while [ $j -lt ${#out[@]} ]; do
    case "${out[$j]}" in
      -vf|-filter:v) vf_idx=$((j+1)) ;;
    esac
    j=$((j+1))
  done
  if [ $vf_idx -ge 0 ]; then
    out[$vf_idx]="${out[$vf_idx]},format=nv12,setrange=tv"
  else
    final=()
    inserted=0
    j=0
    while [ $j -lt ${#out[@]} ]; do
      if [ "$inserted" = "0" ]; then
        case "${out[$j]}" in
          -codec:v*|-c:v*) final+=("-vf" "format=nv12,setrange=tv"); inserted=1 ;;
        esac
      fi
      final+=("${out[$j]}")
      j=$((j+1))
    done
    out=("${final[@]}")
  fi

  bv="${maxrate_val:-4M}"
  final=()
  inserted=0
  j=0
  while [ $j -lt ${#out[@]} ]; do
    final+=("${out[$j]}")
    if [ "$inserted" = "0" ] && [ "${out[$j]}" = "$target_enc" ]; then
      final+=("-b:v" "$bv")
      inserted=1
    fi
    j=$((j+1))
  done
  out=("${final[@]}")
fi

echo "$(date -Iseconds) target_enc=${target_enc:-none} maxrate=${maxrate_val:-none} argc_in=$n argc_out=${#out[@]}" >> "$LOG"

if [ -n "$target_enc" ]; then
  # Hardware path: run in background (not exec) so we can watch for a hang
  # AND fall back on a clean failure. A viewer should never see a hard error
  # or an indefinite stall just because hardware encode rejected or froze on
  # this particular file - worst case is software quality/speed, not a
  # broken stream. Every fallback is logged (flags/counts only) so it stays
  # visible.
  #
  # Real HLS sessions have no -t bound (they run for the whole title), so a
  # flat timeout on the whole process would kill a legitimately slow-but-
  # working encode too. Instead: give it a bounded window to START producing
  # output (the muxer's target file appearing); if it never does, treat it
  # as hung and kill it outright (SIGTERM then SIGKILL - hardware encoders
  # that hang can ignore SIGTERM alone); if it does start producing output
  # in time, let it run to completion normally.
  out_file="${out[-1]}"
  "$REAL_FFMPEG" "${out[@]}" &
  hw_pid=$!
  waited=0
  hung=0
  while [ $waited -lt 20 ]; do
    if ! kill -0 "$hw_pid" 2>/dev/null; then
      break
    fi
    if [ -e "$out_file" ]; then
      break
    fi
    sleep 1
    waited=$((waited+1))
  done
  if kill -0 "$hw_pid" 2>/dev/null && [ ! -e "$out_file" ]; then
    hung=1
    echo "$(date -Iseconds) HANG_DETECTED target_enc=$target_enc no output after ${waited}s -> killing" >> "$LOG"
    kill -TERM "$hw_pid" 2>/dev/null
    sleep 5
    kill -0 "$hw_pid" 2>/dev/null && kill -KILL "$hw_pid" 2>/dev/null
  fi
  wait "$hw_pid" 2>/dev/null
  rc=$?
  if [ "$hung" = "1" ]; then
    rc=1
  fi
  if [ $rc -ne 0 ]; then
    echo "$(date -Iseconds) FALLBACK target_enc=$target_enc exited rc=$rc -> retrying software encode, argc=$n" >> "$LOG"
    exec "$REAL_FFMPEG" "${args[@]}"
    echo "$(date -Iseconds) FALLBACK_EXEC_DID_NOT_LAUNCH" >> "$LOG"
  fi
  exit $rc
else
  exec "$REAL_FFMPEG" "${out[@]}"
fi
