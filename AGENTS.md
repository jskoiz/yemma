# AGENTS

This repo ships Yemma 4, a fully private on-device AI chat app for iPhone. On eligible iOS 26+ Apple Intelligence devices, Apple's built-in foundation model is the zero-download default. Gemma 4 remains an explicit optional 4.2 GB text-and-image runtime and the local fallback for older or ineligible devices. Prompts, images, and responses stay on device.

## Read First

Start from the current implementation in this repo when changing model or runtime behavior:

- `Yemma4/Services/LLMService.swift`
- `Yemma4/Services/AppleFoundationModelRuntime.swift`
- `Yemma4/Services/MLXModelSupport.swift`
- `Yemma4/Services/ModelDownloader.swift`
- `Yemma4/ContentView.swift`
- `Yemma4/Views/OnboardingView.swift`

When working on something new in this repo, always use [@build-ios-apps](plugin://build-ios-apps@openai-curated) first for the iOS-oriented workflow, build, simulator, and debugging tools.

`Yemma4.xcodeproj` is the only build graph. SwiftPM dependencies are declared there and pinned by `Yemma4.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

## Current State

- `SystemLanguageModel.default` is the initial zero-download runtime when it is available on an eligible iOS 26+ Apple Intelligence device.
- Gemma 4 is an explicit optional download. It provides text and image inference and is the default choice on iOS 17-25 and devices that are not eligible for Apple Intelligence.
- Yemma never starts the 4.2 GB Gemma download automatically; the user must choose Gemma and start setup.
- The optional MLX path uses one Gemma 4 bundle instead of separate text GGUF and `mmproj` assets.
- The old Objective-C++ multimodal bridge and legacy LiteRT/GGUF runtime paths are no longer part of the product build.
- Chat messages, users, attachments, and the SwiftUI chat surface are owned by Yemma; there is no third-party chat framework.
- Simulator runs are UI-only with mocked replies. Real Apple Foundation Models and Gemma inference require a physical iPhone.

## Known-Good Upstream Baseline

Use these repos/commits as the validated baseline:

- `mlx-swift-lm` at `3.31.3`
- `mlx-swift-examples` at `31b6cf6`

Do not start by reworking those repos locally inside `yemma`.

## Tech Stack

- Toolchain: Xcode 26+ with an iOS 26 SDK; app and test targets currently use Swift 5 language mode
- UI: SwiftUI with `@Observable`
- Platform: iOS 17+
- Runtime: Apple `FoundationModels` on supported iOS 26+ devices; `MLX`, `MLXLMCommon`, and `MLXVLM` for optional Gemma 4
- Downloads and tokenization: `swift-transformers` (`Hub`, `Tokenizers`)
- Chat UI and value types: Yemma-owned SwiftUI and Swift models
- Markdown: MarkdownUI

## First Files To Inspect

- `Yemma4/Services/LLMService.swift`
- `Yemma4/Services/AppleFoundationModelRuntime.swift`
- `Yemma4/Services/MLXModelSupport.swift`
- `Yemma4/Services/ModelDownloader.swift`
- `Yemma4/ContentView.swift`
- `Yemma4/Views/OnboardingView.swift`

## Architecture

### State Management

Services are `@Observable` and injected through SwiftUI environment:

- `LLMService` for runtime selection, generation lifecycle, and sampling config
- `ModelDownloader` for bundle download, resume, cleanup, and validation
- `AppDiagnostics` for event logging
- `ConversationStore` for persisted chat history

### Runtime Selection

- The simulator always uses deterministic mock replies and never invokes either inference runtime.
- On first launch, `LLMService` selects Apple when `SystemLanguageModel.default` is available or can become available after Apple Intelligence setup.
- iOS 17-25 and Apple Intelligence-ineligible devices initially select Gemma 4.
- Apple Foundation Models handles text chat without a Yemma model download. Image prompts require the optional Gemma 4 runtime.
- Runtime selection is explicit and persisted. Unavailable Apple states explain how to enable Apple Intelligence or choose Gemma; they do not trigger a download.

### Optional Gemma 4 MLX Path

- MLX Swift already provides the general model-loading, tokenizer, and VLM infrastructure; the missing work here was Gemma 4 Swift support plus Yemma-specific integration
- `ModelDownloader` fetches `mlx-community/gemma-4-e2b-it-4bit` only after the user selects Gemma and starts setup
- `ModelDirectoryValidator` verifies tokenizer/config/processor files and safetensors shards before load
- `Gemma4MLXSupport` checks the Gemma 4 multimodal asset contract and normalizes known compatibility gaps
- `LLMService.makeGemma4UserInput(...)` converts turns into structured chat messages and `UserInput` values with optional images
- `context.processor.prepare(input:)` performs text and image preprocessing inside the MLX stack
- `VLMModelFactory.shared._load(...)` currently loads the combined text+vision model into one runtime container
- Yemma adds app-side prompt shaping, smoke checks, and output filtering on top of the MLX runtime

### Concurrency Patterns

- `LLMService` is `@unchecked Sendable` with narrow `NSLock` protection around shared runtime state
- Apple generation uses an iOS 26-gated `LanguageModelSession` and converts snapshot streaming into text deltas
- `ModelDownloader` is `@MainActor`
- Generation streams through `AsyncStream<String>`
- Model loading runs on detached background tasks

## Build And Run

### Local validation

Use:

```bash
./scripts/local_validation.sh
```

The harness runs the shared scheme's simulator tests, then compiles an unsigned Release build for a generic iOS device. Both steps reuse one DerivedData path.

### Device

Open `Yemma4.xcodeproj` in Xcode 26 or newer, target a physical iPhone, and run. Eligible iOS 26+ devices use Apple's built-in model without a Yemma download. Gemma setup starts only when the user explicitly selects it.

### Simulator

Use:

```bash
./scripts/sim_run.sh
```

Simulator mode uses mocked replies and does not attempt Apple Foundation Models or Gemma inference.

### Diagnostics

Use:

```bash
./scripts/device_startup_probe.sh
```

when you need a clean first-launch timing probe on a physical device.

## Conventions And Rules

### Do

- Keep the Yemma UI and session flow stable while changing runtime internals
- Keep runtime selection behind `LLMService` and preserve the simulator mock, Apple text, and Gemma multimodal boundaries
- Keep Gemma download and deletion user-initiated
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

- Apple default: `SystemLanguageModel.default`, built into eligible iOS 26+ Apple Intelligence devices, text-only in Yemma, zero Yemma download
- Optional Gemma repository: `mlx-community/gemma-4-e2b-it-4bit`
- Gemma storage: one 4.2 GB MLX model directory with safetensors weights and config files
- Gemma handles both text and images through one Swift runtime container
- Gemma default sampling: `top-k=64`, `top-p=0.95`, `temperature=0.7`
- Gemma multimodal turns clamp max output tokens to keep image responses stable on device

## File Guide

- `Yemma4/Services/LLMService.swift`: runtime selection, generation lifecycle, MLX loading, prompt shaping, and sampler config
- `Yemma4/Services/AppleFoundationModelRuntime.swift`: iOS 26 availability mapping, bounded transcript construction, and Apple snapshot streaming
- `Yemma4/Services/MLXModelSupport.swift`: model directory validation and Gemma 4 asset contract checks
- `Yemma4/Services/ModelDownloader.swift`: bundle download, resume persistence, progress tracking, validation, cleanup
- `Yemma4/Models/ChatMessage.swift`: app-owned chat message, user, and attachment value types
- `Yemma4/Views/ChatView.swift`: chat UI, streaming display, image attachments
- `Yemma4/Views/Chat/ChatTranscriptView.swift`: transcript rendering and message actions
- `Yemma4/Views/Chat/ChatComposerView.swift`: draft entry and image attachment controls
- `Yemma4/Views/OnboardingView.swift`: first-launch setup UI and progress states
- `Yemma4/ContentView.swift`: root onboarding/loading/chat transitions
