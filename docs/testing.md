# Testing Notes

The highest-value pure-Swift coverage lives under `Tests/Yemma4Tests/`:

- `ConversationStoreTests.swift` exercises async restore, on-disk index recovery, stale-selection repair, and persisted-file protection.
- `Gemma4AssetContractTests.swift` validates the shipped model bundle contract.
- `ModelDownloadIntegrityTests.swift` and `ModelDownloadStorageCheckTests.swift` cover download integrity and disk-space checks.
- `PureFunctionTests.swift` covers model-source, token, ETA, prompt-planning, and related pure helpers.
- `StreamingRendererTests.swift` covers the sanitizer and stop-stream detection helpers.

## Running from Xcode

Opening `Yemma4.xcodeproj` and pressing **Cmd+U** runs the shared `Yemma4` scheme's
test target. The project includes the local package and app-backed test target so tests compile
against the same code that ships in the app.

## Running from the command line

Use the repository validation harness:

```bash
./scripts/local_validation.sh
```

The script runs the shared `Yemma4` scheme's iOS unit tests and therefore compiles the shipping
app target too. It reuses `/tmp/codex-xcode-derived-data/yemma-validation` by default; set
`DERIVED_DATA_PATH` when a separate lane is needed.

Use `./scripts/sim_run.sh` only when you also want to install and launch the simulator shell.
Simulator replies are mocked; real MLX inference requires a physical iPhone.
