import Foundation
import Security

/// Bearer token 的钥匙串存取。按服务器主机名分条，换服务器就是另一条。
///
/// 2026-09-09：修掉一条一直在失败的查询
/// ------------------------------------
/// 这三条查询原本都带 `kSecAttrService`。**那是 generic password 的属性**，
/// 用在 `kSecClassInternetPassword` 上会让整条查询被系统拒掉：
///
///     OSStatus -25303 errSecNoSuchAttr — The specified attribute does not exist.
///
/// 后果不是「报错」，是**静默**：``AuthStore`` 的 catch 会把 token 回退写进
/// `UserDefaults`，登录照常成功、界面没有任何异样，而 bearer token 明文躺在
/// 沙盒里。而且写失败的同时读也失败（同一个非法属性），所以连「上次存的还在
/// 不在」都查不出来——这个洞没有任何自曝的途径。
///
/// 是在 iPad 上跑 ``KeychainTests`` 时撞出来的：实测去掉这个属性后增 / 查 / 删
/// 全部通过。同目录的 ``BiometricAuthService`` 用的是 `kSecClassGenericPassword`
/// + account + service，组合正确，不受影响。
///
/// **为什么不顺手改成 generic password**：万一某个旧系统版本对多余属性是宽容的、
/// 真存下过条目，换 class 会让它们变成孤儿（用户静默登出）；保持 class 只去掉
/// 非法属性，最坏情况是没东西可捞，不会更糟。
///
/// 条目的命名空间由 app 的钥匙串访问组提供，不再需要单独的 service 常量。
enum KeychainManager {

    /// macOS 上必须**显式**要求 data protection 钥匙串。
    ///
    /// 不设这个键时，macOS 走的是旧的文件式钥匙串（login.keychain）：受 App
    /// Sandbox 的约束不同，`kSecAttrAccessible` 也不按 iOS 那套解释。更要命的是
    /// 增 / 查 / 删只要有一处不带它，就会出现「存进去了但查不到」——两次查询落在
    /// **两个不同的钥匙串**上。所以它必须拼进每一条查询，不能只加在写入那条。
    /// 见 Apple TN3137: On Mac Keychain APIs and Implementations。
    ///
    /// iOS / iPadOS 只有 data protection 钥匙串，这个键被忽略。这里仍然用
    /// `#if os(macOS)` 而不是无条件加：线上 iOS 有真实用户，而本地没有凭据能
    /// 实测登录路径。把影响面钉成零，比让代码少一个条件编译重要。
    private static var dataProtection: [String: Any] {
        #if os(macOS)
        [kSecUseDataProtectionKeychain as String: true]
        #else
        [:]
        #endif
    }

    static func save(token: String, server: String) throws {
        // Remove any existing item first
        delete(server: server)

        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String:       kSecClassInternetPassword,
            kSecAttrServer as String:  server,
            kSecValueData as String:   data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ].merging(dataProtection) { a, _ in a }
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError(operation: "save", status: status)
        }
    }

    static func load(server: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassInternetPassword,
            kSecAttrServer as String:  server,
            kSecReturnData as String:  true,
            kSecMatchLimit as String:  kSecMatchLimitOne,
        ].merging(dataProtection) { a, _ in a }
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else {
            return nil
        }
        return token
    }

    static func delete(server: String) {
        let query: [String: Any] = [
            kSecClass as String:       kSecClassInternetPassword,
            kSecAttrServer as String:  server,
        ].merging(dataProtection) { a, _ in a }
        SecItemDelete(query as CFDictionary)
    }
}
