# Services Layer Guide

## LLMService.swift (~1000 lines)

The core of the app. Manages the full llama.cpp lifecycle.

### Class Design
- `@Observable final class LLMService: @unchecked Sendable`
- Thread safety via `NSLock` (`stateLock`) -- required because llama.cpp C pointers (`OpaquePointer`) cannot conform to `Sendable`
- Observable properties: `isModelLoaded`, `isModelLoading`, `isGenerating`, `temperature`, `lastError`, `modelLoadStage`
- Private C pointers: `model`, `context`, `vocab` (all `OpaquePointer?`)

### Key Methods

**`loadResources(modelPath:)`** - Loads GGUF model into memory:
1. Calls `llama_backend_init()` (once, via static lazy)
2. Loads model with `llama_model_load_from_file()` (99 GPU layers for Metal)
3. Creates context with `llama_init_from_model()` (8192 tokens default, 512 batch)
4. Extracts vocab with `llama_model_get_vocab()`
5. Reads sampler defaults from model metadata
6. Updates `modelLoadStage` through: idle -> preparingRuntime -> loadingModel -> activatingModel -> ready

**`generate(prompt:history:)`** - Returns `AsyncStream<String>`:
1. Clears context memory (`llama_memory_clear`)
2. Formats prompt using chat template
3. Tokenizes the full prompt
4. Validates token count against context limit (8192 default)
5. Decodes prompt tokens in batch (512 at a time)
6. Enters generation loop: sample -> check EOG -> accept -> convert -> yield
7. Max 1024 generated tokens per response (user-configurable)

**`formatPrompt(prompt:history:)`** - Applies chat template:
- Tries `llama_chat_apply_template` first (model's built-in template)
- Falls back to `tryApplyGemma4Template()` which manually constructs:
  ```
  <start_of_turn>user\n{text}<end_of_turn>\n<start_of_turn>model\n
  ```
- Returns the formatted string ready for tokenization

**`makeSampler()`** - Builds sampling chain:
- Order: top-k (64) -> top-p (0.95) -> min-p (0.0) -> temperature -> distribution
- Temperature is user-adjustable (0.1 to 2.0, default 0.7)
- Other params read from model metadata at load time

**`cancelGeneration()`** - Sets cancellation flag, waits for generation task to complete.

### SamplerConfig
```swift
struct SamplerConfig {
    var topK: Int32 = 64
    var topP: Float = 0.95
    var minP: Float = 0.0
    var temperature: Float = 0.7
}
```

### ModelLoadStage
Enum tracking load progress: `idle` -> `preparingRuntime` -> `loadingModel` -> `activatingModel` -> `ready` | `failed`

### Simulator Mode
When `supportsLocalModelRuntime == false`, generate returns a mocked streaming response. This allows UI development without downloading the model.

---

## ModelDownloader.swift (~580 lines)

Manages downloading the Gemma 4 GGUF from Hugging Face.

### Class Design
- `@MainActor @Observable public final class ModelDownloader`
- All UI-facing state is MainActor-isolated
- Observable: `downloadProgress`, `isDownloading`, `isDownloaded`, `canResumeDownload`, `error`, `modelPath`

### Download Details
- **URL:** `https://huggingface.co/bartowski/google_gemma-4-E4B-it-GGUF/resolve/main/google_gemma-4-E4B-it-Q4_K_M.gguf`
- **Local filename:** `gemma-4-e4b-it-q4km.gguf`
- **Storage:** `FileManager.default.urls(for: .documentDirectory)`
- **Resume data:** stored in Caches directory as `gemma-4-e4b-it-q4km.resume-data`

### Key Methods
- `validateDownloadedModel()` - Checks if model file exists on disk
- `startDownload()` / `resumeDownload()` - Initiates/resumes background URLSession download
- `cancelDownload()` - Cancels and captures resume data
- `deleteModel()` - Removes model file from disk

### Helper Types
- **`BackgroundModelDownloadSession`** - Wraps `URLSession` with background configuration. Handles delegate callbacks for progress and completion. Session ID: `{bundleID}.model-download`
- **`ModelDownloaderIO`** - Pure static functions for file validation and resume data I/O (keeps `@MainActor` class clean)
- **`BackgroundModelDownloadEvents`** - Singleton that bridges UIApplication background session completion handler

### Progress Throttling
UI updates throttled to max every 150ms or 0.5% progress delta to avoid excessive SwiftUI redraws.

---

## ConversationStore.swift (~170 lines)

Manages persistent chat history as JSON files in the Documents directory.

### Class Design
- `@Observable final class ConversationStore: @unchecked Sendable`
- Thread safety via `NSLock` (`ioLock`) for file I/O operations
- Observable: `conversations` (sorted metadata array), `isChatHistoryEnabled` (UserDefaults-backed)

### Storage Layout
```
~/Documents/chat-history/
  index.json                    # [ConversationMetadata] - lightweight list
  {uuid}/conversation.json      # Full Conversation with messages
```

### Key Methods
- `loadIndex()` -- reads index.json at init
- `loadConversation(id:)` -- reads full conversation JSON on demand
- `saveConversation(id:messages:)` -- creates or updates a conversation; returns UUID
- `deleteConversation(id:)` -- removes conversation directory + updates index
- `deleteAllConversations()` -- removes entire chat-history directory

### Design Decisions
- Index is separate from conversation data to avoid loading all messages just to display the list
- `ExyteChat.Message` is NOT Codable, so `PersistedMessage` acts as a Codable DTO
- File writes use `.atomic` for safety
- ISO 8601 date encoding for JSON compatibility

---

## AppDiagnostics.swift (~130 lines)

Simple thread-safe event logger.

### Class Design
- `@Observable public final class AppDiagnostics: @unchecked Sendable`
- Singleton: `AppDiagnostics.shared`
- Thread safety via `NSLock`

### Usage
```swift
AppDiagnostics.shared.record("Model loaded", category: "model", metadata: ["size": "2.1GB"])
```

### Categories
`startup`, `download`, `model`, `generation`, `ui`, `debug`

### Storage
- Events persisted to `UserDefaults` (key: `diagnosticEvents`)
- Max 120 events retained (oldest trimmed)
- Exportable as plain text via `exportText()`
