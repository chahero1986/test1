import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var appState: AppState

    var body: some View {
        if library.authorizationStatus == .denied || library.authorizationStatus == .restricted {
            PermissionGuideView()
        } else {
            TabView(selection: $appState.selectedTab) {
                NavigationStack { HomeTimelineView() }
                    .tabItem { Label("首页", systemImage: "photo.on.rectangle") }
                    .tag(AppTab.home)

                NavigationStack { AlbumsView() }
                    .tabItem { Label("相册", systemImage: "square.grid.2x2") }
                    .tag(AppTab.albums)

                NavigationStack { StatsView() }
                    .tabItem { Label("清理和统计", systemImage: "chart.bar.xaxis") }
                    .tag(AppTab.stats)
            }
        }
    }
}
