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
    @State private var initialScrollDone = false
    @State private var dayGroups: [DayGroup] = []

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

    var body: some View {
        ScrollViewReader { proxy in
            PhotoGridView(
                assets: flatAssets,
                selection: $selection,
                isSelecting: $isSelecting,
                makeMenu: { menu(for: $0) },
                onOpenAsset: { info in
                    // 「定位到上次操作位置」在打开照片时记录，避免滚动期间高频写入引发全局刷新
                    if appState.settings.lastViewedAssetId != info.id {
                        appState.settings.lastViewedAssetId = info.id
                    }
                    viewingAsset = info
                },
                makeSectionTitle: sectionTitle,
                makeSectionHeader: dayHeader,
                bottomBar: { homeBottomBar }
            )
            .navigationTitle("相册空间大师")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        showFilter = true
                    } label: {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .overlay(alignment: .topTrailing) {
                                if appState.filter.hasActiveConditions {
                                    Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                                        .offset(x: 3, y: -3)
                                }
                            }
                    }
                    .accessibilityLabel("筛选")

                    NavigationLink {
                        TrashView()
                    } label: {
                        Image(systemName: "trash")
                            .overlay(alignment: .topTrailing) {
                                if appState.trashIds.count > 0 {
                                    Text("\(appState.trashIds.count)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Circle().fill(.red))
                                        .offset(x: 8, y: -8)
                                }
                            }
                    }
                    .accessibilityLabel("垃圾箱")

                    NavigationLink {
                        ProtectedView()
                    } label: {
                        Image(systemName: "hand.raised")
                            .overlay(alignment: .topTrailing) {
                                if appState.protectedIds.count > 0 {
                                    Text("\(appState.protectedIds.count)")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundColor(.white)
                                        .padding(3)
                                        .background(Circle().fill(.green))
                                        .offset(x: 8, y: -8)
                                }
                            }
                    }
                    .accessibilityLabel("免删除项目")

                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("设置")
                }
            }
            .sheet(isPresented: $showFilter, onDismiss: { rebuildGroups() }) { FilterPanelView() }
            .fullScreenCover(item: $viewingAsset) { asset in
                NavigationStack {
                    PhotoDetailView(assets: flatAssets, startId: asset.id)
                }
            }
            .onAppear {
                rebuildGroups()
                guard !initialScrollDone,
                      appState.settings.resumeToLastPosition,
                      !appState.settings.lastViewedAssetId.isEmpty else { return }
                initialScrollDone = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    proxy.scrollTo(appState.settings.lastViewedAssetId, anchor: .top)
                }
            }
            .onChange(of: library.assets.count) { _ in rebuildGroups() }
            .onChange(of: appState.filter) { _ in rebuildGroups() }
            .onChange(of: appState.settings.sortOrder) { _ in rebuildGroups() }
            .onChange(of: appState.settings.homeLayout) { _ in rebuildGroups() }
            .onReceive(ratings.objectWillChange) { _ in rebuildGroups() }
        }
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
                Text("\(flatAssets.count) 张照片 · 长按开始多选")
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
            if !locationText.isEmpty {
                Text(locationText)
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
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
