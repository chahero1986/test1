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
