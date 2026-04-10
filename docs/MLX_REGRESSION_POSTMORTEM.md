# Yemma MLX Regression Postmortem

Date: 2026-04-09

## Summary

The current worktree regressed in two separate ways:

1. Startup and onboarding became visibly slower and less informative because the app shell still performs too much work on the critical path.
2. The public MLX model download now completes, but the downloaded directory still fails `LLMService` load with a generic missing-file error.

The model runtime itself is not the problem. The validated MLX path in the scaffold works; the regression is in Yemma integration around startup timing, cache hygiene, and download/load contract validation.

## What Broke

### 1. Startup freeze

The app was doing synchronous work before the first interactive shell could appear.

Key contributors:

- `ConversationStore` loaded its on-disk index in `init`, which blocks app startup on file I/O.
- `ContentView` kicks off model validation as soon as the view appears.
- The onboarding screen currently builds a heavier tree than the release-style setup shell, so any main-thread stall is more visible.

Observed effect:

- The onboarding screen appears late or feels frozen.
- The first-launch flow feels less informative and less responsive than the production submission.

### 2. Model load failure after successful download

The public repo `mlx-community/gemma-4-e2b-it-4bit` downloads successfully, but Yemma later fails to load it with:

- `The data couldn’t be read because it is missing.`

Most likely causes:

- A stale or partially valid cache directory is being reused under the new repo path.
- The current Yemma validation contract marks a directory as downloaded too early, before proving the exact files the MLX loader needs are present and readable.
- The loader is stricter than the download validator and fails fast when a required file is missing.

What the validated scaffold expects:

- `config.json`
- `tokenizer.json`
- `tokenizer_config.json`
- `processor_config.json` or `preprocessor_config.json`
- at least one `*.safetensors`

The Hugging Face repo tree for `mlx-community/gemma-4-e2b-it-4bit` is structurally correct, so the failure is probably local cache/state handling rather than a bad remote artifact.

## What Was Fixed in This Worktree

- Startup I/O was moved off the main path by deferring conversation index loading.
- Model validation was moved away from immediate blocking work on the UI actor.
- Fresh downloads now purge known model cache directories first, instead of trusting whatever was already present.
- The first-launch onboarding shell was simplified relative to the heavier intermediate variant.

These are the right directions, but the device logs show the model load path still needs one more contract pass.

## Why the Current Build Still Fails

The logs show this sequence:

1. Onboarding appears.
2. Download completes into `Documents/huggingface/models/mlx-community/gemma-4-e2b-it-4bit`.
3. The app switches to chat.
4. `LLMService` tries to prepare the bundle.
5. Loading fails with `The data couldn’t be read because it is missing.`

That means the app is accepting the download as “complete” before it has proven the model directory is actually loadable by the MLX runtime.

## Recommended Next Fix

1. Make the download validator match the real MLX loader contract exactly.
2. Confirm the downloader only declares success after all required config files are present and readable.
3. Keep cache purging for fresh downloads, but also make the validation error explicit when a required metadata file is absent.
4. Keep startup work off the main actor so onboarding stays interactive even while the model is being checked.

## Experimental Branch

Current branch snapshot:

- `codex-mlx-regression-postmortem`

