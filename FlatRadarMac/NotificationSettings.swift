import SwiftUI
import AppKit
import FlatRadarCore

/// 通知相关的本机偏好。主窗口（自动注册、「通知没打开」弹窗）和设置页共用。
enum NotificationPreferences {

    /// 用户在「Notifications Are Off」弹窗里勾了「Don't remind me again」。
    static let alertSuppressedKey = "notificationsOffAlertSuppressed"

    // 「用户关掉了推送」这条意愿曾经在这里用 `@AppStorage` 存过一份。现在归
    // ``PushStore/deliveryDisabledByUser`` 管（Core 里落盘、两端同一个键），
    // 这里不再留副本——同一件事存两处，迟早有一处忘了改。

    /// 系统设置里「通知 → FlatRadar」那一页。
    ///
    /// 实测（macOS 27.0）：系统设置收到的是
    /// `extensionIdentity: com.apple.Notifications-Settings.extension, anchor: id=com.j.kong.FlatRadar`，
    /// 直接定位到 FlatRadar。
    static var systemSettingsURL: URL {
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id="
            + (Bundle.main.bundleIdentifier ?? "com.j.kong.FlatRadar"))!
    }
}

// MARK: - Notifications tab

struct NotificationSettings: View {

    @Environment(AuthStore.self) private var auth
    @Environment(PushStore.self) private var push
    @Environment(\.openURL) private var openURL

    @AppStorage(NotificationPreferences.alertSuppressedKey) private var alertSuppressed = false

    @State private var isSendingTest = false
    @State private var testResult: String?

    var body: some View {
        Form {
            if !auth.isAuthenticated || auth.isGuest {
                Section {
                    Text("Sign in with an account to get new listings delivered to this Mac.")
                        .foregroundStyle(.secondary)
                }
            } else {
                thisMacSection
                reminderSection
                if auth.isAdmin { diagnosticsSection }
            }
        }
        .formStyle(.grouped)
        .frame(height: auth.isAdmin ? 440 : 340)
        // 用户可能刚在系统设置里改过——打开这一页、从别的 app 切回来，都重新读一次。
        .task { await syncWithSystem() }
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await syncWithSystem() }
        }
        .alert("Test Push", isPresented: testResultBinding, presenting: testResult) { _ in
            Button("OK", role: .cancel) {}
        } message: { Text($0) }
    }

    // MARK: - Sections

    private var thisMacSection: some View {
        Section {
            LabeledContent("Status") {
                Label(statusText, systemImage: statusSymbol)
                    .foregroundStyle(statusColor)
            }

            Toggle("Deliver notifications to this Mac", isOn: deliveryBinding)
                .disabled(push.permissionStatus == .denied)

            if push.permissionStatus == .denied {
                HStack(alignment: .firstTextBaseline) {
                    Text("Notifications for FlatRadar are turned off in System Settings.")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open System Settings") {
                        openURL(NotificationPreferences.systemSettingsURL)
                    }
                }
            }

            if let err = push.lastError, push.permissionStatus != .denied {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("This Mac")
        } footer: {
            Text("New listings and status changes that match your filter.")
        }
    }

    private var reminderSection: some View {
        Section {
            // 反过来绑：存的是「不再提醒」，开关问的是「要不要提醒」。
            // 这也是弹窗里那个勾选框唯一的撤销入口。
            Toggle("Remind me when notifications are off", isOn: Binding(
                get: { !alertSuppressed },
                set: { alertSuppressed = !$0 }))
        } footer: {
            Text("Shows a reminder at launch if macOS isn't allowing FlatRadar to notify you.")
        }
    }

    /// 和 iOS 一样只给管理员：普通用户用不上设备 id，测试推送会往全站通知表写一条。
    private var diagnosticsSection: some View {
        Section("Diagnostics") {
            LabeledContent("Device ID") {
                Text(push.registeredDeviceId.map(String.init) ?? "Not registered")
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            LabeledContent("Environment", value: pushEnvironment)
            HStack {
                Button(isSendingTest ? "Sending…" : "Send Test Push") {
                    Task { await sendTestPush() }
                }
                .disabled(isSendingTest || push.registeredDeviceId == nil)
                Button("Re-register Device") {
                    Task { await push.requestPermissionAndRegister() }
                }
                .disabled(push.permissionStatus == .denied || push.deliveryDisabledByUser)
            }
        }
    }

    // MARK: - 状态

    private var isAllowed: Bool {
        push.permissionStatus == .authorized || push.permissionStatus == .provisional
    }

    private var statusText: String {
        switch push.permissionStatus {
        case .denied:        return "Off in System Settings"
        case .notDetermined: return "Not requested yet"
        default:
            if push.deliveryDisabledByUser { return "Turned off for this Mac" }
            return push.registeredDeviceId != nil ? "On" : "Allowed — not registered yet"
        }
    }

    private var statusSymbol: String {
        switch push.permissionStatus {
        case .denied: return "bell.slash.fill"
        case .notDetermined: return "bell"
        default:
            return push.deliveryDisabledByUser || push.registeredDeviceId == nil
                ? "bell" : "bell.badge.fill"
        }
    }

    private var statusColor: Color {
        if push.permissionStatus == .denied { return .red }
        return isAllowed && !push.deliveryDisabledByUser && push.registeredDeviceId != nil
            ? .green : .secondary
    }

    private var pushEnvironment: String {
        #if DEBUG
        "Sandbox (debug build)"
        #else
        "Production"
        #endif
    }

    // MARK: - 动作

    /// 开关绑的是**用户的选择**，不是「此刻后端有没有这台设备」。
    ///
    /// iOS 那个开关绑的是 `registeredDeviceId != nil`：注册是异步的，打开之后
    /// 要等 APNs 回 token、后端回 id，这几秒里开关会弹回「关」。
    private var deliveryBinding: Binding<Bool> {
        Binding(
            get: { !push.deliveryDisabledByUser && push.permissionStatus != .denied },
            // 落盘由 `setEnabled` 自己做（它先写意愿再动网络），这里不用再存一次。
            set: { enable in Task { await push.setEnabled(enable) } })
    }

    /// 读系统权限；如果刚在系统设置里打开了、而这台 Mac 还没注册，就补注册一次。
    private func syncWithSystem() async {
        guard auth.isAuthenticated, !auth.isGuest else { return }
        await push.refreshPermissionStatus()
        if isAllowed, !push.deliveryDisabledByUser, push.registeredDeviceId == nil {
            await push.requestPermissionAndRegister()
        }
    }

    private func sendTestPush() async {
        isSendingTest = true
        defer { isSendingTest = false }
        do {
            let r = try await APIClient.shared.testPush()
            if r.sent == r.total {
                testResult = "Sent to \(r.sent) device\(r.sent == 1 ? "" : "s")."
            } else {
                let failures = r.results.filter { !$0.ok }
                    .map { "\($0.status) \($0.reason)" }
                    .joined(separator: "; ")
                testResult = "Sent \(r.sent)/\(r.total). Failures: \(failures)"
            }
        } catch {
            testResult = error.localizedDescription
        }
    }

    private var testResultBinding: Binding<Bool> {
        Binding(get: { testResult != nil }, set: { if !$0 { testResult = nil } })
    }
}
