# Regression Checklist

Use this short pass before shipping UI or model-loading changes.

- Run `./scripts/local_validation.sh` and confirm both simulator tests and the unsigned generic-iOS Release build pass.
- Confirm the harness reports that `FoundationModels.framework` is weak-linked for iOS 17 compatibility.
- On an eligible iOS 26+ Apple Intelligence device, confirm Apple is initially selected, text chat is ready without a Yemma model download, and no Gemma download starts.
- Check Apple Intelligence off, model-not-ready, unsupported-language, and device-ineligible states. Confirm each message is actionable and none starts a download.
- On iOS 17-25 or an ineligible device with no saved preference, confirm Gemma is selected but its 4.2 GB download starts only after the user explicitly begins setup.
- Persist Apple as the selected runtime, then make it unavailable and confirm Yemma keeps that choice, explains the blocker, and does not silently switch or download Gemma.
- Select Gemma, walk setup, downloading, paused, preparing, ready, and failed states, then verify both text and image chat on a physical iPhone.
- In Simulator, confirm mock replies still work and neither real runtime nor model download is attempted.
- Start a new chat, send a prompt, let a response stream, then verify auto-scroll, copy/share, retry, and refine still work.
- Switch between Apple and Gemma with no generation active, then confirm conversations persist and runtime-specific controls update.
- Leave a draft in one conversation, switch to another saved chat, rename it, then return and confirm both history and drafts persist correctly.
- After changing chat value types or persistence, open a conversation saved by the previous app build and confirm its users, status, text, and attachments restore.
- Open Settings and Advanced Settings in light and dark mode. Confirm presets, appearance, trust links, diagnostics, and debug tools still work.
- Check Dynamic Type, VoiceOver labels, Reduce Motion, and high-contrast readability on chat bubbles, message actions, onboarding, and utility sheets.
