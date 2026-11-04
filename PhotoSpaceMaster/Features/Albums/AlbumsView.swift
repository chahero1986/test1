import SwiftUI
import UIKit

/// 相册 Tab：按系统相簿 / 智能相簿分组（带预览缩略图），点入复用网格组件。
struct AlbumsView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore

    @State private var smartAlbums: [AlbumSummary] = []
    @State private var userAlbums: [AlbumSummary] = []
    @State private var previews: [String: [AssetInfo]] = [:]

    private let service = PhotoLibraryService.shared

    var body: some View {
        List {
            Section("智能相簿") {
                ForEach(smartAlbums) { album in
                    NavigationLink {
                        AlbumAssetsView(albumId: album.id, title: album.title)
                    } label: {
                        row(album)
                    }
                }
            }
            Section("我的相簿") {
                ForEach(userAlbums) { album in
                    NavigationLink {
                        AlbumAssetsView(albumId: album.id, title: album.title)
                    } label: {
                        row(album)
                    }
                }
                if userAlbums.isEmpty {
                    Text("暂无自建相簿")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }
        }
        .navigationTitle("相册")
        .toolbar { entryToolbarButtons }
        .onAppear(perform: reload)
        .onChange(of: library.authorizationStatus) { _ in reload() }
    }

    private func reload() {
        guard service.hasAccess else { return }
        smartAlbums = service.smartAlbums()
        userAlbums = service.userAlbums()
        // 预览缩略图（每个相册取最新 3 张）
        for album in smartAlbums + userAlbums where previews[album.id] == nil {
            previews[album.id] = service.previewInfos(inCollectionId: album.id, limit: 3)
        }
    }

    private func row(_ album: AlbumSummary) -> some View {
        HStack(spacing: 10) {
            previewThumbs(album)
            Text(album.title)
            Spacer()
            Text("\(album.count)")
                .foregroundColor(.secondary)
                .font(.subheadline)
        }
    }

    @ViewBuilder
    private func previewThumbs(_ album: AlbumSummary) -> some View {
        let infos = previews[album.id] ?? []
        if infos.isEmpty {
            Image(systemName: album.icon)
                .foregroundColor(.accentColor)
                .frame(width: 56, height: 56)
                .background(Color(.secondarySystemFill))
                .clipShape(RoundedRectangle(cornerRadius: 8))
        } else {
            HStack(spacing: 2) {
                ForEach(Array(infos.prefix(3))) { info in
                    AlbumThumb(info: info)
                }
            }
        }
    }
}

/// 相册列表预览缩略图
struct AlbumThumb: View {
    let info: AssetInfo
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color(.systemGray5)
            }
        }
        .frame(width: 56, height: 56)
        .clipped()
        .task(id: info.id) {
            image = await ThumbnailManager.shared.thumbnail(for: info, side: 56)
        }
    }
}

/// 相簿详情：复用共用网格组件（多选、移入垃圾箱、加免删除、反选）
struct AlbumAssetsView: View {
    let albumId: String
    let title: String

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var ratings: RatingService

    @State private var assets: [AssetInfo] = []
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewingAsset: AssetInfo?

    var body: some View {
        PhotoGridView(
            assets: assets,
            selection: $selection,
            isSelecting: $isSelecting,
            makeMenu: { CommonAssetMenu.make(for: $0, appState: appState, ratings: ratings) },
            onOpenAsset: { viewingAsset = $0 },
            bottomBar: { cleanupBottomBar }
        )
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .fullScreenCover(item: $viewingAsset) { asset in
            NavigationStack {
                PhotoDetailView(assets: assets, startId: asset.id)
            }
        }
    }

    private func reload() {
        let asc = appState.settings.sortOrder == .ascending
        assets = PhotoLibraryService.shared
            .infos(inCollectionId: albumId, sortAscending: asc)
            .filter { !appState.trashIds.contains($0.id) }
    }

    private var cleanupBottomBar: some View {
        HStack(spacing: 16) {
            if isSelecting {
                Button {
                    selection = Set(assets.map(\.id)).symmetricDifference(selection)
                } label: {
                    Label("反选", systemImage: "circle.lefthalf.filled")
                }
                Button {
                    let targets = assets.filter { selection.contains($0.id) }
                    CleanupService.moveToTrash(targets, state: appState)
                    reload()
                    selection.removeAll()
                } label: {
                    Label(selection.isEmpty ? "全部移入垃圾箱" : "移入垃圾箱 \(selection.count)", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                Button {
                    CleanupService.toggleProtected(Array(selection), state: appState)
                    selection.removeAll()
                } label: {
                    Label("加免删除", systemImage: "hand.raised")
                }
                .disabled(selection.isEmpty)
            } else {
                Text("\(assets.count) 项 · 长按开始多选")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
