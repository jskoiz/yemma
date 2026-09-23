# Everyday Yemma features

Scope: straightforward additions to the existing private, on-device chat experience.

## Flows

- Guided Rewrite, Summarize, Ask, and Help me decide flows gather the user's actual input. Use draft returns an editable prompt; Send remains explicit.
- Chat library searches full messages across recent and older conversations, supports pinned chats and saved answers, and opens the matching message. Saved answers store references, not duplicate transcript text.
- Edit question creates a separate draft with earlier context. The original conversation remains intact. Image files are copied so either conversation can be deleted independently.
- Scan text performs local OCR on up to eight camera pages, with a 12,000-character limit. The result is reviewed before it enters the chat draft. Scans are not added to Yemma's attachment storage.
- Read aloud uses device speech synthesis, with an explicit stop action. Playback stops when leaving the app or changing conversations.
- Personal preferences provide up to 500 characters of explicit, editable guidance for subsequent responses. They are stored locally and can be cleared.
- Optional app lock uses device-owner authentication and must cover presented sheets as well as the chat screen. It does not replace the existing file-protection mechanism.
- About Yemma explains supported tasks, local processing, optional image-model setup, and limits without asking the model to describe the product.

## Deliberately deferred

- Sharing into Yemma: a separate extension target, signing/capabilities, and a reliable cross-process handoff require a dedicated implementation.
- Temporary chats: requires audited retention behavior covering transcript persistence, drafts, attachments, cancellation, process termination, and app snapshots.
- Voice dictation: requires permissions, audio-session handling, and language/device gating to guarantee no cloud recognition fallback.

## Verification

Final validation on September 23, 2026: `./scripts/local_validation.sh` passed with 128 tests passed, zero failures, and one expected simulator file-protection skip. The unsigned generic iPhone Release build and FoundationModels weak-link check passed. `git diff --check` and project plist validation passed. Xcode hygiene dry-run reported zero errors and no reclaimable space; no cleanup was applied.

Evidence: `/tmp/yemma-everyday-final-confirmed-validation.log` and `/tmp/codex-xcode-derived-data/yemma-validation/Logs/Test/Test-Yemma4-2026.09.23_11-41-38--1000.xcresult`. Inspected feature screenshots are under `/Users/jk/.codex/visualizations/2026/09/23/01a0d00a-ded4-7902-8891-84fb7fbf24c8/feature-journey-confirmed/`.

New tests cover reference persistence/pruning, search excerpts beyond metadata previews, guided prompt input, preference clearing/limits, independent revision attachments, and cleanup on revision failure.

The simulator UI journey verifies that guided input becomes an unsent draft, saves an answer, creates a second unsaved chat, relaunches, and confirms that the enabled saved-only filter includes the saved answer and excludes the unsaved chat. Screenshots of the guided input and saved-only result were inspected. UI text was entered through sequential single-character keyboard events, without paste or bulk fill.

The settings value-row layout now leaves its spacer flexible so short values can align to the trailing edge, retaining the stacked fallback for longer content. This adjustment has source/build coverage; a separate settings screenshot review remains outstanding.

Camera capture, Face ID/Touch ID/passcode, speech playback, and real Apple/Qwen inference need physical-device verification. Simulator chat replies remain mocked.
