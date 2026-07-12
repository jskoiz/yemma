# Regression Checklist

Use this short pass before shipping UI or model-loading changes.

- Run `./scripts/local_validation.sh` and confirm both simulator tests and the unsigned generic-iOS Release build pass.
- Launch on a device with downloaded assets and confirm the shell appears quickly, then text chat becomes ready before vision input is needed.
- Walk onboarding states: setup, downloading, preparing, ready, failed, and simulator. Confirm the primary action and status copy stay clear at a glance.
- Start a new chat, send a prompt, let a response stream, then verify auto-scroll, copy/share, retry, and refine still work.
- Leave a draft in one conversation, switch to another saved chat, rename it, then return and confirm both history and drafts persist correctly.
- After changing chat value types or persistence, open a conversation saved by the previous app build and confirm its users, status, text, and attachments restore.
- Open Settings and Advanced Settings in light and dark mode. Confirm presets, appearance, trust links, diagnostics, and debug tools still work.
- Check Dynamic Type, VoiceOver labels, Reduce Motion, and high-contrast readability on chat bubbles, message actions, onboarding, and utility sheets.
