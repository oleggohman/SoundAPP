# SoundMix Help & Documentation

SoundMix is a multichannel audio router, downmixer, and parametric equalizer for macOS. It takes a multichannel audio feed—such as a 7.1.4 Dolby Atmos bed or a 5.1 surround mix from a virtual loopback device—and folds it down to a standard 2.0 stereo output for your headphones or speakers.

This guide covers setup, terminology, downmix options, equalization, and troubleshooting.

---

## 1. Setup & Device Configuration

### Microphone Permission
SoundMix routes audio from an input device to an output device. macOS considers any audio input a "microphone", so SoundMix requires Microphone permission to run. Without it, the application cannot capture the audio it needs to process.

### Virtual Loopback Inputs
SoundMix does not decode proprietary formats (like Dolby Atmos bitstreams) directly from a file or streaming service. Instead, you need a virtual loopback device (like BlackHole or Loopback) to route decoded, uncompressed multichannel audio (PCM) from your player (e.g., Apple Music or a DAW) into SoundMix.

1. Set your player or system output to the virtual loopback device.
2. In SoundMix's **Devices** panel, select the virtual loopback device as the **Input**.
3. Select your physical speakers or headphones as the **Output**.

### Sample Rates & Clocking
SoundMix requires both the input and output devices to run at the same sample rate. If they differ, SoundMix will resample the input to match the output. It handles clock drift between independent devices automatically using a safety buffer.

### Starting and Stopping
Once your devices are selected, click **Start** in the transport bar. The status badge will change to "Rendering", and live audio will begin flowing. Changes to devices require stopping and restarting the engine.

---

## 2. Downmix & Routing

### Layouts
SoundMix expects a specific channel layout on the input device. In the **Devices** panel, select the layout that matches your source material:
- **2.0, 2.1, 3.0, 3.1, 4.0, 5.1, 7.1**: Standard surround layouts.
- **5.1.2, 5.1.4, 7.1.2, 7.1.4, 9.1.6**: Immersive layouts with height channels.

*Note: SoundMix expects decoded PCM audio beds. It is not an Atmos object renderer or a binaural/HRTF spatializer. It performs a traditional amplitude-panned downmix.*

### Downmix Recipes (Matrix)
In the **Downmix** panel, choose a recipe that dictates how surround and height channels are folded into the left and right speakers.
- **Reference**: Follows ITU/Dolby guidelines for a standard stereo fold-down.
- **Parity**: A slightly wider mix, often used for parity with certain hardware decoders.
- **Direct**: Passes only the Left and Right channels, ignoring the rest.

### LFE (Low-Frequency Effects)
The LFE channel (.1) is handled separately from ordinary bass managed by your speakers.
- **LFE to L/R**: You can add the LFE channel to the stereo mix.
- **Low-pass Filter**: You can apply a Butterworth low-pass filter to the LFE channel before mixing to prevent high-frequency bleed. You can configure the cutoff frequency (Hz) and slope (order).
- **Gain**: LFE is typically mixed +10dB higher than the main channels in a theatrical mix. SoundMix allows you to adjust the LFE gain explicitly.

### Headroom & Trim
Combining multiple channels into two increases the overall signal level, which can cause digital clipping.
- **Automatic Trim**: SoundMix calculates the worst-case peak gain of your chosen matrix and applies a negative trim to guarantee the output never clips, even if every input channel hits full scale simultaneously.
- **Manual Gain**: If the automatic trim is too quiet (which is common for highly dynamic cinematic mixes), you can manually increase the gain. However, you rely on the True-Peak Limiter to catch transient overloads.

---

## 3. Output EQ & Correction

The **Output EQ** panel provides parametric equalization (PEQ) to correct the frequency response of your headphones or speakers.

### Equalizer APO / REW Compatibility
SoundMix natively understands the plain-text filter format exported by Room EQ Wizard (REW) and used by Equalizer APO. You can paste filters directly into the editor or import `.txt` files.

### Global vs. Speaker Correction
- **Global PEQ**: Applied to both the Left and Right channels equally. Useful for general headphone correction.
- **Speaker Correction**: Applied independently to the Left and Right physical speakers. This correction follows the physical speaker even if you use the "Swap L/R" toggle.

### Profiles & Measurements
- **Profiles**: You can save your EQ settings as named profiles in the library for quick switching.
- **Measurements**: You can load a frequency response measurement file (e.g., from AutoEQ or squig.link) to visualize the uncorrected response alongside your applied EQ curve and target curve. SoundMix supports standard 2-column or 3-column CSV/TXT measurement files.

---

## 4. Monitoring & Protection

### The True-Peak Limiter
In the **Monitor** panel, you can configure the True-Peak Limiter. It sits at the very end of the signal chain to protect your output from clipping.
- **Ceiling**: The absolute maximum output level (e.g., -1.0 dBTP).
- **Release**: How quickly the limiter recovers after reducing gain.
- *Note: A limiter does not make quiet audio louder; it only pushes down loud peaks that exceed the ceiling.*

### Meters
The transport bar displays the final Left and Right output levels. The **Monitor** panel provides a detailed view of every input channel's activity before downmixing.

### The Log
The **Log** panel displays a running history of engine events, layout changes, buffer underruns, and errors. If audio stops unexpectedly, check the log for clues.

---

## 5. Troubleshooting

- **No Audio**: Ensure Microphone permission is granted in System Settings. Verify your loopback device is active and selected.
- **Low Volume**: A full 9.1.6 downmix requires significant automatic trim (-15dB or more) to guarantee no clipping. If the source material is quiet, use the Manual Gain slider to boost the level, but ensure the Limiter is enabled.
- **Distortion / Pumping**: If the audio sounds distorted or "pumps" unnaturally, you have added too much Manual Gain or EQ Preamp, and the Limiter is working too hard. Check the Limiter status in the transport bar; if it shows constant gain reduction (e.g., -6.0 dB), reduce your manual gain.
- **Missing Channels**: Ensure the Layout selected in the Devices panel matches the channel count and order of your source material.
- **Audio Dropouts / Glitches**: This indicates a buffer underrun, often caused by heavy CPU load or misaligned device clocks. Try increasing the `Safety buffer` size in the Devices panel.
