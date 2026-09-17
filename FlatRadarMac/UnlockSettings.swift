import SwiftUI
import FlatRadarCore

/// 「用 Touch ID / 开机密码登录」——Account tab 里的那一段，以及开启它的弹窗。
///
/// 和 iOS 那份的差别只有一处：门松一档
/// ---------------------------------
/// iOS 存凭据用 `.biometryCurrentSet`（只认 Face ID / Touch ID）。macOS 上照搬
/// 的后果是**功能在半数 Mac 上永远不出现**：台式机大多没有 Touch ID，而带
/// `.biometryCurrentSet` 的钥匙串条目在没有生物识别时连写都写不进去——实测这台
/// Mac mini（M4）`SecItemAdd` → -25293 errSecAuthFailed，`canEvaluatePolicy` →
/// LAError -12 `biometryNotPaired`。
///
/// 所以 Mac 用 `.userPresence`：Touch ID、Apple Watch、或者这台 Mac 的开机密码。
/// 判断和取名都在包里（``BiometricAuthService/policy`` /
/// ``BiometricAuthService/unlockMethodName``），两端各写一份必然漂移。
///
/// 界面上**不谎称 Touch ID**：没有生物识别的机器上，这一段的标题和说明里写的是
/// "your password"。`unlockMethodName` 专门为此避开了 `biometryType`——那个值
/// 报的是"这台机器属于哪一类"，这台 Mac mini 没有 Touch ID 也照样报 `.touchID`。
struct UnlockSettings: View {

    @Environment(AuthStore.self) private var auth

    @State private var showEnable = false
    @State private var showRemoveConfirm = false
    /// 开关要能"弹回去"：往开的方向拨只是打开弹窗，真正写进钥匙串之前
    /// 它必须还是关的。iOS 那边踩过——`set` 只处理关，往开拨什么都不写，
    /// 开关弹回原位而且没有任何提示。
    @State private var storedFlag = BiometricAuthService.hasStoredCredentials

    private var method: String { BiometricAuthService.unlockMethodName }

    var body: some View {
        // 机器不支持就整段不画：画一个永远打不开的开关比没有更糟。
        if auth.isUser, BiometricAuthService.isAvailable {
            Section {
                Toggle("Sign in with \(method)", isOn: Binding(
                    get: { storedFlag },
                    set: { on in
                        if on { showEnable = true } else { showRemoveConfirm = true }
                    }))
            } header: {
                Text("Unlocking")
            } footer: {
                Text("Your password is stored in this Mac's Keychain and unlocked with "
                   + "\(method). It never leaves this Mac, and it is not synced to iCloud.")
            }
            .sheet(isPresented: $showEnable) {
                EnableUnlockSheet { storedFlag = BiometricAuthService.hasStoredCredentials }
            }
            .confirmationDialog("Stop signing in with \(method)?",
                                isPresented: $showRemoveConfirm, titleVisibility: .visible) {
                Button("Remove Stored Password", role: .destructive) {
                    BiometricAuthService.deleteCredentials()
                    storedFlag = BiometricAuthService.hasStoredCredentials
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You'll need to type your password the next time you sign in.")
            }
            // 别的窗口（或 iOS 端登出）改过之后，切回这个 tab 要读到新值。
            .onAppear { storedFlag = BiometricAuthService.hasStoredCredentials }
        }
    }
}

/// 开启时**必须重新输一次密码**。
///
/// 理由和 iOS 那边一样：存进钥匙串的是明文密码（日后解锁后回放给
/// `/auth/login`），而密码只在登录那一刻存在于内存里——设置页手里只有 token。
///
/// 密码不发给别处：先调 `/auth/verify` 确认（那个端点只回答对不对，不签发
/// token），确认通过才写钥匙串。
private struct EnableUnlockSheet: View {

    @Environment(AuthStore.self) private var auth
    @Environment(\.dismiss) private var dismiss

    /// 写成功之后让外面重新读一次 `hasStoredCredentials`。
    let onSaved: () -> Void

    @State private var password = ""
    @State private var inlineError: String?
    @State private var isWorking = false
    @FocusState private var focused: Bool

    private var method: String { BiometricAuthService.unlockMethodName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Turn on \(method) sign-in")
                .font(.headline)

            Text("Type your FlatRadar password once. It goes into this Mac's Keychain, "
               + "unlocked with \(method).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            SecureField("Password", text: $password)
                .textContentType(.password)
                .focused($focused)
                .onSubmit { Task { await submit() } }

            if let inlineError {
                Text(verbatim: inlineError)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if isWorking { ProgressView().controlSize(.small) }
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Turn On") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(password.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { focused = true }
    }

    private func submit() async {
        guard !password.isEmpty else { return }
        inlineError = nil
        isWorking = true
        defer { isWorking = false }

        guard await auth.verifyPassword(password) else {
            // 返回 false 可能是密码错，也可能是断网。把 `AuthStore` 记下的原因
            // 原样带出来，不要一律说成"密码错误"。
            inlineError = auth.errorMessage
                ?? "Couldn't verify your password. Please try again."
            return
        }
        guard let name = auth.userInfo?.name else {
            inlineError = "Couldn't read your account name."
            return
        }
        do {
            try BiometricAuthService.saveCredentials(
                .init(username: name, password: password, role: "user"))
        } catch {
            // 写失败必须说出来。吞掉的话用户以为开好了，下次登录才发现按钮没出现。
            inlineError = error.localizedDescription
            return
        }
        password = ""
        onSaved()
        dismiss()
    }
}
