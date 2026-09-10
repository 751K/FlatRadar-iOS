import SwiftUI
import FlatRadarCore

/// 登录入口。视觉对齐两份设计稿：
/// `FlatRadar iOS - Sign in.dc.html`（iPhone 浅 / 深）和
/// `FlatRadar iPad - Sign in.dc.html`（iPad 竖 / 横 / 横深）。
///
/// 这一版换掉了什么
/// ----------------
/// 内容没动——头部、三个统计胶囊、CONTINUE AS 两张卡、Face ID、法务页脚，
/// 顺序和之前一样。换的是**配色、插画和 iPad 的排布**：
///
/// - 原来是一套自成一体的蓝（`brandBlue` #0A84FF + 浅蓝渐变天空 + 手画的
///   `MountainPath` 山脊）。那套颜色和 App 图标没有任何关系，登录页看着像另一个 App。
/// - 现在整屏取自图标本身（见 ``SignInPalette``），插画直接是图标的三层素材
///   （见 ``Skyline`` / `output/icon/make-signin-skyline.py`）。
/// - iPad 不再是把 iPhone 那一竖条拉宽：竖屏走 700 的居中列 + 两张卡并排，
///   横屏走左右分栏、房子留在左栏。所有数值在 ``LoginMetrics``。
struct LoginView: View {
    @Environment(AuthStore.self) private var auth
    @Environment(PushStore.self) private var push
    @Environment(\.colorScheme) private var colorScheme
    /// "减弱动态效果"：用户在 设置 > 辅助功能 > 动态效果 里开启时为 true。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// "增加对比度"系统开关。开启时把若干自定义灰阶 token 提到更深 / 更亮。
    /// 受影响的全是非语义自定义 RGB 颜色，Apple semantic label color
    /// （.primary / .secondary / .tertiary）由系统自己调整。
    @Environment(\.colorSchemeContrast) private var contrast
    private var highContrast: Bool { contrast == .increased }
    @State private var expandedRole: LoginMode?
    @State private var username = ""
    @State private var password = ""
    /// 是否显示密码明文（眼睛图标 toggle）。
    @State private var showPasswordPlain = false
    @State private var liveCount = 0
    @State private var new24h = 0
    @State private var lastScrapeAt: Date?
    /// "live" 小绿点的两段动画相位，**各自独立的状态 + 各自的 repeatForever 曲线**：
    /// - liveRipple：外圈光晕，easeOut + 不回弹（放大渐隐后从头来）
    /// - liveCore  ：内核实心点，easeInOut + 回弹（1.0↔1.12 原地呼吸）
    /// 之前用单个 liveDotBreathing + `.animation(_, value:)` 驱动两段——那种写法
    /// 的 repeatForever 会被视图出现/转场的 ambient 事务"捕获"，偶发变成一次性
    /// 弹跳而不是持续呼吸。改成显式 withAnimation(.repeatForever) 驱动，稳定。
    @State private var liveRipple = false
    @State private var liveCore = false
    @State private var showTerms = false
    @State private var showPrivacy = false
    /// 登录被拒且是 401 时，待确认建号的用户名。非 nil 即弹确认框。
    @State private var pendingRegistrationName: String?
    @State private var isAuthenticatingBiometric = false

    /// 见 ``ServerTime`` 里的说明：`Date.ISO8601FormatStyle` 是 Sendable 值类型，
    /// 默认参数正好等价于 `.withInternetDateTime`。
    private static let isoFrac =
        Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let isoNoFrac =
        Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private var appVersion: String { AppVersion.short }

    private var timeAgo: String {
        guard let date = lastScrapeAt else { return "--" }
        let secs = max(0, Int(Date().timeIntervalSince(date)))
        switch secs {
        case 0..<60: return "\(secs)s"
        case 60..<3600: return "\(secs / 60)m"
        case 3600..<86400: return "\(secs / 3600)h"
        default: return "\(secs / 86400)d"
        }
    }

    private var isDark: Bool { colorScheme == .dark }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            // **宽度必须从外面量，再钉死到内容上。**
            //
            // 只写 `.frame(maxWidth: .infinity)` 是不够的：那个 modifier 在收到
            // 「随便你多宽」的提案时会退回子视图的**理想宽度**，而理想宽度里最宽
            // 的那个是页脚那句免责声明——排成一行是 964pt。于是整棵内容树被撑到
            // 964 再整体居中：iPhone 402pt 只看得见正中间那一条，所有靠左的东西
            // 全被推到屏幕左边外面去了。实测 frame：`FlatRadar` 在 x=-364，
            // Face ID 那条按钮 x=-368 宽 1139。
            //
            // `.frame(width:)` 给的是**确定值**不是上限，子视图再宽也改不了外框的
            // 尺寸，这条反馈回路就断了。三套布局都走这一条。
            GeometryReader { proxy in
                let metrics = LoginMetrics.forSize(proxy.size)
                if metrics.splitsColumns {
                    splitLayout(proxy.size, metrics)
                } else {
                    stackedLayout(proxy.size, metrics)
                }
            }
            .toolbar(.hidden)
            // 登录错误不再用 .alert 弹窗打断——改为在展开的角色卡片里内联红字提示。
            // 打断式 alert 强制用户先点 OK 才能改密码重试，不友好。
            // 登录成功的触觉确认：isAuthenticated 从 false → true 时触发 .success
            // 反馈。closure 形式只在真正"登录"那一刻响一次，logout (true→false)
            // 或重渲染不会误触发。
            .sensoryFeedback(.success, trigger: auth.isAuthenticated) { old, new in
                !old && new
            }
            .task { await fetchStats() }
            // 登录即注册：名字没被注册过时，登录会被后端以 401 拒绝（响应刻意
            // 不区分"密码错"和"查无此人"，不给用户枚举留侧信道）。这里把决定权
            // 交回用户——要不要用这个名字建一个号。
            //
            // 条款同意就落在这个确认框上：Web 端删掉自动注册时列的第一条理由，
            // 正是"登录表单上根本没有勾选框，只能替用户默认同意"。
            .confirmationDialog(
                "Create an account?",
                isPresented: Binding(
                    get: { pendingRegistrationName != nil },
                    set: { if !$0 { pendingRegistrationName = nil } }
                ),
                titleVisibility: .visible,
                presenting: pendingRegistrationName
            ) { name in
                Button("Create Account") {
                    pendingRegistrationName = nil
                    Task { await performRegister() }
                }
                Button("Cancel", role: .cancel) { pendingRegistrationName = nil }
            } message: { name in
                // 第一句必须留着：这个确认框对**任何** 401 都弹，包括"账号存在但
                // 密码打错了"。写成"这个名字还没被注册"就等于替后端确认了账号不
                // 存在——那正是后端刻意不透露的东西。
                Text("No account signed in as \"\(name)\" with that password.\n\nSigning in with a new name creates the account — no separate registration needed.\n\nBy continuing you agree to the Terms of Use and Privacy Policy.")
            }
            .sheet(isPresented: $showTerms) {
                LegalSheetView(title: LegalText.isChineseLocale ? "使用条款" : "Terms of Use",
                               kind: "terms")
            }
            .sheet(isPresented: $showPrivacy) {
                LegalSheetView(title: LegalText.isChineseLocale ? "隐私政策" : "Privacy Policy",
                               kind: "privacy")
            }
        }
    }

    // MARK: - 布局一：竖着排（iPhone + iPad 竖屏）

    /// 头部 → 插画 → 白卡，白卡从插画底下抬起来。
    private func stackedLayout(_ size: CGSize, _ m: LoginMetrics) -> some View {
        ScrollView {
            VStack(spacing: 0) {
                column(m) { hero(m) }
                    .padding(.top, m.heroTopPadding)
                    .padding(.bottom, 20)

                Skyline(width: size.width, height: m.skylineHeight, alignment: .center)

                column(m) { sheetContent(m) }
                    .padding(.top, m.sheetTopPadding)
                    .padding(.bottom, 24)
                    .frame(maxWidth: .infinity)
                    .background(
                        SignInPalette.sheet,
                        in: UnevenRoundedRectangle(topLeadingRadius: m.sheetRadius,
                                                   topTrailingRadius: m.sheetRadius)
                    )
                    // 只向上打影（设计稿 `0 -6px 24px`）——它要表达的是这张卡压在
                    // 插画上面。深色下投影看不见，直接省掉。
                    .shadow(color: SignInPalette.accentInk.opacity(isDark ? 0 : 0.10),
                            radius: 12, y: -3)
            }
            .frame(width: size.width)
        }
        .scrollBounceBehavior(.basedOnSize)
        // 上半截暖底、下半截白卡，一起顶出安全区——状态栏那一条要是暖的，
        // 底下 home indicator 那一条要是白的。暖底给得比 头部+插画 宽裕，
        // 多出来的被白卡自己的底盖住。
        .background {
            VStack(spacing: 0) {
                SignInPalette.pitch.frame(height: m.skylineHeight + 560)
                SignInPalette.sheet
            }
            .ignoresSafeArea()
        }
    }

    /// 内容列：iPhone 满宽，iPad 竖屏收成 700 居中。
    private func column<Content: View>(
        _ m: LoginMetrics, @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .frame(maxWidth: m.columnWidth ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, m.heroSidePadding)
    }

    // MARK: - 布局二：左右分栏（iPad 横屏）

    /// 左栏暖底 + 房子，右栏一整块白。设计稿 B / C。
    private func splitLayout(_ size: CGSize, _ m: LoginMetrics) -> some View {
        let rightWidth = max(size.width - m.leftColumn, 0)
        return ZStack(alignment: .topLeading) {
            // 底色两层，都顶出安全区。右栏那块**保留左侧圆角**——所以不能简单地
            // 把背景按 x 切两半（那样圆角背后露出来的还是白，等于没圆角），
            // 必须让白卡自己带着圆角铺到屏幕边缘。
            SignInPalette.pitch
                .ignoresSafeArea()

            UnevenRoundedRectangle(topLeadingRadius: m.sheetRadius,
                                   bottomLeadingRadius: m.sheetRadius)
                .fill(SignInPalette.sheet)
                .shadow(color: SignInPalette.accentInk.opacity(isDark ? 0 : 0.08),
                        radius: 12, x: -3)
                .frame(width: rightWidth)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .ignoresSafeArea()

            // 房子贴左栏底边，同样顶到屏幕最下沿。
            Skyline(width: m.leftColumn, height: m.skylineHeight, alignment: .leading)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .ignoresSafeArea(edges: .bottom)

            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    hero(m)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, m.heroSidePadding)
                .padding(.top, m.heroTopPadding)
                .frame(width: m.leftColumn, alignment: .topLeading)

                // 右栏内容**垂直居中**（设计稿 `justify-content:center`）。
                // 套一层 ScrollView 是给大字号 / 小机型留的退路：内容比屏幕高时
                // 能滚，够矮时 `minHeight` 把它顶到满高再居中。
                ScrollView {
                    sheetContent(m)
                        .padding(.horizontal, m.sheetSidePadding)
                        .frame(width: rightWidth)
                        .frame(minHeight: size.height, alignment: .center)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: rightWidth)
            }
        }
    }

    // MARK: - 头部

    /// 品牌字 + 标题 + 统计胶囊（+ iPad 上那排平台缩写）。
    ///
    /// 改版前这里还有一枚 48pt 的 `Image("BrandLogo")`。两份设计稿都把它拿掉了，
    /// 理由站得住：下面那张插画本来就是图标的房子，同一张图在一屏里出现两次。
    private func hero(_ m: LoginMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("FlatRadar")
                .font(.system(size: m.wordmark, weight: .bold))
                .tracking(m.wordmark * -0.023)
                .foregroundStyle(SignInPalette.wordmark)

            Text("INDEPENDENT · v\(appVersion)")
                .font(.system(size: m.caption, design: .monospaced))
                .tracking(m.captionTracking)
                .foregroundStyle(pitchMuted)
                .padding(.top, m.caption > 10.5 ? 5 : 3)

            Text("Searching for a new\nhome in the Netherlands?")
                .font(.system(size: m.headline, weight: .bold))
                .tracking(m.headlineTracking)
                .foregroundStyle(SignInPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: m.headlineMaxWidth ?? .infinity, alignment: .leading)
                .padding(.top, m.headline > 30 ? 30 : 18)

            // 平台数由 Platform 推出来，不写死——写死的数字就是下一次
            // "登录页还写着 H2S"。接第八个平台时这里自动跟上。
            Text("Real-time availability across \(Platform.knownKeys.count) rental platforms.")
                .font(.system(size: m.subtitle))
                .foregroundStyle(pitchMuted)
                .padding(.top, m.subtitle > 15 ? 14 : 9)

            statChips(m)
                .padding(.top, m.chipHeight > 34 ? 22 : 16)

            if m.showsPlatformCodes {
                platformCodes.padding(.top, 20)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statChips(_ m: LoginMetrics) -> some View {
        // 会折行：iPad 横屏左栏只有 560 − 88 = 472pt，三个大胶囊排不下时该换行，
        // 而不是被挤扁（`HStack` 装不下会压缩子视图）。设计稿那两屏写的也是
        // `flex-wrap:wrap`。
        FlowLayout(spacing: m.chipGap, lineSpacing: m.chipGap) {
            chip(m, value: "\(liveCount)", label: "live") { liveDot(m) }
            chip(m, value: timeAgo, label: "ago") {
                // 设计稿是个空心圆环，不是时钟图标——和左边的实心绿点成对，
                // 一个"在线"一个"上一次"。
                Circle()
                    .strokeBorder(SignInPalette.ink.opacity(0.45), lineWidth: m.chipDot / 6)
                    .frame(width: m.chipDot + 1, height: m.chipDot + 1)
            }
            chip(m, value: "\(new24h)", label: "new today") {
                // 45° 的小方块。浅色是图标里那栋红房子的红，深色是点亮的窗黄。
                Rectangle()
                    .fill(SignInPalette.flagSolid)
                    .frame(width: m.chipDot - 1, height: m.chipDot - 1)
                    .rotationEffect(.degrees(45))
            }
        }
    }

    /// 统计胶囊的壳。数字加粗、单位不加粗，**两者同色**（改版前单位是另一档更淡
    /// 的灰，浅色下只有 3.6:1）。
    private func chip<Icon: View>(
        _ m: LoginMetrics, value: String, label: String, @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: m.chipGap - 1) {
            icon()
            HStack(spacing: 4) {
                Text(value).font(.system(size: m.chipFont, weight: .bold))
                Text(label).font(.system(size: m.chipFont))
            }
            .foregroundStyle(SignInPalette.ink)
            .fixedSize()
        }
        .padding(.horizontal, m.chipSidePadding)
        .frame(height: m.chipHeight)
        // ⚠️ 用 `.background(_, in:)` 而不是 `.background().clipShape()`：
        // 后者会把 live 绿点的光晕在圆角处剪掉一块，动画看起来不是"原地呼吸"
        // 而是朝一个方向偏出。与 DashboardView.liveBadge 保持一致。
        .background(SignInPalette.chip, in: RoundedRectangle(cornerRadius: m.chipRadius))
        .shadow(color: .black.opacity(isDark ? 0 : 0.08), radius: 4, y: 1)
    }

    /// live 那个会呼吸的绿点。
    private func liveDot(_ m: LoginMetrics) -> some View {
        let shouldAnimate = !reduceMotion
        return ZStack {
            if shouldAnimate {
                // 外层光晕：放大 + 渐隐反复。动画由 startLiveBreathing()
                // 的显式 withAnimation(.repeatForever) 驱动——这里不再挂
                // .animation(value:)，避免被外层转场事务捕获成弹跳。
                Circle()
                    .fill(SignInPalette.live)
                    .frame(width: m.chipDot, height: m.chipDot)
                    .scaleEffect(liveRipple ? 2.4 : 1.0)
                    .opacity(liveRipple ? 0.0 : 0.45)
            }
            // 内层实心点：原地轻微缩放呼吸（1.0↔1.12）。
            // 用裸 Circle 而不是 SF Symbol：`circle.fill` 在这个字号下 glyph box
            // 比可见圆大（含字体上下空白），HStack 居中对齐时圆会偏下。
            Circle()
                .fill(SignInPalette.live)
                .frame(width: m.chipDot, height: m.chipDot)
                .scaleEffect(liveCore ? 1.12 : 1.0)
                .shadow(color: SignInPalette.live.opacity(0.4), radius: 5)
        }
        // 锁定布局尺寸，光晕只在视觉上溢出
        .frame(width: m.chipDot, height: m.chipDot)
        .onAppear { if shouldAnimate { startLiveBreathing() } }
        // reduceMotion 切换时实时停/起。
        .onChange(of: shouldAnimate) { _, willAnimate in
            if willAnimate { startLiveBreathing() } else { stopLiveBreathing() }
        }
    }

    /// 那排平台缩写。只有 iPad 有——iPhone 那一屏塞不下，而且标题下面那句已经
    /// 写了「across 7 rental platforms」。
    ///
    /// 颜色用包里的 ``Platform/color(_:)``，**不用设计稿给的那七个 hex**。
    /// 那七个是从 Mac 端 `Theme.platform` 抄过来的，而 `Platform.color` 的文档
    /// 写得很明白：「同一个平台在任何图表、任何排序下都是同一个颜色」。登录页用
    /// 一套、进去之后房源徽章用另一套，就把这条规矩破了——为了对上设计稿的具体
    /// 色值，代价是 App 内部自相矛盾。
    ///
    /// ⚠️ 对比度：缩写用平台色压在同色 16% 的底上，`.orange`（SE）那一个只有
    /// 约 1.7:1。这一行是气氛不是必读信息，但开了「增加对比度」时换成墨色字，
    /// 给一条出路。
    private var platformCodes: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Platform.featuredOrder, id: \.self) { key in
                let tint = Platform.color(key)
                Text(Platform.shortName(key))
                    .font(.system(size: 11, weight: .heavy, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(highContrast ? SignInPalette.ink : tint)
                    .padding(.horizontal, 9)
                    .frame(height: 24)
                    .background(tint.opacity(highContrast ? 0.28 : 0.16),
                                in: RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    /// 启动 live 绿点的持续呼吸。两段各用**自己的** repeatForever 曲线显式驱动。
    /// 关键稳定点：
    /// 1. 先用 disablesAnimations 事务把相位复位到 false——上一轮 repeatForever
    ///    若被中途打断，残留中间态会和新动画 blend 成"弹跳"。
    /// 2. 用 DispatchQueue.main.async 推迟到下一个 runloop 再启动——避开视图
    ///    appear / 导航转场那一帧的 ambient 事务，否则 repeatForever 会被它
    ///    捕获成一次性 spring。
    private func startLiveBreathing() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            liveRipple = false
            liveCore = false
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) {
                liveRipple = true
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                liveCore = true
            }
        }
    }

    /// 停止呼吸：无动画复位到静止态（reduceMotion 开启时调用）。
    private func stopLiveBreathing() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            liveRipple = false
            liveCore = false
        }
    }

    // MARK: - 白卡里的内容

    private func sheetContent(_ m: LoginMetrics) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CONTINUE AS")
                .font(.system(size: m.sectionLabel, weight: .bold))
                .tracking(m.sectionLabelTracking)
                .foregroundStyle(sheetMuted)
                .padding(.leading, 4)

            roleCards(m).padding(.top, m.cardGap + 2)

            // 设计稿把 Face ID 画成一条**实心**主按钮，和上面两张淡底卡分开。
            // 但它只在钥匙串里真有凭据时才有意义——没有的话点了什么也不会发生。
            if BiometricAuthService.hasStoredCredentials {
                biometricButton(m).padding(.top, m.cardGap + 6)
            }

            footer(m)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func roleCards(_ m: LoginMetrics) -> some View {
        let tenant = expandableCard(
            m, mode: .user, icon: "person.fill", title: "Tenant",
            description: "Saved searches, alerts, watching history",
            isExpanded: expandedRole == .user)
        let guest = expandableCard(
            m, mode: .guest, icon: "eye.fill", title: "Guest",
            description: "Browse current listings only",
            isExpanded: expandedRole == .guest)
        // Staff 卡片已移除。后端 /auth/login 本来就按用户名分流——`__admin__` +
        // 管理密码走 admin 分支，其余走 user 表，角色由服务端在响应里给出
        // （AuthStore.applyMe 读 me.role）。管理员从这同一个表单登录即可，前端
        // 不需要一个独立入口，也不该在登录页上公示后台的存在。
        if m.cardsSideBySide {
            // `.top` 对齐：展开 Tenant 时它会长高，Guest 应该待在原地，
            // 而不是跟着一起被拉长成一张空荡荡的高卡。
            HStack(alignment: .top, spacing: m.cardGap) { tenant; guest }
        } else {
            VStack(spacing: m.cardGap) { tenant; guest }
        }
    }

    // MARK: - 角色卡

    private func expandableCard(
        _ m: LoginMetrics, mode: LoginMode, icon: String, title: String,
        description: String, isExpanded: Bool
    ) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.spring(duration: 0.35, bounce: 0.2)) {
                    expandedRole = isExpanded ? nil : mode
                }
                if mode == .guest { Task { await performLoginAsGuest() } }
            } label: {
                cardFace(m, mode: mode, icon: icon, title: title,
                         description: description, isExpanded: isExpanded)
            }
            .buttonStyle(.plain)

            if isExpanded, mode != .guest {
                credentialForm(m, mode: mode)
                    .padding(.horizontal, m.cardSidePadding - 2)
                    .padding(.bottom, m.cardSidePadding - 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        // 设计稿这两张卡是**没有描边、没有投影**的淡色底块——整屏的分层靠
        // 「暖底 / 白卡 / 淡块」三级明度，不靠线。展开时才给一圈强调色，
        // 因为那时候里面出现了输入焦点，需要说清楚"现在在这张卡里"。
        .background(fill(0.05, 0.07), in: RoundedRectangle(cornerRadius: m.cardRadius))
        .overlay {
            if isExpanded {
                RoundedRectangle(cornerRadius: m.cardRadius)
                    .strokeBorder(SignInPalette.accent, lineWidth: 2)
            }
        }
    }

    /// 卡片折叠时的那一面。
    ///
    /// iPad 竖屏两张卡并排、每张只有一半宽，说明文字放不进同一行，设计稿把它挪到
    /// 图标那一行**下面**；另外两种布局说明文字在标题下方、和图标同一行右侧。
    private func cardFace(
        _ m: LoginMetrics, mode: LoginMode, icon: String, title: String,
        description: String, isExpanded: Bool
    ) -> some View {
        let desc = Text(description)
            .font(.system(size: m.cardDescription))
            .foregroundStyle(sheetMuted)
            .fixedSize(horizontal: false, vertical: true)

        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: m.cardsSideBySide ? 12 : 13) {
                ZStack {
                    RoundedRectangle(cornerRadius: m.iconTileRadius)
                        .fill(fill(0.09, 0.10))
                        .frame(width: m.iconTile, height: m.iconTile)
                    Image(systemName: icon)
                        .font(.system(size: m.iconGlyph))
                        .foregroundStyle(SignInPalette.ink)
                }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(title)
                            .font(.system(size: m.cardTitle, weight: .bold))
                            .tracking(-0.3)
                            .foregroundStyle(SignInPalette.ink)
                        if mode == .user { mostBadge }
                    }
                    if !m.cardsSideBySide { desc }
                }
                // 不塞 `Spacer()`：HStack 的 spacing 会在 Spacer 两侧各算一次，
                // 白白多吃掉一个 gap，说明文字就从一行挤成了两行。设计稿是
                // `flex:1` 挂在文字块上、只有两个 gap——这一行等价。
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: m.chevron, weight: .light))
                    .foregroundStyle(isExpanded ? SignInPalette.accent : chevronTint)
                    .rotationEffect(isExpanded ? .degrees(90) : .zero)
            }
            if m.cardsSideBySide { desc }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, m.cardSidePadding)
        .padding(.top, m.cardTopPadding)
        .padding(.bottom, m.cardBottomPadding)
        .contentShape(Rectangle())
    }

    private var mostBadge: some View {
        Text("MOST")
            .font(.system(size: 10, weight: .heavy))
            .tracking(0.6)
            .foregroundStyle(SignInPalette.flagText)
            .padding(.horizontal, 7)
            .frame(height: 20)
            .background(SignInPalette.flagSolid.opacity(isDark ? 0.22 : 0.13),
                        in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 展开后的表单

    private func credentialForm(_ m: LoginMetrics, mode: LoginMode) -> some View {
        VStack(spacing: 8) {
            Divider()

            if mode == .user {
                HStack(spacing: 0) {
                    Image(systemName: "person.fill")
                        .font(.caption).foregroundStyle(sheetMuted).frame(width: 24)
                    TextField("Username", text: $username)
                        .textContentType(.username).textFieldStyle(.plain)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                }
                .padding(10)
                .background(fill(0.06, 0.08), in: RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 0) {
                Image(systemName: "key.fill")
                    .font(.caption).foregroundStyle(sheetMuted).frame(width: 24)
                // 眼睛 toggle：根据 showPasswordPlain 在 TextField/SecureField
                // 之间切换。两个组件共用同一 @State password，无需迁移。
                if showPasswordPlain {
                    TextField("App password", text: $password)
                        .textContentType(.password).textFieldStyle(.plain)
                        .autocorrectionDisabled().textInputAutocapitalization(.never)
                } else {
                    SecureField("App password", text: $password)
                        .textContentType(.password).textFieldStyle(.plain)
                }
                Button {
                    showPasswordPlain.toggle()
                } label: {
                    Image(systemName: showPasswordPlain ? "eye.slash.fill" : "eye.fill")
                        .font(.caption).foregroundStyle(sheetMuted)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showPasswordPlain ? "Hide password" : "Show password")
            }
            .padding(10)
            .background(fill(0.06, 0.08), in: RoundedRectangle(cornerRadius: 10))

            // 内联错误提示 —— 替代之前打断式 .alert。仅在该角色卡片展开时显示，
            // 跟密码输入框紧贴，用户改密码时一眼能看到。
            if let err = inlineLoginError(for: mode) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").font(.caption)
                    Text(err).font(.caption).multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button {
                Task { await performLogin(mode: mode) }
            } label: {
                HStack(spacing: 6) {
                    if auth.isLoading { ProgressView().tint(SignInPalette.onAccent) }
                    Text(mode == .user ? "Sign In / Register" : "Login")
                        .font(.system(size: 15, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 44)
            }
            // 不用 `.borderedProminent` + `.tint(accent)`：深色模式的强调色是暖黄
            // `#F5D99B`，系统会往上面放白字（约 1.3:1，基本看不见）。
            // 自己填底、自己定字色。
            .buttonStyle(.plain)
            .foregroundStyle(SignInPalette.onAccent)
            .background(
                SignInPalette.accent.opacity(loginDisabled(for: mode) ? 0.35 : 1),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .disabled(loginDisabled(for: mode))

            if mode == .user {
                // 注册不再是单独一屏：名字没被注册过时，登录失败会问一句
                // 「要不要用这个名字建号」，同意即注册。
                VStack(spacing: 2) {
                    // 与网页端登录页同一句：「未注册的账户将自动完成注册。」
                    Text("Unregistered accounts are created automatically.")
                    Text("By continuing you agree to the Terms of Use and Privacy Policy.")
                        .multilineTextAlignment(.center)
                }
                .font(.caption)
                .foregroundStyle(sheetMuted)
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Biometric

    /// 设计稿里那条实心主按钮。浅色是墨蓝底 + 暖白字，深色反过来是暖黄底 + 墨字。
    private func biometricButton(_ m: LoginMetrics) -> some View {
        let name = BiometricAuthService.biometryName
        return Button {
            Task { await performBiometricLogin() }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: name == "Face ID" ? "faceid" : "touchid")
                    .font(.system(size: m.faceGlyph))
                Text("Sign in with \(name)")
                    .font(.system(size: m.faceFont, weight: .semibold))
                    .tracking(-0.2)
                Spacer(minLength: 8)
                if isAuthenticatingBiometric {
                    ProgressView().controlSize(.small).tint(SignInPalette.onAccent)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: m.chevron - 2, weight: .light))
                        .opacity(0.55)
                }
            }
            .foregroundStyle(SignInPalette.onAccent)
            .padding(.horizontal, m.cardSidePadding)
            .frame(height: m.faceHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isAuthenticatingBiometric)
        .background(SignInPalette.accent, in: RoundedRectangle(cornerRadius: m.cardRadius))
    }

    // MARK: - 页脚

    private func footer(_ m: LoginMetrics) -> some View {
        VStack(alignment: m.centersFooter ? .center : .leading, spacing: 0) {
            // 只声明"与 Holland2Stay 无关"是不够的：现在监控七个平台，其余六个
            // 一个都没覆盖到。改成泛指，加平台时不必再回来改这句法律声明。
            Text("FlatRadar is an **independent** third-party client. Not affiliated with, endorsed by, or sponsored by any of the platforms it monitors. All listing data belongs to its respective owners.")
                .font(.system(size: m.legal))
                .foregroundStyle(sheetMuted)
                .multilineTextAlignment(m.centersFooter ? .center : .leading)
                .lineSpacing(m.legal * 0.42)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, m.centersFooter ? (m.legal > 12 ? 30 : 6) : 0)
                .padding(.top, m.centersFooter ? 18 : 34)

            HStack(spacing: 9) {
                Button(LegalText.isChineseLocale ? "使用条款" : "Terms") { showTerms = true }
                Text("·").foregroundStyle(chevronTint)
                Button(LegalText.isChineseLocale ? "隐私政策" : "Privacy") { showPrivacy = true }
                // 横屏那栏把域名推到同一行的右端（设计稿 B）。竖着排的两种布局
                // 域名单独一行、居中。
                if !m.centersFooter {
                    Spacer(minLength: 12)
                    domainMark(m)
                }
            }
            .font(.system(size: m.link, weight: .semibold))
            .foregroundStyle(SignInPalette.accent)
            .frame(maxWidth: .infinity, alignment: m.centersFooter ? .center : .leading)
            .padding(.top, m.centersFooter ? 10 : 14)

            if m.centersFooter {
                domainMark(m).padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: m.centersFooter ? .center : .leading)
    }

    private func domainMark(_ m: LoginMetrics) -> some View {
        Text("flatradar.app")
            .font(.system(size: m.domain, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(SignInPalette.domain)
    }

    // MARK: - 随主题 / 对比度变的几个色

    /// 暖底上的二级文字（INDEPENDENT、副标题）。设计稿给的是实色不是透明度——
    /// 浅色那个 `#54504A` 是**暖灰**，压在 `#F3F0E8` 上 6.95:1。
    private var pitchMuted: Color {
        highContrast ? SignInPalette.ink : SignInPalette.pitchMuted
    }

    /// 白卡上的二级文字（CONTINUE AS、卡片说明、免责声明）。`#5A646F` 是**冷灰**，
    /// 压在白上 6.0:1。暖底配暖灰、白卡配冷灰是设计稿刻意的分层。
    private var sheetMuted: Color {
        highContrast ? SignInPalette.ink : SignInPalette.sheetMuted
    }

    /// 卡片右端那个 `›`。非文字元素，按 UI 组件的 3:1 看，不按 4.5:1。
    private var chevronTint: Color {
        SignInPalette.ink.opacity(highContrast ? 0.55 : 0.30)
    }

    /// 胶囊 / 卡片 / 图标底的填充。浅色是墨色极淡的一层，深色是白色极淡的一层——
    /// 深色下用墨色会直接消失在底里。
    private func fill(_ light: Double, _ dark: Double) -> Color {
        isDark ? Color.white.opacity(dark) : SignInPalette.accentInk.opacity(light)
    }

    // MARK: - Fetch live stats

    private func fetchStats() async {
        do {
            let summary = try await APIClient.shared.getPublicSummary()
            liveCount = summary.total
            new24h = summary.new24h
            let iso = summary.lastScrape
            if !iso.isEmpty, iso != "--" {
                lastScrapeAt = (try? Self.isoFrac.parse(iso))
                    ?? (try? Self.isoNoFrac.parse(iso))
            }
        } catch { }
    }

    private func performBiometricLogin() async {
        isAuthenticatingBiometric = true
        defer { isAuthenticatingBiometric = false }

        guard let cred = await BiometricAuthService.authenticateAndLoad(
            reason: "Unlock FlatRadar to sign in"
        ) else { return }

        if cred.username == "__admin__" {
            await auth.loginAsAdmin(password: cred.password)
        } else {
            await auth.loginAsUser(name: cred.username, password: cred.password)
        }
        if auth.isAuthenticated, !auth.isGuest {
            await push.requestPermissionAndRegister()
        }
    }

    // MARK: - Helpers

    /// 当前应该在哪个角色的卡片里显示内联错误。
    /// - 只在卡片展开 && 该 mode 不是 guest && AuthStore 有错时显示
    /// - guest 模式没有密码字段，错误也没什么位置可放（理论上 guest 不会失败）
    ///
    /// **具体原因优先，通用标题兜底。** 这里只有一行位置，而 `errorDescription`
    /// 是通用标题（`.conflict` → 就是一个词 "Conflict"），`errorMessage` 才是
    /// 后端给的具体说明。`AuthStore.recordError` 的注释也是这么写的：
    /// 「errorMessage 优先取后端给的具体原因（failureReason）」。
    ///
    /// 曾经写成 `lastError?.errorDescription ?? errorMessage`，顺序反了。而
    /// `lastError` 对任何 APIError 都非 nil，所以后端的具体说明**永远走不到
    /// 屏幕上**：注册撞名（409）显示 "Conflict"，密码错误显示 "Login Failed"，
    /// 限流显示 "Too Many Requests"——每一条都把真正有用的那句话换成了一个词。
    ///
    /// 注册撞名那条尤其要紧：`/auth/login` 对「没这个人」和「密码错」返回同一个
    /// 401（后端刻意不区分，防用户名枚举），所以登录失败时客户端只能问一句
    /// 「要不要建号」。用户点了之后后端用 409 明确说了名字被占用——歧义就是在
    /// 这一步才消除的，那句话被吞掉，用户就永远推不出「密码打错了」。
    ///
    /// 别的地方（ListingsView / MapView 等）用 `errorDescription` 是对的：
    /// 那些是 ContentUnavailableView 的**标题**槽，具体说明另有 description 位置。
    /// 这里没有第二个位置。
    private func inlineLoginError(for mode: LoginMode) -> String? {
        guard expandedRole == mode, mode != .guest else { return nil }
        // 后端可能给回空字符串，那种情况下退回标题，别让错误整个消失。
        let specific = auth.errorMessage?.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = (specific?.isEmpty == false ? specific : nil)
            ?? auth.lastError?.errorDescription
        guard let err, !err.isEmpty else { return nil }
        return err
    }

    private func loginDisabled(for mode: LoginMode) -> Bool {
        if auth.isLoading { return true }
        switch mode {
        case .admin: return password.isEmpty
        case .user:  return username.isEmpty || password.isEmpty
        case .guest: return false
        }
    }

    private func performLogin(mode: LoginMode) async {
        // 必须在 login 之前设置 pendingBiometricCredential：
        // login 内部 isAuthenticated → true 时，ContentView.onChange
        // 会立即触发；如果 pending 在 login 之后才写，onChange 看到的还是 nil。
        if mode == .user,
           BiometricAuthService.isAvailable,
           !BiometricAuthService.hasStoredCredentials {
            auth.pendingBiometricCredential = (username, password, "user")
        }

        switch mode {
        case .admin: await auth.loginAsAdmin(password: password)
        case .user:  await auth.loginAsUser(name: username, password: password)
        case .guest: break
        }

        // 登录失败 → 清理 pending（isAuthenticated 未变，onChange 没触发）
        if !auth.isAuthenticated {
            auth.pendingBiometricCredential = nil
            // 凭据被拒（401）才提议建号。网络故障、限流、服务端错误一律不提——
            // 断网时问「要不要注册」会让用户以为自己的账号不存在了。
            // 管理员用同一个表单登录（Staff 入口已删）。他打错密码时不能弹
            // 「要用 __admin__ 建个号吗」——后端 /auth/register 明确拒绝 `__`
            // 开头的用户名，那个提议从一开始就不可能成立。
            if mode == .user,
               !isReservedName(username),
               case .unauthorized = auth.lastError {
                pendingRegistrationName = username
            }
            return
        }

        // 登录成功但拿到的不是 user 角色（管理员走同一个表单）——pending 里
        // 存着明文密码，而 ContentView 的保存提示只对 user 弹，它不会被消费，
        // 就这么留在内存里。这里显式清掉。
        if !auth.isUser {
            auth.pendingBiometricCredential = nil
        }

        if !auth.isGuest {
            await push.requestPermissionAndRegister()
        }
    }

    /// 后端保留给自己的用户名（`__admin__` 等以 `__` 开头的），不可注册。
    /// 与 `app/routes/api_v1/auth.py` 的 `_register` 校验对齐。
    private func isReservedName(_ name: String) -> Bool {
        name.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("__")
    }

    private func performLoginAsGuest() async {
        auth.enterAsGuest()
    }

    /// 用主表单里那对用户名/密码建号。
    ///
    /// 只在用户于确认框里点了「Create Account」之后才会走到这里——那个确认框
    /// 上写着条款同意，这是 App 端 terms_accepted 的落点。Web 端把自动注册删掉
    /// 时列的头一条理由就是"登录表单上根本没有那个勾选框，只能替用户默认同意"。
    ///
    /// 用户名按后端同样的规则截到 64 字符：Web 那条理由之二是自动注册绕过了
    /// `[:64]`，客户端先截一次，显示的名字与真正建出来的账号一致。
    private func performRegister() async {
        let name = String(username.trimmingCharacters(in: .whitespaces).prefix(64))
        guard name.count >= 2, password.count >= 4 else { return }

        // 注册前设 pending，同 performLogin——register 内部 login 完成后
        // isAuthenticated → true，ContentView.onChange 需要此时 pending 已就位。
        if BiometricAuthService.isAvailable,
           !BiometricAuthService.hasStoredCredentials {
            auth.pendingBiometricCredential = (name, password, "user")
        }

        await auth.register(name: name, password: password)
        if auth.isAuthenticated, !auth.isGuest {
            await push.requestPermissionAndRegister()
        } else {
            auth.pendingBiometricCredential = nil
        }
    }
}

// MARK: - 插画

/// 那条运河天际线。
///
/// 素材是 App 图标自己的三层拼出来的**一"幅"**（三栋房子 + 一段运河 + 倒影，
/// 见 `output/icon/make-signin-skyline.py`），天际线由这里横着摆 N 幅拼出来。
///
/// 为什么不烤成一条现成的长图
/// ------------------------
/// 三份设计稿要的幅数不一样：iPhone 3 幅、iPad 竖屏 4 幅、iPad 横屏左栏 3 幅，
/// 而且**每幅的显示尺寸也不同**——房子在 iPad 上更大（一幅 208pt 宽），不是
/// "同样大小摆更多幅"。烤死幅数就得出三份素材。
///
/// 幅与幅之间**交替镜像**（设计稿的 transform 就是 N、M、N、M），这样一眼看不出
/// 是同一张图在重复。素材那条运河线跨满整幅且是方头的，接缝处严丝合缝。
private struct Skyline: View {
    let width: CGFloat
    let height: CGFloat
    /// 摆不满整数幅时，多出来的从哪边裁。设计稿竖排是 `xMidYMax`（居中），
    /// 横屏左栏是 `xMinYMax`（贴左）。
    let alignment: Alignment

    /// 一幅的宽高比，等于素材 viewBox 的 659:730。
    /// `tests/test_signin_skyline.py` 把 viewBox 钉住了，改那边这里要跟着改。
    private static let aspect: CGFloat = 659.0 / 730.0

    var body: some View {
        let tile = height * Self.aspect
        let count = max(1, Int((width / tile).rounded(.up)))
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Image("SignInSkyline")
                    .resizable()
                    .frame(width: tile, height: height)
                    .scaleEffect(x: index.isMultiple(of: 2) ? 1 : -1, y: 1)
            }
        }
        // 确定值，不是上限——摆出来的总宽一定 ≥ width，靠这一层裁掉多的，
        // 同时保证它不会反过来把外层内容撑宽。
        .frame(width: width, height: height, alignment: alignment)
        .clipped()
    }
}

// MARK: - 登录屏的调色板

/// 只有登录屏用的一组色，**全部取自 App 图标**。
///
/// 为什么不进 `FlatRadarCore` 的 `Color+Tokens`
/// ------------------------------------------
/// 那份注释自己写了规矩：「屏幕专属的 chrome 保留在原文件里，避免 token 体系
/// 膨胀」。这些值只有这一屏在用，而且它们的**定义**就是"图标里的那个颜色"，
/// 不是什么可复用的业务语义。
///
/// 每个值的出处
/// -----------
/// - ``pitch`` 浅色 `#F3F0E8` 正是 `2-windows.svg` 里窗户的填充色。插画的窗户是
///   拿背景色"抠"出来的——底色一旦偏一点，窗户就会显出一圈边。
/// - ``accent`` 浅色 `#293B49` 是图标里那栋深色房子；深色 `#F5D99B` 是深色版
///   图标里点亮的窗户——深色模式下墨蓝会直接沉进背景，只能反过来用亮色。
/// - ``flagSolid`` `#AD3E39` 是图标里那栋红房子。
///
/// 二级文字为什么是**实色**不是透明度
/// --------------------------------
/// 头一版我按设计稿的 `rgba(27,43,56,.62)` 写成 `ink.opacity(0.62)`，压在
/// `#F3F0E8` 上只有 4.0:1，低于 WCAG AA 的 4.5:1，我自己上调到了 0.66。
/// 设计稿随后把整套二级色换成了实色，而且分了**冷暖两套**：暖底上用暖灰
/// `#54504A`（6.95:1），白卡上用冷灰 `#5A646F`（6.0:1）。透明度做不到这件事——
/// 同一个墨色透下去，底是暖的它就偏暖，永远只有一套。现在照实色搬。
private nonisolated enum SignInPalette {
    static let pitch = Color(light: 0xF3F0E8, dark: 0x111C29)
    static let ink = Color(light: 0x1B2B38, dark: 0xEDF1F5)
    static let accent = Color(light: 0x293B49, dark: 0xF5D99B)
    /// 那栋深色房子本身。深色模式下 ``accent`` 变成了暖黄，但"墨"这个角色
    /// （投影、极淡的填充）还得有人担着，所以单列一个。
    static let accentInk = Color(light: 0x293B49, dark: 0x0A1420)
    /// 压在 ``accent`` 上的字色。
    static let onAccent = Color(light: 0xF3F0E8, dark: 0x1B2733)
    /// 品牌字。浅色下就是 ``accent``，深色下设计稿用的是**正文色**而不是暖黄——
    /// 暖黄留给可点的东西（Face ID、Terms/Privacy），品牌字不可点。
    static let wordmark = Color(light: 0x293B49, dark: 0xEDF1F5)
    /// 下半屏那张卡（横屏时是右栏整块）的底。
    static let sheet = Color(light: 0xFFFFFF, dark: 0x1B2733)
    /// 暖底上的二级文字。暖灰。
    static let pitchMuted = Color(light: 0x54504A, dark: 0xAFB6BD)
    /// 白卡上的二级文字。冷灰。
    static let sheetMuted = Color(light: 0x5A646F, dark: 0xA9B3BD)
    /// `flatradar.app`。比 ``sheetMuted`` 再淡一档，但仍然过 AA（浅色 4.75:1）。
    static let domain = Color(light: 0x6B747D, dark: 0x98A3AE)
    /// 统计胶囊的底。浅色是实白 + 一层浅影，深色只能靠比底亮一档。
    static let chip = Color(lightColor: .white, darkColor: .white.opacity(0.09))
    /// 红房子色，用在 MOST 徽章底和 "new today" 的小菱形上。
    static let flagSolid = Color(light: 0xAD3E39, dark: 0xF5D99B)
    /// MOST 徽章的字。深色下红字压在半透红底上读不出来，提亮一档。
    static let flagText = Color(light: 0xAD3E39, dark: 0xE8968F)
    static let live = Color(light: 0x34C759, dark: 0x30D158)
}

/// `nonisolated` **不是可选的**——少了它就是一次必崩。
///
/// 工程开着 `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，没标注的类型和函数一律
/// 隐式 `@MainActor`，包括下面传给 `UIColor(dynamicProvider:)` 的那个闭包。而
/// UIKit / SwiftUI **会在非主线程上调它**去解析颜色（比如 HDR 解析走
/// `ViewGraph.updateOutputsAsync`），隔离检查当场 `dispatch_assert_queue_fail`：
///
///     libswift_Concurrency  swift_task_checkIsolatedSwift
///     FlatRadar             closure #1 in Color.init(light:dark:)
///     UIKitCore             -[UIDynamicProviderColor _resolvedColorWithTraitCollection:]
///     SwiftUICore           PlatformColorProvider.resolveHDR(in:)
///
/// 这是 2.1.0 那次线上无限崩溃的同一类问题（后台回调的 ObjC delegate 没写
/// `nonisolated`）。`Color+Tokens.swift` 里那句「模型层和常量是这个默认值的例外」
/// 说的就是这个：色板是纯常量，本来就该跟 actor 无关。
private nonisolated extension Color {
    /// 设计稿给的是浅 / 深两个 hex，这里直接照搬，不再绕 Asset Catalog——
    /// 那 8 个语义色进 catalog 是因为**两端共用**，这些只有登录屏用。
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }

    /// 两边不是纯色 hex（比如深色那半带透明度）时用这个。
    init(lightColor: Color, darkColor: Color) {
        self.init(uiColor: UIColor { traits in
            UIColor(traits.userInterfaceStyle == .dark ? darkColor : lightColor)
        })
    }
}

private nonisolated extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

// MARK: - Legal sheet helper

struct LegalSheetView: View {
    let title: String
    let kind: String  // "terms" or "privacy"
    @State private var loaded: String?
    @State private var isLoading = true
    @Environment(\.dismiss) private var dismiss

    /// Local fallback when API is unreachable
    private var fallback: String {
        if kind == "privacy" { return LegalText.privacyLocalized }
        return LegalText.termsLocalized
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if isLoading {
                    ProgressView().padding(.top, 80)
                }
                Text(loaded ?? fallback)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                do {
                    let resp = try await APIClient.shared.getLegal()
                    loaded = kind == "privacy" ? resp.privacy : resp.terms
                } catch {
                    // Use local fallback (already default)
                }
                isLoading = false
            }
        }
    }
}
