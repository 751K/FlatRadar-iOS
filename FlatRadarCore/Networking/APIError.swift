import Foundation

enum APIError: Error {
    case unauthorized(String)
    case forbidden(String)
    case notFound(String)
    case validation(String)
    case conflict(String)      // 409 — 资源冲突，如注册时用户名已存在
    case rateLimited(String)
    case serverError(String)
    case network(any Error)
    case decoding(any Error)
    case badResponse(Int)

    /// Create from backend error payload. Code never shown to user —
    /// clients branch on code, not message.
    static func fromPayload(code: String, message: String) -> APIError {
        switch code {
        case "unauthorized": return .unauthorized(message)
        case "forbidden":   return .forbidden(message)
        case "not_found":   return .notFound(message)
        case "validation":  return .validation(message)
        case "conflict":    return .conflict(message)
        case "rate_limited": return .rateLimited(message)
        case "server_error": return .serverError(message)
        default:            return .serverError(message)
        }
    }

    /// 401 or 403 — the session should be cleared and user redirected to login.
    var isAuthError: Bool {
        switch self {
        case .unauthorized, .forbidden: return true
        default: return false
        }
    }

    /// Errors that make sense to retry (network blip, server hiccup).
    var isRetryable: Bool {
        switch self {
        case .network, .serverError, .rateLimited: return true
        case .badResponse(let code): return code >= 500 || code == 429
        default: return false
        }
    }
}

extension APIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unauthorized: return String(localized: "Login Failed")
        case .forbidden:    return String(localized: "Access Denied")
        case .notFound:     return String(localized: "Not Found")
        case .validation:   return String(localized: "Invalid Request")
        case .conflict:     return String(localized: "Conflict")
        case .rateLimited:  return String(localized: "Too Many Requests")
        case .serverError:  return String(localized: "Server Error")
        case .network:      return String(localized: "Connection Failed")
        case .decoding:     return String(localized: "Data Error")
        case .badResponse:  return String(localized: "Unexpected Response")
        }
    }

    var failureReason: String? {
        switch self {
        case .unauthorized(let msg): return msg
        case .forbidden(let msg):    return msg
        case .notFound(let msg):     return msg
        case .validation(let msg):   return msg
        case .conflict(let msg):     return msg
        case .rateLimited(let msg):  return msg
        case .serverError(let msg):  return msg
        case .network(let err):      return String(localized: "Network error: \(err.localizedDescription)")
        case .decoding:              return String(localized: "The server returned data in an unexpected format.")
        case .badResponse(let code): return String(localized: "Server returned HTTP \(code)")
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .unauthorized: return String(localized: "Please sign in again.")
        case .forbidden:    return String(localized: "You don't have permission to access this.")
        case .network:      return String(localized: "Check your internet connection and try again.")
        case .serverError:  return String(localized: "Please try again later.")
        case .rateLimited:  return String(localized: "Please wait a moment before retrying.")
        case .notFound:     return String(localized: "It may have been removed.")
        case .conflict:     return String(localized: "Try a different value.")
        case .validation, .decoding, .badResponse: return nil
        }
    }

    /// SF Symbol name suitable for ContentUnavailableView.
    var systemImage: String {
        switch self {
        case .unauthorized: return "lock.shield"
        case .forbidden:    return "hand.raised.slash"
        case .network:      return "wifi.slash"
        case .serverError:  return "exclamationmark.icloud"
        case .rateLimited:  return "clock.badge.exclamationmark"
        case .notFound:     return "questionmark.folder"
        case .validation:   return "exclamationmark.triangle"
        case .conflict:     return "exclamationmark.bubble"
        case .decoding:     return "doc.badge.gearshape"
        case .badResponse:  return "exclamationmark.arrow.triangle.2.circlepath"
        }
    }
}

extension Error {
    /// 这次失败是不是「被取消」——如果是，**它不是失败**。
    ///
    /// 取消的来源是视图生命周期，不是网络或后端：SwiftUI 的 `.task` 在视图消失或
    /// 被重建时会 cancel 里面的 Task，`.refreshable` 在下拉动画被打断时也会。
    /// `URLSession` 随之抛 `URLError.cancelled`，``APIClient`` 把它归一成
    /// `CancellationError`（见那里的 catch）。
    ///
    /// 把它当失败报给用户，弹出来的是一句谁也看不懂的
    /// 「The operation couldn't be completed. (Swift.CancellationError error 1.)」
    /// ——而且弹的那一刻界面通常是好的：数据要么本来就在，要么下一次 `.task`
    /// 马上会重拉。2026-09-05 在日历和 Alerts 两个页面实际出现过。
    ///
    /// 三种形态都认：
    /// - `CancellationError`——APIClient 归一之后的，以及 `Task.checkCancellation()`
    /// - `URLError.cancelled`——没走 APIClient 的直接调用
    /// - `APIError.network` 包着上面两者——网络分支是原样包装的
    ///
    /// `nonisolated`：纯判定，不碰任何状态。工程默认 actor 隔离是 MainActor，
    /// 不写这个的话它会跟着变成 MainActor 隔离——store 里调没问题（它们本来就在
    /// 主 actor 上），但从 detached task 或测试的 autoclosure 里就调不动了。
    nonisolated var isCancellation: Bool {
        if self is CancellationError { return true }
        if let urlError = self as? URLError, urlError.code == .cancelled { return true }
        if let apiError = self as? APIError, case .network(let underlying) = apiError {
            return underlying.isCancellation
        }
        return false
    }
}
