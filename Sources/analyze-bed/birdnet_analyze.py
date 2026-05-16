#!/usr/bin/env python3
"""
BirdNET species classifier helper.

Called by the Swift analyze-bed CLI as a subprocess:
  python3 birdnet_analyze.py <audio_file> <output_json> <lat> <lon> <date_YYYY-MM-DD>
      [--overlap 0.5] [--min-conf 0.25] [--bands low,mid,high,full]
      [min_sec] [max_sec]

Writes a JSON array of detections to <output_json>:
  [{"common": "...", "scientific": "...", "start_sec": 0.0, "end_sec": 3.0, "confidence": 0.91}, ...]

When --bands is given, runs BirdNET on each frequency band + full signal and merges.
Dedup rule: same species within 1 second → keep max confidence.
Per-band temp wavs are deleted after use.
"""

import sys
import os
import json
import datetime
import warnings
import argparse
import subprocess
import tempfile

# Suppress deprecation warnings from TF Lite
warnings.filterwarnings("ignore", category=UserWarning)

# Band definitions: (name, highpass_hz, lowpass_hz)
BAND_DEFS = {
    "low":  (500,  2500),
    "mid":  (2000, 6000),
    "high": (5000, 12000),
    "full": None,   # no filtering
}

FFMPEG_CANDIDATES = [
    "/opt/homebrew/bin/ffmpeg",
    "/usr/local/bin/ffmpeg",
    "/usr/bin/ffmpeg",
    "ffmpeg",
]


def find_ffmpeg():
    for c in FFMPEG_CANDIDATES:
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    return "ffmpeg"


def make_band_wav(ffmpeg, input_path, band_name, hp_hz, lp_hz):
    """Create a bandpass-filtered 16kHz mono WAV. Returns temp path; caller must delete."""
    tmp = tempfile.mktemp(suffix=f"-band-{band_name}.wav")
    if hp_hz is not None and lp_hz is not None:
        af_filter = f"highpass=f={hp_hz},lowpass=f={lp_hz}"
    else:
        af_filter = None  # full band — still resample to 16kHz mono

    cmd = [ffmpeg, "-y", "-i", input_path,
           "-ar", "16000", "-ac", "1"]
    if af_filter:
        cmd += ["-af", af_filter]
    cmd += ["-f", "wav", tmp]

    result = subprocess.run(cmd, capture_output=True)
    if result.returncode != 0:
        err = result.stderr.decode("utf-8", errors="replace")
        sys.stderr.write(f"  [bands] ffmpeg failed for band={band_name}: {err[:400]}\n")
        return None
    return tmp


def run_birdnet_on_file(analyzer, audio_path, lat, lon, date, overlap, min_conf):
    """Run BirdNET on a single audio file and return raw detections list."""
    from birdnetlib import Recording

    try:
        recording = Recording(
            analyzer,
            audio_path,
            lat=lat,
            lon=lon,
            date=date,
            min_conf=min_conf,
            overlap=overlap,
        )
        recording.analyze()
        return recording.detections
    except Exception as e:
        sys.stderr.write(f"  [birdnet] Analysis failed on {audio_path}: {e}\n")
        return []


def normalize_detections(raw_detections, min_conf):
    """Normalize raw birdnetlib detections into our output dict format."""
    results = []
    for d in raw_detections:
        conf = float(d.get("confidence", 0))
        if conf < min_conf:
            continue
        start = float(d.get("start_time", d.get("start_sec", 0)))
        end   = float(d.get("end_time",   d.get("end_sec",   start + 3.0)))
        results.append({
            "common":     d.get("common_name", ""),
            "scientific": d.get("scientific_name", ""),
            "start_sec":  round(start, 3),
            "end_sec":    round(end,   3),
            "confidence": round(conf,  4),
        })
    return results


def merge_detections(all_detections):
    """
    Merge detections from multiple band passes.
    Dedup rule: same species + start within 1 second → keep the one with max confidence.
    Returns sorted list.
    """
    # Group by (scientific_name, rounded_start_bucket)
    # Bucket = floor(start_sec) so anything within ~1 second collapses
    best: dict = {}  # key -> detection dict
    for det in all_detections:
        sci   = det["scientific"]
        bucket = int(det["start_sec"])  # floor to nearest second
        key   = (sci, bucket)
        if key not in best or det["confidence"] > best[key]["confidence"]:
            best[key] = det

    merged = sorted(best.values(), key=lambda d: (d["start_sec"], d["scientific"]))
    return merged


def main():
    parser = argparse.ArgumentParser(description="BirdNET species classifier helper")
    parser.add_argument("audio",       help="Input audio file (any format ffmpeg can decode)")
    parser.add_argument("output",      help="Output JSON path")
    parser.add_argument("lat",         type=float)
    parser.add_argument("lon",         type=float)
    parser.add_argument("date",        help="YYYY-MM-DD")
    parser.add_argument("--overlap",   type=float, default=0.5,
                        help="BirdNET window overlap 0.0–2.9 (default 0.5 = 1.5s step)")
    parser.add_argument("--min-conf",  type=float, default=0.25,
                        help="Minimum confidence threshold (default 0.25)")
    parser.add_argument("--bands",     default="full",
                        help="Comma-separated bands to run: low,mid,high,full (default: full)")
    # Legacy positional time-window support (kept for back-compat)
    parser.add_argument("min_sec",     nargs="?", type=float, default=None)
    parser.add_argument("max_sec",     nargs="?", type=float, default=None)

    args = parser.parse_args()

    try:
        date = datetime.date.fromisoformat(args.date)
    except ValueError:
        date = datetime.date.today()

    from birdnetlib.analyzer import Analyzer

    try:
        analyzer = Analyzer()
    except Exception as e:
        sys.stderr.write(f"ERROR: Failed to load BirdNET model: {e}\n")
        sys.exit(2)

    # Parse requested bands
    requested_bands = [b.strip().lower() for b in args.bands.split(",") if b.strip()]
    # Validate
    for b in requested_bands:
        if b not in BAND_DEFS:
            sys.stderr.write(f"WARNING: Unknown band '{b}' — ignoring\n")
    requested_bands = [b for b in requested_bands if b in BAND_DEFS]
    if not requested_bands:
        requested_bands = ["full"]

    ffmpeg = find_ffmpeg()
    all_detections = []

    for band_name in requested_bands:
        band_range = BAND_DEFS[band_name]

        if band_name == "full" or band_range is None:
            # Run directly on the input file (BirdNET handles its own resampling)
            audio_for_band = args.audio
            tmp_path = None
            sys.stderr.write(f"  [bands] Running BirdNET on full-band signal\n")
        else:
            hp_hz, lp_hz = band_range
            sys.stderr.write(f"  [bands] Creating band wav: {band_name} ({hp_hz}-{lp_hz} Hz)\n")
            tmp_path = make_band_wav(ffmpeg, args.audio, band_name, hp_hz, lp_hz)
            if tmp_path is None:
                sys.stderr.write(f"  [bands] Skipping band {band_name} (ffmpeg failed)\n")
                continue
            audio_for_band = tmp_path

        raw = run_birdnet_on_file(
            analyzer, audio_for_band,
            args.lat, args.lon, date,
            args.overlap, args.min_conf
        )
        band_dets = normalize_detections(raw, args.min_conf)
        sys.stderr.write(f"  [bands] band={band_name}: {len(band_dets)} detections\n")
        all_detections.extend(band_dets)

        # Clean up temp wav immediately
        if tmp_path and os.path.exists(tmp_path):
            try:
                os.remove(tmp_path)
            except OSError:
                pass

    # Merge across bands (dedup same species near same time)
    merged = merge_detections(all_detections)

    # Optional time-window filter (legacy positional args)
    if args.min_sec is not None or args.max_sec is not None:
        filtered = []
        for d in merged:
            if args.min_sec is not None and d["start_sec"] < args.min_sec:
                continue
            if args.max_sec is not None and d["start_sec"] > args.max_sec:
                continue
            filtered.append(d)
        merged = filtered

    with open(args.output, "w") as f:
        json.dump(merged, f)

    print(f"birdnet: {len(merged)} detections written to {args.output} "
          f"(bands={','.join(requested_bands)}, overlap={args.overlap}, min_conf={args.min_conf})",
          flush=True)


if __name__ == "__main__":
    main()
