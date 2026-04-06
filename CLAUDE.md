# Yemma 4 - Project Guide

## What This Is

Yemma 4 is a fully private, on-device LLM chat app for iPhone. It runs Google's Gemma 4 E2B model locally via `llama.cpp` with Metal GPU acceleration. No accounts, no cloud inference, no telemetry. All conversations stay on device and are not persisted to disk.

## Tech Stack

- **Language:** Swift 6.1 (swift-tools-version: 6.1)
- **UI:** SwiftUI with `@Observable` (iOS 17+ Observation framework)
- **Platform:** iOS 17.0+ (iPhone 15 Pro minimum for Metal acceleration)
- **LLM Runtime:** llama.cpp via `LlamaSwift` (mattt/llama.swift)
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
│   ├── Models/
│   │   ├── ChatMessage.swift  # typealias + ExyteChat.User extensions
│   │   └── Conversation.swift # Codable DTOs for chat persistence
│   ├── Services/
│   │   ├── LLMService.swift   # Core: model loading, generation, sampling
│   │   ├── ModelDownloader.swift  # Background model download + resume
│   │   ├── ConversationStore.swift # Chat history persistence (JSON)
│   │   └── AppDiagnostics.swift   # Event logging, persisted to UserDefaults
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
- `LLMService` - model lifecycle, token generation, sampling config
- `ModelDownloader` - background URLSession download with resume
- `AppDiagnostics` - thread-safe event logging
- `ConversationStore` - persistent chat history (JSON files in Documents)

### Concurrency Patterns
- `LLMService` is `@unchecked Sendable` with `NSLock` for thread safety on C pointers
- `ModelDownloader` is `@MainActor`
- Generation uses `AsyncStream<String>` for token-by-token streaming
- Model loading runs on `Task.detached(priority: .utility)`
- `DispatchGroup` used for generation completion tracking

### Data Flow
1. User submits prompt in ChatView
2. ChatView creates user message, then empty assistant message
3. LLMService.generate() returns AsyncStream
4. Tokens streamed and accumulated in the assistant message
5. Control markers (`<start_of_turn>`, `<eos>`, etc.) stripped from display
6. After assistant response completes, conversation auto-saved if history enabled

### Chat History Persistence
- Opt-in via "Save chat history" toggle in Settings (default: enabled)
- Conversations saved as JSON files in `~/Documents/chat-history/`
- `ConversationStore` manages CRUD; lightweight index in `index.json`, full data in `{uuid}/conversation.json`
- `ExyteChat.Message` is NOT Codable, so `PersistedMessage` is a Codable DTO with conversion methods
- Auto-save triggers: after assistant response, on app background, before conversation switch
- Users can browse/resume/delete past conversations via ConversationsView

### Chat Template
- Primary: `llama_chat_apply_template` (model's built-in template)
- Fallback: hardcoded Gemma 4 format (`<start_of_turn>role\ncontent<end_of_turn>`)

## Key Dependencies (Package.swift)

| Package | Product | Purpose |
|---------|---------|---------|
| exyte/Chat (2.7.8+) | ExyteChat | Chat UI components, Message/User types |
| mattt/llama.swift (2.8640.0+) | LlamaSwift | llama.cpp C bindings, Metal inference |
| gonzalezreal/swift-markdown-ui (2.4.1+) | MarkdownUI | Markdown rendering |
| exyte/MediaPicker (3.2.4) | MediaPicker | Photo selection |
| huggingface/swift-huggingface (0.9.0+) | HuggingFace | HF utilities |

## Build & Run

### Device (real inference)
Open `Yemma4.xcodeproj` in Xcode, select a physical iPhone 15 Pro+ target, build and run. The app will download the ~2GB Gemma 4 model on first launch.

### Simulator (mocked inference)
```bash
./scripts/sim_run.sh
```
Uses mocked responses -- no model download needed. Useful for UI iteration.

### Important Build Details
- The `increased-memory-limit` entitlement in `Yemma4.entitlements` is **required** for model loading
- Bundle ID: `com.avmillabs.yemma4`
- `Yemma4AppConfiguration.supportsLocalModelRuntime` is `false` on simulator, `true` on device
- No test targets exist

## Conventions & Rules

### Code Style
- Use `@Observable` (not Combine/ObservableObject) for reactive state
- Use `async/await` and structured concurrency, not completion handlers
- Thread safety for C pointers via `NSLock`, not actors (llama.cpp pointers aren't Sendable)
- Environment injection for services, not singletons (except AppDiagnostics.shared)

### What NOT to Do
- Do not add cloud/API-based inference -- the app is explicitly 100% on-device
- Do not add user accounts or authentication
- Do not run `npm run` or similar JS tooling -- this is a pure Swift/Xcode project
- Do not mock the llama.cpp C API in tests -- use the simulator flag instead
- Do not modify the entitlements file without understanding memory implications

### Model Details
- Model: `google_gemma-4-E2B-it-Q4_K_M.gguf` from bartowski/google_gemma-4-E2B-it-GGUF
- Local filename: `gemma-4-e2b-it-q4km.gguf`
- Stored in: app's Documents directory
- Context: 8192 tokens (default, user-configurable), batch size 512, 99 GPU layers (Metal)
- Default sampling: top-k=64, top-p=0.95, temperature=0.7

### Error Handling
- `LLMServiceError` enum covers all inference failure modes
- User-facing errors shown via alerts in ContentView/ChatView
- Diagnostics logged to `AppDiagnostics` for debugging
- Thermal state tracked during inference

## File Guide (by importance)

| File | Lines | What It Does |
|------|-------|-------------|
| `LLMService.swift` | ~1000 | **Most critical.** Model loading, prompt formatting, token generation loop, sampler config. All llama.cpp C API calls live here. |
| `ChatView.swift` | ~750 | Main chat UI. Message rendering, streaming display, image attachments, quick prompts, control marker filtering. |
| `ModelDownloader.swift` | ~580 | Background URLSession download. Resume data persistence, progress tracking, file validation. |
| `OnboardingView.swift` | ~400 | First-launch download UI. Progress bar, status display, error/retry. |
| `SettingsView.swift` | ~360 | Temperature slider, model management, diagnostics export, debug scenarios. |
| `ContentView.swift` | ~220 | Root view. Orchestrates onboarding -> loading -> chat transitions. |
| `ConversationStore.swift` | ~170 | Chat history persistence. JSON file I/O, index management, CRUD. |
| `AppDiagnostics.swift` | ~130 | Thread-safe event logger. Persists to UserDefaults (max 120 events). |
| `Conversation.swift` | ~80 | Codable DTOs: PersistedMessage, Conversation, ConversationMetadata. Conversion to/from ChatMessage. |
| `ChatMessage.swift` | ~27 | Thin wrapper. `typealias ChatMessage = ExyteChat.Message` + user constants. |
| `RichMessageText.swift` | ~43 | Markdown rendering with GitHub theme. |
