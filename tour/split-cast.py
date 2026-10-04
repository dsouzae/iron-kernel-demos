#!/usr/bin/env python3
"""Split the tour's asciicast into one cast (and GIF) per section.

    demo/split-cast.py demo/tour.cast [out-dir]        (default: demo/tour-gifs)

The tour (initramfs/demo-tour.sh) announces each section with a `>>> N. …`
line and the finale with a `---…` rule; this cuts the recording at those
lines, so each piece opens on its own heading, rebases its timestamps to
zero, and writes `<nn>-<slug>.cast`. With `agg` on PATH it also renders each
piece to `<nn>-<slug>.gif` (same theme and font as `make demo-gifs`), sized
to the piece's own line count rather than the recording's full height. The
boot lines before section 1 become piece 00.

Only asciicast v2 is understood (one JSON header line, then one JSON event
per line); output events are `"o"` events only.
"""
import json
import os
import re
import shutil
import subprocess
import sys

SECTION = re.compile(r"^>>> (\d+)\. (.*)")
FINALE = "----------"
AGG = ["agg", "--theme", "monokai", "--font-size", "14", "--font-family",
       "DejaVu Sans Mono", "--idle-time-limit", "2", "--last-frame-duration", "4"]


def slug(title):
    s = re.sub(r"[^a-z0-9]+", "-", title.lower()).strip("-")
    return "-".join(s.split("-")[:4])


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = sys.argv[1]
    out = sys.argv[2] if len(sys.argv) > 2 else os.path.join(os.path.dirname(src) or ".", "tour-gifs")
    os.makedirs(out, exist_ok=True)

    with open(src) as f:
        header = json.loads(f.readline())
        events = [json.loads(l) for l in f if l.strip()]

    # Cut points: the event whose text starts a section heading or the finale.
    pieces = [(0, "00", "boot")]
    for i, (_, kind, text) in enumerate(events):
        if kind != "o":
            continue
        for line in text.split("\n"):
            m = SECTION.match(line.strip())
            if m:
                pieces.append((i, m.group(1).zfill(2), slug(m.group(2))))
                break
            if line.startswith(FINALE) and pieces[-1][2] != "scoreboard":
                pieces.append((i, str(len(pieces)).zfill(2), "scoreboard"))
                break

    written = []
    for n, (start, num, name) in enumerate(pieces):
        end = pieces[n + 1][0] if n + 1 < len(pieces) else len(events)
        chunk = [e for e in events[start:end] if e[1] == "o"]
        if not chunk:
            continue
        t0 = chunk[0][0]
        # Size each GIF to its content (plus a little air) instead of the
        # recording's full height, so a short section is not mostly blank.
        lines = sum(text.count("\n") for _, _, text in chunk)
        rows = max(6, min(int(header.get("height", 36)), lines + 2))
        path = os.path.join(out, f"{num}-{name}.cast")
        with open(path, "w") as f:
            h = dict(header)
            h["timestamp"] = int(header.get("timestamp", 0)) + int(t0)
            f.write(json.dumps(h) + "\n")
            # Clear the screen first so the piece does not start mid-scroll.
            f.write(json.dumps([0.0, "o", "\x1b[H\x1b[2J"]) + "\n")
            for t, _, text in chunk:
                f.write(json.dumps([round(t - t0 + 0.05, 6), "o", text]) + "\n")
        written.append((path, rows))
        print(f"{path}: {len(chunk)} events, {chunk[-1][0] - t0:.1f} s, {rows} rows")

    if shutil.which("agg"):
        for path, rows in written:
            gif = path[:-5] + ".gif"
            subprocess.run(AGG + ["--rows", str(rows), path, gif], check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            print(f"{gif}: {os.path.getsize(gif) // 1024} KiB")
    else:
        print("agg not on PATH: casts written, GIFs skipped", file=sys.stderr)


if __name__ == "__main__":
    main()
