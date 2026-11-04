import SwiftUI

/// 首页（相册时间线）：按拍摄日期分组、从新到旧；分组头为 iOS 相册「日」视图风格
/// （大字日期 + 星期 + 数量/大小 + 地点）；右上角 4 入口；长按进入多选。
/// 性能：分组结果缓存在 @State，仅在数据/筛选/排序变化时重建，滚动期间零重算。
struct HomeTimelineView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var ratings: RatingService

    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var showFilter = false
    @State private var viewingAsset: AssetInfo?
    @State private var dayGroups: [DayGroup] = []
    // 双指捏合调整缩略图大小的实时倍率（松手后持久化到设置）
    @State private var livePinch: CGFloat = 1
    /// 是否正在双指缩放：缩放中网格按连续边长排版（跟手），松手后回到整齐网格
    @State private var isPinching = false
    /// 网格可用宽度（由 PhotoGridView 回传，松手吸附时用来算「正好铺满」的边长）
    @State private var gridWidth: CGFloat = 0
    // 定位书签跳转（配合 PhotoGridView 的 jumpToId / jumpToken）
    @State private var jumpTargetId: String?
    @State private var jumpToken = 0
    // 最近一次从网格打开的照片（仅在「转到定位」打开书签后返回时用于定位）
    @State private var lastOpenedId: String?
    /// 本次打开的查看器是否由「转到定位」触发：只有它才在关闭后回跳定位位置，
    /// 普通点击浏览返回时保持网格原有滚动位置，不做任何跳转
    @State private var jumpOnDismiss = false
    /// 跨页定位请求：从「按占用空间排序」等页面跳过来时首页可能还没切到前台，
    /// 先挂起，等首页可见、布局就绪后再执行
    private enum JumpRequest { case period }
    @State private var pendingJump: JumpRequest?

    private struct DayGroup: Identifiable {
        let id: Date
        let title: String
        var assets: [AssetInfo]
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    private var flatAssets: [AssetInfo] { dayGroups.flatMap(\.assets) }

    /// 重建分组（只在数据 / 筛选 / 排序 / 评分变化时调用，不在 body 里计算）
    private func rebuildGroups() {
        let calendar = Calendar.current
        let filtered = library.filteredAssets(state: appState, ratings: ratings)
        var buckets: [Date: [AssetInfo]] = [:]
        var order: [Date] = []
        for asset in filtered {
            let day = calendar.startOfDay(for: asset.creationDate ?? .distantPast)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(asset)
        }
        dayGroups = order.map { day in
            DayGroup(id: day, title: Self.dateFormatter.string(from: day), assets: buckets[day] ?? [])
        }
    }

    /// 缩略图基准最小边长（统一方块 = 原生相册式大方块）
    private var baseCellMin: CGFloat {
        appState.settings.homeLayout == .unified ? 124 : 104
    }

    /// 缩放上限对应的边长：最大档 = 单列铺满（一张照片占满整行），
    /// 是个「干净」档位，所以捏合到顶再往回捏不会有死区
    private var maxCellSide: CGFloat {
        gridWidth > 0 ? gridWidth : baseCellMin * 2.2
    }

    /// 实际生效的边长 = 基准 × 持久化缩放 × 捏合实时倍率（捏合过程中逐帧变化）
    private var effectiveCellMin: CGFloat {
        let scale = appState.settings.thumbnailScale * livePinch
        return min(maxCellSide, max(baseCellMin * 0.6, baseCellMin * scale))
    }

    /// 松手吸附：把当前连续边长吸附到「该列数正好铺满容器」的边长再持久化。
    /// 这一步只改几个点，但能让网格从「最后一列被裁一半」变回整齐排列。
    private func commitPinch(_ value: CGFloat) {
        let raw = min(maxCellSide,
                      max(baseCellMin * 0.6, baseCellMin * appState.settings.thumbnailScale * value))
        let side = gridWidth > 0 ? GridMetrics.snappedSide(raw, width: gridWidth) : raw
        isPinching = false
        livePinch = 1
        appState.settings.thumbnailScale = min(4, max(0.6, side / baseCellMin))
    }

    var body: some View {
        PhotoGridView(
            assets: flatAssets,
            selection: $selection,
            isSelecting: $isSelecting,
            cellMinSize: effectiveCellMin,
            isLiveZooming: isPinching,
            onWidthChange: { gridWidth = $0 },
            makeMenu: { menu(for: $0) },
            onOpenAsset: {
                lastOpenedId = $0.id
                jumpOnDismiss = false
                viewingAsset = $0
            },
            makeSectionTitle: sectionTitle,
            makeSectionHeader: dayHeader,
            jumpToId: jumpTargetId,
            jumpToken: jumpToken,
            bottomBar: { homeBottomBar }
        )
            // 双指捏合连续缩放（模仿苹果相册）：
            // 捏合中按连续边长跟手，松手吸附到「正好铺满」的边长再持久化
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { value in
                        if !isPinching {
                            // 进入缩放前先把当前倍率归一到「正好铺满」的档位，
                            // 保证跟手起点与静止画面完全一致，否则一上手会先跳一下
                            if gridWidth > 0 {
                                let clean = GridMetrics.snappedSide(baseCellMin * appState.settings.thumbnailScale,
                                                                    width: gridWidth)
                                appState.settings.thumbnailScale = min(4, max(0.6, clean / baseCellMin))
                            }
                            isPinching = true
                        }
                        livePinch = value
                    }
                    .onEnded { value in
                        commitPinch(value)
                    }
            )
            .navigationTitle("相册空间大师")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        openBookmark()
                    } label: {
                        Image(systemName: "scope")
                            .foregroundColor(.primary)
                    }
                    .disabled(appState.settings.bookmarkAssetId.isEmpty)
                    .accessibilityLabel("转到定位")

                    Button {
                        showFilter = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .foregroundColor(.primary)
                            .overlay(alignment: .topTrailing) {
                                if appState.filter.hasActiveConditions {
                                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                                        .offset(x: 3, y: -3)
                                }
                            }
                    }
                    .accessibilityLabel("筛选")

                    TrashEntryButton()
                    ProtectedEntryButton()
                    SettingsEntryButton()
                }
            }
            .sheet(isPresented: $showFilter, onDismiss: { rebuildGroups() }) { FilterPanelView() }
            .fullScreenCover(item: $viewingAsset, onDismiss: {
                // 仅「转到定位」打开书签照片后返回时才定位到它的网格位置；
                // 普通浏览返回不触发跳转，网格保持原有滚动位置
                guard jumpOnDismiss, let id = lastOpenedId else { return }
                jumpOnDismiss = false
                locateInGrid(id)
            }) { asset in
                NavigationStack {
                    PhotoDetailView(assets: flatAssets, startId: asset.id)
                }
            }
            .onAppear(perform: rebuildGroups)
            .onChange(of: appState.bookmarkJumpToken) { _ in openBookmark() }
            // 从「按日期占用」等页面跳转过来：此时可能正在切 Tab，首页尚未完成布局，
            // 直接滚动会丢位置，所以先挂起，等首页可见后再定位
            .onChange(of: appState.homeJumpToken) { _ in
                pendingJump = .period
                schedulePendingJump()
            }
            .onChange(of: appState.selectedTab) { tab in
                guard tab == .home else { return }
                schedulePendingJump()
            }
            .onChange(of: library.assets.count) { _ in rebuildGroups() }
            .onChange(of: appState.filter) { _ in rebuildGroups() }
            .onChange(of: appState.settings.sortOrder) { _ in rebuildGroups() }
            .onChange(of: appState.settings.homeLayout) { _ in rebuildGroups() }
            .onReceive(ratings.objectWillChange) { _ in rebuildGroups() }
    }

    // MARK: - 转到定位

    /// 打开书签照片；关闭查看器后会自动定位到它的网格位置。
    /// 书签被筛选条件排除时退回为网格定位。
    private func openBookmark() {
        let bookmarkId = appState.settings.bookmarkAssetId
        guard !bookmarkId.isEmpty else { return }
        if let info = flatAssets.first(where: { $0.id == bookmarkId }) {
            lastOpenedId = info.id
            jumpOnDismiss = true
            viewingAsset = info
        } else {
            locateInGrid(bookmarkId)
        }
    }

    /// 定位到网格中的某个项目（书签 / 关闭查看器后回跳）：
    /// 立即滚一次，稍后再补一次——深跳转时首次 scrollTo 常落在估算位置，
    /// 第二次在已稳定的布局上执行就能对准（等价于用户「再点一次」）
    private func locateInGrid(_ id: String) {
        jumpTargetId = id
        jumpToken += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard jumpTargetId == id else { return }
            jumpToken += 1
        }
    }

    // MARK: - 跨页日期定位

    /// 挂起的定位请求延后执行：从统计页点「定位」时会连带切 Tab，
    /// 过渡动画期间滚动视图还没完成布局，这时 scrollTo 会丢位置，
    /// 表现为「第一次定位偏、再点一次才对」。
    private func schedulePendingJump() {
        guard pendingJump != nil else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            performPendingJump()
        }
    }

    private func performPendingJump() {
        guard pendingJump != nil, appState.selectedTab == .home else { return }
        pendingJump = nil
        rebuildGroups()
        DispatchQueue.main.async { jumpToAppointedDate() }
        // 二次定位：与用户「再点一次」等效，用稳定后的布局修正首次滚动的偏差
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) {
            guard appState.selectedTab == .home else { return }
            jumpToAppointedDate()
        }
    }

    /// 定位到指定时间周期（年/月/日）内的照片：
    /// 优先取周期内最新的一张（在「从新到旧」的首页分组里位于该组顶部）；
    /// 周期内没有照片时，取周期开始前最近的一张，再不行取周期结束后最近的一张。
    private func jumpToAppointedDate() {
        guard let start = appState.homeJumpStart, let end = appState.homeJumpEnd else { return }
        guard !flatAssets.isEmpty else { return }

        let date: (AssetInfo) -> Date = { $0.creationDate ?? .distantPast }
        let inRange = flatAssets.filter { date($0) >= start && date($0) < end }
        let target: AssetInfo?
        if let newest = inRange.max(by: { date($0) < date($1) }) {
            target = newest
        } else {
            let before = flatAssets.filter { date($0) < start }.max(by: { date($0) < date($1) })
            let after = flatAssets.filter { date($0) >= end }.min(by: { date($0) < date($1) })
            target = before ?? after
        }
        guard let info = target else { return }

        jumpTargetId = info.id
        jumpToken += 1
    }

    // MARK: - 分组头（iOS 相册「日」视图风格：大字日期 + 星期 + 数量/大小 + 地点）

    /// 分组依据：按日期分组时返回日期文字；平铺显示时返回 nil
    private var sectionTitle: ((AssetInfo) -> String?)? {
        guard appState.settings.homeLayout == .byDate else { return nil }
        return { info in
            guard let date = info.creationDate else { return nil }
            return Self.dateFormatter.string(from: Calendar.current.startOfDay(for: date))
        }
    }

    private func dayHeader(_ title: String, _ count: Int, _ bytes: Int64, _ first: AssetInfo?) -> AnyView {
        AnyView(
            DayHeaderView(
                title: title,
                weekday: first?.creationDate.map(Self.weekdayFormatter.string(from:)) ?? "",
                count: count,
                sizeText: ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file),
                asset: first
            )
        )
    }

    // MARK: - 底部操作栏

    private var homeBottomBar: some View {
        HStack(spacing: 16) {
            if isSelecting {
                Button {
                    selection = Set(flatAssets.map(\.id)).symmetricDifference(selection)
                } label: {
                    Label("反选", systemImage: "circle.lefthalf.filled")
                }
                Button {
                    let targets = flatAssets.filter { selection.contains($0.id) }
                    CleanupService.moveToTrash(targets, state: appState)
                    selection.removeAll()
                } label: {
                    Label("移入垃圾箱 \(selection.count)", systemImage: "trash")
                }
                .disabled(selection.isEmpty)
                Button {
                    CleanupService.toggleProtected(Array(selection), state: appState)
                    selection.removeAll()
                } label: {
                    Label("加免删除", systemImage: "hand.raised")
                }
                .disabled(selection.isEmpty)
            } else {
                Text("\(flatAssets.count) 张照片 · 长按多选 · 双指捏合调整大小")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    // MARK: - 单元格长按菜单（评分打星入口 + 免删除 + 移入垃圾箱）

    private func menu(for info: AssetInfo) -> AnyView {
        AnyView(
            Group {
                ForEach(1...5, id: \.self) { stars in
                    Button {
                        ratings.setRating(stars, for: info.id)
                    } label: {
                        Label("评 \(stars) 星", systemImage: "star.fill")
                    }
                }
                if (ratings.ratings[info.id] ?? 0) > 0 {
                    Button(role: .destructive) {
                        ratings.removeRating(for: info.id)
                    } label: {
                        Label("取消评分", systemImage: "star.slash")
                    }
                }
                Divider()
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
            }
        )
    }
}

// MARK: - 日分组头视图

/// 仿 iOS 相册「日」视图的分组头：大字日期 + 星期 + 数量/大小，下方显示地点（异步反地理编码，带缓存）
private struct DayHeaderView: View {
    let title: String
    let weekday: String
    let count: Int
    let sizeText: String
    let asset: AssetInfo?

    @State private var locationText = ""

    /// 地点文案缓存（asset id → 地点），避免滚动时反复反地理编码
    private static let locationCache = NSCache<NSString, NSString>()

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title)
                    .font(.title2.weight(.bold))
                if !weekday.isEmpty {
                    Text(weekday)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Text("\(count) / \(sizeText)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Image(systemName: "ellipsis")
                    .font(.subheadline.weight(.bold))
                    .foregroundColor(.secondary)
            }
            // 地点是异步反地理编码出来的：若按「有值才显示」，这一行出现时
            // 分组头会变高，下方整组缩略图会整体往下窜一下。用空格占位保持高度恒定。
            Text(locationText.isEmpty ? " " : locationText)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.top, 18)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: asset?.id) {
            guard let asset else { return }
            if let cached = Self.locationCache.object(forKey: asset.id as NSString) {
                locationText = cached as String
                return
            }
            locationText = ""
            guard let text = await AssetDetailProvider.shared.locationText(for: asset), !text.isEmpty else { return }
            Self.locationCache.setObject(text as NSString, forKey: asset.id as NSString)
            locationText = text
        }
    }
}
