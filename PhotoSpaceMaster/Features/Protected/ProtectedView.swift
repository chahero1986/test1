import SwiftUI

/// 免删除项目：被标记的项目在批量删除中默认被排除（受设置开关控制）。
struct ProtectedView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore

    @State private var selection = Set<String>()
    @State private var isSelecting = true
    @State private var showPermissionInfo = false

    private var items: [AssetInfo] {
        library.infos(for: appState.protectedIds)
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    var body: some View {
        PhotoGridView(
            assets: items,
            selection: $selection,
            isSelecting: $isSelecting,
            bottomBar: { protectedBottomBar }
        )
        .navigationTitle("免删除项目")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPermissionInfo) {
            ProtectedPermissionInfoView()
        }
    }

    private var protectedBottomBar: some View {
        HStack(spacing: 12) {
            Button {
                let ids = selection.isEmpty ? Set(items.map(\.id)) : selection
                CleanupService.toggleProtected(Array(ids), state: appState)
                selection.removeAll()
            } label: {
                Label(selection.isEmpty ? "全部取消免删除" : "取消免删除 \(selection.count)",
                      systemImage: "hand.raised.slash")
            }
            .disabled(items.isEmpty)

            Button {
                selection = Set(items.map(\.id)).symmetricDifference(selection)
            } label: {
                Label("反选", systemImage: "circle.lefthalf.filled")
            }
            .disabled(items.isEmpty)

            // 无选中时额外提供「权限」说明入口
            if selection.isEmpty {
                Button {
                    showPermissionInfo = true
                } label: {
                    Label("权限", systemImage: "key")
                }
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}

/// 「权限」说明页：免删除项目的数据来源与开关说明
private struct ProtectedPermissionInfoView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("数据来源") {
                    Text("免删除项目是您在 App 内手动标记的照片或视频，标记记录保存在本机数据库（仅本地存储，不会上传）。")
                }
                Section("生效规则") {
                    Text("开启「设置 → 跳过免删除项目」后，首页 / 相册 / 清理列表中的批量删除会自动排除这些项目。")
                    Text("当前开关状态：" + (appState.settings.skipProtectedItems ? "已开启（批量删除时自动排除）" : "已关闭（免删除项目同样会被移入垃圾箱）"))
                }
                Section("前往设置") {
                    NavigationLink("打开设置") {
                        SettingsView()
                    }
                }
            }
            .navigationTitle("权限说明")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
