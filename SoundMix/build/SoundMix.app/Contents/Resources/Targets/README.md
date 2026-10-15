# Bundled target curves

These CSV files are unmodified downloads. `sources.json` records the exact upstream
revisions, URLs and SHA-256 hashes. The MIT license notices from both source
repositories are included alongside the curves and copied into the app bundle.

- JM-1: **JM-1 with Harman filters** from jaakkopasanen/AutoEq. This is a named
  variant, not an unmodified JM-1 curve or the Squiglink 10 dB tilt variant.
- Harman IEM: **Harman in-ear 2019**, including its published bass rise.
- IEF / Crinacle: **IEF Neutral in-ear** and **IEF Neutral in-ear with bass**
  from iwalton3/AutoEq.

The app normalizes curves for display using its existing 200 Hz–2 kHz reference.
Comparisons require compatible measurement rigs; selecting a target does not
convert measurements between rigs and does not automatically generate EQ.
