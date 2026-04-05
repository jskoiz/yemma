# LiteRT-LM Ask Image -- Developer Guide

## Overview

Ask Image is a multimodal feature that lets users attach a photo and ask
questions about it. Inference runs entirely on-device using Google's
LiteRT-LM runtime and Gemma 4 models, matching the app's privacy-first
philosophy.

The feature is gated behind `AskImageFeature.isEnabled`. Setting that
flag to `false` hides the entry point in `ChatView` without touching any
other file.

---

## Architecture

```
AskImageFeature          Feature flag + device-capability check
       |
AskImageCoordinator      SwiftUI view that routes between Home and Session
       |
AskImageCoordinatorViewModel    @Observable view model (model selection,
       |                        image attachment, prompt dispatch, session state)
       |
       +-- AskImageRuntime (protocol)
       |       |-- LiteRTLMRuntime      real bridge (device)
       |       |-- StubAskImageRuntime  fake streamer (simulator)
       |
       +-- AskImageModelStore (protocol)
       |       |-- LiteRTModelDownloader    background URLSession downloads
       |       |-- StubAskImageModelStore   in-memory stub for previews
       |
       +-- LiteRTLMBridge (Obj-C++)
               Thin wrapper around the LiteRT-LM C++ SDK.
               Currently a stub that simulates the real API shape.
```

### Key types

| Type | Role |
|------|------|
| `LiteRTModelDescriptor` | Immutable value describing a downloadable model (URL, file name, expected size). |
| `LiteRTModelState` | Enum tracking a single model's lifecycle: not downloaded, downloading, downloaded, preparing, ready, failed. |
| `AskImageSessionState` | High-level session state: idle, warming, ready, generating, error. |
| `AskImageMessage` | A single turn in the transcript (user or assistant). |
| `AskImageAttachment` | An image the user attached, with optional thumbnail data. |
| `AskImageTempFiles` | Static helpers for managed temp-image storage in Caches. |

---

## Model storage layout

```
Documents/
  litert-models/
    gemma4-e2b-askimage/
      gemma-4-e2b-it-gpu-int4.task   <- downloaded model
      .gemma4-e2b-askimage.etag      <- cached ETag from server
    gemma4-e4b-askimage/
      gemma-4-e4b-it-gpu-int4.task
      .gemma4-e4b-askimage.etag

Caches/
  litert-gemma4-e2b-askimage.resume-data   <- URLSession resume blob
  askimage-temp/
    <uuid>.jpg   <- user-selected images (cleaned on session reset / 24h prune)
```

Models are stored separately from the existing GGUF path used by
`LLMService`. Each model lives in its own subdirectory keyed by the
descriptor's `id`.

---

## Runtime flow

### 1. Model download

`LiteRTModelDownloader` creates a background `URLSession` download.
Progress is throttled (150 ms or 0.5 % delta) before surfacing to the UI.
Resume data is persisted in Caches so interrupted downloads can continue
after a relaunch.

### 2. Model preparation

When the user taps "Open" on a downloaded model card,
`AskImageCoordinatorViewModel.selectModel(_:)` calls
`runtime.prepareModel(at:)`. This creates the LiteRT-LM Engine and an
initial Conversation via the Obj-C++ bridge. The session moves to
`.warmingModel` -> `.readyForInput`.

### 3. Image attachment

The user selects a photo via `PhotosPicker`. The coordinator writes a
JPEG copy to `Caches/askimage-temp/` via `AskImageTempFiles.store(_:)`
and generates a 320 px thumbnail for the chat bubble.

### 4. Generation

`runtime.generate(prompt:imagePath:)` returns an `AsyncStream<String>`.
Chunks are appended to the in-progress assistant message. A monotonic
fence counter provides best-effort cancellation: when `cancelGeneration()`
is called, in-flight streams whose fence ID no longer matches stop
yielding.

### 5. Session reset / cleanup

`resetSession()` cancels any generation, clears messages and the
attachment, resets the bridge conversation, and removes all temp files.
On app launch, `AskImageTempFiles.pruneStaleFiles()` removes images
older than 24 hours.

---

## Known limitations

1. **Stub bridge.** `LiteRTLMBridge.mm` simulates the real LiteRT-LM
   C++ API. It returns canned responses and does not load a real model.
   Replace the stub bodies once the iOS SDK ships.

2. **Best-effort cancellation.** The LiteRT-LM C++ API does not expose
   a native cancel primitive. The bridge uses a fence flag; late chunks
   may still arrive after cancel is requested.

3. **No chat persistence.** Ask Image sessions are ephemeral. Messages
   are not saved to `ConversationStore` and are lost when the session
   ends or the user returns to the home screen.

4. **Single download at a time.** `LiteRTModelDownloader` rejects a
   second download if one is already in progress.

5. **No text-only mode.** The runtime protocol accepts an `imagePath`
   parameter on every call. Text-only Ask Image queries pass an empty
   string, which the stub bridge handles but the real SDK may not.

---

## Follow-up work

- **Live vision / camera feed.** Accept a live camera stream instead of
  a static photo for real-time scene understanding.
- **Full LiteRT-LM text chat.** Use the same runtime for a pure-text
  chat mode, replacing or complementing the existing llama.cpp path.
- **Real SDK integration.** Swap `LiteRTLMBridge.mm` stub bodies for
  actual LiteRT-LM C++ calls once Google ships the iOS headers.
- **Chat persistence.** Optionally save Ask Image transcripts to
  `ConversationStore` alongside the main chat history.
- **Multi-image support.** Allow attaching multiple images in a single
  session turn.
