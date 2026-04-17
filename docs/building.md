# Building Yemma 4

## Resolve Packages

Yemma now resolves `mlx-swift-lm` directly from upstream SwiftPM at `3.31.3`:

```bash
xcodebuild -resolvePackageDependencies -project Yemma4.xcodeproj
```
