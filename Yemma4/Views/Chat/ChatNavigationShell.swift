import SwiftUI

/// System navigation preserves the detail across resizing and display changes.
struct ChatNavigationShell<Content: View, Sidebar: View>: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Binding var preferredCompactColumn: NavigationSplitViewColumn
    @ViewBuilder let content: () -> Content
    @ViewBuilder let sidebar: () -> Sidebar

    var body: some View {
        NavigationSplitView(
            columnVisibility: $columnVisibility,
            preferredCompactColumn: $preferredCompactColumn
        ) {
            sidebar()
                .navigationSplitViewColumnWidth(min: 280, ideal: 320, max: 380)
        } detail: {
            content()
        }
        .navigationSplitViewStyle(.balanced)
    }
}
