import SwiftUI

/// Owns sidebar geometry and drag state, keeping navigation gestures out of chat logic.
struct ChatNavigationShell<Content: View, Sidebar: View>: View {
    @Binding var isSidebarOpen: Bool
    @State private var sidebarDragOffset: CGFloat = 0
    @ViewBuilder let content: () -> Content
    @ViewBuilder let sidebar: () -> Sidebar

    var body: some View {
        GeometryReader { geometry in
            let sidebarWidth = geometry.size.width
            let sidebarProgress = sidebarRevealProgress(sidebarWidth: sidebarWidth)
            let shellOffset = sidebarProgress * (geometry.size.width + 12)

            ZStack(alignment: .leading) {
                UtilityBackground()

                if isSidebarPresented {
                    sidebar()
                    .frame(width: sidebarWidth)
                    .offset(x: sidebarOffset(sidebarWidth: sidebarWidth))
                }

                content()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .overlay {
                        if sidebarProgress > 0.001 {
                            Color.black
                                .opacity(0.06 * sidebarProgress)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                closeSidebar()
                            }
                        }
                    }
                    .offset(x: shellOffset)
                    .allowsHitTesting(!isSidebarPresented)
                    .simultaneousGesture(sidebarGesture(sidebarWidth: sidebarWidth))
            }
        }
        .onChange(of: isSidebarOpen) { _, _ in sidebarDragOffset = 0 }
    }

    private var isSidebarPresented: Bool {
        isSidebarOpen || sidebarDragOffset > 0
    }

    private func closeSidebar() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
            isSidebarOpen = false
            sidebarDragOffset = 0
        }
    }

    private func sidebarRevealProgress(sidebarWidth: CGFloat) -> CGFloat {
        guard sidebarWidth > 0 else { return 0 }

        let visibleWidth: CGFloat
        if isSidebarOpen {
            visibleWidth = sidebarWidth + min(0, sidebarDragOffset)
        } else {
            visibleWidth = max(0, sidebarDragOffset)
        }

        return min(max(visibleWidth / sidebarWidth, 0), 1)
    }

    private func sidebarOffset(sidebarWidth: CGFloat) -> CGFloat {
        if isSidebarOpen {
            return min(0, sidebarDragOffset)
        }

        return -sidebarWidth + max(0, sidebarDragOffset)
    }

    private func sidebarGesture(sidebarWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                if isSidebarOpen {
                    sidebarDragOffset = max(-sidebarWidth, min(0, value.translation.width))
                } else {
                    guard value.startLocation.x <= 28, value.translation.width > 0 else { return }
                    sidebarDragOffset = min(sidebarWidth, value.translation.width)
                }
            }
            .onEnded { value in
                defer { sidebarDragOffset = 0 }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                if isSidebarOpen {
                    let closingDistance = min(value.translation.width, value.predictedEndTranslation.width)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        isSidebarOpen = closingDistance >= -(sidebarWidth * 0.22)
                    }
                } else {
                    guard value.startLocation.x <= 28 else { return }
                    let openingDistance = max(value.translation.width, value.predictedEndTranslation.width)
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.88)) {
                        isSidebarOpen = openingDistance > sidebarWidth * 0.22
                    }
                }
            }
    }

}
