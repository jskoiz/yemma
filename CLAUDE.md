# Yemma 4 - Project Guide

## What This Is

Yemma 4 is a fully private, on-device AI chat app for iPhone. It runs Gemma 4 locally through a Swift-native MLX multimodal runtime. No accounts, no cloud inference, no telemetry. Prompts, images, and responses stay on device.

## Tech Stack

- **Language:** Swift 6.1 (swift-tools-version: 6.1)
- **UI:** SwiftUI with `@Observable` (iOS 17+ Observation framework)
- **Platform:** iOS 17.0+
- **LLM Runtime:** `MLX`, `MLXLMCommon`, `MLXVLM`
- **Model Download + Tokenization:** `swift-transformers` (`Hub`, `Tokenizers`)
- **Chat UI:** ExyteChat (exyte/Chat)
- **Markdown:** MarkdownUI (gonzalezreal/swift-markdown-ui)
- **Build:** Xcode 16.2+, Swift Package Manager
- **License:** MIT

## Project Structure

```
yemma-4/
├── Package.swift              # SPM manifest (all dependencies here)
├── Yemma4/
│   ├── Yemma4App.swift        # @main entry point, environment setup
│   ├── ContentView.swift      # Root state machine (onboarding vs chat)
│   ├── Services/
│   │   ├── LLMService.swift        # MLX model loading, preprocessing, generation, sampling
│   │   ├── MLXModelSupport.swift   # Model directory validation + Gemma 4 asset contract checks
│   │   ├── ModelDownloader.swift   # Background model bundle download + resume
│   │   ├── ConversationStore.swift # Chat history persistence (JSON)
│   │   ├── AppDiagnostics.swift    # Event logging, persisted to UserDefaults
│   │   └── YemmaPromptPlanner.swift # Prompt shaping for the current UX
│   └── Views/
│       ├── ChatView.swift         # Main chat UI, message streaming
│       ├── OnboardingView.swift   # Model download flow
│       ├── SettingsView.swift     # Settings + debug scenarios
│       └── RichMessageText.swift  # Markdown rendering for responses
├── Yemma4.xcodeproj/
├── scripts/
│   └── sim_run.sh             # Build + run on simulator (mocked inference)
└── website/                   # Landing page (not part of app)
```

## Architecture

### State Management
All services use `@Observable` and are injected via SwiftUI `.environment()` at the app root:
- `LLMService` - model lifecycle, structured multimodal generation, sampling config
- `ModelDownloader` - background model-bundle download with resume
- `AppDiagnostics` - thread-safe event logging
- `ConversationStore` - persistent chat history (JSON files in Documents)

### Concurrency Patterns
- `LLMService` is `@unchecked Sendable` with `NSLock` around shared runtime state
- `ModelDownloader` is `@MainActor`
- Generation uses `AsyncStream<String>` for token-by-token streaming
- Model loading runs on detached background tasks and returns a `ModelContainer`
- Multimodal preprocessing happens through `context.processor.prepare(input:)`

### Data Flow
1. User submits prompt in ChatView
2. ChatView creates user message, then empty assistant message
3. LLMService.generate() returns AsyncStream
4. Tokens streamed and accumulated in the assistant message
5. Control markers and hidden-channel/tool tokens are stripped from display
6. After assistant response completes, conversation auto-saved if history enabled

### Chat History Persistence
- Opt-in via "Save chat history" toggle in Settings (default: enabled)
- Conversations saved as JSON files in `~/Documents/chat-history/`
- `ConversationStore` manages CRUD; lightweight index in `index.json`, full data in `{uuid}/conversation.json`
- `ExyteChat.Message` is NOT Codable, so `PersistedMessage` is a Codable DTO with conversion methods
- Auto-save triggers: after assistant response, on app background, before conversation switch
- Users can browse/resume/delete past conversations via ConversationsView

### Multimodal MLX Path
- `ModelDownloader` fetches a single model repo: `mlx-community/gemma-4-e2b-it-4bit`
- `ModelDirectoryValidator` verifies tokenizer/config/processor files and safetensors shards before load
- `Gemma4MLXSupport` checks that the model and processor configs agree on the multimodal contract
- `LLMService.makeGemma4UserInput(...)` converts turns into structured `Chat.Message` values with optional images
- `context.processor.prepare(input:)` performs MLX-side text and image preprocessing
- `VLMModelFactory.shared._load(...)` loads the entire Gemma 4 text+vision stack into one runtime container

## Key Dependencies (Package.swift)

| Package | Product | Purpose |
|---------|---------|---------|
| exyte/Chat (2.7.8+) | ExyteChat | Chat UI components, Message/User types |
| ml-explore/mlx-swift | MLX | Core MLX runtime |
| mlx-vlm-swift/mlx-swift-lm | MLXLMCommon, MLXVLM | Gemma 4 multimodal load/generation stack |
| huggingface/swift-transformers | Hub, Tokenizers | Hugging Face downloads and tokenizer support |
| gonzalezreal/swift-markdown-ui (2.4.1+) | MarkdownUI | Markdown rendering |

## Build & Run

### Device (real inference)
Open `Yemma4.xcodeproj` in Xcode, select a physical iPhone target, build and run. The app downloads the Gemma 4 MLX bundle on first launch.

### Simulator (mocked inference)
```bash
./scripts/sim_run.sh
```
Uses mocked responses. No MLX model download is attempted on the simulator.

### Important Build Details
- The `increased-memory-limit` entitlement in `Yemma4.entitlements` is **required** for model loading
- Bundle ID: `com.avmillabs.yemma4`
- `Yemma4AppConfiguration.supportsLocalModelRuntime` is `false` on simulator, `true` on device
- No test targets exist

## Conventions & Rules

### Code Style
- Use `@Observable` (not Combine/ObservableObject) for reactive state
- Use `async/await` and structured concurrency, not completion handlers
- Keep MLX runtime state behind narrow locking boundaries where sendability is awkward
- Environment injection for services, not singletons (except AppDiagnostics.shared)

### What NOT to Do
- Do not add cloud/API-based inference -- the app is explicitly 100% on-device
- Do not add user accounts or authentication
- Do not run `npm run` or similar JS tooling -- this is a pure Swift/Xcode project
- Do not reintroduce the old GGUF + `mmproj` runtime path
- Do not add Objective-C++ multimodal bridges for features the MLX stack already handles
- Do not modify the entitlements file without understanding memory implications

### Model Details
- Repository: `mlx-community/gemma-4-e2b-it-4bit`
- Stored locally as one MLX model directory with safetensors weights and config files
- Images and text are both processed through the same Swift runtime container
- Default sampling: top-k=64, top-p=0.95, temperature=0.7
- Multimodal turns clamp max output tokens to keep image replies stable on device

### Error Handling
- `LLMServiceError` enum covers all inference failure modes
- User-facing errors shown via alerts in ContentView/ChatView
- Diagnostics logged to `AppDiagnostics` for debugging
- Model bundle validation failures are surfaced before load

## File Guide (by importance)

| File | Lines | What It Does |
|------|-------|-------------|
| `LLMService.swift` | ~1300 | **Most critical.** Model loading, prompt shaping, multimodal preprocessing, token generation loop, sampler config. |
| `MLXModelSupport.swift` | ~450 | Model directory validation and Gemma 4 multimodal asset contract checks. |
| `ChatView.swift` | ~750 | Main chat UI. Message rendering, streaming display, image attachments, quick prompts, control marker filtering. |
| `ModelDownloader.swift` | ~580 | Background model-bundle download. Resume persistence, progress tracking, validation, cleanup. |
| `OnboardingView.swift` | ~800 | First-launch setup UI. Progress states, download flow, readiness instrumentation. |
| `SettingsView.swift` | ~360 | Temperature slider, model management, diagnostics export, debug scenarios. |
| `ContentView.swift` | ~220 | Root view. Orchestrates onboarding -> loading -> chat transitions. |
| `ConversationStore.swift` | ~170 | Chat history persistence. JSON file I/O, index management, CRUD. |
| `AppDiagnostics.swift` | ~130 | Thread-safe event logger. Persists to UserDefaults (max 120 events). |
| `ChatMessage.swift` | ~27 | Thin wrapper. `typealias ChatMessage = ExyteChat.Message` + user constants. |
| `RichMessageText.swift` | ~43 | Markdown rendering with GitHub theme. |
