# AGENTS

This repo is the product integration target for the Gemma 4 MLX migration.

## Read First

Start here before changing any model/runtime code:

- `/Users/jk/Desktop/NEW CHAT/HANDOFF_TO_YEMMA_AGENT.md`
- `docs/mlx-migration-strategy.md`

Treat those files as the current source of truth for the validated Gemma 4 MLX Swift port and the recommended migration order.

## Immediate Goal

Replace the current Yemma GGUF + `mmproj` inference plumbing with the validated single-bundle MLX Gemma 4 path.

This is now an integration task, not a fresh Gemma 4 parity-debugging task.

## Known-Good Upstream Baseline

Use these repos/commits as the validated baseline:

- `mlx-swift-lm` at `8b5eef7`
- `mlx-swift-examples` at `31b6cf6`

Do not start by reworking those repos locally inside `yemma-4`.

## Integration Rules

- Keep the Yemma UI/session flow stable while swapping the inference backend.
- Prefer introducing an MLX-backed service behind the existing app interface first.
- Keep the old GGUF path until the MLX path is validated on device.
- Do not remove the current runtime until image inference is stable in Yemma.

## What To Reuse

- Gemma 4 runtime/model logic from `mlx-swift-lm`
- request-shaping patterns from `MLXChatExample`
- smoke-style validation ideas, adapted to Yemma’s architecture

## What Not To Do

- do not fork the Python project into this repo
- do not re-debug already-solved multimodal parity issues unless Yemma integration introduces a new regression
- do not copy the entire example app structure into Yemma

## First Files To Inspect In This Repo

- `Yemma4/Services/LLMService.swift`
- `Yemma4/Services/ModelDownloader.swift`
- `Yemma4/ContentView.swift`

The migration should start by identifying the seam where the current GGUF runtime can be replaced with an MLX-backed service.
