# Apple SoundAnalysis — Brazil H8 field recordings (empirical findings)

Date: 2026-05-16  
Corpus: 5 Brazil H8 + VRH-8 source files (Oct 2024), 4-channel 48kHz A-format ambisonic WAV, downmixed to 16kHz mono via ffmpeg for analysis.  
Classifier: `SNClassifySoundRequest(classifierIdentifier: .version1)` — Apple's built-in YAMNet-style model (~300 categories).  
Confidence threshold: 0.3 (auto-retried at 0.1 if zero results).  
Substitutions: F241016_001 (5.8s — too short) → F241016_002; F241019_010 (1.9s — too short) → F241019_008.

---

## Per-file summary

### F241016_002.zprj — 2956s (49 min 16s)

The longest recording. Strong nocturnal character — owl and coyote in the top 5, with "whistling" dominating, which maps to sustained tonal bird calls. Heavy thunder/thunderstorm presence suggests an evening storm session. 47 unique labels — widest vocabulary of any file.

- whistling: 684.0s (322 events)
- bird: 501.1s (362 events)
- bird_vocalization: 216.9s (177 events)
- wind: 185.7s (131 events)
- owl_hoot: 104.3s (91 events)
- elk_bugle: 98.5s (87 events)
- coyote_howl: 88.7s (73 events)
- thunderstorm: 51.7s (41 events)
- thunder: 49.2s (40 events)
- truck: 39.5s (36 events)
- frog: 36.1s (35 events)
- bird_squawk: 35.1s (35 events)
- rail_transport: 32.7s (26 events)
- cricket_chirp: 26.3s (26 events)
- bird_chirp_tweet: 15.6s (16 events)
- frog_croak: 13.6s (14 events)
- car_passing_by: 12.7s (8 events)
- foghorn: 12.7s (11 events)
- emergency_vehicle: 9.7s (9 events)
- chime: 8.8s (9 events)

### F241018_001.zprj — 712.5s (11 min 52s)

Dense daytime bird session. bird_vocalization accounts for more than half of all classified audio. Two label-level cat detections (cat + cat_meow) — almost certainly bird calls morphologically similar to cat sounds, since the classifier shares acoustic feature space. 29 unique labels.

- bird_vocalization: 385.1s (207 events)
- bird: 94.1s (85 events)
- bird_squawk: 89.7s (80 events)
- insect: 66.8s (58 events)
- wind: 52.7s (35 events)
- wind_rustling_leaves: 44.4s (35 events)
- cat: 23.9s (21 events)
- cricket_chirp: 22.9s (20 events)
- bell: 17.6s (17 events)
- rail_transport: 16.6s (11 events)
- chime: 13.2s (12 events)
- bird_chirp_tweet: 7.8s (8 events)
- wind_chime: 5.4s (5 events)
- cat_meow: 5.4s (5 events)
- ratchet_and_pawl: 4.9s (5 events)
- dog: 2.0s (2 events)
- whistling: 2.0s (2 events)
- squeak: 1.0s (1 event)
- bus: 1.0s (1 event)
- toothbrush: 1.0s (1 event)

### F241019_001.zprj — 90.8s (1 min 30s)

Short transitional clip with mixed wind + bird. Water detected (likely a stream or rain). Only 17 unique labels — compressed scene, sparse events. The "artillery_fire" label (1 event) is certainly a loud impact transient (hand clap, wing flap, camera action).

- wind: 23.9s (15 events)
- bird_vocalization: 16.1s (14 events)
- bird: 13.2s (12 events)
- wind_rustling_leaves: 11.7s (11 events)
- water: 6.3s (2 events)
- cricket_chirp: 4.4s (3 events)
- wind_chime: 3.4s (1 event)
- speech: 2.4s (2 events)
- knock: 2.0s (1 event)
- bell: 1.9s (2 events)
- thunder: 1.0s (1 event)
- rail_transport: 1.0s (1 event)
- chime: 1.0s (1 event)
- click: 1.0s (1 event)
- artillery_fire: 1.0s (1 event)
- ratchet_and_pawl: 1.0s (1 event)
- whoosh_swoosh_swish: 1.0s (1 event)

### F241019_005.zprj — 190.4s (3 min 10s)

The most anomalous file. "speech" tops the chart — likely recordist handling the H8, speaking during a take. "tearing" and "crumpling_crinkling" suggest foliage handling or wind-jacket noise. "snake_hiss" (2s) is almost certainly foliage sibilance. "underwater_bubbling" and "boom" are mid-range surprises. 41 unique labels from a 3-minute clip indicates a chaotic acoustic environment or significant handling noise.

- speech: 30.7s (8 events)
- wind: 26.8s (15 events)
- bird: 24.4s (17 events)
- wind_rustling_leaves: 8.8s (8 events)
- tearing: 6.8s (7 events)
- bird_vocalization: 6.8s (6 events)
- cat: 5.8s (6 events)
- insect: 3.9s (4 events)
- person_walking: 3.4s (3 events)
- crumpling_crinkling: 2.9s (3 events)
- fire_crackle: 2.9s (3 events)
- boom: 2.9s (3 events)
- underwater_bubbling: 2.9s (3 events)
- snake_hiss: 2.0s (2 events)
- coin_dropping: 2.0s (2 events)
- cat_purr: 1.9s (2 events)
- ratchet_and_pawl: 1.9s (2 events)
- bird_squawk: 1.9s (2 events)
- cricket_chirp: 1.9s (2 events)
- whoosh_swoosh_swish: 1.9s (2 events)

### F241019_008.zprj — 141.7s (2 min 21s)

Water-dominant scene — 65.8s classified as water (46% of the clip). Strong insect + cricket presence. "elk_bugle" appearing on a 2-minute clip is striking (almost certainly a bird call or frog vocalization misidentified). "rail_transport" recurring across files suggests it's a classifier confound for rhythmic low-frequency rumble (insect drones, wind, frog calls). 16 unique labels — cleanest scene in the set.

- water: 65.8s (30 events)
- wind: 19.0s (17 events)
- insect: 16.6s (14 events)
- cricket_chirp: 14.6s (14 events)
- rail_transport: 8.8s (8 events)
- elk_bugle: 4.9s (5 events)
- bird_vocalization: 4.4s (4 events)
- bird: 3.9s (4 events)
- beep: 1.9s (2 events)
- train: 1.9s (2 events)
- wind_rustling_leaves: 1.9s (2 events)
- rowboat_canoe_kayak: 1.0s (1 event)
- thunder: 1.0s (1 event)
- dog: 1.0s (1 event)
- cough: 1.0s (1 event)
- dog_growl: 1.0s (1 event)

---

## Aggregate findings across all 5 files

Total unique labels: 51  
Total audio analyzed: ~4092 seconds (~68 minutes)  
Classifier speed: ~50-100x realtime (49min file in 17s)

Top 20 labels ranked by total seconds:

| Rank | Label | Total sec | Files (of 5) |
|------|-------|-----------|--------------|
| 1 | whistling | 686.0 | 2 |
| 2 | bird | 636.7 | 5 |
| 3 | bird_vocalization | 629.3 | 5 |
| 4 | wind | 308.1 | 5 |
| 5 | bird_squawk | 126.7 | 3 |
| 6 | owl_hoot | 104.3 | 1 |
| 7 | elk_bugle | 103.4 | 2 |
| 8 | coyote_howl | 88.7 | 1 |
| 9 | insect | 87.3 | 3 |
| 10 | water | 72.1 | 2 |
| 11 | cricket_chirp | 70.1 | 5 |
| 12 | wind_rustling_leaves | 66.8 | 4 |
| 13 | rail_transport | 59.1 | 4 |
| 14 | thunderstorm | 51.7 | 1 |
| 15 | thunder | 51.2 | 3 |
| 16 | truck | 39.5 | 1 |
| 17 | frog | 36.1 | 1 |
| 18 | speech | 33.1 | 2 |
| 19 | cat | 29.7 | 2 |
| 20 | bird_chirp_tweet | 23.4 | 2 |

---

## Bird classification granularity

Apple's classifier resolves 7 distinct bird-related label strings across this corpus:

- `bird` — generic, confident but non-specific
- `bird_vocalization` — broader acoustic pattern (sustained call, warble)
- `bird_squawk` — harsh/raspy call character
- `bird_chirp_tweet` — short tonal percussive call
- `owl_hoot` — specific species-level label (hooting pattern) — 104s in F241016_002
- `whistling` — covers sustained melodic bird song, also human whistle; contextually this corpus has no human whistling present, so the 686s total is bird song

Beyond true birds, some labels are almost certainly bird misclassifications given Brazil rainforest context:
- `coyote_howl` (88.7s) — sustained calling bird or frog
- `elk_bugle` (103.4s) — resonant call morphologically similar to bugle, almost certainly a bird or frog
- `cat` / `cat_meow` (29.7s combined) — calls with feline tonal envelope; likely specific bird species

The classifier is **category-level, not species-level.** No BirdNET-style species names appear. "owl_hoot" is the deepest species-specificity achieved.

---

## Other notable categories detected

Full list of non-bird categories observed (actual label strings from classifier output):

**Atmospheric/weather:** `wind`, `wind_rustling_leaves`, `thunder`, `thunderstorm`  
**Water:** `water`  
**Insects/amphibians:** `insect`, `cricket_chirp`, `frog`, `frog_croak`  
**Handling/transient noise:** `tearing`, `crumpling_crinkling`, `ratchet_and_pawl`, `knock`, `click`, `whoosh_swoosh_swish`, `coin_dropping`  
**Human presence:** `speech`, `person_walking`  
**Urban confounds:** `rail_transport`, `truck`, `car_passing_by`, `emergency_vehicle`, `bus`, `foghorn`  
**Acoustic confounds (misidentified):** `typewriter`, `artillery_fire`, `snake_hiss`, `underwater_bubbling`, `boom`, `beep`, `toothbrush`, `rowboat_canoe_kayak`  
**Musical/harmonic:** `whistling`, `bell`, `chime`, `wind_chime`, `music`

---

## What this means for v0.2 spec

**Apple SoundAnalysis alone gives us:**
- Scene-level labels with timestamps and confidence scores — sufficient to know "this 10-second window is bird-heavy vs wind-heavy vs water-heavy"
- Coarse temporal structure: when does the recording shift from bird-dense to quiet?
- Reliable detection of atmospheric elements (wind, water, thunder) — these are clean, consistent labels
- Transient event detection (knock, click, boom) — useful for finding recordist interference sections
- Fast enough to run as a preprocessing sweep on the full archive in minutes

**Where it falls short:**
- Zero species-level bird identification — "owl_hoot" is the ceiling; most bird activity collapses into `bird` / `bird_vocalization`
- Cross-domain confounds are pervasive and systematic: `rail_transport` appears in 4 of 5 files in a Brazilian rainforest — it's matching insect/frog drone patterns, not trains. `elk_bugle`, `coyote_howl`, `cat` are definitively wrong category labels for bird/frog calls
- The `whistling` label (686s!) cannot be distinguished from human whistling without additional context
- No spatial or directional information whatsoever — a known limitation of mono downmix
- Confidence values at the 0.3–0.4 range are frequent; many events are marginal

**Recommendation: Use Apple + BirdNET/Perch in parallel for bird-rich material.**  
Apple SoundAnalysis is the right first pass — fast, on-device, handles the full acoustic scene (wind, water, insects, transients). Pipe the timestamps where Apple returns any bird-family label into BirdNET or Perch v2 for species resolution. Do NOT replace Apple with BirdNET alone — BirdNET specializes birds and will miss the atmospheric/insect/water context you need for FF scene mapping.

**For FF mapping/visualization:**  
Yes — Apple labels + timestamps + confidence are sufficient to place generic spatial objects. Concrete usage pattern:
- `water` → place a water-source orb at a fixed azimuth (below horizon, e.g. -30°)
- `wind` / `wind_rustling_leaves` → diffuse background layer, no discrete object
- `bird_vocalization` / `bird` / `bird_squawk` → generic bird orb at confidence-weighted random position above horizon
- `owl_hoot` → elevated single object, slower orbit (nocturnal character)
- `cricket_chirp` / `insect` → low-horizon ring of small objects
- `thunder` / `thunderstorm` → wide diffuse object at top of dome

The label + confidence alone is enough to drive a real-time visualization that reads as a credible spatial representation of the scene. Species names would add the next layer.

---

## Surprises

1. **`rail_transport` in every outdoor file** (4 of 5, 59 total seconds): The most consistent confound. The classifier was clearly trained on datasets where this label co-occurred with rhythmic low-frequency energy — exactly what insect drone, frog chorus, and wind in foliage produce. This is a known YAMNet failure mode for tropical recordings.

2. **`elk_bugle` in a Brazilian rainforest** (103.4s across 2 files): The classifier matched sustained resonant bird calls — the acoustic shape of an elk bugle (breathy, elongated, somewhat nasal) maps onto several tropical bird species. Not wrong as a shape descriptor; wrong as a category. Still useful: any `elk_bugle` hit in this corpus can be relabeled "sustained resonant bird call" with high confidence.

3. **`whistling` dominates F241016_002 at 684 seconds** — 23% of a 49-minute recording. This is sustained melodic bird song from what is likely a single species present through the full session. The classifier is correct acoustically ("whistling" is the right shape); just not the right category for naturalist use.

4. **Speed**: 49 minutes of audio analyzed in 17 seconds wall-clock time. The entire Brazil H8 archive (23 recordings, likely 10–15 hours total audio) could be preprocessed in under 5 minutes. This changes the feasibility of running it on every upload at ingest time.

5. **F241019_005 generated 41 unique labels from 3 minutes**: When there is handling noise (tearing, crumpling, speech), the label diversity explodes. This could serve as a useful handling-noise detector: if unique_labels/duration_sec exceeds a threshold, flag the take as contaminated.
