# SoundMix — working memory

Session of 2026-10-14. What a later session needs that the code and git history do not say.

## What this is

A native Swift/SwiftUI macOS app that folds a 9.1.6 immersive bed to stereo, written to
replace **Downmix Renderer 0.0.0** (`../Downmix Renderer.app`), which was reverse
engineered first. Three documents carry the detail:

| File | Holds |
|---|---|
| `../reverse-engineering/FINDINGS.md` | the original's architecture, exact matrix, 37-flag CLI, 20 weaknesses |
| `README.md` | what changed and why, feature by feature |
| `VERIFICATION.md` | measured results from the live audio run |

## Decisions, and why

- **Native Swift, one process.** Chosen over the original's Python + C++ + localhost-HTTP
  + stdout-scraping design. 1.6 MB against ~100 MB.
- **"Original parity (ADC2 direct)" must stay.** It reproduces the old app's compiled-in
  matrix exactly, LFE coefficient `2.26464431` (+7.100 dB) included, recovered from the
  binary at `_main+0x1f40`. It is the only way to A/B against the old app.
- **Domain names kept.** The product renamed to SoundMix, but "downmix" survives as the
  audio term in the nav section, the recipe label, and references to Downmix Renderer.
  That was deliberate; do not sweep it.
- **Scope grew one request at a time.** Parity + correct matrix + limiter first; then the
  EQ profile manager, offline rendering, per-ear measurements, target curves.

## Standing next feature

**Binaural / HRTF headphone mode** — offered and deferred several times. The most likely
next ask.

## Bugs found by testing, worth not reintroducing

1. **Stale sample-rate comparison** — comparing an input device's rate against the cached
   enumeration skipped a needed rate change and produced silence with no error. Re-read
   from the HAL and verify the change settled. This one cost the most time.
2. **`os_unfair_lock` as a stored property** — `&self.lock` does not guarantee a stable
   address under optimisation. Both locks are heap-allocated now.
3. **Apply did not reopen the stream** — device and buffer changes need the audio units
   rebuilt; `applyLive()` now restarts when they differ and hot-applies otherwise.
4. **Zero-frame files rendered to silence** — `inspect` now rejects a file whose header
   reports no frames.
5. **A third column is not always the right ear** — it was phase in a real user file.
   `parsePair` now needs a header or plausible level data before splitting.

## Environment

- Build needs the sandbox **off** (SwiftUI macro expansion spawns `swift-plugin-server`)
  and a redirected module cache. `./build.sh` handles the cache; the caller handles the
  sandbox.
- GUI apps cannot be launched from here — reveal in Finder and let the user double-click,
  which also makes macOS attribute the microphone prompt to the app.
- **BlackHole 16ch has its own volume**, found at −24 dB and silently attenuating. Check
  `kAudioDevicePropertyVolumeDecibels` before believing a level reading.
- `build/bedgen` generates known multichannel signals; `Samples/9.1.6 channel ident.wav`
  is a 16-channel identification file whose fold is verified slot by slot.

## State at the end of the session

- 188 DSP checks + 23 offline checks pass.
- Live path measured: routing ±0.9 dB, 0 underruns over 53.6 s, limiter holding −1.0 dBTP
  under 16 dB of overdrive.
- Not verified: behaviour with a physical multichannel interface, device removal by
  unplugging, drift over hours.
- The user's own EQ profiles live in `~/Library/Application Support/SoundMix/EQ Profiles`.
  One holds a real KZ Vibe X L/R pair; profiles only write on **Save**.
