import SwiftUI
import AVKit

/// 大图查看器
/// - 顶部信息：日期时间 / 类型·分辨率·大小 / 地点·海拔 / 相机参数
/// - 左上角返回；右上角：垃圾箱（数量角标）、免删除（数量角标）、设置
/// - 双指缩放；左滑=下一张、右滑=上一张；上滑=直接移入垃圾箱（免确认）、下滑=免删除
/// - 标记后飞出动画 + 按当前浏览方向自动前进；打开/切换均有过渡动画
/// - 底部：收藏、评分（点开评星级）
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

    // 标记飞出动画
    @State private var swipeOutOffset: CGSize = .zero
    @State private var swipeOutOpacity: Double = 1
    @State private var isMarking = false

    // 媒体内容与信息
    @State private var image: UIImage?
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
                        mediaArea
                            .frame(width: proxy.size.width, height: proxy.size.height)
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

    // MARK: - 媒体内容（双指缩放 + 四向滑动 + 动画）

    @ViewBuilder
    private var mediaContent: some View {
        if current.kind == .video {
            if let player {
                VideoPlayer(player: player)
            } else {
                ProgressView().tint(.white)
            }
        } else if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ProgressView().tint(.white)
        }
    }

    /// 切换上一张/下一张时的方向性过渡
    private var swipeTransition: AnyTransition {
        switch direction {
        case .forward:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .backward:
            return .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
        }
    }

    private var mediaArea: some View {
        mediaContent
            .scaleEffect(scale * pinchScale)
            .offset(CGSize(width: panOffset.width + dragOffset.width + swipeOutOffset.width,
                           height: panOffset.height + dragOffset.height + swipeOutOffset.height))
            .opacity(swipeOutOpacity)
            .clipped()
            .id(current.id)
            .transition(swipeTransition)
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
                    .onEnded { value in
                        if isZoomed {
                            panOffset = CGSize(width: panOffset.width + value.translation.width,
                                               height: panOffset.height + value.translation.height)
                        } else {
                            handleSwipe(value)
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

    // MARK: - 逻辑

    private func handleSwipe(_ value: DragGesture.Value) {
        let w = value.translation.width
        let h = value.translation.height
        if abs(w) > 60 && abs(w) > abs(h) * 1.2 {
            // 左滑 = 下一张，右滑 = 上一张
            move(w < 0 ? .forward : .backward)
        } else if abs(h) > 60 && abs(h) > abs(w) {
            if h < 0 {
                // 上滑 = 直接移入垃圾箱（免确认），飞出动画
                markWithAnimation(.trash)
            } else {
                // 下滑 = 加入免删除，飞出动画
                markWithAnimation(.protect)
            }
        }
    }

    /// 标记（免确认）：当前照片飞出 → 应用标记 → 按浏览方向自动前进
    private func markWithAnimation(_ kind: MarkKind) {
        guard !isMarking else { return }
        isMarking = true
        let flyOut: CGSize = kind == .trash
            ? CGSize(width: 0, height: -800)
            : CGSize(width: 0, height: 800)
        withAnimation(.easeIn(duration: 0.3)) {
            swipeOutOffset = flyOut
            swipeOutOpacity = 0
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
            swipeOutOffset = .zero
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
            withAnimation(.easeInOut(duration: 0.3)) {
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
