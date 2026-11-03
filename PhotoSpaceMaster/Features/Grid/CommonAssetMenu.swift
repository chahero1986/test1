import SwiftUI

/// 公共单元格长按菜单（供相册 / 清理列表复用；首页菜单含评分入口故单独实现）
enum CommonAssetMenu {
    @MainActor
    static func make(for info: AssetInfo, appState: AppState, ratings: RatingService) -> AnyView {
        AnyView(
            Group {
                Button {
                    CleanupService.toggleProtected([info.id], state: appState)
                } label: {
                    Label(appState.isProtected(info.id) ? "取消免删除" : "加入免删除", systemImage: "hand.raised")
                }
                Button {
                    CleanupService.moveToTrash([info], state: appState)
                } label: {
                    Label("移入垃圾箱", systemImage: "trash")
                }
                if let stars = ratings.ratings[info.id] {
                    Text("当前评分：\(stars) 星")
                }
            }
        )
    }
}

// MARK: - 列表页右上角公共入口（垃圾箱 / 免打扰项目 / 设置），带数量角标

/// 图标颜色用 .primary：浅色模式下黑色、深色模式下白色，始终与导航栏底色对比清晰
struct TrashEntryButton: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        NavigationLink {
            TrashView()
        } label: {
            Image(systemName: "trash")
                .foregroundColor(.primary)
                .overlay(alignment: .topTrailing) {
                    if appState.trashIds.count > 0 {
                        Text("\(appState.trashIds.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Circle().fill(.red))
                            .offset(x: 8, y: -8)
                    }
                }
        }
        .accessibilityLabel("垃圾箱")
    }
}

struct ProtectedEntryButton: View {
    @EnvironmentObject private var appState: AppState
    var body: some View {
        NavigationLink {
            ProtectedView()
        } label: {
            Image(systemName: "hand.raised")
                .foregroundColor(.primary)
                .overlay(alignment: .topTrailing) {
                    if appState.protectedIds.count > 0 {
                        Text("\(appState.protectedIds.count)")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                            .padding(3)
                            .background(Circle().fill(.green))
                            .offset(x: 8, y: -8)
                    }
                }
        }
        .accessibilityLabel("免打扰项目")
    }
}

struct SettingsEntryButton: View {
    var body: some View {
        NavigationLink {
            SettingsView()
        } label: {
            Image(systemName: "gearshape")
                .foregroundColor(.primary)
        }
        .accessibilityLabel("设置")
    }
}

extension View {
    /// 相册 / 清理和统计等列表页右上角的三入口（与首页一致）
    @ToolbarContentBuilder
    var entryToolbarButtons: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            TrashEntryButton()
            ProtectedEntryButton()
            SettingsEntryButton()
        }
    }
}
