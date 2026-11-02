import SwiftUI

/// 垃圾箱：展示已移入垃圾箱的待删除项目。
/// 点击即选中/取消；底部 恢复 / 删除 / 反选；删除调用 PhotoKit 真删（走系统最近删除）。
struct TrashView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore

    @State private var selection = Set<String>()
    @State private var isSelecting = true
    @State private var showDeleteConfirm = false
    @State private var errorMessage: String?

    private var items: [AssetInfo] {
        library.infos(for: appState.trashIds)
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    private var deleteTargetIds: [String] {
        Array(selection.isEmpty ? Set(items.map(\.id)) : selection)
    }

    var body: some View {
        PhotoGridView(
            assets: items,
            selection: $selection,
            isSelecting: $isSelecting,
            bottomBar: { trashBottomBar }
        )
        .navigationTitle("垃圾箱")
        .navigationBarTitleDisplayMode(.inline)
        .alert("确认删除", isPresented: $showDeleteConfirm) {
            Button("取消", role: .cancel) {}
            Button("删除", role: .destructive) {
                Task {
                    do {
                        try await CleanupService.realDelete(ids: deleteTargetIds, state: appState)
                        selection.removeAll()
                    } catch {
                        errorMessage = "删除失败：\(error.localizedDescription)"
                    }
                }
            }
        } message: {
            Text("共 \(deleteTargetIds.count) 项将从系统相册删除，先进入系统「最近删除」（保留 30 天），到期后不可恢复。")
        }
        .alert("错误", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("好的", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var trashBottomBar: some View {
        HStack(spacing: 12) {
            Button {
                let ids = selection.isEmpty ? Set(items.map(\.id)) : selection
                CleanupService.restore(ids: Array(ids), state: appState)
                selection.removeAll()
            } label: {
                Label(selection.isEmpty ? "全部恢复" : "恢复 \(selection.count)",
                      systemImage: "arrow.uturn.backward")
            }

            Button {
                showDeleteConfirm = true
            } label: {
                Label(selection.isEmpty ? "全部删除" : "删除 \(selection.count)",
                      systemImage: "trash.fill")
            }
            .foregroundStyle(.red)

            Button {
                selection = Set(items.map(\.id)).symmetricDifference(selection)
            } label: {
                Label("反选", systemImage: "circle.lefthalf.filled")
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
