import SwiftUI

/// 网格布局计算：列数与「正好铺满容器」的单元格边长互为反函数。
/// 连续缩放（捏合跟手 + 松手吸附）依赖这两者保持一致。
enum GridMetrics {
    /// 单元格间距
    static let spacing: CGFloat = 2

    /// 目标边长下能放几列（至少 1 列）
    static func columnCount(width: CGFloat, side: CGFloat) -> Int {
        guard width > 0, side > 0 else { return 1 }
        return max(1, Int((width + spacing) / (side + spacing)))
    }

    /// 该列数正好铺满容器时的单元格边长（在这条边长下列数恰好还是它）
    static func filledSide(width: CGFloat, columns: Int) -> CGFloat {
        guard width > 0, columns > 0 else { return 0 }
        return max(1, (width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
    }

    /// 捏合过程中的列数：允许最后一列只露出一部分。
    /// 边长因此可以连续变化而不出现大片右侧留白——这是「丝滑」的关键。
    static func overflowColumnCount(width: CGFloat, side: CGFloat) -> Int {
        guard width > 0, side > 0 else { return 1 }
        return max(1, Int(ceil((width + spacing) / (side + spacing))))
    }

    /// 静止态 / 松手吸附后的边长：保持当前列数，把格子铺满容器。
    /// 与「按最小边长自适应列数」的旧行为完全一致（格子只会变得比目标略大）。
    static func snappedSide(_ side: CGFloat, width: CGFloat) -> CGFloat {
        guard width > 0, side > 0 else { return side }
        let columns = columnCount(width: width, side: side)
        return filledSide(width: width, columns: columns)
    }
}

/// 共用网格组件：所有列表页（首页 / 相册 / 清理列表 / 垃圾箱 / 免删除）复用。
/// - 行切片布局：每行一个 HStack，单元格边长可连续变化（捏合缩放跟手）
/// - 分页加载（每页 120 项）
/// - 多选模式：长按进入，点击选中/取消
/// - 底部操作栏由各页面通过闭包注入，保证交互一致
/// - 支持按相邻同标题分组，并可注入富样式分组头（iOS 相册「日」视图风格）
struct PhotoGridView<BottomBar: View>: View {
    private let pageSize = 120

    let assets: [AssetInfo]
    /// 缩略图边长（决定列数）：双指捏合时由外部逐帧传入连续值
    var cellMinSize: CGFloat = 104
    /// 是否正在捏合缩放。缩放中按连续边长排版（右侧可能留白），
    /// 松手后按列数铺满，网格重新整齐——这是苹果相册的手感来源。
    var isLiveZooming: Bool = false
    /// 回传网格可用宽度（用于松手吸附计算「正好铺满」的边长）
    var onWidthChange: ((CGFloat) -> Void)? = nil
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
        isLiveZooming: Bool = false,
        onWidthChange: ((CGFloat) -> Void)? = nil,
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
        self.isLiveZooming = isLiveZooming
        self.onWidthChange = onWidthChange
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

    /// 分组显示：相邻同标题的项归为一段
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
            GeometryReader { geo in
                ScrollViewReader { proxy in
                    ScrollView {
                        gridContent(width: geo.size.width)
                    }
                    .onChange(of: jumpToken) { _ in
                        scrollToBookmark(proxy)
                    }
                }
                .onAppear { reportWidth(geo.size.width) }
                .onChange(of: geo.size.width) { width in reportWidth(width) }
            }
            bottomBar()
        }
        .onChange(of: assetsSignature) { _ in
            visibleCount = pageSize
        }
    }

    /// 宽度回传（延后一拍，避免在视图更新期间改外部状态）
    private func reportWidth(_ width: CGFloat) {
        DispatchQueue.main.async { onWidthChange?(width) }
    }

    /// 当前排版：
    /// - 捏合中：边长连续跟手；列数允许「半个列」，最后一列被视口裁掉一部分，永远铺满宽度
    /// - 静止：按列数铺满容器（整齐），也是松手吸附的目标值，所以松手不会二次跳动
    private func gridLayout(width: CGFloat) -> (side: CGFloat, columns: Int) {
        guard width > 0 else { return (cellMinSize, 1) }
        if isLiveZooming {
            return (cellMinSize, GridMetrics.overflowColumnCount(width: width, side: cellMinSize))
        }
        let side = GridMetrics.snappedSide(cellMinSize, width: width)
        return (side, GridMetrics.columnCount(width: width, side: side))
    }

    @ViewBuilder
    private func gridContent(width: CGFloat) -> some View {
        let layout = gridLayout(width: width)
        let side = layout.side
        let columns = layout.columns
        if makeSectionTitle != nil {
            // 分组显示：分组头与缩略图行拍平到同一个 LazyVStack（懒加载容器不能嵌套，
            // 否则内层无法正确估算高度，滚动会出现空白/跳动）
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(blocks(columns: columns)) { block in
                    switch block.kind {
                    case .header(let section):
                        sectionHeader(section)
                    case .row(let row, let isFirstInSection):
                        rowView(row, side: side,
                                topPadding: isFirstInSection ? 0 : GridMetrics.spacing)
                    }
                }
            }
            // 固定为视口宽度：捏合时最后一列会超出，靠这里裁掉，避免撑宽滚动内容
            .frame(width: width, alignment: .leading)
            .clipped()
        } else {
            LazyVStack(spacing: GridMetrics.spacing) {
                ForEach(Self.makeRows(displayed, columns: columns)) { row in
                    rowView(row, side: side, topPadding: 0)
                }
            }
            .padding(.bottom, 12)
            .frame(width: width, alignment: .leading)
            .clipped()
        }

        if assets.isEmpty {
            emptyState
        }
    }

    // MARK: - 行切片

    /// 一行缩略图（行内单元格等宽等高，行数随列数变化）
    struct GridRow: Identifiable {
        let id: String
        var items: [AssetInfo]
    }

    /// 分组头 / 缩略图行拍平后的块
    struct GridBlock: Identifiable {
        enum Kind {
            case header(AssetSection)
            case row(GridRow, isFirstInSection: Bool)
        }
        let id: String
        let kind: Kind
    }

    private func blocks(columns: Int) -> [GridBlock] {
        var result: [GridBlock] = []
        result.reserveCapacity(sections.count + displayed.count / max(1, columns) + 1)
        for section in sections {
            if !section.title.isEmpty {
                // 分组头用 section.key 作为滚动目标（与 scrollTargetId 对应）
                result.append(GridBlock(id: section.key, kind: .header(section)))
            }
            for (offset, row) in Self.makeRows(section.assets, columns: columns).enumerated() {
                result.append(GridBlock(id: row.id, kind: .row(row, isFirstInSection: offset == 0)))
            }
        }
        return result
    }

    private static func makeRows(_ items: [AssetInfo], columns: Int) -> [GridRow] {
        let cols = max(1, columns)
        guard !items.isEmpty else { return [] }
        var rows: [GridRow] = []
        rows.reserveCapacity((items.count + cols - 1) / cols)
        var index = 0
        while index < items.count {
            let end = min(index + cols, items.count)
            let slice = Array(items[index..<end])
            rows.append(GridRow(id: slice[0].id, items: slice))
            index = end
        }
        return rows
    }

    private func rowView(_ row: GridRow, side: CGFloat, topPadding: CGFloat) -> some View {
        // 捏合中行宽可能超过视口（最后一列只露出一部分），用固定行宽让右侧自然溢出裁剪；
        // 静止态行宽 = 视口宽，恰好铺满
        let rowWidth = CGFloat(row.items.count) * side
            + CGFloat(max(0, row.items.count - 1)) * GridMetrics.spacing
        return HStack(spacing: GridMetrics.spacing) {
            ForEach(row.items) { info in
                cellView(info, side: side)
            }
        }
        .frame(width: rowWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, topPadding)
    }

    /// 缩略图采样边长：按档位取整。捏合过程中单元格每帧都在变，
    /// 若采样边长跟着每帧变，`.task(id:)` 会不断重启加载，缩放立刻卡住。
    private static func sampleSide(for side: CGFloat) -> CGFloat {
        if side <= 100 { return 160 }
        if side <= 180 { return 240 }
        if side <= 280 { return 360 }
        return 480
    }

    @ViewBuilder
    private func cellView(_ info: AssetInfo, side: CGFloat) -> some View {
        GridCellView(
            info: info,
            thumbSide: Self.sampleSide(for: side),
            isSelecting: isSelecting,
            isSelected: selection.contains(info.id),
            onTap: { handleTap(info) },
            onLongPress: {
                if !isSelecting { isSelecting = true }
                selection.insert(info.id)
            },
            menu: makeMenu?(info)
        )
        .frame(width: side, height: side)
        .onAppear {
            onCellAppear?(info)
            if info.id == displayed.last?.id, visibleCount < assets.count {
                visibleCount += pageSize
            }
        }
    }

    /// 跳转到定位书签：先扩充分页让目标行存在，再滚动。
    /// 分组模式下滚动到目标所在的分组头——目标单元格嵌在行切片的 HStack 里，
    /// 直接 scrollTo 单元格不可靠；分组头是 LazyVStack 的顶层元素，可靠。
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
