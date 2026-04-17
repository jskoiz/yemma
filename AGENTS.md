# AGENTS

This repo ships Yemma 4, a fully private on-device AI chat app for iPhone. The app now runs Gemma 4 through a Swift-native MLX multimodal runtime. Prompts, images, and responses stay on device.

## Read First

Start from the current implementation in this repo when changing model or runtime behavior:

- `Yemma4/Services/LLMService.swift`
- `Yemma4/Services/MLXModelSupport.swift`
- `Yemma4/Services/ModelDownloader.swift`
- `Yemma4/ContentView.swift`
- `Yemma4/Views/OnboardingView.swift`

When working on something new in this repo, always use [@build-ios-apps](plugin://build-ios-apps@openai-curated) first for the iOS-oriented workflow, build, simulator, and debugging tools.

## Current State

- The shipping runtime is MLX, not `llama.cpp`.
- The app uses one local MLX Gemma 4 bundle instead of separate text GGUF and `mmproj` assets.
- The old Objective-C++ multimodal bridge and legacy LiteRT/GGUF runtime paths are no longer part of the product build.
- Simulator runs are UI-only with mocked replies. Real inference requires a physical iPhone.

## Known-Good Upstream Baseline

Use these repos/commits as the validated baseline:

- `mlx-swift-lm` at `3.31.3`
- `mlx-swift-examples` at `31b6cf6`

Do not start by reworking those repos locally inside `yemma-4`.

## Tech Stack

- Language: Swift 6.1
- UI: SwiftUI with `@Observable`
- Platform: iOS 17+
- Runtime: `MLX`, `MLXLMCommon`, `MLXVLM`
- Downloads and tokenization: `swift-transformers` (`Hub`, `Tokenizers`)
- Chat UI: ExyteChat
- Markdown: MarkdownUI

## First Files To Inspect

- `Yemma4/Services/LLMService.swift`
- `Yemma4/Services/MLXModelSupport.swift`
- `Yemma4/Services/ModelDownloader.swift`
- `Yemma4/ContentView.swift`
- `Yemma4/Views/OnboardingView.swift`

## Architecture

### State Management

Services are `@Observable` and injected through SwiftUI environment:

- `LLMService` for model lifecycle, multimodal generation, and sampling config
- `ModelDownloader` for bundle download, resume, cleanup, and validation
- `AppDiagnostics` for event logging
- `ConversationStore` for persisted chat history

### Multimodal MLX Path

- MLX Swift already provides the general model-loading, tokenizer, and VLM infrastructure; the missing work here was Gemma 4 Swift support plus Yemma-specific integration
- `ModelDownloader` fetches `mlx-community/gemma-4-e2b-it-4bit` and also recognizes legacy local bundles from `EZCon/gemma-4-E2B-it-4bit-mlx`
- `ModelDirectoryValidator` verifies tokenizer/config/processor files and safetensors shards before load
- `Gemma4MLXSupport` checks the Gemma 4 multimodal asset contract and normalizes known compatibility gaps
- `LLMService.makeGemma4UserInput(...)` converts turns into structured chat messages and `UserInput` values with optional images
- `context.processor.prepare(input:)` performs text and image preprocessing inside the MLX stack
- `VLMModelFactory.shared._load(...)` currently loads the combined text+vision model into one runtime container
- Yemma adds app-side prompt shaping, smoke checks, and output filtering on top of the MLX runtime

### Concurrency Patterns

- `LLMService` is `@unchecked Sendable` with narrow `NSLock` protection around shared runtime state
- `ModelDownloader` is `@MainActor`
- Generation streams through `AsyncStream<String>`
- Model loading runs on detached background tasks

## Build And Run

### Device

Open `Yemma4.xcodeproj` in Xcode, target a physical iPhone, and run. The app downloads the MLX bundle on first launch.

### Simulator

Use:

```bash
./scripts/sim_run.sh
```

Simulator mode uses mocked replies and does not attempt real MLX inference.

### Diagnostics

Use:

```bash
./scripts/device_startup_probe.sh
```

when you need a clean first-launch timing probe on a physical device.

## Conventions And Rules

### Do

- Keep the Yemma UI and session flow stable while changing runtime internals
- Prefer extending the MLX-backed service behind existing app interfaces
- Keep model validation strict so the app never marks a broken bundle as ready
- Reuse runtime/model logic from `mlx-swift-lm` and request-shaping patterns from `MLXChatExample`

### Do Not

- Do not reintroduce the old GGUF + `mmproj` runtime path
- Do not add Objective-C++ multimodal bridges for functionality the MLX stack already handles
- Do not fork the Python project into this repo
- Do not re-debug already-solved multimodal parity issues unless Yemma integration introduces a new regression
- Do not add cloud/API-based inference, user accounts, or telemetry
- Do not modify entitlements without understanding model-loading memory requirements

## Model Details

- Default repository: `mlx-community/gemma-4-e2b-it-4bit`
- Legacy-compatible local bundle ID: `EZCon/gemma-4-E2B-it-4bit-mlx`
- Stored locally as one MLX model directory with safetensors weights and config files
- Images and text are processed through the same Swift runtime container
- Default sampling: `top-k=64`, `top-p=0.95`, `temperature=0.7`
- Multimodal turns clamp max output tokens to keep image responses stable on device

## File Guide

- `Yemma4/Services/LLMService.swift`: model loading, prompt shaping, multimodal preprocessing, token generation loop, sampler config
- `Yemma4/Services/MLXModelSupport.swift`: model directory validation and Gemma 4 asset contract checks
- `Yemma4/Services/ModelDownloader.swift`: bundle download, resume persistence, progress tracking, validation, cleanup
- `Yemma4/Views/ChatView.swift`: chat UI, streaming display, image attachments
- `Yemma4/Views/OnboardingView.swift`: first-launch setup UI and progress states
- `Yemma4/ContentView.swift`: root onboarding/loading/chat transitions
