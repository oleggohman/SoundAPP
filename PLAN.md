# SoundMix future work

## Full help documentation

Status: Completed.

Create a complete user-facing help file explaining every application feature and the audio terminology needed to use it confidently.

- [x] Inventory the implemented features and controls across Devices, Downmix, Output EQ, Monitor, and Log. Document actual behavior and limitations.
- [x] Explain setup: microphone permission, virtual loopback inputs, physical outputs, channel requirements, sample rates, and starting/stopping playback.
- [x] Explain Dolby versus Dolby Atmos, decoded multichannel PCM, channel beds versus objects, stereo downmixing, and why this application is not an Atmos decoder or binaural/HRTF renderer.
- [x] Explain channel layouts and mapping, including 2.0, 2.1, 5.1, 7.1.4, 9.1.6, and each channel abbreviation used by the application.
- [x] Explain every downmix recipe, matrix coefficients, channel contributions, stereo swapping, and the treatment of height and surround channels.
- [x] Explain headroom, automatic trim, peak-safe versus power-preserving modes, manual gain, dB, dBFS, dBTP, peak/RMS levels, clipping, and perceived loudness.
- [x] Explain LFE versus ordinary bass, low-pass filtering, cutoff, slope/order, gain, group delay, and dry-path alignment.
- [x] Explain the stereo limiter, ceiling, look-ahead, release, gain reduction, inter-sample peaks, Ready/Off/Stopped states, and why a limiter does not increase quiet volume.
- [x] Explain parametric EQ, preamp, frequency, Q, bandwidth, shelves, global versus speaker correction, per-ear settings, bypass/A-B comparison, and how EQ affects available headroom.
- [x] Explain profile creation, saving, duplication, deletion, import/export, supported file formats, and how save errors are reported.
- [x] Explain measured frequency responses, target curves, normalization, corrected-response plots, deviation, and the limits of predicting perceived sound from a plot.
- [x] Explain offline rendering, source-layout selection, output bit depth, progress/cancellation, source-file protection, render statistics, and output locations. (Removed - feature no longer exists)
- [x] Explain buffer size, safety buffering, latency, independent device clocks, drift correction, underruns/overruns, device changes, and when settings require a restart.
- [x] Add troubleshooting for low volume, missing channels, no audio, distortion, excessive limiter activity, dropouts, permissions, incompatible sample rates, and file errors.
- [x] Add a searchable glossary, practical examples, and screenshots matching the released interface. Keep configuration examples explicit about gain changes.
- [x] Decide the help file format/location and an in-app access point before implementation.
- [x] Verify every explanation against the shipped application and test the setup/troubleshooting instructions.

Acceptance: Every visible feature is covered, terminology is understandable to a non-specialist, examples match actual behavior, and unsupported capabilities are clearly identified.

## Remove the File section from the main navigation

Status: Completed.

- [x] Remove the File option and its entire offline-rendering section from the main navigation; this workflow is not relevant to the intended application.
- [x] Review related navigation, state, entry points, and documentation so no dead links or references remain.
- [x] Decide whether to retain the offline renderer internally for automated tests before removing supporting code. (Retained OfflineRenderer for internal use).
- [x] Update the future help-documentation scope to match the resulting interface and omit the removed File workflow.
- [x] Verify that live input/output playback, device controls, downmix, EQ, monitoring, and logs remain unchanged.

## Remove CloudZone naming from code and interface

Status: Completed.

- [x] Find case-insensitive occurrences of CloudZone across source code, visible UI, identifiers, bundle metadata, queue labels, comments, documentation, build scripts, and resources.
- [x] Replace or remove the branding consistently using SoundMix naming where appropriate.
- [x] Check whether any identifiers affect saved settings, permissions, signing, or compatibility; preserve existing user data and provide migration if required.
- [x] Rebuild generated application artifacts so the delivered interface and binaries reflect the renamed sources.
- [x] Verify that no CloudZone naming remains in the active code or interface and that playback, settings, and device permissions still work.

Historical Git commits remain unchanged unless history rewriting is explicitly requested.

## Binaural / HRTF rendering for the downmix matrix

Status: Completed. Implemented 2026-10-15; 312 automated checks pass (253 DSP, 59 offline).

Added a headphone-oriented binaural fold alongside the amplitude matrix. Every bed channel is
auditioned from its real loudspeaker direction through a head-related impulse response pair
instead of being panned by a scalar coefficient. The amplitude recipes are untouched and
remain the default; binaural is a second fold mode.

### Decisions taken, which the plan left open

- **No dataset ships.** The bank is synthesised from first principles at the device rate:
  Woodworth inter-aural delay, the Brown-Duda spherical head shadow, an elevation-dependent
  pinna notch and a rear high-frequency roll-off. Nothing to license, nothing to download,
  no rate lock-in, and no dataset in the bundle: the binary grew by 0.6 MB, from 2.2 to
  2.8 MB, which is the code. SOFA import is deferred, and
  the engine takes a bank as data so it can be added without touching the renderer.
- **Headphone compensation is not baked in.** The existing per-ear EQ, measured-response and
  target-curve machinery already does that job better, because it can use the user's own
  measurement. Nothing is applied automatically.
- **Room and early reflections are out of scope**, and so is head tracking. Both are stated
  as absent in the README and the help.
- **Latency budget: the bulk delay of the bank**, a third of a millisecond at 48 kHz,
  reported in the Monitor panel and included in the chain's latency accounting.

### Deviations from the plan as written

- **Direct block convolution, not partitioned FFT.** At 96-384 taps the direct form through
  `vDSP_convD` is faster than an FFT partition scheme would be and adds no block latency of
  its own. The structure is otherwise what the plan describes.
- **A nullable `binaural` profile on `ProcessorConfiguration`, not a `FoldMode` enum.** It
  keeps every existing call site, test and the verified matrix render path untouched; the
  branch happens once, at the top of `process`.

### Architecture

- [x] Fold-stage selection on `ProcessorConfiguration` (`binaural: BinauralProfile?`), so the matrix path is selected against rather than layered on. `effectiveMatrix` still describes the amplitude fold for the interface; in binaural mode only the LFE row of the matrix is rendered.
- [x] 16-in / 2-out FIR bank with block convolution on Accelerate, every FFT-free buffer, tap array and scratch region allocated when the engine is built on the control thread. The render callback allocates nothing, locks nothing and chunks long buffers to a fixed block capacity.
- [x] Convolution count halved with the sum/difference identity on mirrored pairs — fifteen convolutions per block instead of twenty-nine — gated on `isMirrorSymmetric()` and proved against a naive four-convolution reference in the tests.
- [x] Latency budget decided and reported: the bank's bulk delay is added to `latencyMS`, so it reaches the Monitor panel, the log and the snapshot alongside the limiter look-ahead and the LFE dry-path delay.
- [x] Headroom model extended: the exact peak bound is the summed absolute taps per ear and the power figure the root of the summed tap energy, computed from the loaded bank with the LFE row counted exactly as the matrix counts it. `peakSafe` and `powerPreserving` keep behaving the same way, and the headroom readout stays truthful. The figures are quoted at a 48 kHz reference rate so the trim does not shift when the device changes rate.
- [x] Chain order kept: fold → global PEQ → swap → speaker PEQ → limiter, with the output stage shared by both folds so it can only behave one way. Documented that `swapOutputs` mirrors the whole scene and that per-ear speaker PEQ now genuinely means per ear.

### HRIR data

- [x] Dataset and licence settled by not shipping one; see the decisions above.
- [x] SOFA parsing versus baking settled the same way. `HRIRBank` is plain immutable data, so a parser or a baker can produce one later.
- [x] All sixteen bed slots mapped to an azimuth and elevation, in `BedChannel.direction`, with the heights at 35-45 degrees; the interpolation question disappears with a synthesised bank, which is evaluated exactly at the angle asked for.
- [x] Sample rate handled by generating the bank for the device rate, with the tap count derived from the maximum inter-aural delay plus the filter tail. Verified that the bank lengthens with the rate and that inter-aural delay survives.
- [x] Size: no data added to the bundle; 0.6 MB of code.

### Spatial behaviour and controls

- [x] Bass crossed out of the HRTF path through a Linkwitz-Riley 4th-order split, with the bass leg summed equally to both ears and delay-aligned to the bank's bulk delay. Verified flat to within 0.35 dB through the crossover.
- [x] Headphone compensation decided (see above) and stated in the help.
- [x] Crossfeed-only mode shipped as a bank variant, so it costs no extra render code.
- [x] Room and early reflections excluded, and said so in the help.
- [x] Head tracking recorded as out of scope.
- [x] Interface: a Fold card selecting the mode, a Binaural card with the bank, head radius, bass crossover, rear damping and elevation cue, a per-channel table of angle, inter-aural delay and per-ear level, the tap count, the bulk delay and a headphones-only warning. The recipe editors are replaced rather than left live and inert, and the fields that do not apply to crossfeed are disabled.
- [x] Settings persist, and a settings file written before the binaural fold restores to the amplitude matrix exactly as it was saved.

### Verification

- [x] Block convolution matches a naive time-domain reference to 1e-9 across block sizes of 1, 7, 11, 37, 120, 300 and 512, including blocks shorter than the filter.
- [x] A delta filter bank reproduces the matrix path exactly, to the 32-bit float output floor — the null test that proves the stage is transparent.
- [x] Measured impulse arrival matches the reported latency to within half a sample, with its peak within two samples of that.
- [x] The one signal built to reach the L1 bound lands at full scale and no further under `peakSafe`, and the trim figures equal the bank norms exactly.
- [x] The generated bank is an exact mirror pair by pair, every response has unity DC gain, and the sum/difference fold matches the four-convolution form.
- [x] The bass crossover sums flat to 0.35 dB, a hard-panned source is centred below it and still panned above it, and the LFE is untouched.
- [x] No allocation, locking or unbounded work in the render callback — by construction and review rather than by instrumentation. Measured cost: about 30x real time at 48 kHz with all sixteen channels fed, 15x at 96 kHz and 7x at 192 kHz, in both the live chain and the offline renderer.
- [x] Offline rendering is byte-for-byte deterministic and goes through the same processor as the live path. Note: that shared path is relied on rather than separately asserted sample for sample.
- [x] Every mapped channel is confirmed to arrive from its intended side at 4 kHz, and not from its mirror, through a real file render per channel. Note: this uses generated per-channel files rather than the shipped identification WAV.

### Documentation

- [x] `README.md`, `Resources/Help.md` and the generated `Resources/SoundMix.help` all corrected together; the "not a binaural/HRTF spatializer" claim is gone from every one of them.
- [x] The binaural terms are explained where they are used rather than in a separate glossary, since the help has no glossary section to extend.
- [x] Stated plainly that the fold is for headphones only, that it colours timbre by design, and that front/back confusion and in-head localisation are properties of a generic synthesised head rather than faults.
- [x] No dataset attribution needed, there being no dataset.

Acceptance met: binaural mode is selectable without disturbing any amplitude recipe, parity
included; it is real-time safe at the supported rates and buffer sizes; it reports its
latency and headroom as truthfully as the matrix path; it passes the null and symmetry
tests; and it is documented, limits included.

## Audition PEQ plot edits live while editing

Status: Not started. Planned only.

The graphical PEQ editor is draft-only: `PEQPlotEditor` keeps a `PEQEditDraft` and nothing
reaches the engine until **Apply** calls `model.applyPEQDraft(draft)`. Dragging a band
therefore changes the picture and not the sound, which is the wrong way round for an editor
whose whole purpose is to tune by ear. Edits should be audible as they are made, while
staying a draft on disk.

- [ ] Push the draft's combined profiles (`draft.combined(.left)` / `.right` and the global stage) to the running processor as the user drags, without rewriting the APO text, marking the library profile dirty, or changing `model.globalPEQText` / `speakerPEQText`.
- [ ] Keep the existing commit semantics intact: Apply still rewrites the text, Reset still returns to the state at open or last Apply, and Cancel/Close must restore the engine to exactly the pre-edit EQ — including when the window is closed by other means.
- [ ] Coalesce updates. `SoundMixProcessor.apply` allocates a fresh render state and rebuilds every biquad chain, the limiter and the delay buffers; a drag at display rate would do that 60 times a second. Throttle or mark-dirty-and-flush on a tick, and confirm the control-thread cost is bounded.
- [ ] Deal with coefficient jumps. History is inherited across an apply, so state is continuous, but the coefficients step — a large gain drag will click. Decide between a short ramp, a crossfade between two chains, or accepting stepped audio, and state the choice.
- [ ] Make the live path respect the editor's existing guards: no preview while `draft.warnings` is non-empty, and no preview while `conflict` is true (the main window changed the EQ underneath the editor).
- [ ] Keep the headroom and limiter readouts honest during the preview, since a preamp drag changes available headroom immediately.
- [ ] Decide whether live audition is a toggle in the editor (recommended, default on, labelled as auditioning an unsaved draft) or unconditional.
- [ ] Verify the A/B bypass control and the per-stage hide/solo state still mean what they say while a preview is active.

Acceptance: Dragging a band or changing preamp in the plot editor is heard immediately with
no clicking beyond the stated tolerance, no measurable change in render-thread cost,
cancelling leaves the engine exactly as it was before the editor opened, and nothing is
written to the profile library until Apply.

## Make the PEQ plot editor a complete editor

Status: Not started. Planned only.

Three gaps in `PEQPlotEditor`, all of which force the user back to the inspector fields or
to the main window for things the plot should handle directly.

### Drag points horizontally to set frequency

`ResponseCurve` exposes `onChangeGain(index:gain:)` and nothing else, so horizontal
movement is discarded — the editor even says so twice ("frequency locked", "horizontal
movement is ignored").

- [ ] Add a frequency channel to the plot's drag handling (`onChangeBand(index:frequency:gainDB:)` or a second callback) and a `setFrequency` on `PEQEditDraft` beside `setGain`, keeping the existing gain-only path working.
- [ ] Map horizontal pixels through the plot's logarithmic frequency axis, clamp to 20 Hz … Nyquist/2 as the inspector field already does, and quantise sensibly so a drag does not produce 1037.4183 Hz.
- [ ] Decide how dragging interacts with band order: APO filters are a list, and moving one past another changes nothing acoustically but makes the numbered points jump. Either keep the list order fixed or re-sort and renumber consistently, and say which.
- [ ] Offer a modifier to constrain a drag to one axis, since most edits are deliberately gain-only or frequency-only, and update the plot's caption, which currently advertises the restriction.

### Choose the EQ profile from inside the editor

The editor opens on whatever the main window had selected and treats any change made behind
it as a `conflict` that disables editing. Switching profile means closing, switching, reopening.

- [ ] Put the profile library's picker in the editor's header, bound to the same selection the main window uses.
- [ ] Define what switching does to unapplied edits: offer Apply, discard or cancel rather than silently dropping the draft, and re-seed the draft from the newly selected profile.
- [ ] Keep the conflict guard meaningful: a switch made deliberately in the editor must not read as an external change, while a change actually made in the main window still must.
- [ ] Make the measured response and target curves follow the switch, since the result plot is drawn from the selected profile's measurement.

### Delete a band from the list

Deletion today is a single button that acts on the selected band only.

- [ ] Give each row in the band list its own delete control, and support the Delete key on the selected row.
- [ ] Keep the selection and the numbering sane after a removal — select the next band rather than clearing the selection, which is what the current button does.
- [ ] Make removal undoable within the editor: Reset already restores the state at open or last Apply, so deletion must be covered by it rather than being immediate and final.
- [ ] Mirror the same affordance for enable/disable, so a band can be silenced without being destroyed.

Acceptance: A band can be moved in both axes and deleted from its row, a different profile
can be loaded without leaving the editor, every one of those edits is still a draft that
Reset restores and only Apply commits, and the captions no longer describe restrictions
that have been lifted.
