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
  <img alt="Gemma 4 E2B" src="https://img.shields.io/badge/Model-Gemma%204%20E2B-2E7D32?style=for-the-badge">
</p>

<p align="center">
  <strong>Private, on-device AI chat for iPhone.</strong><br>
  Runs Gemma 4 locally through a Swift-native MLX multimodal runtime. No cloud, no accounts, no telemetry.
</p>

<p align="center">
  <a href="#screenshots">Screenshots</a> ·
  <a href="#structure">Structure</a> ·
  <a href="#gemma-4-mlx-port">Gemma 4 MLX Port</a> ·
  <a href="#model-bundle">Model Bundle</a> ·
  <a href="#build">Build</a>
</p>

This repo contains the iOS app, landing page, and brand assets.

Yemma now ships on a single-bundle MLX Gemma 4 runtime. The app downloads one Hugging Face repository, validates the bundle locally, and lets MLX handle both text and image preprocessing in Swift. Historical migration notes still live in [docs/mlx-migration-strategy.md](docs/mlx-migration-strategy.md) and [docs/MLX_REGRESSION_POSTMORTEM.md](docs/MLX_REGRESSION_POSTMORTEM.md).

## Features

- Streaming chat with markdown rendering, image attachments, and conversation history
- Resumable background model bundle download (~4.2 GB first-time setup)
- On-device multimodal text and image inference via `MLXVLM`
- Local model-bundle validation before the app marks setup complete
- Configurable response style, temperature, and response limits
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
    <td valign="top"><strong>Advanced controls</strong><br>Temperature, context window, flash attention, response length.</td>
    <td valign="top"><strong>Debug probes</strong><br>Markdown and renderer test scenarios.</td>
    <td valign="top"><strong>Diagnostics</strong><br>Event log, copyable logs, runtime metadata.</td>
  </tr>
</table>

## Structure

- `ContentView.swift` — root state machine (onboarding vs chat)
- `LLMService.swift` — MLX multimodal load, generation, streaming, and runtime lifecycle
- `MLXModelSupport.swift` — model directory validation and Gemma 4 asset contract checks
- `ModelDownloader.swift` — single-repository download, resume, cleanup, and local validation
- `ConversationStore.swift` — chat history persistence
- `YemmaPromptPlanner.swift` — prompt shaping for the chat experience
- `Gemma4SmokeAutomation.swift` — smoke checks for the shipped model path
- `SettingsView.swift` / `AdvancedSettingsView.swift` — runtime tuning, diagnostics, debug probes
- `Appearance.swift` — theme system
- `website/` — landing page and brand assets

## Gemma 4 MLX Port

Yemma originally ran Gemma 4 through two separate GGUF assets: a text model plus a standalone `mmproj` vision projector. The shipped MLX path replaces that with one Swift-native multimodal bundle and one runtime container.

Validated upstream baseline:

- `mlx-swift-lm` at `8b5eef7`
- `mlx-swift-examples` at `31b6cf6`

How the Swift port works:

- `Package.swift` pulls in `MLX`, `MLXLMCommon`, `MLXVLM`, `Hub`, and `Tokenizers`, so the app stays in Swift instead of bridging through `llama.cpp` or Objective-C++ vision code.
- `ModelDownloader` pulls one Hugging Face repository, `mlx-community/gemma-4-e2b-it-4bit`, using `*.safetensors`, `*.json`, and `*.jinja` patterns instead of downloading a text GGUF and a second `mmproj` file.
- `ModelDirectoryValidator` proves the downloaded bundle is actually loadable by checking required metadata files, processor config, tokenizer files, weight shards, and safetensors index references before the app accepts setup as complete.
- `Gemma4MLXSupport` enforces the Gemma 4 multimodal contract in Swift by cross-checking processor and model values like soft-token budgets, patch size, and pooling kernel size, and it normalizes compatibility gaps like a missing top-level `pad_token_id`.
- `LLMService` converts each conversation turn into structured `Chat.Message` entries with optional image URLs, then calls `context.processor.prepare(input:)` so MLX performs the image and text preprocessing directly inside the same Swift runtime.
- `VLMModelFactory.shared._load(...)` loads the entire Gemma 4 VLM from one local directory, so text generation and image understanding live in one `ModelContainer` instead of separate GGUF and projector runtimes.
- Multimodal generation stability is handled in Swift too: Yemma adds a hidden-channel budget processor and response-token filtering so on-device image turns stay clean without a custom native bridge.

What that buys us:

- no standalone `mmproj` download
- no Objective-C++ multimodal bridge
- one model bundle to download, validate, load, and delete
- one runtime path for both text-only and image-assisted turns

## Model Bundle

- Source repository: [`mlx-community/gemma-4-e2b-it-4bit`](https://huggingface.co/mlx-community/gemma-4-e2b-it-4bit)
- Approximate first-download size: `4.2 GB`
- Downloaded file classes: safetensors weights, tokenizer/config JSON, processor config, and chat template files
- Runtime contract: `config.json`, `tokenizer.json`, `tokenizer_config.json`, `processor_config.json` or `preprocessor_config.json`, plus one or more readable `.safetensors` weight files

After the bundle is downloaded, Yemma can load, unload, and run it entirely on device.

## Build

1. Open `Yemma4.xcodeproj` in a recent Xcode with Swift 6.1 support.
2. Run on a physical iPhone with iOS 17+ for real MLX inference.
3. Use `./scripts/sim_run.sh` for simulator testing with mocked replies.
4. Use `./scripts/device_startup_probe.sh` when you need a clean first-launch timing probe on device.

## Release

App Store Connect deployment via `asc-cli`.

## License

MIT. See [LICENSE](LICENSE).
