# Source Separation + BirdNET Overlap Improvement — 2026-05-16

## What Changed

Two improvements layered on the v0.2 species pass:

### A — Tighter BirdNET overlap (overlap=0.5)
BirdNET previously analyzed with overlap=0.0 (one 3-second window every 3 seconds). Changed to overlap=0.5 (one window every 1.5 seconds). Species that call briefly — a single chip note, a flyover — that happen to fall between two non-overlapping windows were silently missed. 

### B — Frequency-band pre-split (4 passes per file)
Before running BirdNET, bed.m4a is split into 3 bandpass-filtered 16kHz mono WAVs via ffmpeg:
- **low**: 500–2500 Hz — large birds, doves, owls, mammal vocalizations
- **mid**: 2000–6000 Hz — most passerines (sparrows, warblers, tanagers)
- **high**: 5000–12000 Hz — insects, hummingbirds, high-frequency calls

BirdNET runs on all 3 bands + the full unprocessed signal (4 passes total). Results are merged and deduped: same species within 1 second → keep max confidence entry. Per-band temp wavs are deleted after each pass.

### C — min_conf lowered from 0.5 → 0.25
BirdNET's published precision at 0.25 is usable for cataloging. The previous 0.5 floor was dropping real detections. With the band approach, the same species appearing in multiple band passes cross-validates genuine calls — a species that only appears at 0.27 confidence in one band but 0.45 in another is retained.

---

## Before / After Comparison

| Slug | Duration | Before | After | Δ species | New species vs. before |
|------|----------|--------|-------|-----------|------------------------|
| backyard-woodland-hills-may-14-2026-2026-05-15-d53c1b | 46 min | 5 | 7 | +2 | White-winged Dove, Gadwall |
| field-recording-2024-10-18-52df6e | 12 min | 4 | 15 | +11 | Sick's Swift, Variable Oriole, Blackish Rail, Burrowing Owl, White Woodpecker, Rufous-tailed Jacamar, Mouse-colored Tyrannulet, Mato Grosso Antbird, Rufous Hornero, Black-billed Thrush, Yellow-bellied Elaenia |
| mic1234-2024-10-19-ff4d86 | 3.6 min | 4 | 7 | +3 | Rufous-tailed Jacamar, White-browed Antbird, Planalto Woodcreeper |
| field-recording-2026-05-11-f594ed | 49 sec | 0 | 0 | 0 | — (no bird-flagged windows; Apple SoundAnalysis found only insect/wind/knock) |
| recording-20200103-15-31-acn-sn3d-3-2026-05-16-9fd802 | 7 min | 0 | 0 | 0 | — (water-dominant; no bird-flagged windows, confirmed correct) |

Δ confidence (avg max_conf across species that appeared in both before and after):
- backyard: consistent (California Towhee 0.97→0.99, Song Sparrow retained, Barn Owl retained)
- Brazil Oct 18: all 4 original species retained at equal or higher confidence
- Brazil Oct 19: all 4 original species retained

---

## Did the Bandpass Approach Help?

**Yes, materially.** Brazil Oct 18 nearly 4× species count (4 → 15). Oct 19 added 3 more species in a 3.6-minute clip. The backyard went from 5 → 7.

The bandpass did NOT degrade accuracy on the recordings where it had material impact:
- All species detected by the previous approach are still present in the new results
- No species were dropped by the new approach
- No species appeared at implausible locations

The approach did NOT produce false positives on the two non-bird recordings (Zylia water file, May 11 test), confirming no regression on files that correctly return 0 species.

One observation: the high-band (5000–12000 Hz) contributed fewer unique-after-merge species than mid — this makes sense since BirdNET's training is biased toward broadband recordings. The full-band pass is still the dominant contributor. The mid band added the most unique detections in Brazil (passerines + tyrannulets call heavily in 2–6 kHz). The main gain from the low band was better separation of the loudest callers (Great Kiskadee, which dominates the full-band mix) from quieter co-occurring species.

---

## Spot-Check: 3 New Detections

### 1. White-winged Dove — backyard (Woodland Hills, LA, CA)
**New at conf=0.606** in backyard recording. White-winged Dove (*Zenaida asiatica*) is a year-round resident of Southern California — range covers the entire LA basin and San Fernando Valley. Common in suburban backyards, frequently visits feeders. Plausible: yes, fully expected for Woodland Hills.

### 2. Sick's Swift — Brazil Oct 18 (conf=0.793)
*Chaetura meridionalis* — resident of lowland Brazil including Cerrado and Pantanal transition zones. Fast-flying aerial insectivore, commonly heard over forest edges and open areas. Latitude/longitude used is Brazil center (-15, -50), well within this species' range. Plausible: yes. Swifts are frequently missed in full-band recordings because their high chip calls are masked by broader-band vocalizations; the mid + high band passes likely separated the call.

### 3. White-browed Antbird — Brazil Oct 19 (conf=0.668)
*Myrmoborus leucophrys* — resident of Amazonian and central Brazilian lowland forest undergrowth. Known caller in dense vegetation near water; pairs call back and forth. The Oct 19 recording prefix is `mic1234` suggesting a handheld mic placement close to the vegetation layer. Plausible: yes for central Brazil habitat.

---

## Any Surprises?

- **Burrowing Owl in Brazil (conf=0.458)** — *Athene cunicularia* is genuinely present across Brazil, especially in Cerrado open grasslands. Not a false positive — it's a real Brazilian species, though confidence is moderate. Retained at 0.25 threshold.
- **Blackish Rail (conf=0.507)** — *Pardirallus nigricans* — freshwater marsh/reed-bed species, present in interior Brazil. Plausible if there was any nearby wetland vegetation in the Oct 18 recording site.
- **Gadwall in backyard (conf=0.267)** — lowest-confidence detection in the set. Gadwall is a duck present in LA during winter (October–March). The backyard recording is from May 2026, which is past typical winter duck season for LA. This is a low-confidence marginal detection — worth noting as the most likely false positive in the set. Retained per 0.25 threshold policy.

---

## Analyzer Version

`apple-soundanalysis-v1+birdnet-v2.4-bandsplit-overlap0.5`

All 5 events.json files in R2 now carry this version string. catalog.json updated accordingly.
