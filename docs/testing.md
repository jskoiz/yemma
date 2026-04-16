# Testing Notes

The highest-value pure-Swift coverage added for this task lives under `Tests/Yemma4Tests/`:

- `ConversationStoreTests.swift` exercises the async restore path against an ISO-8601 persisted conversation.
- `StreamingRendererTests.swift` covers the sanitizer and stop-stream detection helpers.

Run the package-backed XCTest target with:

```bash
xcodebuild test \
  -workspace .swiftpm/xcode/package.xcworkspace \
  -scheme Yemma4 \
  -destination 'platform=iOS Simulator,name=Yemma Preview 17 Pro Max'
```

The app target can still be validated separately with the project build path when you want a simulator compile of the shipped shell.
