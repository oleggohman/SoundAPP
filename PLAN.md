# SoundMix future work

## Full help documentation

Status: Planned. Do not implement as part of the current bug fixes.

Create a complete user-facing help file explaining every application feature and the audio terminology needed to use it confidently.

- [ ] Inventory the implemented features and controls across Devices, Downmix, Output EQ, Monitor, and Log. Document actual behavior and limitations.
- [ ] Explain setup: microphone permission, virtual loopback inputs, physical outputs, channel requirements, sample rates, and starting/stopping playback.
- [ ] Explain Dolby versus Dolby Atmos, decoded multichannel PCM, channel beds versus objects, stereo downmixing, and why this application is not an Atmos decoder or binaural/HRTF renderer.
- [ ] Explain channel layouts and mapping, including 2.0, 2.1, 5.1, 7.1.4, 9.1.6, and each channel abbreviation used by the application.
- [ ] Explain every downmix recipe, matrix coefficients, channel contributions, stereo swapping, and the treatment of height and surround channels.
- [ ] Explain headroom, automatic trim, peak-safe versus power-preserving modes, manual gain, dB, dBFS, dBTP, peak/RMS levels, clipping, and perceived loudness.
- [ ] Explain LFE versus ordinary bass, low-pass filtering, cutoff, slope/order, gain, group delay, and dry-path alignment.
- [ ] Explain the stereo limiter, ceiling, look-ahead, release, gain reduction, inter-sample peaks, Ready/Off/Stopped states, and why a limiter does not increase quiet volume.
- [ ] Explain parametric EQ, preamp, frequency, Q, bandwidth, shelves, global versus speaker correction, per-ear settings, bypass/A-B comparison, and how EQ affects available headroom.
- [ ] Explain profile creation, saving, duplication, deletion, import/export, supported file formats, and how save errors are reported.
- [ ] Explain measured frequency responses, target curves, normalization, corrected-response plots, deviation, and the limits of predicting perceived sound from a plot.
- [x] Explain offline rendering, source-layout selection, output bit depth, progress/cancellation, source-file protection, render statistics, and output locations. (Removed - feature no longer exists)
- [ ] Explain buffer size, safety buffering, latency, independent device clocks, drift correction, underruns/overruns, device changes, and when settings require a restart.
- [ ] Add troubleshooting for low volume, missing channels, no audio, distortion, excessive limiter activity, dropouts, permissions, incompatible sample rates, and file errors.
- [ ] Add a searchable glossary, practical examples, and screenshots matching the released interface. Keep configuration examples explicit about gain changes.
- [ ] Decide the help file format/location and an in-app access point before implementation.
- [ ] Verify every explanation against the shipped application and test the setup/troubleshooting instructions.

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
