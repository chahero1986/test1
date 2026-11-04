import SwiftUI
import AVKit

/// 大图查看器
/// - 顶部信息：日期时间 / 类型·分辨率·大小 / 地点·海拔 / 相机参数
/// - 左上角返回；右上角：垃圾箱（数量角标）、免删除（数量角标）、设置
/// - 幻灯片式左右滑动：照片跟手移动，左右可见上一张/下一张，松手滑入切换
/// - 上滑：屏幕顶端红色渐变，照片旋转飞入右上角垃圾箱 = 移入垃圾箱（免确认）
/// - 下滑：屏幕顶端绿色渐变，照片旋转飞入右上角免打扰入口 = 免删除
/// - 标记后按当前浏览方向自动前进；双指缩放；底部收藏 / 评分
struct PhotoDetailView: View {
    /// forward = 下一张（新→旧）；backward = 上一张方向（旧→新）
    enum Direction { case forward, backward }
    private enum MarkKind { case trash, protect }

    let assets: [AssetInfo]      // 调用方按 新→旧 排序
    let startId: String

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var ratings: RatingService
    @Environment(\.dismiss) private var dismiss

    private let service = PhotoLibraryService.shared

    @State private var index: Int = 0
    @State private var direction: Direction = .forward
    @State private var appeared = false

    // 缩放与拖动
    @State private var scale: CGFloat = 1
    @GestureState private var pinchScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    // 幻灯片滑动（未缩放时跟手）
    @State private var liveDrag: CGSize = .zero
    /// 手势方向锁：一次拖动一旦判定主方向，松手前不再切换（避免滑动中途变向）
    @State private var dragAxis: DragAxis?

    private enum DragAxis { case horizontal, vertical }

    // 标记动画（变色 + 旋转飞出）
    @State private var markTint: Color?
    @State private var swipeOutOpacity: Double = 1
    @State private var isMarking = false
    // 顶部渐变提示（上滑 = 红色，下滑 = 绿色，跟随拖动距离渐显）
    @State private var topTint: Color?
    // 旋转飞出（飞向右上角对应入口图标）
    @State private var flyOffset: CGSize = .zero
    @State private var flyRotation: Double = 0

    // 媒体内容与信息
    @State private var image: UIImage?
    @State private var prevImage: UIImage?
    @State private var nextImage: UIImage?
    @State private var player: AVPlayer?
    /// 当前播放器对应的资产 id：换页后旧播放器未清理时不会误显示上一段视频
    @State private var playerAssetId: String?
    /// 视频首帧海报：播放器就绪前占位，避免黑屏（也避免用上一张照片兜底造成闪回）
    @State private var videoPoster: UIImage?
    /// 海报对应的资产 id：跨视频切换时不会显示上一段视频的海报
    @State private var videoPosterAssetId: String?
    @State private var dateText = ""
    @State private var metaLine = ""
    @State private var locationLine = ""
    @State private var cameraLine = ""

    // 收藏与评分
    @State private var isFavorite = false
    @State private var showRatingPanel = false

    init(assets: [AssetInfo], startId: String) {
        self.assets = assets
        self.startId = startId
        let startIndex = assets.firstIndex { $0.id == startId } ?? 0
        _index = State(initialValue: startIndex)
    }

    private var current: AssetInfo { assets[min(max(index, 0), assets.count - 1)] }
    private var isZoomed: Bool { scale * pinchScale > 1.05 }
    private var ratingStars: Int { ratings.ratings[current.id] ?? 0 }
    /// 已入垃圾箱或免打扰的项目不允许上滑/下滑标记
    private var canMark: Bool {
        !appState.isTrashed(current.id) && !appState.isProtected(current.id)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topInfo
                GeometryReader { proxy in
                    ZStack {
                        Color.black
                        mediaArea(size: proxy.size)
                        statusBadge
                        topGradient
                    }
                }
                if showRatingPanel { ratingPanel }
                bottomBar
            }
            .background(Color.black.ignoresSafeArea(edges: .bottom))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarContent }
            .task(id: current.id) { loadCurrent() }
            .onAppear {
                withAnimation(.easeOut(duration: 0.28)) { appeared = true }
            }
        }
        .scaleEffect(appeared ? 1 : 0.94)
        .opacity(appeared ? 1 : 0)
    }

    // MARK: - 工具栏（左上角返回 + 右上角三按钮）

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.title3.weight(.semibold))
                    .foregroundColor(.white)
            }
            .accessibilityLabel("返回")
        }
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            NavigationLink {
                TrashView()
            } label: {
                Image(systemName: "trash")
                    .foregroundColor(.white)
                    .overlay(alignment: .topTrailing) { countBadge(appState.trashIds.count) }
            }
            NavigationLink {
                ProtectedView()
            } label: {
                Image(systemName: "hand.raised")
                    .foregroundColor(.white)
                    .overlay(alignment: .topTrailing) { countBadge(appState.protectedIds.count) }
            }
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
                    .foregroundColor(.white)
            }
        }
    }

    @ViewBuilder
    private func countBadge(_ count: Int) -> some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(.white)
                .padding(3)
                .background(Circle().fill(.red))
                .offset(x: 8, y: -8)
        }
    }

    // MARK: - 幻灯片式媒体区（上一张 | 当前 | 下一张）

    @ViewBuilder
    private func slideNeighbor(_ image: UIImage?) -> some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            Color.black
        }
    }

    /// 当前媒体内容：视频播放器或图片
    @ViewBuilder
    private var mediaContent: some View {
        if current.kind == .video {
            // 播放器必须属于当前资产，否则显示首帧海报/黑底占位——
            // 不能用 `image` 兜底，否则会闪一下上一张照片
            if let player, playerAssetId == current.id {
                VideoPlayer(player: player)
                    .ignoresSafeArea()
            } else if let videoPoster, videoPosterAssetId == current.id {
                ZStack {
                    Color.black
                    Image(uiImage: videoPoster)
                        .resizable()
                        .scaledToFit()
                }
            } else {
                ZStack {
                    Color.black
                    ProgressView()
                        .tint(.white)
                }
            }
        } else if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                // 注意：此处不加 .animation(value: image)——换页时必须瞬时换图，
                // 否则新旧照片交叉淡化会形成「闪回上一张」的观感；
                // 同一张照片 700px→1200px 的清晰度替换在 loadCurrent 里用 withAnimation 做
        } else {
            ZStack {
                Color.black
                ProgressView()
                    .tint(.white)
            }
        }
    }

    private var currentMedia: some View {
        mediaContent
            .scaleEffect(scale * pinchScale)
            .rotationEffect(.degrees(flyRotation))
            .offset(CGSize(width: panOffset.width + dragOffset.width + flyOffset.width,
                           height: panOffset.height + dragOffset.height + flyOffset.height))
            .overlay {
                // 标记变色：红 = 垃圾箱，绿 = 免删除
                if let markTint {
                    markTint
                        .allowsHitTesting(false)
                }
            }
            .clipped()
    }

    /// 标记时屏幕顶端的颜色渐变（上滑 = 红色，下滑 = 绿色，见参考图）
    @ViewBuilder
    private var topGradient: some View {
        if let topTint {
            LinearGradient(colors: [topTint, topTint.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 240)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
        }
    }

    private func mediaArea(size: CGSize) -> some View {
        let slideWidth = size.width
        return ZStack {
            slideNeighbor(prevImage)
                .offset(x: -slideWidth)
            slideNeighbor(nextImage)
                .offset(x: slideWidth)
            currentMedia
        }
        .offset(x: liveDrag.width, y: liveDrag.height)
        .opacity(swipeOutOpacity)
        .simultaneousGesture(
            MagnificationGesture()
                .updating($pinchScale) { value, state, _ in state = value }
                .onEnded { value in
                    scale = min(6, max(1, scale * value))
                    if scale == 1 { panOffset = .zero }
                }
        )
        .simultaneousGesture(
            DragGesture(minimumDistance: 15)
                .updating($dragOffset) { value, state, _ in
                    if isZoomed { state = value.translation }
                }
                .onChanged { value in
                    if !isZoomed && !isMarking {
                        let w = value.translation.width
                        let h = value.translation.height
                        // 方向锁定：位移超过 15pt 时判定主方向，本手势内不再改变
                        if dragAxis == nil, max(abs(w), abs(h)) > 15 {
                            dragAxis = abs(w) >= abs(h) ? .horizontal : .vertical
                        }
                        if dragAxis == .horizontal || (dragAxis == .vertical && !canMark) {
                            // 横向（或不可标记时的任意方向）：幻灯片跟手，左右滑动可见上一张/下一张
                            liveDrag = value.translation
                            clearMarkFeedback()
                        } else if dragAxis == .vertical {
                            // 纵向：实时显示顶部渐变与变色反馈（不移动照片）
                            liveDrag = .zero
                            let c: Color = h < 0 ? .red : .green
                            topTint = c.opacity(min(0.6, Double(abs(h)) / 600))
                            markTint = c.opacity(min(0.3, Double(abs(h)) / 1600))
                        }
                    }
                }
                .onEnded { value in
                    dragAxis = nil
                    if isZoomed {
                        panOffset = CGSize(width: panOffset.width + value.translation.width,
                                           height: panOffset.height + value.translation.height)
                    } else {
                        handleSwipe(value, size: size)
                    }
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.easeInOut(duration: 0.2)) {
                scale = scale > 1 ? 1 : 2
                panOffset = .zero
            }
        }
    }

    /// 清除拖动过程中的渐变/变色反馈
    private func clearMarkFeedback() {
        if topTint != nil || markTint != nil {
            withAnimation(.easeOut(duration: 0.2)) {
                topTint = nil
                markTint = nil
            }
        }
    }

    // MARK: - 顶部信息（4 行）

    private var topInfo: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(dateText)
                    .font(.footnote.weight(.semibold))
                    .foregroundColor(.white)
                Text(metaLine)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.85))
                if !locationLine.isEmpty {
                    Text(locationLine)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.85))
                }
                if !cameraLine.isEmpty {
                    Text(cameraLine)
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.85))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black)
    }

    // MARK: - 底部：取消删除 / 取消免打扰 / 收藏 / 评分

    private var bottomBar: some View {
        HStack {
            if appState.isTrashed(current.id) {
                // 已入垃圾箱：仅提供取消删除，且禁止上滑/下滑标记
                Button {
                    CleanupService.restore(ids: [current.id], state: appState)
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "trash.slash")
                            .font(.title3)
                        Text("取消删除")
                            .font(.caption2)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                }
            } else {
                if appState.isProtected(current.id) {
                    // 已免打扰：增加取消免打扰按钮，且禁止上滑/下滑标记
                    Button {
                        CleanupService.toggleProtected([current.id], state: appState)
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: "hand.raised.slash")
                                .font(.title3)
                            Text("取消免打扰")
                                .font(.caption2)
                        }
                        .foregroundColor(.green)
                        .frame(maxWidth: .infinity)
                    }
                }
                bookmarkButton
                Button {
                    toggleFavorite()
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: isFavorite ? "heart.fill" : "heart")
                            .font(.title3)
                        Text(isFavorite ? "已收藏" : "收藏")
                            .font(.caption2)
                    }
                    .foregroundColor(isFavorite ? .red : .white)
                    .frame(maxWidth: .infinity)
                }
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { showRatingPanel.toggle() }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.title3)
                        Text(ratingStars > 0 ? "\(ratingStars) 星" : "评分")
                            .font(.caption2)
                    }
                    .foregroundColor(.yellow)
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.65))
    }

    /// 定位书签：再次点击取消书签；设置后可在首页筛选面板「转到定位」跳转
    private var isBookmarked: Bool { appState.settings.bookmarkAssetId == current.id }

    private var bookmarkButton: some View {
        Button {
            appState.settings.bookmarkAssetId = isBookmarked ? "" : current.id
        } label: {
            VStack(spacing: 3) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                Text(isBookmarked ? "已定位" : "定位")
                    .font(.caption2)
            }
            .foregroundColor(isBookmarked ? .orange : .white)
            .frame(maxWidth: .infinity)
        }
    }

    private var ratingPanel: some View {
        HStack(spacing: 14) {
            Text("评分")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
            ForEach(1...5, id: \.self) { stars in
                Button {
                    ratings.setRating(stars, for: current.id)
                } label: {
                    Image(systemName: ratingStars >= stars ? "star.fill" : "star")
                        .font(.title3)
                        .foregroundColor(.yellow)
                        .scaleEffect(ratingStars == stars ? 1.2 : 1)
                }
            }
            if ratingStars > 0 {
                Button {
                    ratings.removeRating(for: current.id)
                } label: {
                    Text("清除")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(Color.black.opacity(0.85))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - 标记覆盖（红色 = 垃圾箱；绿色 = 免删除，与网格一致）

    @ViewBuilder
    private var statusBadge: some View {
        if appState.isTrashed(current.id) {
            Color.red.opacity(0.25).allowsHitTesting(false)
        } else if appState.isProtected(current.id) {
            Color.green.opacity(0.25).allowsHitTesting(false)
        }
    }

    // MARK: - 手势逻辑

    private func handleSwipe(_ value: DragGesture.Value, size: CGSize) {
        let w = value.translation.width
        let h = value.translation.height
        if abs(w) > 60 && abs(w) > abs(h) * 1.2 {
            // 左滑 = 下一张，右滑 = 上一张（幻灯片滑入）
            commitSlide(w < 0 ? .forward : .backward, width: size.width)
        } else if abs(h) > 60 && abs(h) > abs(w) {
            if canMark {
                // 上滑 = 顶部红色渐变 + 旋转飞入垃圾箱；下滑 = 顶部绿色渐变 + 旋转飞入免打扰
                commitMark(h < 0 ? .trash : .protect, size: size)
            } else {
                // 已入垃圾箱/免打扰的项目禁止上滑、下滑标记
                springBack()
                clearMarkFeedback()
            }
        } else {
            springBack()
            clearMarkFeedback()
        }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.75)) {
            liveDrag = .zero
        }
    }

    /// 幻灯片切换：当前照片滑出屏幕，下一张/上一张滑入居中
    private func commitSlide(_ dir: Direction, width: CGFloat) {
        guard !isMarking else { return }
        direction = dir
        let target = (dir == .forward) ? -width : width
        withAnimation(.easeOut(duration: 0.22)) {
            liveDrag = CGSize(width: target, height: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.23) {
            resetZoom()
            if let next = nextNavigableIndex(from: index, dir: dir) {
                // 预载的邻图恰好就是目标照片时，随换页同步换图（无动画），
                // 避免「先渲染旧图一帧再换图」造成的闪回上一张
                let adjacent: UIImage? = {
                    if dir == .forward, next == index + 1 { return nextImage }
                    if dir == .backward, next == index - 1 { return prevImage }
                    return nil
                }()
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    index = next
                    if assets[next].kind == .video {
                        // 目标是视频：清空旧图与旧播放器，只显示该视频自己的海报，
                        // 否则 mediaContent 会先渲染上一张照片再切到视频（闪一下）
                        image = nil
                        videoPoster = adjacent
                        videoPosterAssetId = adjacent != nil ? assets[next].id : nil
                        player?.pause()
                        player = nil
                        playerAssetId = nil
                    } else if let adjacent {
                        image = adjacent
                    } else {
                        image = nil
                    }
                    liveDrag = .zero
                }
            } else {
                // 已到头，弹回
                springBack()
            }
        }
    }

    /// 标记（免确认）：顶部渐变提示，照片变色并旋转飞向右上角对应入口图标
    /// （上滑 = 红色渐变，飞入垃圾箱；下滑 = 绿色渐变，飞入免打扰项目）→ 应用标记 → 按浏览方向自动前进
    private func commitMark(_ kind: MarkKind, size: CGSize) {
        guard !isMarking else { return }
        isMarking = true
        let tint: Color = (kind == .trash) ? .red : .green
        // 飞向右上角对应入口图标（垃圾箱 / 免打扰），带旋转与缩小
        let target = CGSize(width: size.width * 0.55, height: -size.height * 0.8)
        withAnimation(.easeIn(duration: 0.15)) {
            topTint = tint.opacity(0.6)
            markTint = tint.opacity(0.3)
            flyOffset = target
            flyRotation = 24
            swipeOutOpacity = 0.15
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.17) {
            switch kind {
            case .trash:
                CleanupService.moveToTrash([current], state: appState)
            case .protect:
                if !appState.isProtected(current.id) {
                    CleanupService.toggleProtected([current.id], state: appState)
                }
            }
            withAnimation(.easeOut(duration: 0.25)) {
                topTint = nil
                markTint = nil
            }
            flyOffset = .zero
            flyRotation = 0
            swipeOutOpacity = 1
            isMarking = false
            move(direction)
        }
    }

    /// 浏览方向：默认新→旧；一旦操作过"上一张"（右滑），后续自动前进沿用旧→新
    private func nextNavigableIndex(from currentIndex: Int, dir: Direction) -> Int? {
        let skipProtected = appState.settings.skipProtectedItems
        let skipTrashed = appState.settings.skipTrashedItems
        var i = currentIndex
        while true {
            i += (dir == .forward) ? 1 : -1
            guard assets.indices.contains(i) else { return nil }
            let candidate = assets[i]
            if skipTrashed && appState.isTrashed(candidate.id) { continue }
            if skipProtected && appState.isProtected(candidate.id) { continue }
            return i
        }
    }

    private func move(_ dir: Direction) {
        direction = dir
        resetZoom()
        if let next = nextNavigableIndex(from: index, dir: dir) {
            // 标记飞出后无动画换页（当前照片已飞走，新照片直接就位）
            // 同步换图：目标恰为相邻照片时用已预载的邻图，避免闪回上一张
            let adjacent: UIImage? = {
                if dir == .forward, next == index + 1 { return nextImage }
                if dir == .backward, next == index - 1 { return prevImage }
                return nil
            }()
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                index = next
                if assets[next].kind == .video {
                    // 标记后自动前进到视频：同样清空旧画面，避免闪回上一张
                    image = nil
                    videoPoster = adjacent
                    videoPosterAssetId = adjacent != nil ? assets[next].id : nil
                    player?.pause()
                    player = nil
                    playerAssetId = nil
                } else if let adjacent {
                    image = adjacent
                } else {
                    image = nil
                }
            }
        } else {
            dismiss()
        }
    }

    private func toggleFavorite() {
        isFavorite.toggle()
        service.setFavorite(isFavorite, id: current.id)
    }

    private func resetZoom() {
        scale = 1
        panOffset = .zero
    }

    // MARK: - 加载当前照片信息

    private func loadCurrent() {
        let info = current
        player?.pause()
        player = nil
        playerAssetId = nil
        resetZoom()
        isFavorite = info.isFavorite

        // 图片：不清空画面——换页时已在 commitSlide/move 里同步换上预载邻图，
        // 这里只等 1200px 高清图加载后做清晰度替换；视频等播放器就绪前显示占位。
        if info.kind == .video {
            image = nil
        }
        prevImage = nil
        nextImage = nil

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        formatter.locale = Locale(identifier: "zh_CN")
        dateText = info.creationDate.map(formatter.string(from:)) ?? "未知时间"

        var metaParts = [info.kind.title]
        if info.kind == .video {
            metaParts.append(Self.durationText(info.durationSeconds))
        }
        metaParts.append("\(info.pixelWidth)×\(info.pixelHeight)")
        metaParts.append(ByteCountFormatter.string(fromByteCount: info.byteSize, countStyle: .file))
        metaLine = metaParts.joined(separator: " · ")
        locationLine = ""
        cameraLine = ""

        Task {
            let img = await ThumbnailManager.shared.largeImage(for: info, side: 1200)
            // 过期保护：快速连续滑动时只应用仍处于当前页的结果
            guard current.id == info.id, let img else { return }
            // 同一张照片的清晰度升级：瞬时替换（不做交叉淡化，避免轻微闪烁）
            image = img
        }
        // 视频首帧海报：播放器就绪前先显示画面，避免黑屏
        if info.kind == .video {
            Task {
                let poster = await ThumbnailManager.shared.largeImage(for: info, side: 1080)
                guard current.id == info.id else { return }
                videoPosterAssetId = info.id
                videoPoster = poster
            }
        }
        // 幻灯片相邻项预加载（图片载入画面，视频载入海报并预取播放项）
        Task {
            guard index > 0, current.id == info.id else { return }
            let neighbor = assets[index - 1]
            let img = await ThumbnailManager.shared.largeImage(for: neighbor, side: 700)
            if neighbor.kind == .video {
                AssetDetailProvider.shared.preloadPlayerItem(for: neighbor)
            }
            if current.id == info.id { prevImage = img }
        }
        Task {
            guard index < assets.count - 1, current.id == info.id else { return }
            let neighbor = assets[index + 1]
            let img = await ThumbnailManager.shared.largeImage(for: neighbor, side: 700)
            if neighbor.kind == .video {
                AssetDetailProvider.shared.preloadPlayerItem(for: neighbor)
            }
            if current.id == info.id { nextImage = img }
        }
        Task {
            if let item = await AssetDetailProvider.shared.playerItem(for: info) {
                // 过期保护：等待期间用户可能已翻页，不要把旧视频塞进新页面
                guard current.id == info.id else { return }
                playerAssetId = info.id
                player = AVPlayer(playerItem: item)
            }
        }
        Task {
            locationLine = await AssetDetailProvider.shared.locationText(for: info) ?? ""
        }
        Task {
            cameraLine = await AssetDetailProvider.shared.cameraParamsText(for: info) ?? ""
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
