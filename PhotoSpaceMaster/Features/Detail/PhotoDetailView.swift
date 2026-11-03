import SwiftUI
import AVKit

/// 大图查看器
/// - 顶部信息：日期时间 / 类型·分辨率·大小 / 地点·海拔 / 相机参数
/// - 左上角返回；右上角：垃圾箱（数量角标）、免删除（数量角标）、设置
/// - 幻灯片式左右滑动：照片跟手移动，左右可见上一张/下一张，松手滑入切换
/// - 上滑：照片变红飞出 = 移入垃圾箱（免确认）；下滑：照片变绿飞出 = 免删除
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

    // 标记动画（变色 + 飞出）
    @State private var markTint: Color?
    @State private var swipeOutOpacity: Double = 1
    @State private var isMarking = false

    // 媒体内容与信息
    @State private var image: UIImage?
    @State private var prevImage: UIImage?
    @State private var nextImage: UIImage?
    @State private var player: AVPlayer?
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topInfo
                GeometryReader { proxy in
                    ZStack {
                        Color.black
                        mediaArea(slideWidth: proxy.size.width)
                        statusBadge
                    }
                }
                if showRatingPanel { ratingPanel }
                bottomBar
            }
            .background(Color.black.ignoresSafeArea(edges: .bottom))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
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

    private var currentMedia: some View {
        mediaContent
            .scaleEffect(scale * pinchScale)
            .offset(CGSize(width: panOffset.width + dragOffset.width,
                           height: panOffset.height + dragOffset.height))
            .overlay {
                // 标记变色：红 = 垃圾箱，绿 = 免删除
                if let markTint {
                    markTint.opacity(0.4)
                        .allowsHitTesting(false)
                }
            }
            .clipped()
    }

    private func mediaArea(slideWidth: CGFloat) -> some View {
        ZStack {
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
                        // 幻灯片跟手：左右滑动可见上一张/下一张
                        liveDrag = value.translation
                    }
                }
                .onEnded { value in
                    if isZoomed {
                        panOffset = CGSize(width: panOffset.width + value.translation.width,
                                           height: panOffset.height + value.translation.height)
                    } else {
                        handleSwipe(value, slideWidth: slideWidth)
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

    // MARK: - 底部：收藏 / 评分

    private var bottomBar: some View {
        HStack {
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
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.65))
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

    // MARK: - 标记角标（红色 X = 垃圾箱；绿色 ✓ = 免删除）

    @ViewBuilder
    private var statusBadge: some View {
        VStack {
            HStack {
                Spacer()
                if appState.isTrashed(current.id) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.red)
                        .background(Circle().fill(.white.opacity(0.85)))
                } else if appState.isProtected(current.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(.green)
                        .background(Circle().fill(.white.opacity(0.85)))
                }
            }
            .padding()
            Spacer()
        }
    }

    // MARK: - 手势逻辑

    private func handleSwipe(_ value: DragGesture.Value, slideWidth: CGFloat) {
        let w = value.translation.width
        let h = value.translation.height
        if abs(w) > 60 && abs(w) > abs(h) * 1.2 {
            // 左滑 = 下一张，右滑 = 上一张（幻灯片滑入）
            commitSlide(w < 0 ? .forward : .backward, width: slideWidth)
        } else if abs(h) > 60 && abs(h) > abs(w) {
            // 上滑 = 变红飞入垃圾箱；下滑 = 变绿飞入免删除
            commitMark(h < 0 ? .trash : .protect)
        } else {
            springBack()
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
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    index = next
                    liveDrag = .zero
                }
            } else {
                // 已到头，弹回
                springBack()
            }
        }
    }

    /// 标记（免确认）：照片变色 + 朝对应方向飞出 → 应用标记 → 按浏览方向自动前进
    private func commitMark(_ kind: MarkKind) {
        guard !isMarking else { return }
        isMarking = true
        let tint: Color = (kind == .trash) ? .red : .green
        let fly: CGSize = (kind == .trash)
            ? CGSize(width: 0, height: -900)    // 上滑变红飞入垃圾箱
            : CGSize(width: 0, height: 900)     // 下滑变绿飞入免删除
        withAnimation(.easeIn(duration: 0.3)) {
            markTint = tint
            liveDrag = fly
            swipeOutOpacity = 0.35
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            switch kind {
            case .trash:
                CleanupService.moveToTrash([current], state: appState)
            case .protect:
                if !appState.isProtected(current.id) {
                    CleanupService.toggleProtected([current.id], state: appState)
                }
            }
            markTint = nil
            liveDrag = .zero
            swipeOutOpacity = 1
            isMarking = false
            move(direction)
        }
    }

    /// 浏览方向：默认新→旧；一旦操作过"上一张"（右滑），后续自动前进沿用旧→新
    private func nextNavigableIndex(from currentIndex: Int, dir: Direction) -> Int? {
        let skipProtected = appState.settings.skipProtectedItems
        var i = currentIndex
        while true {
            i += (dir == .forward) ? 1 : -1
            guard assets.indices.contains(i) else { return nil }
            let candidate = assets[i]
            if appState.isTrashed(candidate.id) { continue }
            if skipProtected && appState.isProtected(candidate.id) { continue }
            return i
        }
    }

    private func move(_ dir: Direction) {
        direction = dir
        resetZoom()
        if let next = nextNavigableIndex(from: index, dir: dir) {
            // 标记飞出后无动画换页（当前照片已飞走，新照片直接就位）
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                index = next
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
        image = nil
        prevImage = nil
        nextImage = nil
        player = nil
        resetZoom()
        isFavorite = info.isFavorite

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
            image = await ThumbnailManager.shared.thumbnail(for: info, side: 1200)
        }
        // 幻灯片相邻照片预加载（视频显示黑底占位）
        Task {
            if index > 0 {
                let neighbor = assets[index - 1]
                if neighbor.kind != .video {
                    prevImage = await ThumbnailManager.shared.thumbnail(for: neighbor, side: 700)
                }
            }
        }
        Task {
            if index < assets.count - 1 {
                let neighbor = assets[index + 1]
                if neighbor.kind != .video {
                    nextImage = await ThumbnailManager.shared.thumbnail(for: neighbor, side: 700)
                }
            }
        }
        Task {
            if let item = await AssetDetailProvider.shared.playerItem(for: info) {
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
