# Yemma 4
Private AI chat for iPhone, powered by Gemma 4 E4B and running fully on device.

## What It Is
Yemma 4 is a fully private, on-device LLM chat app for iPhone. It downloads a Gemma 4 E4B GGUF model, loads it locally through `llama.cpp`, and keeps all inference on your device after the initial model download.

## Features
- 100% offline after the model is downloaded
- No account, no telemetry, no cloud inference
- Gemma 4 E4B GGUF support with Metal GPU acceleration
- Long-context chat designed for multi-turn conversations
- Local model download, storage, and deletion flow
- Minimal SwiftUI UI built for iPhone

## Tech Stack
- SwiftUI
- `llama.cpp` via `mattt/llama.swift`
- `exyte/Chat` for chat UI
- Gemma 4 E4B GGUF model
- Apache 2.0 licensed model weights

## Requirements
- iPhone 15 Pro or newer
- iOS 17 or later
- About 2 GB of free storage for the model
- Xcode 15 or newer

## Build And Run
1. Clone this repository.
2. Open the project in Xcode 15+.
3. Build and run on a physical device.

The app relies on Metal acceleration, so device testing is required. The simulator is useful for UI work, but it is not the target runtime for model inference.

For faster Simulator iteration, you can keep a local GGUF at `.local-models/gemma-4-e4b-it-q4km.gguf` and run `./scripts/sim_run.sh`. That build/install script seeds the simulator app with a symlink to the local model file so you do not need to redownload it between runs. Simulator chat uses a mocked response path for UI/debug loops; real Gemma inference should still be tested on a physical iPhone.

## Architecture
The flow is:
1. Launch the app.
2. Download the GGUF model locally.
3. Load the model into `llama.cpp`.
4. Stream chat responses token by token in the UI.

All message history stays on device. The app does not send prompts or responses to a server.

## License
MIT. See [LICENSE](LICENSE).

## Credits
- Google DeepMind for Gemma 4
- ggerganov for `llama.cpp`
- exyte for the chat UI components
- mattt for `llama.swift`
