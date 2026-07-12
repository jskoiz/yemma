# Building Yemma 4

## Build Graph

`Yemma4.xcodeproj` is the sole build graph. It declares the app, app-backed unit tests, and remote SwiftPM dependencies. The resolved dependency graph is pinned at `Yemma4.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Use a Swift 6.1-compatible toolchain. The app and test targets currently compile in Swift 5 language mode; the toolchain version does not imply Swift 6 language mode.

## Resolve Packages

Resolve the pinned project dependencies, including `mlx-swift-lm` at `3.31.3`, with:

```bash
xcodebuild -resolvePackageDependencies -project Yemma4.xcodeproj
```

## Validate

```bash
./scripts/local_validation.sh
```

This runs simulator unit tests and an unsigned Release compile for a generic iOS device using the same DerivedData path. Real model inference still requires a physical iPhone.
