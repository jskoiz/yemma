# Testing Notes

The highest-value pure-Swift coverage added for this task lives under `Tests/Yemma4Tests/`:

- `ConversationStoreTests.swift` exercises the async restore path against an ISO-8601 persisted conversation.
- `StreamingRendererTests.swift` covers the sanitizer and stop-stream detection helpers.

## Running from Xcode (Cmd+U)

Opening `Yemma4.xcodeproj` and pressing **Cmd+U** now runs these tests. The shared
`Yemma4` scheme uses the `Yemma4.xctestplan` test plan, which references the
`Yemma4Tests` target from the local Swift package. The project pulls the package in
via an `XCLocalSwiftPackageReference` (relative path `.`) so the test target is
reachable from the standard scheme.

## Running from the command line

Via the project scheme and test plan:

```bash
xcodebuild test \
  -project Yemma4.xcodeproj \
  -scheme Yemma4 \
  -testPlan Yemma4 \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

The package-backed workspace path still works as well:

```bash
xcodebuild test \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme Yemma4 \
  -destination 'platform=iOS Simulator,name=Yemma Preview 17 Pro Max'
```

The app target can still be validated separately with the project build path when you want a simulator compile of the shipped shell.
