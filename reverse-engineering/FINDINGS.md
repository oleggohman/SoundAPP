# Downmix Renderer — Reverse-Engineering Findings

**Target:** `Downmix Renderer.app` (`com.peqdb.downmixrenderer`, CFBundleShortVersionString `0.0.0`, built 2026-06-24)
**Method:** static analysis of the shipped artifact (REA/Hopper on the native Mach-O; PyInstaller CArchive + PYZ extraction and CPython 3.11 bytecode analysis on the Python layer), plus the renderer's own `--help` output.
**Evidence:** `ev_6887edc6…` (binary overview), `ev_012135c3…` / `ev_4d81afe0…` (strings), `ev_b821da70…` (procedure resolution), local disassembly `otool -tV`.

---

## 1. Architecture

Three processes, not one:

```
┌─────────────────────────────────────────────────────────────┐
│ Downmix Renderer.app/Contents/MacOS/Downmix Renderer        │
│   PyInstaller bootloader (arm64, 4.3 MB)                    │
│   → CPython 3.11 + pywebview 6.2.1 + WKWebView              │
│   → downmix_renderer_webview_app  (native window shell)     │
│   → bed_renderer_web_launcher     (the actual application)  │
│        · ThreadingHTTPServer on 127.0.0.1:<dynamic port>    │
│        · serves a single 139 KB HTML/CSS/JS page            │
│        · SSE stream + JSON REST for control                 │
└────────────────────┬────────────────────────────────────────┘
                     │ spawns, pipes stdout, parses text lines
         ┌───────────┴────────────┬──────────────────────────┐
         ▼                        ▼                          │
┌──────────────────────┐  ┌──────────────────────────┐       │
│ bed_renderer_916_    │  │ same binary, second copy  │       │
│ low_latency          │  │ --keep-output-alive       │       │
│ (C++/PortAudio,      │  │ (writes digital silence   │       │
│  138 KB, arm64)      │  │  to hold the DAC open)    │       │
│ THE DSP ENGINE       │  └──────────────────────────┘       │
└──────────────────────┘                                      │
```

The Python layer contains **no DSP whatsoever**. It is a device picker, preference store, process supervisor and log scraper. All audio work happens in the 138 KB C++ binary, driven entirely by command-line flags.

### Control surface (localhost HTTP)
`/api/devices` · `/api/start` · `/api/stop` · `/api/apply` · `/api/status` · `/api/log` · `/api/events` (SSE) · `/api/preferences` · `/api/minimize` · `/api/client_open` · `/api/client_ping` · `/api/client_close`

Preferences persist to `~/.bed_renderer_web_launcher.json`.

### Launcher → renderer status channel
The renderer prints a status line every 50 ms; the launcher parses it with a regex:

```
Status: active=<labels> | levels=<per-ch dB> | meterL=<dBFS> | meterR=<dBFS> | clipL=<n> | clipR=<n> | transients=<…>
```

Device inventory is likewise scraped from `--list-devices` stdout with the regex
`^\[(\d+)\]\s*(?:\[default-in\]\s*)?(?:\[default-out\]\s*)?(.*?)\s*\|\s*in:\s*(\d+)\s*\|\s*out:\s*(\d+)`.

---

## 2. The DSP engine — exact behaviour

`bed_renderer_916_low_latency` is a **fixed-function 9.1.6-bed → stereo matrix downmixer** on PortAudio.

Bed channel order (fixed, 16 slots):
```
L, R, C, LFE, Ls, Rs, Lrs, Rrs, Lw, Rw, Ltf, Rtf, Ltm, Rtm, Ltr, Rtr
```

### 2.1 The downmix matrix (observed, from the binary's own startup print and code constants)

| Bed channel(s) | → L | → R |
|---|---|---|
| FL | 1.00000000 | 0.00000000 |
| FR | 0.00000000 | 1.00000000 |
| FC | 0.70710678 | 0.70710678 |
| LFE | **2.26464431** | **2.26464431** |
| BL / BLC / SL / TFL / TSL / TBL (all left-side surrounds + heights) | 1.00000000 | 0.00000000 |
| BR / BRC / SR / TFR / TSR / TBR (all right-side surrounds + heights) | 0.00000000 | 1.00000000 |

The LFE coefficient is the IEEE-754 double `0x40021DFDD6042E0D` = **2.26464431**, i.e. **+7.100 dB**, hard-coded as an immediate in `_main` at `0x100002780`. `--lfe-gain-db` scales the LFE *before* this fixed coefficient.

**This matrix is not configurable.** There are no per-channel coefficients, no standard-compliant attenuation, no layout-aware gain.

### 2.2 LFE path
- Default: 4th-order Butterworth low-pass, **125 Hz, 24 dB/octave**, then the ×2.2646 coefficient.
- The **dry (non-LFE) path is delayed** to phase-align with the filtered LFE. Delay is auto-computed over a reported "phase fit band" and can be overridden with `--delay-override-samples`.
- `--dry-lfe` / `--lfe-filter-mode dry` bypasses the low-pass ("Dry ADC2 direct LFE").

### 2.3 PEQ
Two independent parametric-EQ stages on the output, loaded from **text files** in REW / Equalizer-APO format (`Preamp: … dB`, `Filter N: ON PK Fc … Hz Gain … dB Q …`; types `PK/PEQ/peak/peaking`, `LS/LSC/lowshelf`, `HS/HSC/highshelf`). Multi-channel files are supported via ` l` / `:l` / ` r` / `:r` suffixes and `--*-peq-channel` selectors.

- `--global-output-peq-file` — "user/global" PEQ, applied to **both** channels **pre-swap**.
- `--speaker-output-peq-file` — stereo speaker-correction EQ, applied **post-swap**; the launcher flips the L/R channel selection when `--swap-outputs` is active.

### 2.4 Full CLI (37 flags)
```
--list-devices --list-output-devices --list-outputs --keep-output-alive
--input-device <name|index> --output-device <name|index>
--expected-input-device-name <name> --expected-output-device-name <name>
--samplerate 48000 --frames-per-buffer <n> (default 64)
--input-latency-ms <ms> --output-latency-ms <ms>
--input-channels <n> (default/min 16) --input-map a,b,…,p (1-based, 16 entries, 0/x/mute allowed)
--master-gain-db <dB> --lfe-gain-db <dB>
--lfe-filter-mode butterworth|dry  --dry-lfe  --stereo-matrix-mode standard|adc2-direct
--delay-search-max-samples <n> (no-op)  --delay-override-samples <n>
--swap-outputs --clip-output
--global-output-peq-file/-channel  --speaker-output-peq-file  --speaker-left/right-peq-channel
--show-active-inputs --no-show-active-inputs --show-output-meter
--active-threshold-db <dB> (default -160)
--status-interval-ms <n> (default 50)  --xrun-log-interval-ms <n> (default 100)
--no-mac-pro-mode --no-mac-device-changes
```
Flags the GUI never exposes: `--lfe-gain-db`, `--clip-output`, `--samplerate`, `--delay-override-samples`, `--stereo-matrix-mode`, `--expected-*-device-name`, `--no-mac-pro-mode`, `--no-mac-device-changes`.

---

## 3. GUI feature inventory

Collapsible sections: **Input device · Output device · Renderer settings · Output routing and channel PEQ · Bed input visualizer and stereo meters · Renderer log**.

- Device lists with channel counts; "Show incompatible devices" toggle.
- **Layout presets** that only rewrite the 16-slot input map (muting unused slots):

| Preset | input map (1-based, 0 = muted) |
|---|---|
| 9.1.6 bed (1:1) | 1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16 |
| 7.1.4 | 1,2,3,4,5,6,7,8,0,0,9,10,11,12,0,0 |
| 7.1.2 | 1,2,3,4,5,6,7,8,0,0,9,10,0,0,0,0 |
| 7.1 | 1,2,3,4,5,6,7,8,0,0,0,0,0,0,0,0 |
| 5.1.4 | 1,2,3,4,5,6,0,0,0,0,7,8,9,10,0,0 |
| 5.1.2 | 1,2,3,4,5,6,0,0,0,0,7,8,0,0,0,0 |
| 5.1 | 1,2,3,4,5,6,0,0,0,0,0,0,0,0,0,0 |
| 3.1 | 1,2,3,4,0,… |
| 3.0 | 1,2,3,0,… |
| 2.1 | 1,2,0,3,0,… |
| 2.0 stereo | 1,2,0,… |

- Preamp dB (**default −9.5**), frames/buffer, input/output safety latency (0–250 ms), LFE filter mode, L/R swap, output keep-alive.
- PEQ text areas for global and speaker EQ, with named save/load/delete profiles.
- 9.1.6 overhead-layout activity visualiser + stereo peak meters + clip counters.
- Read-only renderer log.

---

## 4. Weaknesses — the concrete "better" list

### Audio quality / correctness
1. **Unity-gain summation.** Seven left-side bed channels (L, Ls, Lrs, Lw, Ltf, Ltm, Ltr) each hit L at **1.0**, plus C at 0.707 and LFE at 2.265. Worst-case gain ≈ **+20 dB**. The app's answer is a manual **−9.5 dB preamp default** — a blunt fix that costs ~9.5 dB of dynamic range on quiet content and still clips loud content.
2. **No standard downmix.** ITU-R BS.775 / Dolby / Apple spatial downmixes attenuate surrounds (−3 dB) and heights (−3 to −6 dB). This one does not attenuate them at all, so surrounds and ceiling channels are as loud as the front L/R — an audibly wrong, "collapsed" image.
3. **LFE at +7.1 dB into both channels**, non-standard (most downmixes drop LFE or apply ~+10 dB only with bass management). Not exposed in the GUI.
4. **Layout presets change nothing but muting.** Because all left channels share coefficient 1.0, selecting 5.1 vs 9.1.6 changes only which inputs are silenced — not the gain structure. A 5.1 source and a 9.1.6 source get wildly different output levels.
5. **No limiter.** Only `--clip-output` (hard clip), and the GUI doesn't expose it.
6. **48 kHz only** — the binary rejects anything else (`This renderer is defined for 48 kHz only.`).
7. **Rigid LFE filter** — 125 Hz / 4th-order Butterworth is hard-coded; cutoff and slope are not adjustable.
8. Possible slip: the 7.1.4 preset routes its four height channels to `Ltf,Rtf,Ltm,Rtm` (front + middle) rather than front + rear. Inaudible here only because every height shares the same coefficient.

### Scope
9. **Live device input only.** No file rendering — you cannot downmix a multichannel WAV/CAF offline.
10. **Input must expose ≥16 channels.** A real 5.1 or 7.1 interface is rejected outright.
11. **Output must be exactly 2 channels**, with a hard-coded quirk allowlist for DACs that report an extra endpoint (`fosi`, `ds2`, `cs43131` string matching).
12. **No binaural/headphone mode** — no HRTF, no crossfeed.
13. **No output recording / capture.**

### Engineering
14. **Three processes, a localhost HTTP server, SSE, and stdout text-scraping** as the internal API. Status and device inventory are parsed out of human-readable log lines with regexes — brittle by construction.
15. **~100 MB bundle** (CPython 3.11 + pywebview + WebKit + PortAudio + OpenSSL 1.1) for 138 KB of actual DSP. Slow cold start.
16. **The "keep-alive" second process** exists to work around Core Audio dropping an idle device — an entire extra process and failure mode that a proper `AudioDeviceAddPropertyListener` design does not need.
17. **Device-change handling is polling + heuristics**: name normalisation, sample-rate-suffix stripping, "quiet windows", recovery retry ladders (0/3/7/12 s), stale-process detection. Hundreds of lines of recovery code compensating for not using Core Audio's notification API.
18. **Stale-path bug acknowledged in its own source comment** — older builds saved an absolute renderer path in `~/.bed_renderer_web_launcher.json`, so a newer app could silently launch an older renderer.
19. **Unsigned-ish / version 0.0.0**, `NSMicrophoneUsageDescription` is the only entitlement-adjacent key; no sandboxing.
20. **PEQ is text-file only** — no curve display, no interactive editing, no verification that a filter set is stable.

---

## 7. peqdb.com/studio data format (2026-10)

**Target:** `https://peqdb.com/studio/` — the measurement database behind the PEQdB brand/model picker in SoundMix's profile library.
**Method:** static analysis of the studio page HTML and its bundled `index-*.js`.

### Catalog index
- The studio HTML inlines the whole catalog as `window.__INDEX__ = {…};` inside an inline script tag.
- Shape: section IE/OE, then source, then MODEL NAME, then variant, then `[offset, channelCount]`.
- 16 IE sources (Super Review, Timtuned, Precogvision, oratory1990 …), 9 OE sources; ~650 brands, ~7500 models, ~13.8k variants (2026-10 snapshot).
- `channelCount` 2 = measured L/R pair (two consecutive records); 1 = single curve.

### Curve blob
- `https://peqdb.com/data/graph-data.bin?v=<epoch>` (~20 MB, 26 147 records).
- Record = 776 bytes: little-endian Float32 `scale`, Float32 `offset`, then 384 Int16 samples.
- Decoded level = `scale * sample - offset` dB, on a shared 384-point log grid, 20 Hz to 20 kHz.
- Verified: SONY MH755 decodes to a plausible IEM curve (+9.7 dB bass shelf, -42 dB at 20 kHz).

### Implementation
- `SoundMix/Sources/SoundMixCore/PEQDBCatalog.swift` — fetch, disk cache (Application Support/SoundMix/PEQdB), parse, decode, search.
- Studio page also embeds ~180 reference targets as inline CSV (`csv:` entries) — not needed for the picker; the bundled Targets folder already covers those.
