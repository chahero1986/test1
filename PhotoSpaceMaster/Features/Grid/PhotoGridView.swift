import SwiftUI

/// 共用网格组件：所有列表页（首页 / 相册 / 清理列表 / 垃圾箱 / 免删除）复用。
/// - LazyVGrid 自适应列 + 分页加载（每页 120 项）
/// - 多选模式：长按进入，点击选中/取消
/// - 底部操作栏由各页面通过闭包注入，保证交互一致
/// - 支持按相邻同标题分组，并可注入富样式分组头（iOS 相册「日」视图风格）
struct PhotoGridView<BottomBar: View>: View {
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]
    private let pageSize = 120

    let assets: [AssetInfo]
    var onCellAppear: ((AssetInfo) -> Void)? = nil
    var makeMenu: ((AssetInfo) -> AnyView)? = nil
    /// 非多选状态下点击照片 → 打开大图查看器
    var onOpenAsset: ((AssetInfo) -> Void)? = nil
    /// 分组依据：返回 nil 表示该项无标题；相邻同标题的项归为同一组
    var makeSectionTitle: ((AssetInfo) -> String?)? = nil
    /// 富样式分组头：参数 = 标题、项目数、总字节数、组内第一个项目（用于取地点等）；为 nil 时用简单文字标题
    var makeSectionHeader: ((String, Int, Int64, AssetInfo?) -> AnyView)? = nil

    @Binding var selection: Set<String>
    @Binding var isSelecting: Bool

    private let bottomBar: () -> BottomBar

    @State private var visibleCount = 120

    init(
        assets: [AssetInfo],
        selection: Binding<Set<String>>,
        isSelecting: Binding<Bool>,
        onCellAppear: ((AssetInfo) -> Void)? = nil,
        makeMenu: ((AssetInfo) -> AnyView)? = nil,
        onOpenAsset: ((AssetInfo) -> Void)? = nil,
        makeSectionTitle: ((AssetInfo) -> String?)? = nil,
        makeSectionHeader: ((String, Int, Int64, AssetInfo?) -> AnyView)? = nil,
        @ViewBuilder bottomBar: @escaping () -> BottomBar
    ) {
        self.assets = assets
        self._selection = selection
        self._isSelecting = isSelecting
        self.onCellAppear = onCellAppear
        self.makeMenu = makeMenu
        self.onOpenAsset = onOpenAsset
        self.makeSectionTitle = makeSectionTitle
        self.makeSectionHeader = makeSectionHeader
        self.bottomBar = bottomBar
    }

    private var displayed: [AssetInfo] { Array(assets.prefix(visibleCount)) }

    /// 分组显示：相邻同标题的项归为一段（与 LazyVGrid 兼容的分段实现）
    struct AssetSection: Identifiable {
        let key: String
        let title: String
        let firstAsset: AssetInfo?
        var count: Int
        var totalBytes: Int64
        var assets: [AssetInfo]
        var id: String { key }
    }

    private var sections: [AssetSection] {
        guard let makeSectionTitle else {
            return [AssetSection(key: "all", title: "", count: displayed.count, totalBytes: 0, firstAsset: displayed.first, assets: displayed)]
        }
        var result: [AssetSection] = []
        for info in displayed {
            let title = makeSectionTitle(info) ?? ""
            if var last = result.last, last.title == title {
                last.assets.append(info)
                result[result.count - 1] = last
            } else {
                result.append(AssetSection(key: "\(result.count)-\(title)", title: title, count: 1, totalBytes: info.byteSize, firstAsset: info, assets: [info]))
            }
        }
        // 汇总每段数量与大小
        return result.map { section in
            var s = section
            s.count = s.assets.count
            s.totalBytes = s.assets.reduce(0) { $0 + $1.byteSize }
            return s
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                if makeSectionTitle != nil {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections) { section in
                            if !section.title.isEmpty {
                                sectionHeader(section)
                            }
                            gridCells(section.assets)
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, spacing: 2) {
                        gridCells(displayed)
                    }
                    .padding(.horizontal, 2)
                    .padding(.bottom, 12)
                }

                if assets.isEmpty {
                    emptyState
                }
            }
            bottomBar()
        }
        .onChange(of: assets.first?.id) { _ in
            visibleCount = pageSize
        }
    }

    @ViewBuilder
    private func sectionHeader(_ section: AssetSection) -> some View {
        if let makeSectionHeader {
            makeSectionHeader(section.title, section.count, section.totalBytes, section.firstAsset)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text(section.title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.top, 14)
                .padding(.bottom, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func gridCells(_ items: [AssetInfo]) -> some View {
        ForEach(items) { info in
            GridCellView(
                info: info,
                isSelecting: isSelecting,
                isSelected: selection.contains(info.id),
                onTap: { handleTap(info) },
                onLongPress: {
                    if !isSelecting { isSelecting = true }
                    selection.insert(info.id)
                },
                menu: makeMenu?(info)
            )
            .onAppear {
                onCellAppear?(info)
                if info.id == displayed.last?.id, visibleCount < assets.count {
                    visibleCount += pageSize
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("没有符合条件的项目")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.top, 80)
        .frame(maxWidth: .infinity)
    }

    private func handleTap(_ info: AssetInfo) {
        guard !isSelecting else {
            if selection.contains(info.id) {
                selection.remove(info.id)
            } else {
                selection.insert(info.id)
            }
            return
        }
        onOpenAsset?(info)
    }
}

// MARK: - 单元格

struct GridCellView: View {
    let info: AssetInfo
    let isSelecting: Bool
    let isSelected: Bool
    var onTap: () -> Void
    var onLongPress: () -> Void
    var menu: AnyView?

    @State private var image: UIImage?
    @EnvironmentObject private var appState: AppState

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(.systemGray5))

            if let image {
                // 缩略图为正方形裁切（ThumbnailManager aspectFill），直接铺满即可，无需运行时缩放
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            }

            HStack(spacing: 4) {
                if info.kind == .video {
                    Label(Self.durationText(info.durationSeconds), systemImage: "play.fill")
                        .font(.caption2.weight(.medium))
                }
                if info.isLivePhoto {
                    Image(systemName: "livephoto")
                        .font(.caption2)
                }
                Spacer(minLength: 0)
            }
            .foregroundColor(.white)
            .padding(4)

            if isSelecting {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundColor(isSelected ? .accentColor : .white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(6)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipped()
        .overlay {
            if isSelecting && isSelected {
                Rectangle().stroke(Color.accentColor, lineWidth: 2)
            }
        }
        .overlay {
            // 标记覆盖：已入垃圾箱 = 半透明红色；免删除 = 半透明绿色（红优先）
            // 多选模式下不显示，避免干扰选择
            if !isSelecting {
                if appState.isTrashed(info.id) {
                    Color.red.opacity(0.45).allowsHitTesting(false)
                } else if appState.isProtected(info.id) {
                    Color.green.opacity(0.45).allowsHitTesting(false)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
        .contextMenu {
            if let menu { menu }
        }
        .task(id: info.id) {
            image = await ThumbnailManager.shared.thumbnail(for: info, side: 140)
        }
    }

    private static func durationText(_ seconds: Double) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter.string(from: seconds) ?? ""
    }
}
