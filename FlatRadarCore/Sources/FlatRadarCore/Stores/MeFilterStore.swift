import Foundation

/// 当前 user 的 ``ListingFilter`` 缓存 + 编辑保存能力。
///
/// 数据来源
/// --------
/// - 登录成功后 ``AuthStore.applyMe`` 已经把 ``user.listing_filter`` 写进
///   ``UserInfo``，进入 Settings/Edit 时直接读那个就行
/// - 但编辑提交后服务端会校验/规范化字段（比如 ALLOWED 字段大小写、energy
///   白名单），返回标准形态——这里就要把 ``AuthStore.userInfo.listing_filter``
///   也同步更新，否则 Dashboard 的 matched 计数会跟实际不一致
///
/// 因此 save 路径会：
/// 1. ``PUT /me/filter`` 提交客户端构造的新 filter
/// 2. 拿后端 round-trip 返回的标准化版本
/// 3. 让 caller 决定是否调 ``AuthStore`` 把 ``UserInfo`` 替换
@MainActor
@Observable
public final class MeFilterStore {

    /// 隐式 init 随 `public` 一起变成 internal，宿主 app 构造不了。
    /// 这些 store 的属性全有默认值，空实现与迁移前的隐式构造等价。
    public init() {}
    public var isSaving = false
    public var errorMessage: String?
    var lastResponse: MeFilterResponse?

    private let client = APIClient.shared

    public func save(_ filter: ListingFilter) async -> MeFilterResponse? {
        guard !isSaving else { return nil }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            let resp = try await client.updateMeFilter(filter)
            lastResponse = resp
            return resp
        } catch {
            // 被取消不是失败——见 Error.isCancellation。
            if !error.isCancellation {
                errorMessage = error.localizedDescription
            }
            #if DEBUG
            print("[MeFilterStore] save error: \(error)")
            #endif
            return nil
        }
    }

    /// 登出时清空——上个用户的 filter response 不应给下个用户看到。
    public func clear() {
        isSaving = false
        errorMessage = nil
        lastResponse = nil
    }
}
