import SwiftUI

/// 共用网格组件：所有列表页（首页 / 相册 / 清理列表 / 垃圾箱 / 免删除）复用。
/// - LazyVGrid 自适应列 + 分页加载（每页 120 项）
/// - 多选模式：长按进入，点击选中/取消
/// - 底部操作栏由各页面通过闭包注入，保证交互一致
/// - 支持按相邻同标题分组，并可注入富样式分组头（iOS 相册「日」视图风格）
struct PhotoGridView<BottomBar: View>: View {
    /// 列配置：按 cellMinSize 自适应列数（首页双指捏合可调整 cellMinSize 实现缩略图缩放）
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: cellMinSize), spacing: 2)]
    }
    private let pageSize = 120

    let assets: [AssetInfo]
    /// 缩略图最小边长（决定列数）：双指捏合时可由外部调整
    var cellMinSize: CGFloat = 104
    var onCellAppear: ((AssetInfo) -> Void)? = nil
    var makeMenu: ((AssetInfo) -> AnyView)? = nil
    /// 非多选状态下点击照片 → 打开大图查看器
    var onOpenAsset: ((AssetInfo) -> Void)? = nil
    /// 分组依据：返回 nil 表示该项无标题；相邻同标题的项归为同一组
    var makeSectionTitle: ((AssetInfo) -> String?)? = nil
    /// 富样式分组头：参数 = 标题、项目数、总字节数、组内第一个项目（用于取地点等）；为 nil 时用简单文字标题
    var makeSectionHeader: ((String, Int, Int64, AssetInfo?) -> AnyView)? = nil
    /// 跳转定位：配合 jumpToken 变化触发，滚动到该书签项目并自动扩充分页
    var jumpToId: String? = nil
    var jumpToken: Int = 0

    @Binding var selection: Set<String>
    @Binding var isSelecting: Bool

    private let bottomBar: () -> BottomBar

    @State private var visibleCount = 120
    /// 定位滚动序列代号：新的定位请求会让旧的延时滚动全部失效
    @State private var jumpSeq = 0

    init(
        assets: [AssetInfo],
        selection: Binding<Set<String>>,
        isSelecting: Binding<Bool>,
        cellMinSize: CGFloat = 104,
        onCellAppear: ((AssetInfo) -> Void)? = nil,
        makeMenu: ((AssetInfo) -> AnyView)? = nil,
        onOpenAsset: ((AssetInfo) -> Void)? = nil,
        makeSectionTitle: ((AssetInfo) -> String?)? = nil,
        makeSectionHeader: ((String, Int, Int64, AssetInfo?) -> AnyView)? = nil,
        jumpToId: String? = nil,
        jumpToken: Int = 0,
        @ViewBuilder bottomBar: @escaping () -> BottomBar
    ) {
        self.assets = assets
        self._selection = selection
        self._isSelecting = isSelecting
        self.cellMinSize = cellMinSize
        self.onCellAppear = onCellAppear
        self.makeMenu = makeMenu
        self.onOpenAsset = onOpenAsset
        self.makeSectionTitle = makeSectionTitle
        self.makeSectionHeader = makeSectionHeader
        self.jumpToId = jumpToId
        self.jumpToken = jumpToken
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
            return [AssetSection(key: "all", title: "", firstAsset: displayed.first, count: displayed.count, totalBytes: 0, assets: displayed)]
        }
        var result: [AssetSection] = []
        for info in displayed {
            let title = makeSectionTitle(info) ?? ""
            if var last = result.last, last.title == title {
                last.assets.append(info)
                result[result.count - 1] = last
            } else {
                // key 使用「标题 + 组内首项 id」而非序号：分页扩张后仍保持稳定，
                // 序号 key 在数据变化时会错位导致 scrollTo 落到别的分组
                result.append(AssetSection(key: "\(title)#\(info.id)", title: title, firstAsset: info, count: 1, totalBytes: info.byteSize, assets: [info]))
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

    /// 资产列表签名：用于检测列表整体变化（筛选/排序/数据源切换）。
    /// 原实现只看第一项 id——筛选后首项不变时分页不会重置。
    private var assetsSignature: String {
        "\(assets.count)|\(assets.first?.id ?? "")|\(assets.last?.id ?? "")"
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    if makeSectionTitle != nil {
                        // 分组显示：每组 = 一行日期分组头 + 该组的多列缩略图网格
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                if !section.title.isEmpty {
                                    sectionHeader(section)
                                }
                                LazyVGrid(columns: columns, spacing: 2) {
                                    gridCells(section.assets)
                                }
                                .padding(.horizontal, 2)
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
                .onChange(of: jumpToken) { _ in
                    scrollToBookmark(proxy)
                }
            }
            bottomBar()
        }
        .onChange(of: assetsSignature) { _ in
            visibleCount = pageSize
        }
    }

    /// 跳转到定位书签：先扩充分页让目标行存在，再滚动。
    /// 分组模式下滚动到目标所在的分组头——目标单元格嵌在 LazyVStack+LazyVGrid
    /// 双层懒加载容器内，直接 scrollTo 单元格不可靠；分组头在 LazyVStack 顶层，可靠。
    ///
    /// 深跳转（如跳到几年前）时 LazyVStack 只有估算高度，单次 scrollTo 会停在估算位置，
    /// 表现为「第一次定位偏、再点一次才对」。这里改成：
    /// 1. 先用无动画直达，让目标区域进入渲染范围；
    /// 2. 随后多次滚动校正（每次都在最新布局上重新解析目标），逐步收敛到准确位置；
    /// 3. 每次解析都重新取 sections，保证分页扩张后仍能命中正确的分组头。
    private func scrollToBookmark(_ proxy: ScrollViewProxy) {
        guard let target = jumpToId else { return }
        if let idx = assets.firstIndex(where: { $0.id == target }) {
            let needed = min(assets.count, idx + 1)
            if needed > visibleCount { visibleCount = needed }
        }
        jumpSeq += 1
        let seq = jumpSeq
        // (延时, 是否带动画)：首帧无动画直达，之后带动画校正
        let schedule: [(delay: Double, animated: Bool)] = [
            (0.02, false), (0.12, true), (0.3, true), (0.55, true),
            (0.9, true), (1.4, true), (2.0, true), (2.8, true)
        ]
        for step in schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + step.delay) {
                guard seq == jumpSeq else { return }
                let targetId = scrollTargetId(for: target)
                if step.animated {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(targetId, anchor: .top)
                    }
                } else {
                    var transaction = Transaction()
                    transaction.disablesAnimations = true
                    withTransaction(transaction) {
                        proxy.scrollTo(targetId, anchor: .top)
                    }
                }
            }
        }
    }

    /// 定位滚动目标：分组模式下用分组头 key，否则用项目 id
    private func scrollTargetId(for target: String) -> String {
        guard makeSectionTitle != nil else { return target }
        guard let section = sections.first(where: { $0.assets.contains { $0.id == target } }) else {
            return target
        }
        return section.key
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
        // 缩略图采样随单元格大小变化（捏合放大时提高清晰度），上限 480
        let side = min(480, max(140, 140 * cellMinSize / 104))
        ForEach(items) { info in
            GridCellView(
                info: info,
                thumbSide: side,
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
    /// 缩略图采样边长（随单元格缩放调整，保证放大后仍清晰）
    var thumbSide: CGFloat = 140
    let isSelecting: Bool
    let isSelected: Bool
    var onTap: () -> Void
    var onLongPress: () -> Void
    var menu: AnyView?

    @State private var image: UIImage?
    @EnvironmentObject private var appState: AppState

    var body: some View {
        // 规范正方形单元格：Color.clear 定尺寸，图片 overlay 铺满后整体裁切
        // （任何列配置下都保证苹果相册式正方形 + 自动裁切）
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack(alignment: .bottomLeading) {
                    Color(.systemGray5)
                    if let image {
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
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundColor(isSelected ? .accentColor : .white)
                        .padding(6)
                }
            }
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
            .clipped()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
            .contextMenu {
                if let menu { menu }
            }
            .task(id: "\(info.id)|\(Int(thumbSide))") {
                // 渐进式加载：先收到快速低清帧，高清帧到达后自动替换
                for await frame in ThumbnailManager.shared.thumbnailStream(for: info, side: thumbSide) {
                    image = frame
                }
            }
    }

    private static let shortDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    private static let longDurationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()

    private static func durationText(_ seconds: Double) -> String {
        let formatter = seconds >= 3600 ? longDurationFormatter : shortDurationFormatter
        return formatter.string(from: seconds) ?? ""
    }
}
