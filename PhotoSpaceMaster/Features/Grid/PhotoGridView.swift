import SwiftUI

/// 共用网格组件：所有列表页（首页 / 相册 / 清理列表 / 垃圾箱 / 免删除）复用。
/// - LazyVGrid 自适应列 + 分页加载（每页 120 项）
/// - 多选模式：长按进入，点击选中/取消
/// - 底部操作栏由各页面通过闭包注入，保证交互一致
struct PhotoGridView<BottomBar: View>: View {
    private let columns = [GridItem(.adaptive(minimum: 104), spacing: 2)]
    private let pageSize = 120

    let assets: [AssetInfo]
    var onCellAppear: ((AssetInfo) -> Void)? = nil
    var makeMenu: ((AssetInfo) -> AnyView)? = nil

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
        @ViewBuilder bottomBar: @escaping () -> BottomBar
    ) {
        self.assets = assets
        self._selection = selection
        self._isSelecting = isSelecting
        self.onCellAppear = onCellAppear
        self.makeMenu = makeMenu
        self.bottomBar = bottomBar
    }

    private var displayed: [AssetInfo] { Array(assets.prefix(visibleCount)) }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(displayed) { info in
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
                        .id(info.id)
                        .onAppear {
                            onCellAppear?(info)
                            if info.id == displayed.last?.id, visibleCount < assets.count {
                                visibleCount += pageSize
                            }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.bottom, 12)

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
        guard isSelecting else { return }
        if selection.contains(info.id) {
            selection.remove(info.id)
        } else {
            selection.insert(info.id)
        }
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

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Rectangle().fill(Color(.systemGray5))

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
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .onLongPressGesture(minimumDuration: 0.35, perform: onLongPress)
        .contextMenu {
            if let menu { menu }
        }
        .task(id: info.id) {
            image = await ThumbnailManager.shared.thumbnail(for: info, side: 150)
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
