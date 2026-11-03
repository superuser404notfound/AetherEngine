#!/usr/bin/env python3
"""Generate public synthetic AVI MPEG-4/B-frame cache reproduction material.

Needs ffmpeg/ffprobe on PATH; no downloads or external input media. The optional
long clip crosses the temporary pairing-table capacity without a large file.
"""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess


def run(args):
    return subprocess.check_output(args, text=True)


def generate(folder, long_clip=False, swift=None):
    folder.mkdir(parents=True, exist_ok=True)
    common = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y"]
    video = ["-c:v", "mpeg4", "-bf", "2", "-g", "30", "-q:v", "5",
             "-threads:v", "1", "-vtag", "XVID", "-flags:v", "+bitexact"]
    fixture = folder / "decoder-fixture.avi"
    subprocess.run(common + ["-f", "lavfi", "-i", "color=c=black:s=32x32:r=25",
        "-frames:v", "250", *video, "-an", "-fflags", "+bitexact", str(fixture)], check=True)
    sample = folder / "mpeg4-cache.avi"
    subprocess.run(common + ["-f", "lavfi", "-i", "testsrc2=size=160x90:rate=30000/1001",
        "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "15",
        *video, "-c:a", "libmp3lame", "-b:a", "64k", "-fflags", "+bitexact", str(sample)], check=True)
    files = [fixture, sample]
    if long_clip:
        sample = folder / "mpeg4-cache-long.avi"
        subprocess.run(common + ["-f", "lavfi", "-i", "color=c=blue:s=160x90:r=30000/1001",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000", "-t", "2400",
            *video, "-c:a", "libmp3lame", "-b:a", "32k", "-fflags", "+bitexact", str(sample)], check=True)
        files.append(sample)
    manifest = {"generator": "FFmpeg lavfi only; no external source media",
                "ffmpeg": run(["ffmpeg", "-version"]).splitlines()[0], "files": []}
    for file in files:
        probe = json.loads(run(["ffprobe", "-v", "error", "-show_entries",
            "stream=index,codec_name,profile,codec_tag_string,width,height,has_b_frames,r_frame_rate,time_base,duration,sample_rate,channels:format=duration,size",
            "-of", "json", str(file)]))
        manifest["files"].append({"name": file.name, "sha256": hashlib.sha256(file.read_bytes()).hexdigest(),
                                  "probe": probe})
    (folder / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if swift:
        packets = json.loads(run(["ffprobe", "-v", "error", "-select_streams", "v:0",
            "-show_packets", "-show_entries", "packet=pos,size,dts,flags", "-of", "json", str(fixture)]))["packets"]
        source = fixture.read_bytes()
        lines = ["import Foundation", "", "// Generated black 32x32/25fps MPEG-4, -bf 2 -g 30; no external media.",
                 "// Regenerate with Scripts/generate-avi-mpeg4-cache-fixture.py --fixture-swift <this file>.",
                 "enum MPEG4CacheTimingFixture {", "    static let packets: [(Int64, Bool, String)] = ["]
        for packet in packets:
            start, size = int(packet["pos"]), int(packet["size"])
            encoded = base64.b64encode(source[start:start + size]).decode("ascii")
            key = "true" if "K" in packet["flags"] else "false"
            lines.append(f'        ({packet["dts"]}, {key}, "{encoded}"),')
        swift.write_text("\n".join(lines + ["    ]", "}", ""]))
    print(json.dumps({"output": str(folder), "files": [f.name for f in files]}))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, default=Path("build/avi-mpeg4-cache"))
    parser.add_argument("--long", action="store_true", help="also generate a 40-minute, low-bitrate cap-crossing sample")
    parser.add_argument("--fixture-swift", type=Path, help="explicitly regenerate the embedded Swift decoder fixture")
    args = parser.parse_args()
    generate(args.output_dir, args.long, args.fixture_swift)
