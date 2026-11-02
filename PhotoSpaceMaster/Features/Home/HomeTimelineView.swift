import SwiftUI

/// 首页（相册时间线）：按拍摄日期分组、从新到旧；右上角 4 入口；长按进入多选。
struct HomeTimelineView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var ratings: RatingService

    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var showFilter = false
    @State private var initialScrollDone = false

    private struct DayGroup: Identifiable {
        let id: Date
        let title: String
        let assets: [AssetInfo]
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日"
        formatter.locale = Locale(identifier: "zh_CN")
        return formatter
    }()

    private var groups: [DayGroup] {
        let calendar = Calendar.current
        let filtered = library.filteredAssets(state: appState, ratings: ratings)
        var buckets: [Date: [AssetInfo]] = [:]
        for asset in filtered {
            let day = calendar.startOfDay(for: asset.creationDate ?? .distantPast)
            buckets[day, default: []].append(asset)
        }
        let ascending = appState.settings.sortOrder == .ascending
        return buckets
            .sorted { ascending ? $0.key < $1.key : $0.key > $1.key }
            .map {
                DayGroup(id: $0.key, title: Self.dateFormatter.string(from: $0.key), assets: $0.value)
            }
    }

    var body: some View {
        ScrollViewReader { proxy in
            PhotoGridView(
                assets: groups.flatMap(\.assets),
                selection: $selection,
                isSelecting: $isSelecting,
                onCellAppear: { info in
                    if appState.settings.lastViewedAssetId != info.id {
                        appState.settings.lastViewedAssetId = info.id
                    }
                },
                makeMenu: { menu(for: $0) },
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
            .sheet(isPresented: $showFilter) { FilterPanelView() }
            .onAppear {
                guard !initialScrollDone,
                      appState.settings.resumeToLastPosition,
                      !appState.settings.lastViewedAssetId.isEmpty else { return }
                initialScrollDone = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    proxy.scrollTo(appState.settings.lastViewedAssetId, anchor: .top)
                }
            }
        }
    }

    // MARK: - 底部操作栏

    private var homeBottomBar: some View {
        HStack(spacing: 16) {
            if isSelecting {
                Button {
                    selection = Set(groups.flatMap(\.assets).map(\.id)).symmetricDifference(selection)
                } label: {
                    Label("反选", systemImage: "circle.lefthalf.filled")
                }
                Button {
                    let targets = groups.flatMap(\.assets).filter { selection.contains($0.id) }
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
                Text("\(groups.reduce(0) { $0 + $1.assets.count }) 张照片 · 长按开始多选")
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
