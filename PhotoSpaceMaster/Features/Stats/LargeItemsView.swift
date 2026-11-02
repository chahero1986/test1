import SwiftUI

enum LargeItemsMode: String {
    case largeVideo
    case screenRecording
    case largePhoto

    var title: String {
        switch self {
        case .largeVideo: return "大视频"
        case .screenRecording: return "大录屏"
        case .largePhoto: return "大图片"
        }
    }

    var thresholdMBKeyPath: WritableKeyPath<SettingsStore, Int> {
        switch self {
        case .largeVideo, .screenRecording: return \.largeVideoThresholdMB
        case .largePhoto: return \.largePhotoThresholdMB
        }
    }

    var thresholdOptions: [Int] {
        switch self {
        case .largeVideo, .screenRecording: return [100, 200, 500, 1024]
        case .largePhoto: return [5, 10, 20, 50]
        }
    }
}

/// 大视频 / 大录屏 / 大图片：按文件大小降序，阈值可调，复用网格组件。
struct LargeItemsView: View {
    let mode: LargeItemsMode

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var ratings: RatingService

    @State private var selection = Set<String>()
    @State private var isSelecting = false

    private var items: [AssetInfo] {
        let minBytes = Int64(appState.settings[keyPath: mode.thresholdMBKeyPath]) * 1024 * 1024
        return library.assets
            .filter { !appState.trashIds.contains($0.id) }
            .filter { asset in
                guard asset.byteSize >= minBytes else { return false }
                switch mode {
                case .largeVideo: return asset.kind == .video
                case .screenRecording: return asset.isScreenRecording
                case .largePhoto: return asset.kind != .video
                }
            }
            .sorted { $0.byteSize > $1.byteSize }
    }

    var body: some View {
        PhotoGridView(
            assets: items,
            selection: $selection,
            isSelecting: $isSelecting,
            makeMenu: { CommonAssetMenu.make(for: $0, appState: appState, ratings: ratings) },
            bottomBar: { largeItemsBottomBar }
        )
        .navigationTitle(mode.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                thresholdMenu
            }
        }
    }

    private var thresholdMenu: some View {
        Menu {
            ForEach(mode.thresholdOptions, id: \.self) { mb in
                Button {
                    appState.settings[keyPath: mode.thresholdMBKeyPath] = mb
                } label: {
                    if appState.settings[keyPath: mode.thresholdMBKeyPath] == mb {
                        Label("大于 \(mb) MB", systemImage: "checkmark")
                    } else {
                        Text("大于 \(mb) MB")
                    }
                }
            }
        } label: {
            Label("≥\(appState.settings[keyPath: mode.thresholdMBKeyPath]) MB", systemImage: "slider.horizontal.3")
        }
    }

    private var largeItemsBottomBar: some View {
        HStack(spacing: 12) {
            if isSelecting {
                Button {
                    selection = Set(items.map(\.id)).symmetricDifference(selection)
                } label: {
                    Label("反选", systemImage: "circle.lefthalf.filled")
                }
                Button {
                    let targets = items.filter { selection.contains($0.id) }
                    CleanupService.moveToTrash(targets, state: appState)
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
                Text("\(items.count) 项 · 长按开始多选")
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
