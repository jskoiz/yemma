# MLX Migration Strategy

This document describes how to turn the Gemma 4 Swift port work into something reusable for both `Yemma 4` and the broader MLX Swift ecosystem.

## Current State

- `Yemma 4` currently runs Gemma 4 through `llama.cpp` with two GGUF files:
  - the main text model
  - the multimodal projector
- The MLX Swift work now has a functioning Gemma 4 multimodal path on iPhone using a single MLX model bundle.
- The reusable implementation work lives in upstream-oriented repos, not in `Yemma 4` itself:
  - `mlx-swift-lm`
  - `mlx-swift-examples`

## Recommended Publishing Path

The right order is:

1. Upstream the reusable runtime/model changes to `ml-explore/mlx-swift-lm`
2. Upstream the example-app and smoke-validation changes to `ml-explore/mlx-swift-examples`
3. Integrate the resulting MLX path into `Yemma 4`
4. Reference the upstream PRs or merged commits from `Yemma 4`

This keeps the core Gemma 4 Swift implementation in the repo family where people already look for MLX Swift model support.

## What Belongs Upstream

These changes are reusable and should live in the MLX Swift repos:

- Gemma 4 processor parity
- Gemma 4 multimodal runtime fixes
- Gemma 4 text-model parity fixes
- quantization/sanitize fixes for Gemma 4 checkpoints
- regression tests that protect Gemma 4 multimodal behavior
- the standalone example app smoke-validation flow

## What Belongs In `Yemma 4`

These changes are product-specific and should stay in `Yemma 4`:

- app UX and theme choices
- model download/storage policy
- diagnostics specific to the Yemma product
- migration from the current GGUF runtime to the MLX runtime
- app-store copy, screenshots, and release packaging

## What Not To Do

Do not fork the Python repo and gut it into Swift.

That would create the wrong project identity:

- wrong language
- wrong package structure
- misleading history
- confusing contribution story for outside users

Instead, cite the Python reference implementation in documentation and PR descriptions, and keep the Swift implementation in Swift-native repos.

## If Upstream PRs Stall

If the upstream repos do not accept the work quickly enough, create a new Swift-native repo rather than a fork of the Python project.

Recommended shape:

- `Sources/` for reusable Swift packages
- `Examples/` for a small iPhone sample app
- `Tests/` for parity and regression coverage
- `Docs/` for porting notes and source references
- `NOTICE.md` or `PortingNotes.md` describing the Python reference files that informed the Swift port

That repo should be positioned as:

- a Swift MLX Gemma 4 port
- derived from the Python reference behavior
- not a continuation of the Python codebase itself

## Practical Next Step For `Yemma 4`

When you start the product migration, treat the MLX work as an external dependency first.

Recommended sequence:

1. Pin `Yemma 4` to the known-good `mlx-swift-lm` and `mlx-swift-examples` commits that contain the Gemma 4 fixes
2. Replace the current GGUF inference layer with an MLX-backed service behind the existing `Yemma 4` app interface
3. Keep the `Yemma 4` UI and product behavior stable while swapping the inference backend
4. Remove the old two-file GGUF path only after the MLX path is validated on device

## Visibility

If the goal is to shine a light on the work, the best public trail is:

- upstream PR to `mlx-swift-lm`
- upstream PR to `mlx-swift-examples`
- a short write-up in `Yemma 4` linking to those PRs and explaining the migration

That gives the work both credibility and discoverability without splitting the implementation story across the wrong repos.
