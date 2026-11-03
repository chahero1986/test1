import SwiftUI
import AVKit

/// 大图查看器
/// - 顶部信息：日期时间 / 类型·分辨率·大小 / 地点·海拔 / 相机参数
/// - 右上角：垃圾箱（数量角标）、免删除（数量角标）、设置
/// - 双指缩放；左滑=下一张、右滑=上一张；上滑=移入垃圾箱（需确认）、下滑=免删除
/// - 标记后按当前浏览方向自动前进，且跳过免删除（受筛选面板"自动跳过"开关控制）
struct PhotoDetailView: View {
    /// forward = 下一张（新→旧）；backward = 上一张方向（旧→新）
    enum Direction { case forward, backward }

    let assets: [AssetInfo]      // 调用方按 新→旧 排序
    let startId: String

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var index: Int = 0
    @State private var direction: Direction = .forward
    @State private var showDeleteConfirm = false

    // 缩放与拖动
    @State private var scale: CGFloat = 1
    @GestureState private var pinchScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @GestureState private var dragOffset: CGSize = .zero

    // 媒体内容与信息
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var dateText = ""
    @State private var metaLine = ""
    @State private var locationLine = ""
    @State private var cameraLine = ""

    init(assets: [AssetInfo], startId: String) {
        self.assets = assets
        self.startId = startId
        let startIndex = assets.firstIndex { $0.id == startId } ?? 0
        _index = State(initialValue: startIndex)
    }

    private var current: AssetInfo { assets[min(max(index, 0), assets.count - 1)] }
    private var isZoomed: Bool { scale * pinchScale > 1.05 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                topInfo
                GeometryReader { proxy in
                    ZStack {
                        Color.black
                        gestureArea
                            .frame(width: proxy.size.width, height: proxy.size.height)
                        statusBadge
                    }
                }
            }
            .background(Color.black.ignoresSafeArea(edges: .bottom))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.black, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar { toolbarContent }
            .task(id: current.id) { loadCurrent() }
            .confirmationDialog(
                "移入垃圾箱？",
                isPresented: $showDeleteConfirm,
                titleVisibility: .visible
            ) {
                Button("移入垃圾箱", role: .destructive) {
                    CleanupService.moveToTrash([current], state: appState)
                    move(direction)
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("照片将打上删除标记并记录到垃圾箱（右上角显示红色标志），可在垃圾箱中恢复或真正删除。")
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

    // MARK: - 右上角三按钮

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            NavigationLink {
                TrashView()
            } label: {
                Image(systemName: "trash")
                    .overlay(alignment: .topTrailing) { countBadge(appState.trashIds.count) }
            }
            NavigationLink {
                ProtectedView()
            } label: {
                Image(systemName: "hand.raised")
                    .overlay(alignment: .topTrailing) { countBadge(appState.protectedIds.count) }
            }
            NavigationLink {
                SettingsView()
            } label: {
                Image(systemName: "gearshape")
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

    // MARK: - 媒体内容（双指缩放 + 四向滑动）

    @ViewBuilder
    private var content: some View {
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
                .scaleEffect(scale * pinchScale)
                .offset(CGSize(width: panOffset.width + dragOffset.width,
                               height: panOffset.height + dragOffset.height))
                .clipped()
        } else {
            ProgressView().tint(.white)
        }
    }

    private var gestureArea: some View {
        content
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
                scale = scale > 1 ? 1 : 2
                panOffset = .zero
            }
            .clipped()
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
                // 上滑 = 移入垃圾箱（需确认）
                showDeleteConfirm = true
            } else {
                // 下滑 = 加入免删除
                markProtected()
            }
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
            index = next
        } else {
            dismiss()
        }
    }

    private func markProtected() {
        if !appState.isProtected(current.id) {
            CleanupService.toggleProtected([current.id], state: appState)
        }
        move(direction)
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
