# Testing Notes

The highest-value pure-Swift coverage lives under `Tests/Yemma4Tests/`:

- `ConversationStoreTests.swift` exercises current-format restore, on-disk index recovery, stale-selection repair, and persisted-file protection.
- `Gemma4AssetContractTests.swift` validates the shipped model bundle contract.
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

The script runs the shared `Yemma4` scheme's iOS simulator unit tests, then compiles an unsigned
Release build for a generic iOS device. Both steps reuse
`/tmp/codex-xcode-derived-data/yemma-validation` by default; set `DERIVED_DATA_PATH` when a
separate lane is needed.

Use `./scripts/sim_run.sh` only when you also want to install and launch the simulator shell.
Simulator replies are mocked. The unsigned device build catches device-only compile and link
regressions, but real MLX inference still requires a physical iPhone.
