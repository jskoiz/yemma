# Building Yemma 4

## Bootstrap MLX Dependencies

Start every fresh clone with:

```bash
./scripts/bootstrap_mlx_swift_lm.sh
```

That script creates a repo-local checkout at `Dependencies/mlx-swift-lm`, but it needs a validated local seed checkout of `mlx-swift-lm` at `8b5eef7c9c1a698deb00f2699cb847988491163b` first. By default it looks for `../mlx-vlm-swift/mlx-swift-lm`, and you can override that with `MLX_SWIFT_LM_SOURCE_DIR`. It then applies `ci_scripts/patches/001-mlx-swift-lm-yemma-gemma4-port.patch`.

## Resolve Packages

After bootstrapping, SwiftPM and Xcode both use the same local package path:

```bash
xcodebuild -resolvePackageDependencies -project Yemma4.xcodeproj
```

If you move or delete `Dependencies/mlx-swift-lm`, rerun the bootstrap script before opening the project.
