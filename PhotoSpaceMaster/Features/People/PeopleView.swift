import SwiftUI

/// 人物模块：本地人脸聚类结果浏览。
/// 首次进入需扫描（Vision 人脸检测，大图库耗时较长，支持取消与进度显示），
/// 扫描结果持久化，之后进入直接展示。
struct PeopleView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore
    @ObservedObject private var store = PeopleStore.shared

    var body: some View {
        Group {
            switch store.phase {
            case .idle:
                idleView
            case .scanning:
                scanningView
            case .done:
                peopleGrid
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("人物")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if store.phase == .done {
                    Button {
                        store.startScan(assets: library.assets, excludeTrashed: appState.trashIds)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("重新扫描")
                }
            }
        }
    }

    // MARK: - 未扫描

    private var idleView: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text("按人物浏览照片")
                .font(.headline)
            Text("将在本地识别照片中的人脸并自动归类为人物（不联网、不上传）。照片较多时扫描需要一些时间。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                store.startScan(assets: library.assets, excludeTrashed: appState.trashIds)
            } label: {
                Label("开始扫描", systemImage: "sparkle.magnifyingglass")
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 扫描中

    private var scanningView: some View {
        VStack(spacing: 14) {
            ProgressView(value: store.progress)
                .progressViewStyle(.linear)
                .padding(.horizontal, 48)
            Text("正在识别人脸… \(Int(store.progress * 100))%")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Button("取消") { store.cancelScan() }
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 人物网格

    private var peopleGrid: some View {
        ScrollView {
            if store.people.isEmpty {
                Text("没有在照片中识别到人脸")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 90), spacing: 16)], spacing: 20) {
                    ForEach(store.people) { person in
                        NavigationLink {
                            PersonAssetsView(person: person)
                        } label: {
                            VStack(spacing: 6) {
                                PersonFace(person: person, size: 84)
                                Text("人物 \((store.people.firstIndex(where: { $0.id == person.id }) ?? 0) + 1)")
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                                Text("\(person.assetIds.count) 张")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
            }
        }
    }
}

/// 人物圆形头像（按需生成并缓存）
struct PersonFace: View {
    let person: PeopleStore.Person
    var size: CGFloat = 84

    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color(.systemGray5))
                    ProgressView()
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: person.id) {
            image = await PeopleStore.shared.faceImage(for: person)
        }
    }
}

/// 人物照片网格：复用共用网格组件（多选、移入垃圾箱、加免删除、评分）
struct PersonAssetsView: View {
    let person: PeopleStore.Person

    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var ratings: RatingService

    @State private var assets: [AssetInfo] = []
    @State private var selection = Set<String>()
    @State private var isSelecting = false
    @State private var viewingAsset: AssetInfo?

    var body: some View {
        PhotoGridView(
            assets: assets,
            selection: $selection,
            isSelecting: $isSelecting,
            makeMenu: { CommonAssetMenu.make(for: $0, appState: appState, ratings: ratings) },
            onOpenAsset: { viewingAsset = $0 },
            bottomBar: { bottomBar }
        )
        .navigationTitle("人物")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .fullScreenCover(item: $viewingAsset) { asset in
            NavigationStack {
                PhotoDetailView(assets: assets, startId: asset.id)
            }
        }
    }

    private func reload() {
        let ids = Set(person.assetIds)
        assets = library.assets
            .filter { ids.contains($0.id) && !appState.trashIds.contains($0.id) }
            .sorted { ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast) }
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if isSelecting {
                Button {
                    selection = Set(assets.map(\.id)).symmetricDifference(selection)
                } label: {
                    Label("反选", systemImage: "circle.lefthalf.filled")
                }
                Button {
                    let targets = assets.filter { selection.contains($0.id) }
                    CleanupService.moveToTrash(targets, state: appState)
                    reload()
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
                Text("\(assets.count) 张 · 长按开始多选")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }
}
