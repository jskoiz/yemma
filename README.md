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
  Built around Gemma 4, local inference, multimodal input, and a lot of product-level iteration.
</p>

<p align="center">
  <a href="#screenshots">Screenshots</a> ·
  <a href="#stack-and-structure">Stack</a> ·
  <a href="#inference-handling">Inference</a> ·
  <a href="#model-assets">Model Assets</a> ·
  <a href="#current-issues">Current Issues</a>
</p>

Yemma 4 is an iOS app that runs Gemma 4 locally through `llama.cpp`, with prompts and responses staying on device after setup. This repo also includes the website design, landing page, and brand assets in [`website/`](website/).

## Screenshots

These are some of the less-obvious product surfaces that took real dogfooding time: runtime controls, debug probes, and diagnostics.

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
    <td valign="top"><strong>Dogfooding probes</strong><br>Built-in markdown and renderer test scenarios for formatting stability work.</td>
    <td valign="top"><strong>Diagnostics</strong><br>Recent events, copyable logs, and runtime metadata for debugging startup and model load behavior.</td>
  </tr>
</table>

## Snapshot

- No account, telemetry, or cloud inference
- Streaming SwiftUI chat with markdown rendering, attachments, conversation management, advanced runtime controls, and diagnostics
- Appearance system with `System`, `Light`, and `Dark` modes
- Local multimodal path for image prompts
- App code, website design, and App Store metadata in one repo all OSS

## What Went Into It

- Multi-asset local download flow with resume, validation, unload, and delete handling
- Background `URLSession` download handling so the large first-run setup can continue, reconnect, and recover cleanly
- Objective-C++ multimodal bridge for the `mmproj` vision projector
- Runtime tuning for context size, flash attention, temperature, and response limits
- Settings surfaces for diagnostics logs, event inspection, advanced inference controls, and debug formatting scenarios used for dogfooding
- System-aware visual design with explicit light, dark, and follow-system appearance modes
- Repeated UI iteration on onboarding, streaming behavior, scroll behavior, typing states, and chat readability
- Simulator mock mode for faster product and UI iteration

## Stack And Structure

- `SwiftUI` app shell and screens in `Yemma4/Views`, with `ContentView.swift` deciding between onboarding and chat
- `Appearance.swift` defines the app theme system and the `System` / `Light` / `Dark` appearance preference
- `ChatSessionController.swift` manages prompt submission, streaming state, attachments, and conversation flow
- `LLMService.swift` owns local inference through `llama.swift` / `llama.cpp`
- `ModelDownloader.swift` handles the two-file model setup, resume support, validation, and local storage
- `Yemma4App.swift` wires app lifecycle into the background model download session
- `MultimodalRuntime.h` and `MultimodalRuntime.mm` bridge the vision projector into the local runtime
- `SettingsView.swift`, `AdvancedSettingsView.swift`, and `AppDiagnostics.swift` cover model management, observability, runtime tuning, and debug/test probes
- `website/` contains the landing page, website design, and brand assets
- `METADATA.md` holds App Store metadata drafts, and App Store Connect deployment currently goes through `asc-cli`

## Inference Handling

- `LLMService.swift` wraps the full local inference lifecycle: model load, context creation, multimodal runtime setup, prompt formatting, token streaming, cancellation, and unload
- Prompt formatting uses the model chat template when available and falls back to a Gemma 4-specific template path when needed
- Sampling defaults are pulled from GGUF model metadata rather than being entirely hardcoded, then exposed through in-app controls for temperature, context window, flash attention, and max response length
- The runtime is tuned for on-device Gemma 4 usage with heavy Metal offload, explicit batch sizing, KV-cache reuse for text turns, and a separate multimodal path when image embeddings are involved

## Model Assets

- Hugging Face reference build used during development: [unsloth/gemma-4-E4B-it-GGUF](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF)
- Main GGUF: [`gemma-4-E4B-it-Q4_K_M.gguf`](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/blob/main/gemma-4-E4B-it-Q4_K_M.gguf)
- Image projector: [`mmproj-F16.gguf`](https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF/blob/main/mmproj-F16.gguf)

## Current Issues

- First-time model preparation/loading is still the main rough edge: after download, initial runtime load can be slow and occasionally buggy
- Image inference currently depends on two local model assets: the 5.4 GB Gemma 4 GGUF and the ~1.0 GB `mmproj` projector, so first-time setup is about 6.4 GB

## Build

1. Open `Yemma4.xcodeproj` in Xcode 15+.
2. Run on a physical iPhone with iOS 17+.
3. Use `./scripts/sim_run.sh` for mocked simulator iteration.

## Release

- App Store Connect deployment is handled with `asc-cli`

## License

Open source under the MIT License. See [LICENSE](LICENSE).
