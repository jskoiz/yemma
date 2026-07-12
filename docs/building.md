# Building Yemma 4

## Build Graph

`Yemma4.xcodeproj` is the sole build graph. It declares the app, app-backed unit tests, and remote SwiftPM dependencies. The resolved dependency graph is pinned at `Yemma4.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

Use Xcode 26 or newer with an iOS 26 SDK so the compiler can import Apple's `FoundationModels` framework. The deployment target remains iOS 17, and the app and test targets currently compile in Swift 5 language mode.

`FoundationModels` is an Apple system framework, not a Swift package or embedded binary. The Release validation gate confirms it is weak-linked so the app can still launch on iOS 17-25. The MLX packages remain in the project for the explicit optional Gemma 4 runtime.

## Resolve Packages

Resolve the pinned project dependencies, including `mlx-swift-lm` at `3.31.3`, with:

```bash
xcodebuild -resolvePackageDependencies -project Yemma4.xcodeproj
```

## Validate

```bash
./scripts/local_validation.sh
```

The harness first confirms the selected iOS SDK contains `FoundationModels.framework`. It then runs simulator unit tests, compiles an unsigned Release build for a generic iOS device using the same DerivedData path, locates the resulting app executable, and verifies Foundation Models is weak-linked for iOS 17 compatibility.

Simulator replies are mocked. Real Apple Foundation Models and Gemma inference require a physical iPhone.
