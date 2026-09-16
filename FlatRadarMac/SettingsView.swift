import SwiftUI
import AppKit
import FlatRadarCore

/// 设置窗口（⌘,）。`FlatRadarMacApp` 里的 `Settings {}` 场景。
///
/// 为什么是独立场景而不是侧栏第五项
/// ------------------------------
/// docs/DESIGN.md §7.2 定的：Mac 上设置的位置就是应用菜单里的「Settings…」，
/// 用户按 ⌘, 找它，不会去侧栏里找。侧栏只放「看数据」的几屏。
///
/// 没有设计稿，按系统设置的样式做
/// ----------------------------
/// 分组表单（`.formStyle(.grouped)`）+ 顶部工具栏式的 tab。设置窗口是 Mac 用户最
/// 期待「长得像系统」的地方；其它几屏照 Claude Design 的稿子做，这一屏刻意不做。
///
/// 和 iOS `SettingsView` 的对照
/// ---------------------------
/// | iOS 区块 | Mac |
/// |---|---|
/// | Notification Filter | **Filters** tab |
/// | Appearance | **General** |
/// | Push Notifications | **Notifications** tab |
/// | Account（导出 / 改密码 / 登出 / 删号 / 访客转正） | **Account** tab |
/// | Legal / Send Feedback / 版本 | **General** |
/// | Face ID 登录 | 没做——Touch ID 在 Mac 上是新功能，不是移植 |
/// | Buy me a coffee | 没做——内购商品要先在 ASC 上对 macOS 开放 |
/// | Admin 工具 | 没做——DESIGN.md §7.3：网页端已有全套 |
/// | Rate FlatRadar | 没做——Mac 版还没上 Mac App Store，链接只能指到 iOS 的页面 |
struct SettingsView: View {

    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue

    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") {
                GeneralSettings()
            }
            Tab("Account", systemImage: "person.crop.circle") {
                AccountSettings()
            }
            Tab("Notifications", systemImage: "bell.badge") {
                NotificationSettings()
            }
            Tab("Filters", systemImage: "line.3.horizontal.decrease.circle") {
                FilterSettings()
            }
        }
        .frame(width: SettingsLayout.width)
        .task(id: appearance) { AppearancePreference(rawValue: appearance)?.apply() }
    }
}

/// 几个 tab 共用的尺寸。宽度统一——切 tab 时窗口只动高度，不左右跳。
enum SettingsLayout {
    static let width: CGFloat = 580
}

// MARK: - 外观

/// 浅色 / 深色 / 跟随系统。和 iOS 用同一个 key（`color_scheme`）和同一组取值。
///
/// 为什么设 `NSApp.appearance` 而不用 `.preferredColorScheme`
/// ------------------------------------------------------
/// `.preferredColorScheme` 只管它所在的那一个窗口：主窗口、设置窗口、弹窗各设
/// 各的，漏一个就是半边浅半边深。而且从「深色」切回「跟随系统」（传 nil）时，
/// macOS 上的窗口不一定会跟着恢复。`NSApp.appearance` 是整个 app 一处生效，
/// 设成 nil 就是跟随系统，语义正好对上。
enum AppearancePreference: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "color_scheme"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light:  "Light"
        case .dark:   "Dark"
        }
    }

    func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light:  NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:   NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {

    @Environment(AuthStore.self) private var auth
    @AppStorage(AppearancePreference.storageKey) private var appearance = AppearancePreference.system.rawValue

    @State private var legal: LegalSheet?
    @State private var showFeedback = false

    var body: some View {
        Form {
            Section("Appearance") {
                // 行名不能也叫 Appearance：分组标题已经是这个词，同一个词上下摞两遍。
                // 和 iOS 设置页同名。
                Picker("Color Scheme", selection: $appearance) {
                    ForEach(AppearancePreference.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
            }

            // 反馈接口要带 bearer（`POST /feedback` 是 authenticated），访客发不出去。
            // iOS 对访客也显示这个入口，点了会 401——这里不照抄。
            if auth.isUser {
                Section {
                    Button("Send Feedback…") { showFeedback = true }
                } header: {
                    Text("Support")
                } footer: {
                    Text("Suggestions and bug reports go straight to the developer.")
                }
            }

            // admin 是后端运维者，条款是他自己维护的，iOS 也不给他看这一段。
            if !auth.isAdmin {
                Section("Legal") {
                    Button("Terms of Use") { legal = .terms }
                    Button("Privacy Policy") { legal = .privacy }
                }
            }

            Section("About") {
                LabeledContent("Version", value: AppVersion.displayName)
            }
        }
        .formStyle(.grouped)
        .frame(height: 470)
        .sheet(item: $legal) { LegalView(kind: $0) }
        .sheet(isPresented: $showFeedback) { FeedbackSheet() }
    }
}

// MARK: - 反馈

/// 移植自 iOS `FeedbackView`：类型 + 正文，5–2000 字。
private struct FeedbackSheet: View {

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var kind = "suggestion"
    @State private var message = ""
    @State private var isSubmitting = false
    @State private var errorText: String?
    @State private var showSuccess = false

    private static let maxLength = 2000
    private static let minLength = 5

    private var trimmed: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool {
        trimmed.count >= Self.minLength && message.count <= Self.maxLength && !isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Send Feedback").font(.title3.weight(.semibold))

            Picker("Type", selection: $kind) {
                Text("Suggestion").tag("suggestion")
                Text("Bug Report").tag("bug")
                Text("Other").tag("other")
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextEditor(text: $message)
                .font(.body)
                .frame(height: 160)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))

            HStack {
                if let errorText {
                    Text(errorText).font(.callout).foregroundStyle(.red)
                }
                Spacer()
                Text("\(message.count)/\(Self.maxLength)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(message.count > Self.maxLength - 100 ? .red : .secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isSubmitting ? "Sending…" : "Send") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
            }
        }
        .padding(20)
        .frame(width: 460)
        .alert("Thank you!", isPresented: $showSuccess) {
            Button("Done") { dismiss() }
        } message: {
            Text("Your feedback has been submitted. I read every piece of feedback — it directly shapes what gets built next.")
        }
    }

    private func submit() async {
        guard canSend else { return }
        isSubmitting = true
        errorText = nil
        defer { isSubmitting = false }
        do {
            _ = try await APIClient.shared.submitFeedback(
                kind: kind, message: trimmed,
                userName: auth.userInfo?.name ?? "",
                appVersion: AppVersion.short)
            showSuccess = true
        } catch {
            errorText = error.localizedDescription
        }
    }
}
