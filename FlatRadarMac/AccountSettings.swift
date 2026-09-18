import SwiftUI
import UniformTypeIdentifiers
import FlatRadarCore

/// 登出 / 删号这类「会话级」动作。应用菜单的 Sign Out 和设置页共用一份。
///
/// **先解绑设备，再动会话。** `DELETE /devices/<id>` 要带 bearer；顺序反过来
/// token 已经被撤销，解绑请求 401，这台 Mac 就会继续收到上一个账号的推送。
@MainActor
enum SessionActions {

    static func signOut(auth: AuthStore, push: PushStore) async {
        await push.logout()
        await auth.logout()
    }

    static func deleteAccount(auth: AuthStore, push: PushStore) async {
        await push.logout()
        await auth.deleteAccount()
    }
}

// MARK: - Account tab

struct AccountSettings: View {

    @Environment(AuthStore.self) private var auth
    @Environment(PushStore.self) private var push

    @State private var showSignOutConfirm = false
    @State private var showDeleteConfirm = false
    @State private var showChangePassword = false
    @State private var showCreateAccount = false

    @State private var isExporting = false
    @State private var exportDocument: ExportDocument?
    @State private var showExporter = false
    @State private var errorText: String?

    var body: some View {
        Form {
            if !auth.isAuthenticated {
                Section {
                    Text("Not signed in. Sign in or continue as a guest from the main window.")
                        .foregroundStyle(.secondary)
                }
            } else if auth.isGuest {
                guestSections
            } else if auth.isAdmin {
                adminSections
            } else {
                userSections
            }

            if let errorText {
                Section {
                    Label(errorText, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 460)
        .sheet(isPresented: $showChangePassword) { ChangePasswordSheet() }
        .sheet(isPresented: $showCreateAccount) { CreateAccountSheet() }
        .fileExporter(
            isPresented: $showExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: Self.exportFilename()
        ) { result in
            if case .failure(let error) = result {
                errorText = error.localizedDescription
            }
            exportDocument = nil
        }
        .confirmationDialog(
            auth.isGuest ? "Sign out of guest mode?" : "Sign out of FlatRadar?",
            isPresented: $showSignOutConfirm
        ) {
            Button("Sign Out", role: .destructive) {
                Task { await SessionActions.signOut(auth: auth, push: push) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(
            "Permanently delete your account?",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task {
                    await SessionActions.deleteAccount(auth: auth, push: push)
                    // 删失败时 AuthStore 保持登录，错误写在 errorMessage 里。
                    if auth.isAuthenticated { errorText = auth.errorMessage }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your account data, saved filters, alert history, and preferences will be permanently removed. This cannot be undone.")
        }
    }

    // MARK: - 普通用户

    @ViewBuilder
    private var userSections: some View {
        Section("Account") {
            LabeledContent("Username", value: auth.userInfo?.name ?? "—")
            Button("Change Password…") { showChangePassword = true }
            Button("Sign Out…") { showSignOutConfirm = true }
        }

        // 机器不支持生物识别 / 不是普通用户时它自己整段不画。
        UnlockSettings()

        Section {
            Button {
                Task { await export() }
            } label: {
                HStack(spacing: 8) {
                    Text(isExporting ? "Preparing Export…" : "Export My Data…")
                    if isExporting { ProgressView().controlSize(.small) }
                }
            }
            .disabled(isExporting)
        } header: {
            Text("Your Data")
        } footer: {
            Text("A JSON file with your account, filter, devices, and alert history.")
        }

        Section {
            Button("Delete Account…", role: .destructive) { showDeleteConfirm = true }
        } footer: {
            Text("Deleting your account removes it from the server and signs out every device.")
        }
    }

    // MARK: - 访客

    /// 访客在 iOS 上曾经只有「退出访客模式」一个按钮——看起来像要把人赶出去，
    /// 没人会为了注册去点它。所以把注册入口放在第一位。
    @ViewBuilder
    private var guestSections: some View {
        Section {
            Text("You're browsing as a guest. An account keeps your notification filter and alert history, and lets FlatRadar send new listings to this Mac.")
                .foregroundStyle(.secondary)
            Button("Create an Account…") { showCreateAccount = true }
        } header: {
            Text("Guest")
        }
        Section {
            Button("Sign Out of Guest Mode…") { showSignOutConfirm = true }
        }
    }

    // MARK: - 管理员

    /// 管理员密码在后端 `.env` 里，不走 `/auth/password`；`AuthStore.changePassword`
    /// 对非 user 角色直接拒绝。这里只给身份和登出。
    @ViewBuilder
    private var adminSections: some View {
        Section("Account") {
            LabeledContent("Signed in as", value: String(localized: "Administrator"))
            Button("Sign Out…") { showSignOutConfirm = true }
        }
    }

    // MARK: - 导出

    private func export() async {
        isExporting = true
        errorText = nil
        defer { isExporting = false }
        do {
            exportDocument = ExportDocument(data: try await APIClient.shared.meExport())
            showExporter = true
        } catch {
            errorText = error.localizedDescription
        }
    }

    private static func exportFilename() -> String {
        let f = DateFormatter()
        f.calendar = ServerTime.calendar
        f.timeZone = ServerTime.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "FlatRadar-export-\(f.string(from: Date())).json"
    }
}

/// `/me/export` 的原始 JSON，交给系统存盘面板。
///
/// `nonisolated`：`FileDocument` 的要求是 nonisolated 的，而工程默认把没标注的
/// 类型放到主 actor 上——不标就是一条隔离不匹配的编译错误（和 `Shape.path(in:)`
/// 那一批同理）。它只装一段 `Data`，本来就跟 actor 无关。
nonisolated struct ExportDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.json]

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

// MARK: - 修改密码

/// 移植自 iOS `ChangePasswordSheet`，规则也和它一致。
///
/// 门槛就是后端 `/auth/password` 的 **4 位**（`auth.py:466`），不是登录屏建号用的
/// 12 位。改密码是**已有用户**的日常操作，不是开户：客户端比服务端严，只会让一个
/// 后端认可的密码在这里被拒，而用户看不出是谁拒的。
private struct ChangePasswordSheet: View {

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var currentPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var serverError: String?
    @State private var showSuccess = false

    /// 与后端 `/auth/password` 对齐：≥ 4。客户端先挡一道只为即时反馈，服务端仍会重做。
    private static let minLength = 4

    private var validationError: String? {
        guard !newPassword.isEmpty else { return nil }
        if newPassword.count < Self.minLength {
            return String(localized: "New password must be at least \(Self.minLength) characters.")
        }
        if !confirmPassword.isEmpty, newPassword != confirmPassword {
            return String(localized: "New passwords don't match.")
        }
        if newPassword == currentPassword {
            return String(localized: "New password must differ from current.")
        }
        return nil
    }

    private var canSubmit: Bool {
        !currentPassword.isEmpty && newPassword.count >= Self.minLength
            && newPassword == confirmPassword && validationError == nil && !auth.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Change Password").font(.title3.weight(.semibold))

            Form {
                SecureField("Current password", text: $currentPassword)
                    .textContentType(.password)
                SecureField("New password", text: $newPassword)
                    .textContentType(.newPassword)
                SecureField("Confirm new password", text: $confirmPassword)
                    .textContentType(.newPassword)
            }
            .formStyle(.columns)

            Group {
                if let err = serverError ?? validationError {
                    Text(err).foregroundStyle(.red)
                } else {
                    Text("Other devices signed in to this account will be signed out.")
                        .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Update") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 420)
        .alert("Password Updated", isPresented: $showSuccess) {
            Button("OK") { dismiss() }
        } message: {
            Text("Use the new password next time you sign in. Other devices have been signed out.")
        }
    }

    private func submit() async {
        guard canSubmit else { return }
        serverError = nil
        if await auth.changePassword(current: currentPassword, new: newPassword) {
            showSuccess = true
        } else {
            // 表单不清空，改一处就能重提。
            serverError = auth.errorMessage
        }
    }
}

// MARK: - 访客转正

/// 移植自 iOS `RegisterAccountSheet`，门槛按 Mac 登录屏的「新建账号」来（12 位）。
///
/// 条款同意落在这张表上：按钮上方就写着同意条款，按下去即为凭证——后端
/// `_register` 不校验这个字段，所以必须在界面上说清楚。
private struct CreateAccountSheet: View {

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var legal: LegalSheet?

    private var trimmedName: String { username.trimmingCharacters(in: .whitespaces) }

    /// 与后端 `_register` 对齐：≥2 字符、不可用 `__` 开头（后端保留给自己）。
    private var validationError: String? {
        if !trimmedName.isEmpty {
            if trimmedName.count < 2 {
                return String(localized: "Username must be at least 2 characters.")
            }
            if trimmedName.lowercased().hasPrefix("__") {
                return String(localized: "That username isn't available.")
            }
        }
        if !password.isEmpty, password.count < SignInPane.minNewPasswordLength {
            return String(localized: "Password must be at least \(SignInPane.minNewPasswordLength) characters.")
        }
        if !confirmPassword.isEmpty, password != confirmPassword {
            return String(localized: "Passwords don't match.")
        }
        return nil
    }

    private var canSubmit: Bool {
        trimmedName.count >= 2 && password.count >= SignInPane.minNewPasswordLength
            && password == confirmPassword && validationError == nil && !auth.isLoading
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Create an Account").font(.title3.weight(.semibold))

            Form {
                TextField("Username", text: $username)
                    .textContentType(.username)
                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                SecureField("Confirm password", text: $confirmPassword)
                    .textContentType(.newPassword)
            }
            .formStyle(.columns)

            if let err = auth.errorMessage ?? validationError {
                Text(err).font(.callout).foregroundStyle(.red)
            }

            HStack(spacing: 4) {
                Text("By creating an account you agree to the")
                Button("Terms of Use") { legal = .terms }.buttonStyle(.link)
                Text("and")
                Button("Privacy Policy") { legal = .privacy }.buttonStyle(.link)
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create Account") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear { auth.errorMessage = nil }
        .sheet(item: $legal) { LegalView(kind: $0) }
    }

    /// 注册成功后 `isAuthenticated` 翻成 user，主窗口的 `.task(id:)` 会接着申请
    /// 通知权限、注册推送——这里不用再管。
    private func submit() async {
        guard canSubmit else { return }
        await auth.register(name: String(trimmedName.prefix(64)), password: password)
        if auth.isUser { dismiss() }
    }
}
