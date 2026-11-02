import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        if library.authorizationStatus == .denied || library.authorizationStatus == .restricted {
            PermissionGuideView()
        } else {
            TabView {
                NavigationStack { HomeTimelineView() }
                    .tabItem { Label("首页", systemImage: "photo.on.rectangle") }

                NavigationStack { AlbumsView() }
                    .tabItem { Label("相册", systemImage: "square.grid.2x2") }

                NavigationStack { StatsView() }
                    .tabItem { Label("清理和统计", systemImage: "chart.bar.xaxis") }
            }
        }
    }
}
