import SwiftUI
import StoreKit
import FlatRadarCore

/// Settings 的 **Support** tab：打赏 + 评分。
///
/// 为什么单开一个 tab 而不是塞进 General
/// -----------------------------------
/// 打赏那一段是**三个可购买商品**加上加载中 / 失败 / 重试三种状态，塞进
/// General（外观 / 菜单栏 / 反馈 / 条款 / 版本）会把那一页变成杂物抽屉。
/// 两件事又是同一类："你可以怎么支持这个 app"。
///
/// Send Feedback 留在 General 没动——挪它属于这次没被要求的改动。
///
/// 内购**不需要为 macOS 单独开放**——查过 ASC 才知道的
/// ----------------------------------------------
/// 这个仓库里原先写着「商品要先在 App Store Connect 上对 macOS 开放」，
/// 而 ASC 上**根本没有这个开关**：内购挂在 *app* 上，不挂在平台上。
/// `inAppPurchasesV2` 的对象只有 `productId / type / state / territory 可用性`
/// 这些字段，没有任何平台维度；FlatRadar 又是**一个 app 记录**同时带
/// IOS 和 MAC_OS 两条版本记录，所以三个 `coffee.*`（都已 APPROVED、175 个地区、
/// 含 NLD 和 USA）对 Mac 天然就是可用的。
///
/// 实测佐证：`FlatRadar.storekit` 里 flatwhite 写的是 5.99，ASC 基准区（NLD）
/// 也是 €5.99，而运行中的 Mac app 显示 **US$4.99**——那是同一个价格档在美区
/// 商店的对应价。两个本地来源都产不出这个数，说明取到的是**真实商品**。
///
/// Mac scheme 上仍然挂着 `FlatRadar.storekit`（和 iOS scheme 一样）：它的价值是
/// 从 Xcode 跑时有一套确定的、不花钱的商品，不是因为真商品拿不到。
/// 副作用要知道：**从 Xcode 跑看到的是配置文件的价，直接打开 .app 看到的是真价**。
///
/// ⚠️ 评分这一半的前提是真的
/// ------------------------
/// Mac 版还没上架 Mac App Store。`requestReview` 在没上架的 app 上什么也不会发生
/// （系统决定弹不弹，调用方无从得知），`writeReviewURL` 打开的商店页此刻也还
/// 不存在。代码是对的，链路要等上架。
struct SupportSettings: View {

    @Environment(AuthStore.self) private var auth
    @Environment(CoffeeStore.self) private var coffee
    @Environment(ReviewPromptStore.self) private var review
    @Environment(\.requestReview) private var requestReview

    var body: some View {
        Form {
            // admin 是后端运维者——给自己买咖啡没意义，和 iOS 同一条判断。
            if !auth.isAdmin {
                coffeeSection
            }
            rateSection
        }
        .formStyle(.grouped)
        .task { await coffee.loadProducts() }
        .alert("Thank you! 🙏", isPresented: Binding(
            get: { coffee.showThanks }, set: { coffee.showThanks = $0 })) {
            // 问评分的时机是**致谢弹窗被关掉之后**，不是购买成功那一刻：
            // 两个系统弹窗叠在一起，第二个大概率被系统直接吞掉，白白用掉
            // 一年三次配额里的一次。和 iOS 同一个处理。
            Button("You're welcome!") {
                guard review.shouldAsk(.tipCompleted) else { return }
                review.markAsked()
                requestReview()
            }
        } message: {
            Text("Your support means a lot.\nEnjoy your \(coffee.thanksMessage)!")
        }
    }

    // MARK: - 打赏

    @ViewBuilder
    private var coffeeSection: some View {
        Section {
            if coffee.isLoading && coffee.products.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading…").foregroundStyle(.secondary)
                }
            } else if coffee.products.isEmpty {
                // 空状态要说**下一步**。StoreKit 把拿不到的商品 ID 静默丢掉，
                // 只写"出错了"的话，用户唯一能做的就是盲目重试。
                // 商品本身在 ASC 上是 APPROVED 且对这个 app 全平台可用的，
                // 所以走到这里基本只剩网络和商店账号两种原因。
                VStack(alignment: .leading, spacing: 6) {
                    Text("Couldn't load the tips")
                        .foregroundStyle(.secondary)
                    Text("Check your connection and that you're signed in to the App Store. Nothing is wrong with your FlatRadar account.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Try Again") { Task { await coffee.loadProducts() } }
                }
            } else {
                ForEach(coffee.products, id: \.id) { product in
                    HStack {
                        Text(product.displayName)
                        Spacer(minLength: 12)
                        Button(product.displayPrice) {
                            Task { await coffee.purchase(product) }
                        }
                        .monospacedDigit()
                    }
                }
            }

            if let err = coffee.purchaseError {
                Text(verbatim: err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Buy me a coffee")
        } footer: {
            Text("A one-time tip to support development. Does not unlock any features.")
        }
    }

    // MARK: - 评分

    @ViewBuilder
    private var rateSection: some View {
        Section {
            // ⚠️ 手动入口**必须是链接**，不能调 `requestReview()`。Apple 明令禁止
            // 把系统评分框挂在「点这里评分」按钮上。`?action=write-review`
            // 直接打开撰写评论界面。这条规则和 URL 都在包里（`ReviewPromptStore`），
            // 两端共用一份。
            Link(destination: ReviewPromptStore.writeReviewURL) {
                Text("Rate FlatRadar")
            }
        } footer: {
            // 只说它做什么。原先还跟了一句"Mac 版还没上架，所以这个链接现在
            // 打不开"——那是一句**上架当天就会变成假话**的文案，而没有任何
            // 机制会提醒谁回来删它。开发侧的这个提醒留在类型注释里就够了。
            Text("Opens the App Store.")
        }
    }
}
