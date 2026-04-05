<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="website/brand/y4-dark-256.png">
    <img src="website/brand/y4-light-256.png" alt="Yemma 4 logo" width="84">
  </picture>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="website/brand/domain-dark-600.png">
    <img src="website/brand/domain-light-600.png" alt="yemma.chat" width="300">
  </picture>
</p>

<p align="center">
  <a href="LICENSE"><img alt="MIT License" src="https://img.shields.io/badge/license-MIT-111111?style=for-the-badge"></a>
  <img alt="iOS 17+" src="https://img.shields.io/badge/iOS-17%2B-0A84FF?style=for-the-badge&logo=apple">
  <img alt="Swift 6.1" src="https://img.shields.io/badge/Swift-6.1-F05138?style=for-the-badge&logo=swift&logoColor=white">
  <img alt="On-device inference" src="https://img.shields.io/badge/Inference-On--Device-5E4AE3?style=for-the-badge">
  <img alt="Gemma 4 E4B" src="https://img.shields.io/badge/Model-Gemma%204%20E4B-2E7D32?style=for-the-badge">
</p>

<p align="center">
  <strong>Private, on-device AI chat for iPhone.</strong><br>
  Runs Gemma 4 locally via llama.cpp. No cloud, no accounts, no telemetry.
</p>

<p align="center">
  <a href="#screenshots">Screenshots</a> ·
  <a href="#structure">Structure</a> ·
  <a href="#inference">Inference</a> ·
  <a href="#model-assets">Model Assets</a> ·
  <a href="#known-issues">Known Issues</a>
</p>

Yemma 4 runs Gemma 4 on-device through `llama.cpp` with Metal GPU acceleration. Prompts and responses stay on the phone. This repo includes the app, website, and brand assets.

## Features

- Streaming chat with markdown rendering, image attachments, and conversation history
- Resumable background model download (~6.4 GB first-time setup)
- Multimodal inference via Objective-C++ `mmproj` vision projector bridge
- Configurable context size, flash attention, temperature, and response limits
- Light / Dark / System appearance modes
- Built-in diagnostics, debug probes, and simulator mock mode

## Screenshots

Runtime controls, debug probes, and diagnostics.

<table>
  <tr>
    <td width="33%">
      <img src="docs/readme/advanced-settings.jpg" alt="Advanced settings for inference tuning" width="100%">
    </td>
    <td width="33%">
      <img src="docs/readme/debug-scenarios.jpg" alt="Debug scenarios for markdown and formatting tests" width="100%">
    </td>
    <td width="33%">
      <img src="docs/readme/diagnostics-log.jpg" alt="Diagnostics event log and runtime details" width="100%">
    </td>
  </tr>
  <tr>
    <td valign="top"><strong>Advanced controls</strong><br>Temperature, context window, flash attention, and response length tuning in-app.</td>
    <td valign="top"><strong>Debug probes</strong><br>Built-in markdown and renderer test scenarios for formatting stability work.</td>
    <td valign="top"><strong>Diagnostics</strong><br>Recent events, copyable logs, and runtime metadata for debugging startup and model load behavior.</td>
  </tr>
</table>

## Structure

- `ContentView.swift` — root state machine (onboarding vs chat)
- `ChatSessionController.swift` — prompt submission, streaming, attachments, conversation flow
- `LLMService.swift` — llama.cpp inference lifecycle (load, generate, cancel, unload)
- `ModelDownloader.swift` — two-file download with resume, validation, local storage
- `MultimodalRuntime.h/.mm` — Objective-C++ bridge for the vision projector
- `SettingsView.swift` / `AdvancedSettingsView.swift` — runtime tuning, diagnostics, debug probes
- `Appearance.swift` — theme system
- `website/` — landing page and brand assets

## Inference

- Prompt formatting uses the model's chat template with a Gemma 4 fallback
- Sampling defaults read from GGUF metadata, adjustable in-app
- Metal offload, explicit batch sizing, KV-cache reuse for text turns, separate multimodal path for images

## Model Assets

- Hugging Face reference build used during development: [unsloth/gemma-4-E4B-it-GGUF](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF)
- Main GGUF: [`gemma-4-E4B-it-Q4_K_M.gguf`](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/blob/main/gemma-4-E4B-it-Q4_K_M.gguf)
- Image projector: [`mmproj-F16.gguf`](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/blob/main/mmproj-F16.gguf)

## Known Issues

- Initial model load after download can be slow and occasionally flaky
- First-time setup downloads ~6.4 GB (5.4 GB model + ~1.0 GB vision projector)

## Build

1. Open `Yemma4.xcodeproj` in Xcode 15+.
2. Run on a physical iPhone with iOS 17+.
3. Use `./scripts/sim_run.sh` for mocked simulator iteration.

## Release

App Store Connect deployment via `asc-cli`.

## License

MIT. See [LICENSE](LICENSE).
