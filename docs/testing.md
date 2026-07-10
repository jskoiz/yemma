# Testing Notes

The highest-value pure-Swift coverage lives under `Tests/Yemma4Tests/`:

- `ConversationStoreTests.swift` exercises async restore, on-disk index recovery, and stale-selection repair.
- `StreamingRendererTests.swift` covers the sanitizer and stop-stream detection helpers.

Run the app-backed XCTest target with:

```bash
./scripts/local_validation.sh
```

The validation script runs the shared `Yemma4` scheme's iOS unit tests and therefore compiles the
shipping app target too. Use `./scripts/sim_run.sh` when you also want to install and launch the
simulator shell. Both scripts reuse scoped paths under `/tmp/codex-xcode-derived-data` by default so
repeated local checks do not grow build artifacts inside the repository. Override
`DERIVED_DATA_PATH` when a separate lane is needed.
