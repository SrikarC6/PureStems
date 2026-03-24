# PureStems

> A glassmorphic macOS stem player and separator, powered by [Demucs](https://github.com/facebookresearch/demucs).

PureStems splits any song into its four core stems — Vocals, Drums, Bass, and Melody — and lets you play them back individually or together, in any mix you want. Built with the same design language as PureVibes.

---

## Table of Contents

- [Screenshots](#screenshots)
- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Architecture Highlights](#architecture-highlights)
- [Roadmap](#roadmap)
- [Known Issues](#known-issues)
- [Contributing](#contributing)
- [Built With](#built-with)
- [Acknowledgements](#acknowledgements)
- [License](#license)

---

## Screenshots

<!-- Add screenshots to the assets/ folder and uncomment:

![Home Screen](assets/home-screen.png)
![Stem Player](assets/stem-player.png)
![Processing Overlay](assets/processing-overlay.png)

-->

*Screenshots coming soon.*

---

## Features

### Stem Separation
- One-click separation via the **Demucs** CLI (`htdemucs_ft` model)
- Two quality modes: **Fast** (standard pass) and **Pro** (2 shifts, 0.50 overlap)
- **Batch folder mode** — separate an entire folder of songs in sequence
- Open pre-separated stems folders directly, skipping the separation step
- Real-time progress bar with per-pass percentage tracking

### Stem Player
- Independent volume sliders for all four stems: **Vocals**, **Drums**, **Bass**, **Melody**
- Volume range of **0–200%** per stem (unity at 100%)
- **Keyboard shortcuts**: hold `Cmd+1–4` to target a stem, then scroll or use arrow keys to adjust its volume
- Waveform scrubber with a draggable playhead for precise seeking

### Snippet & Export
- **Snippet mode** — drag bracket handles on the waveform to define a loop region
- Magnetic snap-to-second on handle edges for precise looping
- Gapless looping of the selected region
- **Export snippet** — offline renders the active mix to a `.wav` file at source quality

### Design
- Glassmorphic UI with `ultraThinMaterial`, gradient strokes, and drop shadows
- Blurred album artwork as a dynamic ambient background layer
- Animated dot-grid that pulses and waves during active separation
- `LiquidGlassToggle` for Pro Mode switching
- Fully hidden title bar with `fullSizeContentView`

---

## Requirements

- macOS 14 (Sonoma) or later
- Python 3.11+ with Demucs installed:
  ```bash
  pip3 install demucs
  ```
- First separation will download the `htdemucs_ft` model (~200 MB) automatically

---

## Installation

### Option A — Download the DMG *(recommended)*
1. Go to the [Releases](../../releases) page
2. Download the latest `PureStems.dmg`
3. Open the DMG and drag **PureStems** into your Applications folder

### Option B — Build from source
1. Clone the repository:
   ```bash
   git clone git@github.com:SrikarC6/PureStems.git
   cd PureStems
   ```
2. Open `PureStems.xcodeproj` in Xcode
3. Select your Mac as the run destination and press `⌘R`

---

## Usage

### Separating a song
1. Launch PureStems
2. Click **Separate a Song** and select any audio file (`.mp3`, `.wav`, `.flac`, etc.)
3. Toggle **Pro Mode** on for higher quality (slower) separation
4. Watch the progress overlay — separation typically takes 30 seconds to a few minutes depending on your machine and quality setting
5. Stems load automatically into the player when complete

### Playing stems
- Use the volume sliders to isolate or blend stems
- Hold `Cmd+1` (Bass), `Cmd+2` (Drums), `Cmd+3` (Melody), or `Cmd+4` (Vocals) and scroll to adjust that stem's volume hands-free

### Looping a region
1. Toggle **Snippet Mode** in the player
2. Drag the left and right bracket handles on the waveform to define your loop
3. Playback loops gaplessly within the region
4. Hit the **Export** button to render the current mix of that region to a `.wav` file

---

## Architecture Highlights

- **`DemucsService`** — `actor`-isolated subprocess wrapper that finds the Demucs executable across common Python install paths, streams stderr for live progress, and maps per-pass percentages to a continuous 0–100% global progress metric
- **`StemPlayerViewModel`** — `@Observable` + `@MainActor` class managing `AVAudioEngine`, per-stem `AVAudioPlayerNode` routing, frame-accurate seeking, and gapless snippet looping via recursive segment scheduling
- **`SnippetExportService`** — `actor`-isolated offline renderer using `AVAudioEngine`'s manual rendering mode to export the active stem mix as a 16-bit PCM `.wav` at source sample rate
- **`InteractionMonitor`** — `NSEvent` local monitor tracking `Cmd+1–4` held states with scroll-wheel accumulation and threshold dampening for smooth trackpad volume control
- **`DesignSystem`** — shared glassmorphic components (`GlassButton`, `GlassPanelModifier`, `VisualEffectView`, `FaintGridBackground`) and `NSImage` extensions for Gaussian blur caching and dominant color extraction

---

## Roadmap

- [ ] Drag-and-drop capabilities
- [ ] Per-stem isolate and mute buttons
- [ ] Independent stem download

---

## Known Issues

- The first separation on a new machine downloads the `htdemucs_ft` model (~200 MB); progress stalls at 0% during this download with no indicator
- Batch mode processes songs sequentially; no parallelism yet
- Very short audio files (<5 seconds) may cause Demucs to error silently

---

## Contributing

Issues and pull requests are welcome. For major changes, please open an issue first to discuss what you'd like to change.

---

## Built With

- [Swift](https://swift.org/) & [SwiftUI](https://developer.apple.com/xcode/swiftui/)
- [AVFoundation](https://developer.apple.com/av-foundation/) — audio engine, offline rendering, and file I/O
- [Accelerate](https://developer.apple.com/accelerate/) — waveform data processing
- [Demucs](https://github.com/facebookresearch/demucs) — AI-powered source separation backend

---

## Acknowledgements

PureStems would not exist without **Demucs**, the open-source music source separation library developed by the [Meta AI Research](https://ai.facebook.com/) team. The `htdemucs_ft` model used by this app is their state-of-the-art hybrid Transformer model, fine-tuned for four-stem separation.

> Défossez, A., Usunier, N., Bottou, L., & Bach, F. (2021). *Hybrid Spectrogram and Waveform Source Separation*. https://github.com/facebookresearch/demucs

If you find Demucs useful, please consider starring their repository and reading their research.

---

## License

This project is licensed under the MIT License. See [`LICENSE`](LICENSE) for details.
