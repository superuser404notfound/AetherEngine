#!/usr/bin/env python3
"""Generate original MPEG-2 field-picture fixtures; never run by the test suite.

The external MSSG encoder and its NTSC.par are not redistributed here.
See docs/mpeg-cache-qualification.md for their pinned source and build requirements.
"""
import argparse
import hashlib
import pathlib
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--encoder", type=pathlib.Path, required=True)
parser.add_argument("--reference-parameters", type=pathlib.Path, required=True)
parser.add_argument("--output-directory", type=pathlib.Path, required=True)
args = parser.parse_args()
encoder = args.encoder.resolve(strict=True)
lines = args.reference_parameters.read_text().splitlines()
if len(lines) < 55 or "field pictures" not in lines[13]:
    parser.error("expected NTSC.par from the documented MSSG source revision")
out = args.output_directory.resolve()
out.mkdir(parents=True, exist_ok=True)
if any(out.iterdir()):
    parser.error("output directory must be empty")
changes = {
    0: "Generated moving luma pattern, no third-party images",
    1: "frame%d", 2: "-", 5: "stats.txt", 6: "1", 7: "60",
    13: "1", 14: "128", 15: "96", 17: "4", 18: "1000000.0",
    30: "128", 31: "96",
}
for index, value in changes.items():
    lines[index] = value
(out / "fields.par").write_text("\n".join(lines) + "\n")
for frame in range(60):
    luma = bytes(40 + ((x // 8 + y // 8 + frame) % 2) * 150
                 for y in range(96) for x in range(128))
    (out / f"frame{frame}.yuv").write_bytes(luma + bytes([128]) * (128 * 96 // 2))
with (out / "encode.log").open("w") as log:
    subprocess.run([str(encoder), "fields.par", "fields.m2v"], cwd=out,
                   stdout=log, stderr=subprocess.STDOUT, check=True)
for suffix in ("mkv", "ts"):
    subprocess.run(["ffmpeg", "-v", "warning", "-fflags", "+genpts", "-i", "fields.m2v",
                    "-map", "0:v:0", "-c", "copy", "-fflags", "+bitexact", "fields." + suffix],
                   cwd=out, check=True)
for suffix in ("m2v", "mkv", "ts"):
    data = (out / ("fields." + suffix)).read_bytes()
    print(suffix, len(data), hashlib.sha256(data).hexdigest())
