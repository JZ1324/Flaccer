# Flaccer

Flaccer is a native macOS utility for checking whether audio files look genuinely lossless or appear to be lossy transcodes in a lossless container. It analyzes audio locally with macOS audio decoding APIs and Accelerate/vDSP.

## Requirements

- macOS 26.0 or newer
- Xcode 26.4.1 or newer, with the macOS 26 SDK

## How to Run

Open `Flaccer.xcodeproj` in Xcode and run the `Flaccer` scheme, or build from Terminal:

```bash
./script/build_and_run.sh --build-only
```

To build and launch:

```bash
./script/build_and_run.sh
```

## What It Supports

Flaccer scans files and folders recursively. It can also import M3U/M3U8 playlists and Rekordbox XML library exports, resolving their track paths into normal local audio files. It attempts to read FLAC, WAV, AIFF, ALAC, MP3, AAC, M4A, and CAF using macOS audio decoding APIs. Format support depends on the codecs available on the Mac running the app.

Scans are queued first, then analyzed in parallel with a configurable limit up to 100 files at once. Results are grouped by verdict so `FAKE`, `MEDIUM`, `LOSSLESS`, and `ERROR` files are easy to filter, reveal, copy, or export.

## How Verdicts Work

The analyzer reads floating-point PCM windows sampled across the full track, mixes channels to mono, applies a Hann window, runs an 8192-point FFT with Accelerate/vDSP, and averages high-frequency energy over time.

Verdicts are heuristic:

- `LOSSLESS`: energy reaches close to Nyquist and no clear brickwall cutoff is detected.
- `FAKE`: a strong cutoff appears around common lossy ranges, especially the 16 kHz to 19.5 kHz area after sample-rate scaling.
- `MEDIUM`: the spectrum is ambiguous, often because the cutoff is high, weak, inconsistent, or musically plausible.
- `ERROR`: AVFoundation could not read the file or PCM data.

Confidence increases when the cutoff is sharp, upper bands are consistently empty, and the cutoff aligns with common lossy signatures. It decreases for short, quiet, or sparse tracks.

## Finder Tags

Finder tagging is optional in Settings. Flaccer replaces previous Finder color tags with one verdict color:

- Green for `LOSSLESS`
- Yellow for `MEDIUM`
- Red for `FAKE`
- Gray for `ERROR`

Uncolored user tags are preserved.

## Limitations

This is a working MVP, not a forensic audio lab. Some genuinely lossless music has little high-frequency content, and some lossy encoders preserve energy unusually high in the spectrum. The spectrogram and diagnosis should be treated as evidence, not a mathematical proof.

The watch folder uses lightweight recursive polling every few seconds. It is reliable for normal desktop use but not intended as a high-volume filesystem ingestion service.

## Privacy

All analysis runs locally on the Mac. The app has no account system, backend, analytics, telemetry, or network calls.
