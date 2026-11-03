import SwiftUI

/// 相似/重复照片清理页：
/// - 右上角：垃圾箱 / 免打扰项目 / 设置入口
/// - 顶部筛选：类型（图片/视频/Live）、相似度（比较像/非常像/重复）、自动选择规则
/// - 下方按相似组展示：每组头部有「全部标记删除」「自动选择」按钮
/// - 点击照片 = 标记删除（仍走垃圾箱，不直接删除）
/// - 底部：批量处理（10/20/50/100/全部组，按自动选择规则标记）+ 移入垃圾箱
struct SimilarPhotosView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var store = SimilarityStore.shared

    /// 自动选择规则：组内保留符合条件的一张，其余标记删除
    enum KeepRule: String, CaseIterable, Identifiable {
        case largest, smallest, newest
        var id: String { rawValue }
        var title: String {
            switch self {
            case .largest: return "最大文件"
            case .smallest: return "最小文件"
            case .newest: return "最新文件"
            }
        }
    }

    /// 相似度级别
    enum SimLevel: String, CaseIterable, Identifiable {
        case similar, verySimilar, duplicate
        var id: String { rawValue }
        var title: String {
            switch self {
            case .similar: return "比较像"
            case .verySimilar: return "非常像"
            case .duplicate: return "重复"
            }
        }
        var threshold: Int {
            switch self {
            case .similar: return SimilarityStore.similarThreshold
            case .verySimilar: return SimilarityStore.verySimilarThreshold
            case .duplicate: return SimilarityStore.duplicateThreshold
            }
        }
    }

    private enum TypeChip: String, CaseIterable, Identifiable {
        case photo, screenshot, video, live
        var id: String { rawValue }
        var title: String {
            switch self {
            case .photo: return "图片"
            case .screenshot: return "截图"
            case .video: return "视频"
            case .live: return "Live"
            }
        }
    }

    @State private var selectedTypes: Set<TypeChip> = [.photo, .screenshot, .video, .live]
    @State private var selectedLevels: Set<SimLevel> = [.duplicate, .verySimilar, .similar]
    @State private var keepRule: KeepRule = .largest
    /// 标记删除的 asset id
    @State private var marked = Set<String>()
    @State private var groups: [[AssetInfo]] = []
    @State private var groupIndexById: [String: Int] = [:]
    /// 当前已应用的批量选项（nil = 未选择；-1 = 全部组）；初始灰色，选择后变蓝
    @State private var appliedBatch: Int?

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            content
        }
        .navigationTitle("相似照片清理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { entryToolbarButtons }
        .onAppear {
            store.scanIfNeeded(assets: scanPool)
            rebuildGroups()
        }
        .onChange(of: selectedTypes) { _ in rebuildGroups() }
        .onChange(of: selectedLevels) { _ in rebuildGroups() }
        .onChange(of: store.phase) { _ in rebuildGroups() }
        .onChange(of: store.stats) { _ in rebuildGroups() }
        .onChange(of: appState.trashIds) { _ in rebuildGroups() }
    }

    // MARK: - 数据

    /// 扫描池：全部照片（排除已入垃圾箱），哈希缓存跨类型复用
    private var scanPool: [AssetInfo] {
        library.assets.filter { !appState.trashIds.contains($0.id) }
    }

    /// 当前类型筛选下的候选
    private var candidates: [AssetInfo] {
        scanPool.filter { typeMatches($0) }
    }

    private func typeMatches(_ info: AssetInfo) -> Bool {
        if info.kind == .video { return selectedTypes.contains(.video) }
        if info.kind == .screenshot { return selectedTypes.contains(.screenshot) }
        if info.isLivePhoto { return selectedTypes.contains(.live) }
        return selectedTypes.contains(.photo)
    }

    private func rebuildGroups() {
        guard store.phase == .done else { return }
        let threshold = selectedLevels.map(\.threshold).max() ?? SimLevel.similar.threshold
        groups = store.groups(for: candidates, threshold: threshold)
        var indexById: [String: Int] = [:]
        for (i, group) in groups.enumerated() {
            for info in group { indexById[info.id] = i }
        }
        groupIndexById = indexById
        let valid = Set(indexById.keys)
        marked.formIntersection(valid)
    }

    // MARK: - 顶部筛选

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            chipRow(title: "类型") {
                ForEach(TypeChip.allCases) { chip in
                    FilterChip(
                        title: chip.title,
                        isOn: Binding(
                            get: { selectedTypes.contains(chip) },
                            set: { on in
                                if on { selectedTypes.insert(chip) } else { selectedTypes.remove(chip) }
                            }
                        )
                    )
                }
            }
            chipRow(title: "相似度") {
                ForEach(SimLevel.allCases) { level in
                    FilterChip(
                        title: level.title,
                        isOn: Binding(
                            get: { selectedLevels.contains(level) },
                            set: { on in
                                if on { selectedLevels.insert(level) } else { selectedLevels.remove(level) }
                            }
                        )
                    )
                }
            }
            chipRow(title: "自动选择") {
                ForEach(KeepRule.allCases) { rule in
                    FilterChip(
                        title: rule.title,
                        isOn: Binding(
                            get: { keepRule == rule },
                            set: { if $0 { keepRule = rule } }
                        )
                    )
                }
            }
            Text("自动选择 = 每组保留所选条件的一张，其余标记删除")
                .font(.caption2)
                .foregroundColor(.secondary)
                .padding(.horizontal, 16)
        }
        .padding(.vertical, 8)
    }

    private func chipRow<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.footnote.weight(.medium))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            FlowLayout(spacing: 6) { content() }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if store.phase == .scanning {
            VStack(spacing: 12) {
                ProgressView(value: store.progress)
                    .frame(maxWidth: 260)
                Text("正在计算照片特征… \(Int(store.progress * 100))%")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if groups.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
                Text("未发现相似或重复照片")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            similarGrid
        }
    }

    /// 相似分组网格（独立属性，降低 body 的类型检查复杂度）
    private var similarGrid: some View {
        PhotoGridView(
            assets: groups.flatMap { $0 },
            selection: $marked,
            isSelecting: .constant(true),
            makeSectionTitle: { info in
                groupIndexById[info.id].map { "组\($0)" }
            },
            makeSectionHeader: { title, count, bytes, _ in
                groupHeader(for: title, count: count, bytes: bytes)
            },
            bottomBar: { batchBar }
        )
    }

    private func groupHeader(for title: String, count: Int, bytes: Int64) -> AnyView {
        let index = Int(title.dropFirst()) ?? 0
        guard groups.indices.contains(index) else { return AnyView(EmptyView()) }
        return AnyView(self.groupHeader(groups[index], index: index, count: count, bytes: bytes))
    }

    private func groupHeader(_ group: [AssetInfo], index: Int, count: Int, bytes: Int64) -> some View {
        HStack(spacing: 12) {
            Text("第 \(index + 1) 组 · \(count) 张 · \(ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file))")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                autoSelect(group)
            } label: {
                Text("自动选择")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))
            }
            Button {
                group.forEach { marked.insert($0.id) }
            } label: {
                Text("全部标记删除")
                    .font(.footnote.weight(.medium))
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.red.opacity(0.12)))
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 标记逻辑

    /// 自动选择：按保留规则留一张，其余标记
    private func autoSelect(_ group: [AssetInfo]) {
        guard let keep = keepIndex(in: group) else { return }
        for (i, info) in group.enumerated() where i != keep {
            marked.insert(info.id)
        }
        marked.remove(group[keep].id)
    }

    private func keepIndex(in group: [AssetInfo]) -> Int? {
        switch keepRule {
        case .largest:
            return group.indices.max { group[$0].byteSize < group[$1].byteSize }
        case .smallest:
            return group.indices.min { group[$0].byteSize < group[$1].byteSize }
        case .newest:
            return group.indices.max {
                (group[$0].creationDate ?? .distantPast) < (group[$1].creationDate ?? .distantPast)
            }
        }
    }

    // MARK: - 底部：批量处理 + 移入垃圾箱

    private var batchBar: some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Text("批量处理")
                        .font(.footnote.weight(.medium))
                        .foregroundColor(.secondary)
                    ForEach([10, 20, 50, 100], id: \.self) { n in
                        batchButton(title: "\(n) 组", tag: n, enabled: groups.count >= n)
                    }
                    batchButton(title: "全部组", tag: -1, enabled: !groups.isEmpty)
                }
                .padding(.horizontal, 12)
            }
            HStack {
                Button {
                    marked.removeAll()
                    appliedBatch = nil
                } label: {
                    Text("清除标记")
                        .font(.footnote)
                }
                .disabled(marked.isEmpty)
                Spacer()
                Button {
                    moveToTrash()
                } label: {
                    Label("移入垃圾箱 \(marked.count)", systemImage: "trash")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .disabled(marked.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .padding(.top, 8)
        .background(.bar)
    }

    /// 批量按钮：初始灰色，点击应用后变为蓝色（当前应用项高亮）
    private func batchButton(title: String, tag: Int, enabled: Bool) -> some View {
        let isActive = appliedBatch == tag
        return Button {
            autoSelectGroups(tag == -1 ? nil : tag)
        } label: {
            Text(title)
                .font(.footnote.weight(.medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(isActive ? Color.accentColor.opacity(0.15) : Color(.secondarySystemFill)))
                .foregroundColor(isActive ? .accentColor : .secondary)
        }
        .disabled(!enabled)
    }

    /// 对前 N 组（nil = 全部组）应用自动选择规则
    private func autoSelectGroups(_ count: Int?) {
        marked.removeAll()
        let target = count.map { Array(groups.prefix($0)) } ?? groups
        for group in target {
            autoSelect(group)
        }
        appliedBatch = (count == nil) ? -1 : count
    }

    private func moveToTrash() {
        let targets = groups.flatMap { $0 }.filter { marked.contains($0.id) }
        guard !targets.isEmpty else { return }
        CleanupService.moveToTrash(targets, state: appState)
        marked.removeAll()
        appliedBatch = nil
        rebuildGroups()
    }
}
