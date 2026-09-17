import SwiftUI
import AppKit
import FlatRadarCore

/// 登录屏：左边说这个 app 是什么，右边登录 / 注册 / 进访客。
///
/// 唯一一处**没有照做**的：合并按钮不能自己判断用户名是不是新的
/// -------------------------------------------------------
/// 设计稿写的是「One button for both — if the username is new, it creates the
/// account」，Panel C 还有一行绿点的「Available — we will set the account up now」。
/// 这要求客户端能区分「用户名不存在」和「密码错了」。**后端刻意让它区分不了**：
///
/// ```python
/// # 时序对齐：无论用户存在与否，都跑一次 bcrypt（真或 dummy），
/// # 否则 ~100ms 的时序差让攻击者能枚举出真实用户名。
/// if user is None:
///     _dummy_bcrypt_verify(password)
///     return _err.err_unauthorized("用户名或密码错误")
/// ```
///
/// 两条分支同一个错误码、同一句话，连耗时都对齐了；而且**没有**任何
/// 「用户名是否可用」的端点（`docs/openapi.json` 里查不到）。照设计稿实现
/// ——登录失败就断言"这个名字是新的"——等于亲手造一个用户名枚举器：
/// 拿任意密码试一遍，看 app 是提示"去创建"还是"密码错了"，就知道谁注册过。
/// 那正是那段 dummy bcrypt 要挡的事。
///
/// 所以这里**保留了合并的流程，去掉了那句断言**：
///
/// - `Continue` 仍然是唯一的主按钮，走登录；
/// - 失败了照样能翻到创建账号那一屏（Panel C 的形态），但文案不说"这个名字是
///   新的"，而是"没有账号的话现在建一个"——**这一步对存在和不存在的用户名
///   表现完全一样**，不泄露任何东西；
/// - 真正的判定留给 `POST /auth/register`：重名回 `conflict`。那是任何注册
///   表单都无法避免的泄露，而且后端对它单独限了流（同 IP 每小时几个）。
///
/// 连带去掉的还有 Panel C 那行实时的「Available」——没有端点，而且做一个出来
/// 本身就是个枚举器。
///
/// 其余全部照做
/// -----------
/// 两栏、暖底、大数字 + 平台徽章 + 最后扫描时间、`Continue` 满宽墨色按钮、
/// `or` 分隔、访客卡片带行内 `Browse`、底部 Privacy / Terms、深色模式。
/// 左下角那幅运河房子**不是重画的**，是把 `AppIcon.icon` 的三层
/// （water / houses / windows）合成一个 SVG 放进 asset catalog，浅色深色各一份。
///
/// 设计稿里**唯一删掉**的控件是 `Forgot?`：后端只有改密码
/// （`POST /auth/password`，还要先登录），没有找回流程，链接点了没地方去。
struct SignInPane: View {

    @Environment(AuthStore.self) private var auth

    /// 右栏当前是哪一屏。对应设计稿的 Panel A / Panel C。
    private enum Mode { case signIn, create }

    @State private var mode: Mode = .signIn
    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var staySignedIn = true
    @State private var legal: LegalSheet?

    /// 左栏那些数字。`/stats/public/summary` 是 `bearer_optional`，
    /// **没登录也能拿**——正好，这一屏本来就在登录之前。
    @State private var summary = SummaryModel()

    var body: some View {
        HStack(spacing: 0) {
            pitch
            Divider()
            form
        }
        .frame(minWidth: 820, minHeight: 560)
        .task { await summary.load() }
        .sheet(item: $legal) { LegalView(kind: $0) }
    }

    // MARK: - 左栏

    private var pitch: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FlatRadar")
                .font(.largeTitle.weight(.semibold))
                .tracking(-0.5)
            Text("One list for every Dutch housing platform.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)

            // 和列表屏的统计带同一个配方：一个大数当锚点。
            // 数字没回来之前显示 `—`，**不显示 0**——0 是"一条都没有"，
            // 和"还不知道"不是一回事。
            Text(summary.summary.map { "\($0.total)" } ?? "—")
                .font(.system(size: 44, weight: .semibold, design: .monospaced))
                .tracking(-1.6)
                .monospacedDigit()
                .padding(.top, 26)
            Text("listings tracked right now")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            platformChips.padding(.top, 16)

            if let scanned = summary.scannedAgoText {
                // `scannedAgoText` 只回相对时间（"25s ago"），前缀在这里加——
                // 光一个"25s ago"读不出是**什么**在 25 秒前发生。
                Text("Last scan \(scanned)")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 10)
            }

            Spacer(minLength: 20)

            // 左下角的运河房子。**取自 app 图标**，不是另画的一幅——见类型注释。
            // 浅色深色两份由 asset catalog 自己切。
            Image("SignInHouses")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity)
                // 抵掉左右内边距，让插画**满幅贴住**左栏的三条边。
                // 设计稿里它是从边缘长出来的，留白反而像一张贴在中间的图。
                .padding(.horizontal, -28)
                .accessibilityHidden(true)      // 纯装饰
        }
        .padding(.horizontal, 28)
        .padding(.top, 30)
        .frame(width: 320, alignment: .leading)
        .frame(maxHeight: .infinity)
        .background(Theme.pitchBackground)
    }

    /// 七个平台的缩写。取包里的 ``Platform/featuredOrder``，不写死——
    /// 加了第八家的时候这里自己就多一个。
    ///
    /// 顺序**不用** `knownKeys`：那是按显示名字母排的，H2S 会排在 MG / OC 后面。
    /// 设计稿把大的放前面，照做——用户第一眼要看到的是自己认得的那几家。
    /// 这个顺序 iPad 登录屏也在用，所以它住在包里，不在这儿。
    private var platformChips: some View {
        HStack(spacing: 5) {
            ForEach(Platform.featuredOrder, id: \.self) { key in
                Text(Platform.shortName(key))
                    .font(.system(size: 9, weight: .heavy, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(Theme.platform(key))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Theme.platform(key).opacity(0.16), in: Capsule())
            }
        }
    }

    // MARK: - 右栏

    private var form: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // 两个等权 Spacer 把表单夹在中间，页脚仍旧钉在底部。
                    // 只写 `alignment: .center` 不管用——VStack 里一旦有 Spacer
                    // 就会撑满高度，外层的 alignment 随之失效（这个坑踩过两次了）。
                    Spacer(minLength: 24)
                    switch mode {
                    case .signIn: signInForm
                    case .create: createForm
                    }
                    errorBox
                    Spacer(minLength: 24)
                    legalFooter
                }
                .frame(maxWidth: 380, alignment: .leading)
                .padding(.horizontal, 34)
                .padding(.vertical, 30)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Panel A —— 登录

    @ViewBuilder
    private var signInForm: some View {
        Text("Sign in to FlatRadar")
            .font(.title2.weight(.semibold))
        Text("One account for every platform we track.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 2)

        field("Username", text: $username, secure: false).padding(.top, 22)
        field("Password", text: $password, secure: true).padding(.top, 14)

        Toggle("Keep me signed in on this Mac", isOn: $staySignedIn)
            .padding(.top, 14)
            // 这个勾**有真东西可控**：勾上发 ttl_days=90（后端上限），不勾发 1
            // （后端下限）。不是装饰——不勾的话明天就要重新登录。
            .help(staySignedIn ? "Session lasts 90 days" : "Session expires after one day")

        primaryButton("Continue", enabled: !username.isEmpty && !password.isEmpty) {
            Task {
                await auth.loginAsUser(name: username, password: password,
                                       ttlDays: staySignedIn ? 90 : 1)
                password = ""
            }
        }
        .padding(.top, 18)

        unlockButton

        // 设计稿这里写的是「Signs you in, or creates an account if the username
        // is new」。改掉了：客户端判断不出用户名是不是新的，见类型注释。
        Text("No account yet? Continue, then choose Create account.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
            .padding(.top, 7)

        orDivider.padding(.vertical, 20)
        guestCard
    }

    // MARK: Panel C —— 创建账号

    @ViewBuilder
    private var createForm: some View {
        Text("Create your account")
            .font(.title2.weight(.semibold))
        // 设计稿原句：「Same Continue button — this username has no FlatRadar
        // account yet」。**不能这么说**——我们不知道有没有，见类型注释。
        Text("Pick a name and a password. If the name is taken we will say so.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 2)
            .fixedSize(horizontal: false, vertical: true)

        field("Username", text: $username, secure: false).padding(.top, 22)
        field("Choose a password", text: $password, secure: true).padding(.top, 14)
        strengthMeter.padding(.top, 6)
        field("Confirm password", text: $confirmPassword, secure: true).padding(.top, 14)

        if !confirmPassword.isEmpty, confirmPassword != password {
            Text("The two passwords do not match.")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(.top, 5)
        }

        Toggle("Save to Keychain and keep me signed in", isOn: $staySignedIn)
            .padding(.top, 14)

        primaryButton("Create account", enabled: canCreate) {
            Task {
                await auth.register(name: username, password: password,
                                    ttlDays: staySignedIn ? 90 : 1)
                password = ""
                confirmPassword = ""
            }
        }
        .padding(.top, 18)

        Button("Back to sign in") {
            mode = .signIn
            auth.errorMessage = nil
        }
        .buttonStyle(.link)
        .font(.body)
        .frame(maxWidth: .infinity)
        .padding(.top, 10)
    }

    /// 新账号的密码门槛 = 后端 `_register` 的 **4 位**（`auth.py:372`）。
    ///
    /// 这里曾经按设计稿写成 12 位。客户端比服务端严，挡掉的都是后端本来接受的
    /// 密码，而用户看不出是谁在拒他——同一个账号在网页端能建、在 Mac 上建不了。
    /// 门槛归后端一处定，客户端只做即时反馈。
    ///
    /// 设置页里**访客转正**用的也是这一条（同样是开户）；「修改密码」走
    /// `/auth/password` 自己的下限，也是 4（见 `AccountSettings.ChangePasswordSheet`）。
    static let minNewPasswordLength = 4

    private var canCreate: Bool {
        !username.isEmpty
            && password.count >= Self.minNewPasswordLength
            && password == confirmPassword
    }

    /// 密码长度条。四格，每 4 个字符点亮一格——**不做熵估算**：这条给的是
    /// "有多长"这一个信号。装成能看穿密码强弱的样子，反而会让人以为一个短的
    /// 怪字符串"很强"。
    ///
    /// 门槛从 12 降到 4 之后这里也跟着改了口径：原先满足门槛就写 "Strong"，
    /// 那会对着一个**四位**密码说它很强——比不说还糟。现在只报长度，够不够
    /// 门槛用颜色区分。
    private var strengthMeter: some View {
        let filled = min(4, password.count / 4)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { i in
                    Capsule()
                        .fill(i < filled ? Color.energyTop : Color.primary.opacity(0.12))
                        .frame(height: 3)
                }
            }
            Text(password.count >= Self.minNewPasswordLength
                 ? "\(password.count) characters"
                 : "\(Self.minNewPasswordLength) characters or more")
                .font(.footnote)
                .foregroundStyle(password.count >= Self.minNewPasswordLength
                                 ? AnyShapeStyle(Color.energyTop) : AnyShapeStyle(.tertiary))
        }
    }

    // MARK: - 零件

    private func field(_ label: String, text: Binding<String>, secure: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Group {
                if secure {
                    SecureField("", text: text).textContentType(.password)
                } else {
                    TextField("", text: text).textContentType(.username)
                }
            }
            .textFieldStyle(.roundedBorder)
            .controlSize(.large)
        }
    }

    /// 用 Touch ID / 开机密码直接登录。
    ///
    /// 只在**这台 Mac 上真的存过凭据**时出现（`hasStoredCredentials` 读的是
    /// UserDefaults 里的角色标记，**不查钥匙串**——查一条受保护的条目本身就
    /// 可能弹出系统认证框，那会变成"打开登录页就被问一次密码"）。
    ///
    /// 解锁失败或用户取消时什么都不做，不报错：取消是正常操作，弹一条
    /// "认证失败"只会让人以为出了问题。密码框还在上面，照常输就是。
    @ViewBuilder
    private var unlockButton: some View {
        if BiometricAuthService.isAvailable, BiometricAuthService.hasStoredCredentials {
            Button {
                Task { await unlockAndSignIn() }
            } label: {
                Label("Sign in with \(BiometricAuthService.unlockMethodName)",
                      systemImage: "touchid")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .disabled(auth.isLoading)
            .padding(.top, 10)
        }
    }

    private func unlockAndSignIn() async {
        let reason = "Sign in to FlatRadar"
        guard let cred = await BiometricAuthService.authenticateAndLoad(reason: reason) else {
            return   // 取消 / 失败：静默，密码框还在
        }
        await auth.loginAsUser(name: cred.username, password: cred.password,
                               ttlDays: staySignedIn ? 90 : 1)
    }

    private func primaryButton(_ title: String, enabled: Bool,
                               _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if auth.isLoading { ProgressView().controlSize(.small) }
                Text(title).font(.body.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 30)
        }
        .buttonStyle(.borderedProminent)
        // 强调色是 ink（近黑），和设计稿那个满宽深色按钮一致。窗口的 `.tint`
        // 是设在主窗口上的，登录屏这一层没有，所以显式给。
        .tint(Theme.ink)
        .keyboardShortcut(.defaultAction)
        .disabled(!enabled || auth.isLoading)
    }

    private var orDivider: some View {
        HStack(spacing: 10) {
            VStack { Divider() }
            Text("or").font(.footnote).foregroundStyle(.tertiary)
            VStack { Divider() }
        }
    }

    /// 访客卡片。设计稿是「一段说明 + 右侧行内 Browse 按钮」。
    ///
    /// 这一段是真做了的：`/listings`、`/map`、`/calendar`、`/stats/public/*`
    /// 全是 `bearer_optional`，``AuthStore/enterAsGuest()`` 也早在包里。
    /// 少什么照实写：没账号就没 `listing_filter`，看到的是全库；也没有通知。
    private var guestCard: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Continue as guest").font(.callout.weight(.semibold))
                Text("Public listings only · no alerts, no saved filters")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 6)
            Button("Browse") { auth.enterAsGuest() }
        }
        .padding(12)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    @ViewBuilder
    private var errorBox: some View {
        if let msg = auth.errorMessage {
            VStack(alignment: .leading, spacing: 6) {
                // 完成判据：「拒绝网络或凭据错误时，窗口显示可理解的错误」。
                // 用后端给的具体原因，不是「登录失败」四个字。
                Text(auth.lastError?.errorDescription ?? "Sign-in failed")
                    .font(.callout.weight(.medium))
                Text(msg).font(.caption).fixedSize(horizontal: false, vertical: true)

                // 登录失败之后给一条去创建账号的路——但**不断言**这个用户名是新的。
                // 对存在和不存在的用户名，这里长得一模一样，所以不泄露任何东西。
                if mode == .signIn {
                    Button("Create an account instead") {
                        auth.errorMessage = nil
                        password = ""
                        confirmPassword = ""
                        mode = .create
                    }
                    .buttonStyle(.link)
                    .font(.body)
                }
            }
            .foregroundStyle(.red)
            .padding(.top, 14)
        }
    }

    /// 底部 Privacy Policy · Terms of Use。
    ///
    /// 做成**弹窗**而不是外链：`https://flatradar.app/legal` 实测 **404**，
    /// 只有 API `GET /api/v1/legal` 是 200。链一个 404 出去，和设计稿里那个
    /// 没有后端的 `Forgot?` 是同一种错。
    private var legalFooter: some View {
        HStack(spacing: 6) {
            Button("Privacy Policy") { legal = .privacy }
            Text("·").foregroundStyle(.tertiary)
            Button("Terms of Use") { legal = .terms }
        }
        .buttonStyle(.link)
        .font(.footnote)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - 条款弹窗

enum LegalSheet: String, Identifiable {
    case privacy, terms
    var id: String { rawValue }
    var title: String { self == .privacy ? "Privacy Policy" : "Terms of Use" }
}

/// 条款正文。走 `GET /api/v1/legal`（``APIClient/getLegal(lang:)``）。
///
/// 登录屏和设置页共用。
struct LegalView: View {

    let kind: LegalSheet

    @Environment(\.dismiss) private var dismiss
    @State private var text: String?
    @State private var failed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(kind.title).font(.title3.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollView {
                Group {
                    if let text {
                        Text(text).font(.callout).textSelection(.enabled)
                    } else if let failed {
                        // 拉不到就明说拉不到，不显示一片空白让人以为条款是空的。
                        Text(failed).font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
        }
        .frame(width: 560, height: 480)
        .task {
            do {
                let resp = try await APIClient.shared.getLegal()
                text = kind == .privacy ? resp.privacy : resp.terms
            } catch {
                failed = "Could not load: \(error.localizedDescription)"
            }
        }
    }
}
