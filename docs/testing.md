# Testing Notes

The highest-value pure-Swift coverage lives under `Tests/Yemma4Tests/`:

- `ConversationStoreTests.swift` exercises current-format restore, on-disk index recovery, stale-selection repair, and persisted-file protection.
- `Qwen35AssetContractTests.swift` validates the shipped model bundle contract.
- `ModelDownloadIntegrityTests.swift` and `ModelDownloadStorageCheckTests.swift` cover download integrity and disk-space checks.
- `PureFunctionTests.swift` covers response-token math, prompt shaping, ETA, and automation configuration.
- `StreamingRendererTests.swift` covers the sanitizer and stop-stream detection helpers.

## Running from Xcode

Opening `Yemma4.xcodeproj` and pressing **Cmd+U** runs the shared `Yemma4` scheme's
app-backed test target, so tests compile against the same code that ships in the app.

## Running from the command line

Use the repository validation harness:

```bash
./scripts/local_validation.sh
```

The script runs the shared `Yemma4` scheme's iOS simulator unit and UI tests, then compiles an unsigned
Release build for a generic iOS device. Both steps reuse
`/tmp/codex-xcode-derived-data/yemma-validation` by default; set `DERIVED_DATA_PATH` when a
separate lane is needed. Before building, the harness requires an iOS 26 SDK that contains
`FoundationModels.framework`. After building, it verifies the Release binary weak-links the
framework so the iOS 17 deployment target remains valid.

Use `./scripts/sim_run.sh` only when you also want to install and launch the simulator shell.
Simulator replies are mocked. The unsigned device build catches device-only compile and link
regressions, but real Apple Foundation Models and Qwen3.5 4B inference require a physical iPhone.

## UI journeys

`Tests/Yemma4UITests/ChatJourneyTests.swift` covers draft restore, send, mock response,
chat restore after relaunch, and explicit setup choices at accessibility text size.
Each run has an isolated conversation directory and preferences suite. The debug-only
`YEMMA_UI_TEST_SESSION` environment value must be a UUID; release builds ignore it.
The tests seed draft data instead of typing or pasting into a live input.
The harness uses an available iPhone simulator; set `DEVICE_NAME` for an exact model.

## Runtime matrix

When runtime routing changes, verify all of these cases:

- Simulator always returns mock replies and never invokes Apple Foundation Models or Qwen3.5 4B.
- An eligible iOS 26+ device with Apple Intelligence available selects `SystemLanguageModel.default` without a Yemma model download.
- Apple Intelligence off, model-not-ready, and unsupported-language states explain the blocker and do not start a download.
- With no saved preference, iOS 17-25 and Apple Intelligence-ineligible devices select Qwen3.5 4B, but the 3.05 GB download starts only after explicit user action.
- A saved Apple selection remains selected even if Apple later becomes unavailable; Yemma shows the reason and waits for the user to choose Qwen3.5 4B.
- Image chat is available only after the user selects and installs the optional Qwen3.5 4B runtime.
- Switching runtimes preserves conversations and cancels any active generation safely.

The simulator and unsigned build do not prove real inference. Before release, exercise Apple text chat on an eligible iOS 26+ physical iPhone and Qwen3.5 4B text-and-image chat on a physical iPhone. An actual iOS 17 launch also remains separate back-deployment proof.
