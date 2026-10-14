# SoundMix

A native macOS replacement for **Downmix Renderer 0.0.0**, rebuilt from the reverse-engineering
findings in [`../reverse-engineering/FINDINGS.md`](../reverse-engineering/FINDINGS.md).

Same job — fold an immersive bed down to a stereo pair in real time — with a correct,
configurable downmix matrix, exact headroom maths, and a true-peak limiter instead of a
blunt preamp.

```bash
./build.sh              # builds build/SoundMix.app and build/bedgen
./run-tests.sh          # 162 DSP checks (no audio hardware needed)
./run-offline-tests.sh  # 23 checks that render real files end to end
```

Swift 6 toolchain and the macOS SDK are the only requirements. No Xcode project, no package
manager, no network access.

---

## What changed

| | Downmix Renderer 0.0.0 | SoundMix |
|---|---|---|
| **Processes** | 3 (PyInstaller/pywebview shell + C++ renderer + a second renderer as a "keep-alive") | 1 |
| **Internal API** | localhost HTTP + SSE; status and device lists scraped out of stdout with regexes | direct function calls |
| **Bundle size** | ~100 MB (CPython 3.11, WebKit, PortAudio, OpenSSL 1.1) | **1.2 MB** |
| **Audio I/O** | PortAudio | Core Audio AUHAL directly |
| **Device loss** | polling, name-matching heuristics, "quiet windows", a 0/3/7/12 s retry ladder | `kAudioDevicePropertyDeviceIsAlive` notifications |
| **Downmix matrix** | compiled in, every surround and height at unity | data-driven, four recipes, every coefficient visible |
| **Headroom** | manual −9.5 dB preamp default | computed L1/L2 trim, shown in dB before you press Start |
| **Overload protection** | `--clip-output` hard clip, not exposed in the UI | 4× oversampled true-peak limiter with look-ahead |
| **Sample rate** | 48 kHz only (hard refusal) | whatever the output device runs at |
| **Input channels** | hard minimum of 16 | whatever the chosen layout needs (4 for 2.1, 16 for 9.1.6) |
| **Output channels** | exactly 2, plus a hard-coded quirk list (`fosi`, `ds2`, `cs43131`) | any device with ≥ 2 outputs |
| **LFE filter** | fixed 125 Hz, 4th-order Butterworth | mode, cut-off and slope all adjustable |
| **Offline rendering** | none — live device only | drag in a multichannel file, render to stereo at ~127× real time |
| **Earphone correction** | PEQ text only | pair a measured response with each EQ profile; plot measured, EQ and corrected together |
| **Tests** | none shipped | **185** automated checks, including real file renders |

## The matrix problem, and the fix

The original gives **every** left-side bed channel a coefficient of exactly `1.0`:

```
FL, BL, BLC, SL, TFL, TSL, TBL  → L   at 1.00000000
FC                              → L,R at 0.70710678
LFE                             → L,R at 2.26464431   (+7.100 dB)
```

Seven unity channels plus centre plus LFE is a worst-case gain of **9.9718 ×, or +19.98 dB**.
The app's only answer is a −9.5 dB preamp default, which does not come close — the test suite
demonstrates the overload directly:

```
ok   the original's −9.5 dB preamp alone still overloads   (peak +4.9 dBFS)
ok   full-scale 9.1.6 bed stays under the −1 dBTP ceiling
```

SoundMix keeps that matrix available as **Original parity (ADC2 direct)** so you can A/B
against the old app, and adds three alternatives:

- **Reference fold (−3 dB)** — the conventional fold: centre and every surround at −3.01 dB,
  heights folded onto the floor layer, LFE discarded.
- **Immersive fold (depth-weighted)** — wides −1.5, sides −3, rears −4.5, front heights −4.5,
  middle −6, rear heights −7.5 dB, with a small opposite-side bleed so the rear field does not
  collapse into one speaker.
- **Lt/Rt (matrix-encoded)** — the classic ±0.866 / ±0.5 encode, so a surround decoder
  downstream can unfold it.

For every one of them the Downmix panel shows the worst-case gain, the uncorrelated gain, the
automatic trim and the total applied gain, in dB, live.

## Carried over unchanged

- The canonical bed order `L,R,C,LFE,Ls,Rs,Lrs,Rrs,Lw,Rw,Ltf,Rtf,Ltm,Rtm,Ltr,Rtr`.
- Layout presets as 1-based input maps over those 16 slots.
- REW / Equalizer APO PEQ text, including the `l` / `r` channel-suffix convention.
- Global PEQ applied to both channels **before** the swap, speaker EQ applied **after** it,
  with the left/right file sections flipping when the swap is on.
- The dry-path delay that keeps the bass in phase with the filtered LFE — here it is derived
  from the filter's own DC group delay (159.7 samples / 3.33 ms for 125 Hz 4th-order at 48 kHz).

One deliberate correction: the original's **7.1.4** preset routes its four height channels to
`Ltf, Rtf, Ltm, Rtm` — front and middle. SoundMix routes them to `Ltf, Rtf, Ltr, Rtr`,
front and rear, which is what 7.1.4 means. It made no audible difference in the original only
because every height shared the same coefficient.

## Offline rendering

The **File** panel folds a multichannel file to stereo with no audio interface involved,
through the identical chain the live path uses — same matrix, LFE filter, EQ, headroom
trim and limiter. Drop a file in, or choose one; the layout is inferred from its channel
count and can be overridden. Output is WAV at the source sample rate, 16/24-bit or
32-bit float.

It reports what actually happened: peak per channel, how much the limiter had to pull,
how many samples reached full scale, and the render speed. On this machine a 16-channel
48 kHz file renders at about 127× real time.

## Earphone correction

Each EQ profile can carry the measured response of the headphone it was written for —
an AutoEQ, oratory1990, squig.link or REW export, parsed from `frequency level` lines in
CSV, tab, semicolon or whitespace form. The Response plot then shows three curves on one
set of axes: the **measured** earphone, the **EQ** being applied, and the **result** you
will actually hear, plus how far that result still deviates across the band.

The measurement is stored inside the profile, so it saves, exports and imports with it.
Upload it from either the profile detail or the Response card.

## Layout

```
Sources/
  SoundMixCore/      pure DSP — no Core Audio, no AppKit, fully testable
    BedLayout.swift         channels, groups, layout presets
    Biquad.swift            biquads, RBJ designers, Butterworth cascades, group delay
    APOParser.swift         REW / Equalizer APO text → filters
    SoundMixMatrix.swift     matrix, recipes, headroom analysis
    TruePeakLimiter.swift   4× oversampled look-ahead limiter
    Metering.swift          meters and the UI snapshot
    SoundMixProcessor.swift  the real-time chain
  SoundMixCore/
    FrequencyResponse.swift measured curves, parsing, interpolation
    EQProfileLibrary.swift  the profile library and its portable format
  SoundMixEngine/    Core Audio
    AudioDevice.swift       HAL enumeration + change notifications
    RingBuffer.swift        lock-free SPSC bridge between the two device clocks
    SoundMixEngine.swift    two AUHAL units, bring-up, device-loss handling
    OfflineRenderer.swift   file in, stereo file out, same chain
  SoundMixApp/       SwiftUI, CloudZone design system
Tests/main.swift    118 checks
```

## Interface

Built on the CloudZone design system: dark-blue (`#0e1e4d`) sidebar, pale-blue (`#eef2fb`)
content area, blue (`#2fa8f7`) primary actions, Landour for body and headings, Wix Madefor for
navigation and buttons. Every component is custom-built on SwiftUI primitives — no third-party
UI library — and every colour comes from a named token in `Sources/SoundMixApp/Theme.swift`.

## Known limits

- No binaural / HRTF mode.
- Input and output must run at the same sample rate. SoundMix asks Core Audio to match
  the input to the output and reports clearly when the device refuses, rather than resampling.
- Ad-hoc signed. Gatekeeper will ask on first launch unless you sign it with your own identity.
- **Microphone permission is mandatory.** macOS classes every Core Audio input as a microphone,
  including a virtual loopback like BlackHole, so the first Start shows the system prompt. If it
  is refused the Devices panel says so and offers a button straight to the right Settings pane.
  Approving it cannot be scripted, so the capture path has not been run end to end here.

## Verified so far

- **162/162 DSP checks pass** (`./run-tests.sh`), covering matrix parity with the shipped
  binary, headroom maths, Butterworth design and group delay, REW/APO parsing, the EQ
  profile library and its import/export, earphone-measurement parsing, limiter ceilings,
  and end-to-end routing, swap and muting through the processor.
- **The live audio path is measured, not assumed** — see
  [VERIFICATION.md](VERIFICATION.md). Routing accurate to ±0.9 dB across all 16 slots,
  0 ring-buffer underruns over 53.6 s across two independent device clocks, and the
  true-peak limiter holding a −1.0 dBTP ceiling at −1.0 dBFS with 16 dB of reduction and
  no clipping.
- Core Audio enumeration, sample-rate matching at both 48 and 96 kHz, and hot
  reconfiguration while streaming all work.
