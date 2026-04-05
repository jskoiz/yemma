# Changelog

This is a high-level record of how Yemma has changed recently, focused on the app itself: new features, important bug fixes, and the product improvements that landed in a very short stretch of work.

## Snapshot

In the span of April 3-5, 2026, the app moved from a solid Gemma 4 chat client into a much more polished product:

- better startup and onboarding
- cleaner visual system and dark mode support
- faster and smoother chat streaming
- conversation persistence and drafts
- better settings and debug surfaces
- an Ask Image feature scaffold with downloader, UI, and runtime plumbing
- Xcode simulator and device build stabilization

## Timeline

### April 3, 2026: Foundation and Core Chat Improvements

This phase tightened the base app experience and made Gemma 4 support feel more complete.

- Added dark mode appearance support.
- Reworked onboarding brand assets and app icon assets.
- Improved model startup handling and onboarding behavior.
- Added a debug inference test menu.
- Added Gemma 4 multimodal image support.
- Fixed Gemma 4 chat prompt formatting and template behavior.
- Added startup timing and debug telemetry to help diagnose inference performance.
- Updated `llama.cpp` to `b8660`.
- Tuned `llama.cpp` defaults for better on-device performance.
- Redesigned the download progress UI.
- Fixed several attachment and multimodal integration regressions.

Representative commits:

- `9cce6e7` Add dark mode appearance support
- `354a728` Improve model startup handling and onboarding
- `0c81d4c` Add debug inference test menu
- `bfa2df6` Add Gemma 4 multimodal image support
- `aa15a26` Fix Gemma 4 chat template + add startup timing & debug telemetry
- `08354cc` Update llama.cpp to b8660 and redesign download progress UI
- `0f45dc9` Tune llama.cpp defaults for better on-device performance

### April 4, 2026: Chat UX, Persistence, and Product Shell

This was the biggest app-facing jump. The app started to feel more like a polished product than a feature testbed.

- Decomposed and cleaned up `ChatView`.
- Improved TTFT with KV cache reuse and throttled streaming renders.
- Polished chat UI: bubble sizing, scroll behavior, streaming, markdown, and typing feedback.
- Added local conversation persistence with `ConversationStore`.
- Added conversation drafts.
- Added quicker chat entry actions.
- Simplified onboarding and empty states.
- Simplified settings and improved accessibility.
- Moved diagnostics and debug controls into better-organized settings surfaces.
- Refined the startup shell and overall design system.
- Added a regression checklist to make polish passes safer.

Representative commits:

- `4eb33f5` Decompose ChatView into focused components and apply hygiene fixes
- `cc4da03` Optimize TTFT with KV cache reuse and throttle streaming renders
- `ed06d22` Polish chat UI: bubble sizing, streaming, scroll, markdown, typing indicator
- `3b15ceb` QOL: unload model on delete, harden validation, perf & cleanup
- `e8875c0` Improve startup shell and design system
- `ecef293` Polish chat streaming and markdown rendering
- `11cb2a2` Simplify onboarding and empty state
- `4706023` Add conversation drafts and quick chat actions
- `80629de` Simplify settings and improve accessibility

### April 4-5, 2026: Ask Image Built Out Fast

Ask Image went from a scaffold to a real product slice very quickly.

- Added the Ask Image feature scaffold.
- Added LiteRT-LM model descriptors, catalog, and download state.
- Added downloader and validation logic for LiteRT-LM models.
- Added temp-file handling and runtime abstractions.
- Added Ask Image home/session models and coordinator flow.
- Added Ask Image UI shell and full user flow.
- Wired the feature end-to-end.
- Added polish, previews, failure handling, and documentation.
- Added native bridge and runtime plumbing for LiteRT-LM / Gemma 4 image inference.

Representative commits:

- `96801d0` Add Ask Image feature scaffold
- `879765f` Add LiteRT-LM native bridge and runtime for Ask Image
- `c514f34` Add LiteRT-LM model catalog, downloader, and validation
- `8f1c794` Implement Phase 1C: Ask Image UI shell with full user flow
- `5d743f6` Wire Ask Image end-to-end integration
- `a934421` Phase 3: Ask Image performance polish and failure handling
- `bdf0c6a` Phase 4: Ask Image polish, previews, and developer docs
- `5eda373` Wire real LiteRT-LM C++ bridge for Gemma 4 on-device inference

### April 5, 2026: Build Repair and Xcode Stabilization

After the feature work landed, current Xcode surfaced several breakages across package resolution, Swift 6 checks, and the LiteRT device bridge. Those were repaired so the project would build again in both simulator and device configurations.

- Re-pinned Xcode SwiftPM resolution to the package versions the app currently expects.
- Fixed ExyteChat compatibility issues after upstream API changes.
- Fixed Swift 6 concurrency and locking issues in Ask Image and model loading.
- Removed obsolete preview modifiers that now warn in recent Xcode.
- Split simulator and device LiteRT linker settings.
- Repaired the device build after a simulator/device mismatch was discovered.
- Added missing LiteRT header shims required by the current compile path.
- Stabilized the LiteRT bridge by using a stubbed device path instead of compiling against a mismatched LiteRT C++ / protobuf stack.

Representative commits:

- `957f322` Fix Xcode build regressions and LiteRT integration
- `d77caa0` Merge ask-image-litert: fix Xcode build regressions and LiteRT integration

## Major Themes Across This Stretch

### The app became more usable

- onboarding got simpler
- empty states got clearer
- settings got easier to navigate
- the startup shell became more intentional

### The chat experience got much better

- smoother streaming
- better markdown rendering
- better bubble sizing and scroll behavior
- faster perceived first-token response

### The app became more durable

- local chat persistence
- conversation drafts
- stronger model validation and cleanup
- more diagnostics and regression coverage

### The product surface expanded

- multimodal Gemma 4 support
- debug/testing tools
- Ask Image groundwork and UI

## Documentation and Repo Cleanup

Not all of the work was in the app itself. Documentation also got cleaned up during this stretch.

- README copy was tightened and de-fluffed.
- Captions and section ordering were improved.
- The public repo presentation became easier to scan.

Representative commits:

- `2c69bfa` Polish public repo README and harden ignores
- `0df593c` Refine README section order and wording
- `3a184c3` Clean up README: remove fluff and tighten copy
- `16ed460` Further trim README: cut redundancy and tighten captions

## Current Known Limitation

Yemma currently builds in current Xcode for both simulator and iOS device targets, but the LiteRT Ask Image bridge is intentionally stubbed on device until the bundled LiteRT SDK, generated protobufs, and bridge API are version-aligned for real native inference.
