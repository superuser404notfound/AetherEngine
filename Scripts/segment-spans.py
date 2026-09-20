#!/usr/bin/env python3
"""Print per-track [tfdt, tfdt + sum(sample_duration)] for every moof in an fMP4 file.

Answers one question about a run of produced segments: are they contiguous, do
they overlap, or do they leave a hole, and on which track. Pass the files in
playback order; each segment is compared against the previous end of the same
track id.

    swift run aetherctl segverify --from 0 --count 12 --dump /tmp/segs <url>
    python3 Scripts/segment-spans.py /tmp/segs/segverify_seg{0..11}.mp4

`segverify --dump` writes init.mp4 prefixed to each segment, so the timescales
are read from the same file. Bare segN.mp4 grabbed with curl carries no moov,
so prepend init.mp4 first (`cat init.mp4 seg8.mp4 > seg8.full.mp4`).

A healthy run prints `contiguous` on every line. AE#561 is the counter-example:
the reported session had seg7 video running to 34.034 s while seg8 opened at
33.492 s.
"""
import struct
import sys


def boxes(buf, start, end):
    i = start
    while i + 8 <= end:
        size = struct.unpack_from(">I", buf, i)[0]
        typ = buf[i + 4:i + 8].decode("latin1")
        hdr = 8
        if size == 1:
            size = struct.unpack_from(">Q", buf, i + 8)[0]
            hdr = 16
        elif size == 0:
            size = end - i
        if size < hdr or i + size > end:
            return
        yield typ, i + hdr, i + size
        i += size


def timescales(buf):
    """trak_id -> timescale, from moov/trak/mdia/mdhd."""
    out = {}
    for t, s, e in boxes(buf, 0, len(buf)):
        if t != "moov":
            continue
        for t2, s2, e2 in boxes(buf, s, e):
            if t2 != "trak":
                continue
            tid = None
            ts = None
            for t3, s3, e3 in boxes(buf, s2, e2):
                if t3 == "tkhd":
                    ver = buf[s3]
                    tid = struct.unpack_from(">I", buf, s3 + (20 if ver == 1 else 12))[0]
                elif t3 == "mdia":
                    for t4, s4, e4 in boxes(buf, s3, e3):
                        if t4 == "mdhd":
                            ver = buf[s4]
                            ts = struct.unpack_from(">I", buf, s4 + (20 if ver == 1 else 12))[0]
            if tid is not None and ts:
                out[tid] = ts
    return out


def trex_defaults(buf):
    out = {}
    for t, s, e in boxes(buf, 0, len(buf)):
        if t != "moov":
            continue
        for t2, s2, e2 in boxes(buf, s, e):
            if t2 != "mvex":
                continue
            for t3, s3, e3 in boxes(buf, s2, e2):
                if t3 == "trex":
                    tid, _, dur, _, _ = struct.unpack_from(">IIIII", buf, s3 + 4)
                    out[tid] = dur
    return out


def spans(buf, trex):
    """yield (moof_index, track_id, tfdt, total_duration, n_samples)"""
    n = 0
    for t, s, e in boxes(buf, 0, len(buf)):
        if t != "moof":
            continue
        for t2, s2, e2 in boxes(buf, s, e):
            if t2 != "traf":
                continue
            tid = None
            tfdt = None
            deflt = None
            total = 0
            nsamp = 0
            for t3, s3, e3 in boxes(buf, s2, e2):
                if t3 == "tfhd":
                    flags = struct.unpack_from(">I", buf, s3 - 8 + 8)[0] & 0xFFFFFF
                    off = s3 + 4
                    tid = struct.unpack_from(">I", buf, off)[0]
                    off += 4
                    if flags & 0x01:
                        off += 8
                    if flags & 0x02:
                        off += 4
                    if flags & 0x08:
                        deflt = struct.unpack_from(">I", buf, off)[0]
                        off += 4
                elif t3 == "tfdt":
                    ver = buf[s3]
                    tfdt = (struct.unpack_from(">Q", buf, s3 + 4)[0] if ver == 1
                            else struct.unpack_from(">I", buf, s3 + 4)[0])
                elif t3 == "trun":
                    ver = buf[s3]
                    flags = struct.unpack_from(">I", buf, s3)[0] & 0xFFFFFF
                    cnt = struct.unpack_from(">I", buf, s3 + 4)[0]
                    off = s3 + 8
                    if flags & 0x000001:
                        off += 4
                    if flags & 0x000004:
                        off += 4
                    nsamp += cnt
                    per = 0
                    for bit in (0x000100, 0x000200, 0x000400, 0x000800):
                        if flags & bit:
                            per += 4
                    for _ in range(cnt):
                        if flags & 0x000100:
                            total += struct.unpack_from(">I", buf, off)[0]
                        else:
                            total += (deflt if deflt is not None
                                      else trex.get(tid, 0))
                        off += per
            if tid is not None and tfdt is not None:
                yield n, tid, tfdt, total, nsamp
        n += 1


def main(paths):
    prev_end = {}
    for p in paths:
        buf = open(p, "rb").read()
        ts = timescales(buf)
        trex = trex_defaults(buf)
        label = p.rsplit("/", 1)[-1]
        for _, tid, tfdt, total, nsamp in spans(buf, trex):
            scale = ts.get(tid, 1) or 1
            start = tfdt / scale
            end = (tfdt + total) / scale
            note = ""
            if tid in prev_end:
                delta = start - prev_end[tid]
                note = ("  gap=%+.4fs" % delta) if abs(delta) > 0.0005 else "  contiguous"
            prev_end[tid] = end
            print("%-28s trak=%d  %9.4f -> %9.4f  (dur %6.4f, %4d samples)%s"
                  % (label, tid, start, end, end - start, nsamp, note))


if __name__ == "__main__":
    main(sys.argv[1:])
