#!/usr/bin/env python3
"""
BirdNET species classifier helper.

Called by the Swift analyze-bed CLI as a subprocess:
  python3 birdnet_analyze.py <audio_file> <output_json> <lat> <lon> <date_YYYY-MM-DD> [min_sec] [max_sec]

Writes a JSON array of detections to <output_json>:
  [{"common": "...", "scientific": "...", "start_sec": 0.0, "end_sec": 3.0, "confidence": 0.91}, ...]

Only emits detections with confidence >= 0.5.
If min_sec/max_sec are provided, only emits detections whose start_time falls in that range.
"""

import sys
import json
import datetime
import warnings

# Suppress deprecation warnings from TF Lite
warnings.filterwarnings("ignore", category=UserWarning)

def main():
    if len(sys.argv) < 6:
        sys.stderr.write(
            "usage: birdnet_analyze.py <audio> <output.json> <lat> <lon> <YYYY-MM-DD> "
            "[min_sec] [max_sec]\n"
        )
        sys.exit(1)

    audio_path  = sys.argv[1]
    output_path = sys.argv[2]
    lat         = float(sys.argv[3])
    lon         = float(sys.argv[4])
    date_str    = sys.argv[5]

    # Optional time window filter (seconds)
    min_sec = float(sys.argv[6]) if len(sys.argv) > 6 else None
    max_sec = float(sys.argv[7]) if len(sys.argv) > 7 else None

    try:
        date = datetime.date.fromisoformat(date_str)
    except ValueError:
        date = datetime.date.today()

    from birdnetlib import Recording
    from birdnetlib.analyzer import Analyzer

    # Load model (cached across calls when using subprocess pool, but we are one-shot here)
    try:
        analyzer = Analyzer()
    except Exception as e:
        sys.stderr.write(f"ERROR: Failed to load BirdNET model: {e}\n")
        sys.exit(2)

    # Run analysis — BirdNET segments by 3-second windows internally
    try:
        recording = Recording(
            analyzer,
            audio_path,
            lat=lat,
            lon=lon,
            date=date,
            min_conf=0.5,       # confidence filter; we also re-filter below for safety
        )
        recording.analyze()
    except Exception as e:
        sys.stderr.write(f"ERROR: BirdNET analysis failed: {e}\n")
        sys.exit(3)

    detections = recording.detections

    # Filter by time window if requested
    if min_sec is not None or max_sec is not None:
        filtered = []
        for d in detections:
            start = float(d.get("start_time", d.get("start_sec", 0)))
            if min_sec is not None and start < min_sec:
                continue
            if max_sec is not None and start > max_sec:
                continue
            filtered.append(d)
        detections = filtered

    # Normalize output format
    results = []
    for d in detections:
        conf = float(d.get("confidence", 0))
        if conf < 0.5:
            continue
        start = float(d.get("start_time", d.get("start_sec", 0)))
        end   = float(d.get("end_time",   d.get("end_sec",   start + 3.0)))
        results.append({
            "common":      d.get("common_name", ""),
            "scientific":  d.get("scientific_name", ""),
            "start_sec":   round(start, 3),
            "end_sec":     round(end,   3),
            "confidence":  round(conf,  4),
        })

    with open(output_path, "w") as f:
        json.dump(results, f)

    print(f"birdnet: {len(results)} detections written to {output_path}", flush=True)

if __name__ == "__main__":
    main()
