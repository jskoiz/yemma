# iPhone Duo adaptation

Evaluated on September 23, 2026 using Xcode 27.1 beta (27A9269) and the installed iOS 27.1 Duo simulator. Build with the iOS 27.1 SDK to enable the full display and system vertical navigation controls. The deployment target remains iOS 17.

## Design decisions

- Use `NavigationSplitView` for chat and the existing conversation/settings sidebar. System navigation manages compact collapse, expanded columns, asymmetric safe areas, and fold-aware column layout.
- Use a labeled system toolbar button for New chat, allowing the system to move it vertically or into overflow. Remove the custom full-width sliding shell and its drag gesture.
- Keep messages, attachments, draft, and generation state in `ChatView`, above the adaptive columns. Selecting a chat returns to detail on compact displays without forcibly hiding the expanded sidebar.
- Keep the composer in the bottom safe-area inset, with at most three lines in compact height or six otherwise. Decorative backgrounds ignore container edges, not keyboard safe areas, and do not determine chat geometry.
- Limit transcript and composer content to a maximum readable width of 760 points, while allowing narrower layouts. Start an empty transcript at the top.
- Keep existing landscape support. No device-name, screen-size, orientation, or idiom branching is added. No separate second-display scene is needed for this single chat workflow.
- Standard split navigation handles fold regions. A custom `ReservedRegion` layout is unnecessary for this implementation; reconsider only if adding controls outside the system safe area.

## Evidence and remaining checks

The local validation harness passed on the Duo runtime, including simulator unit tests and an unsigned generic iOS Release build with weak-linked FoundationModels. A subsequent simulator build of the keyboard fix also passed.

Observed on the closed Duo display: chat, system vertical back/new-chat controls, and the composer above the visible software keyboard. The first visual pass found the keyboard obscuring the composer; moving decorative artwork out of layout sizing and respecting the keyboard safe area corrected it.

Device Hub subsequently stopped exposing a usable automation window. Sequential hardware key events were attempted but were not delivered to the simulator; no paste or bulk text entry was used. Therefore draft entry/continuity, inner-display and book poses, rotation, Split View on both sides, large Dynamic Type, and photo picker transitions remain unverified. Before a Duo release, complete these checks and run text/image inference and memory-pressure testing on physical Duo hardware. Simulator replies are mocked.

The earlier TestFlight build 1.0.2 (2026092301) predates these changes and was archived with Xcode 27.0. This adaptation has not been uploaded.

## Apple references

- [Get ready for iPhone Duo](https://developer.apple.com/iphone-duo/)
- [Designing for iPhone Duo](https://developer.apple.com/design/human-interface-guidelines/designing-for-iphone-duo)
- [Prepare your app for iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111461/)
- [Raise the bar with iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111462/)
- [Strike a pose with adaptive layouts on iPhone Duo](https://developer.apple.com/videos/play/tech-talks/111463/)
