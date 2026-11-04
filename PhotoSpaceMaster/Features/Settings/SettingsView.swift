import SwiftUI

/// 设置：主题 / 语言 / 浏览行为 / 恢复默认
struct SettingsView: View {
    @EnvironmentObject private var appState: AppState
    @State private var showResetConfirm = false
    @State private var showUpdateAlert = false

    static let appVersion = "V2026.1103"

    var body: some View {
        Form {
            Section("主题") {
                Picker(selection: $appState.settings.theme) {
                    ForEach(ThemeMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                } label: {
                    Label("外观", systemImage: "paintpalette")
                }
            }

            Section {
                Picker(selection: $appState.settings.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                } label: {
                    Label("语言", systemImage: "globe")
                }
            } footer: {
                Text("默认跟随系统。当前界面文案仅提供简体中文，切换语言会影响系统组件（日期选择器、系统菜单等）的显示语言。")
            }

            Section {
                Toggle(isOn: $appState.settings.skipProtectedItems) {
                    Label("自动跳过免删除项目", systemImage: "forward.end")
                }
                Toggle(isOn: $appState.settings.skipTrashedItems) {
                    Label("自动跳过已加入垃圾箱的项目", systemImage: "trash.slash")
                }
            } header: {
                Text("浏览")
            } footer: {
                Text("自「筛选」面板迁入，与原有的「跳过免删除项目」为同一开关，已合并去重。开启后，大图查看的上一张/下一张与标记后的自动前进会跳过对应项目；「自动跳过免删除项目」同时作用于批量删除（自动排除免删除项）。排序与首页显示方式仍在「筛选」面板中设置。")
            }

            Section {
                Button(role: .destructive) {
                    showResetConfirm = true
                } label: {
                    Label("恢复默认设置", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
            }

            Section("关于") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("所有数据处理均在本地完成，不会上传任何照片")
                        .font(.footnote.weight(.semibold))
                        .foregroundColor(.red)

                    HStack {
                        Text(Self.appVersion)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("检查更新") {
                            showUpdateAlert = true
                        }
                        .font(.footnote)
                    }

                    HStack {
                        Text("邮箱")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("386047639@qq.com")
                            .textSelection(.enabled)
                    }
                    HStack {
                        Text("微信")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("graphite1")
                            .textSelection(.enabled)
                    }
                    Text("京ICP备XXXXXXX号")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("检查更新", isPresented: $showUpdateAlert) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("当前已是最新版本 \(Self.appVersion)")
        }
        .confirmationDialog(
            "确定恢复默认设置吗？主题、排序、定位、开关等全部项目将被重置。",
            isPresented: $showResetConfirm,
            titleVisibility: .visible
        ) {
            Button("恢复默认", role: .destructive) {
                appState.settings.resetToDefaults()
            }
            Button("取消", role: .cancel) {}
        }
    }
}
