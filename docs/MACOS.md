# macOS 客户端任务书

写于 2026-09-09。这份文档只管 macOS 客户端这一件事；版本目标看 [NEXT.md](NEXT.md)，
视觉规范和页面清单看 [DESIGN.md](DESIGN.md)。

2026-09-09 审阅修订：已对照当前 iOS 代码、本地 macOS SDK 和文末 Apple 文档。
维护取舍：优先降低长期双端维护成本，先迁移为仓库内的本地 SwiftPM 包，再开发 Mac 视图。

**2026-09-09 执行记录**：Phase 0 已完成，Phase 1 的 target / 签名部分已完成。
`FlatRadarCore/` 现在是本地 SwiftPM 包，iOS 与 macOS 两个 app 都只依赖它的产品。
两端 Debug / Release 均构建通过，测试 175 条（78 app + 97 包）与迁移前一致，
另新增 3 条包资源测试。后端排序能力、签名权限和实际推送链路仍待按阶段验证。

**一句话**：把 `FlatRadarCore/` 这层现成的模型 / 网络 / store 整理为两端依赖的本地 SwiftPM 包，
为 macOS 单独写一套视图层，
做成**原生 macOS app**——不是 Catalyst，不是 Designed for iPad。

---

## 为什么是原生

三条路都评估过：

| | 跑的是什么 | 代价 | 结论 |
|---|---|---|---|
| Designed for iPad | iOS 二进制本身 | 零（ASC 一个勾，已开） | **已在用**，但只是"装在盒子里的 iPad app" |
| Mac Catalyst | 同一份视图代码编成 Mac 二进制 | 低 | **排除** |
| 原生 macOS | 为 Mac 单写视图层 | 高 | **选它** |

排除 Catalyst 的理由不是它不好用，而是**它的卖点恰好是我们不要的东西**。Catalyst 省的是
"视图层不用重写"，而做 Mac 版的全部动机正是视图层要重写——Mac 是指针 + 键盘的机器：

- **悬停**在触摸屏上不存在，是白捡的一整层交互
- **选中**很便宜，所以可以"选中什么就在旁边显示什么"，不用进出详情页
- **键盘**让连续浏览近乎免费，↑↓ 翻二十条的成本等于手机上滑一次

租房本质是**比较**任务，而比较需要把候选并排放。Mac 版把表格、键盘浏览和固定候选并排查看
作为主要交互，再接入系统窗口与菜单。网页和 iPad 也能实现比较；选择原生 macOS 的理由是
希望围绕这些桌面交互完整设计一套体验，而不是假定其它平台做不到。

**已知的反对意见，写下来免得反复**：Mac 端的桌面需求其实已经被后端的网页端覆盖了
（`templates/` 下 listings / map / calendar / stats 全套），而 Designed for iPad 三个月只有
2 次下载、7 周零活跃。所以这个项目**不以用户需求立项**，它的理由是维护者想做。这是正当理由，
但别在后面的决策里假装有需求压力——凡是"为了赶上线而降低质量"的取舍，在这个项目里都不成立。

---

## 现状盘点（开工前，2026-09-09）

`f7f77f7` 把跟 UI 无关的三层挪进 `FlatRadarCore/`，但当时同属 `FlatRadar` 这一个 target、
一个模块。**2026-09-09 已做成本地 SwiftPM 包**（下表是迁移前的盘点，保留作为对照）。

| | 行数 | macOS 上怎么办 |
|---|---|---|
| `FlatRadarCore/Models` | 2857 | 复用；语义颜色等依赖共享资源 |
| `FlatRadarCore/Networking` | 1081 | 复用；设备信息、钥匙串和平台上报需适配 |
| `FlatRadarCore/Stores` | 1797 | 复用业务逻辑；推送桥接、设备名及状态归属需调整 |
| `FlatRadar/Navigation` | 186 | **不共享**，只抽路由类型和 URL 解析 |
| `FlatRadar/Push` | 135 | 重写（`UIApplicationDelegate` → `NSApplicationDelegate`） |
| `FlatRadar/Diagnostics` | 243 | 重写或跳过（MetricKit 在 macOS 上部分属性不可用） |
| `FlatRadar/Views` | 11165 | 按选定功能独立写 Mac 视图 |

Core 约 5735 行可作为复用基础，现有视图约 11165 行供功能参考。这不是承诺原样共享全部 Core，
也不是要求在 Mac 重写全部 iOS 页面。这是**第二个 app**，按晚上和周末算，以周为单位，不是以天。

### 决定：现在做一个本地 SwiftPM 包

**优先减少长期维护工作，接受一次性的迁移成本。** 在第二个 app 开始依赖 Core 前完成模块边界，
避免两端铺开后再同时改调用、资源与测试。把共享源文件分别加入两个 app target 也能共享代码，
但不能阻止 Core 反向引用同一模块内的视图，也需要维护两套编译配置与源码归属。

采用**同一仓库、一个本地包、一个主要库 target `FlatRadarCore`，加包测试 target**。
包放在 `FlatRadarCore/` 下，不新建仓库、不单独发版、不建立远程依赖，不为 Models / Networking /
Stores 分别拆包。iOS 与 Mac 都只依赖包产品，不再直接编译这批源文件。

包负责模型、网络、共享业务状态、路由类型，以及自身使用的字符串和语义颜色。各 app 负责视图、
窗口导航、生命周期、权限与系统 delegate 桥接、签名及平台资源。允许包内保留两端都支持的 SwiftUI
颜色 / 展示辅助代码，不为追求「纯 Foundation」额外拆模块。UIKit / AppKit 专有能力通过适配接口进入。

一次性迁移必须处理四件事：

1. **最小公开接口**：只对 app 真正需要的类型、成员和构造方法加 `public`；内部网络细节与实现仍
   保持内部可见，不批量公开整个目录。后续新增跨模块能力需要同步维护接口，这是持续成本。
2. **保留并发语义**：包有独立编译配置。明确工具链要求，在 `Package.swift` 设置默认隔离并核对
   已启用并发特性；迁移期间保留现有 `@MainActor` / `nonisolated` 语义，不顺手重构并发模型。
   Swift 6.2 起支持 `.defaultIsolation(MainActor.self)`，不能依赖 app target 的设置自动继承。
3. **明确资源所有权**：包内文字与颜色从包资源读取，使用 `Bundle.module`；app 的版本号与 Bundle ID
   仍代表宿主应用，不能机械替换所有 `Bundle.main`。共享文字只保留一个维护来源；两端共用的视图
   文案通过明确的资源访问入口读取，平台独有文字留在各 app，防止长期手工同步两份翻译。
4. **迁移测试**：模型、解析和业务规则测试迁到包并导入 `FlatRadarCore`；iOS UI / 导航测试继续留在
   app 测试目标。包测试在 Mac 上运行，两端仍需构建与平台集成验证。

**包化不等于不再维护两端。** 视图、系统适配、签名和运行验证仍各自负责；包的收益是把共享逻辑、
资源和编译边界集中管理。一旦迁移完成，不长期保留「包版 Core」和「直接编译源码版 Core」两条路径。

### Core 的平台依赖初步盘点

下表同时包含编译问题和能编过但行为不正确的问题；完整结果以 Phase 1 编译与运行审计为准。

| 位置 | 用的什么 | macOS 对应 |
|---|---|---|
| `Networking/APIClient.swift` | `import UIKit`、诊断元信息使用 `UIDevice` | 注入中性设备描述与系统版本；诊断上传仍可不做 |
| `Stores/PushStore.swift` | `import UIKit`、`UIDevice.current.systemVersion` | 注入系统版本 |
| `PushStore.setup()` | 直接引用 Core 外的 `PushDelegate.shared`，安装回调并重放缓存 token | 平台桥接层转发 token / 错误，保留早到 token 的重放行为 |
| `PushStore.requestPermissionAndRegister()` | `UIApplication.shared.registerForRemoteNotifications()` | macOS 桥接层调用 `NSApplication.shared` 对应方法 |
| `PushStore.map(_:)` | `UNAuthorizationStatus.ephemeral` | 本地 SDK 明确标记 macOS 不可用；由平台层归一化权限状态 |
| `Stores/AuthStore.swift` 的 `DeviceName.current` | 已有非 iOS 分支：`Host.current().name ?? "Mac"` | **首次 Mac 登录前替换为 `"Mac"`**，见风险 4 |
| `APIClient.registerDevice()` | 请求内硬编码 `platform: "ios"` | 注入平台标识；正式 Mac 注册前与后端契约对齐 |
| `KeychainManager` / `BiometricAuthService` | 两套钥匙串查询 | 验证 data protection 钥匙串、签名权限及实际读写 |

适配分成两类，不能把系统行为都塞进 `PlatformInfo`：

- **设备信息**：用协议或值结构注入设备显示名、系统版本、平台标识等。名称不取主机名；
  硬件型号与 CPU 架构分开定义，不把 `utsname.machine` 在 Mac 上的结果未经验证就当成机型。
- **推送能力**：各平台负责权限查询、注册和 delegate 回调，向共享状态机返回统一结果。
  Core 不引用具体 app delegate；平台专有枚举也在桥接层处理。Phase 1 注入不执行推送的实现，
  不申请权限、不注册 token、不调用后端设备注册接口。

平台判断集中在适配层，避免散入业务逻辑；注入接口应能在测试中替换。保留 iOS 原有推送时序和行为。

---

## 阶段划分

每一阶段都必须**能跑、能看**，并满足文末回归门槛才算完。不接受"编过了但打不开"。

### Phase 0 · Core 包迁移（Mac 视图开发的前置条件）

- [x] 建立本地包清单，声明 iOS 18 / macOS 26 支持，固定所需 Swift tools 版本和隔离 / 并发设置
      —— `swift-tools-version: 6.2`，`.defaultIsolation(MainActor.self)` + `.swiftLanguageMode(.v6)`
      + `MemberImportVisibility`。**测试 target 不开默认隔离**：Xcode 里两个测试 target 本来
      也没开，跟着开会让 `XCTestCase` 子类变 `@MainActor`，跟它 nonisolated 的三个 `init`
      冲突（实测 8 个文件 57 个 override 隔离错误）。
- [x] 把前文盘点的平台依赖适配掉 —— 见 `Platform/PlatformInfo.swift`（数据注入）与
      `Platform/PushPlatformBridge.swift`（系统能力）。iOS 实现在 `FlatRadar/Push/PlatformInfo+iOS.swift`，
      macOS 在 `FlatRadarMac/PlatformInfo+macOS.swift`（不注册推送）。
- [x] 公开 app 所需的最小接口 —— 顶层类型 54/74 公开，20 个留在内部（`SSEClient`、
      `KeychainManager`、`DeviceName` 和全部纯传输 DTO）。逐轮按编译器点名添加，不批量公开目录。
- [ ] 移入共享路由类型和 URL 解析 —— **未做**。`NavigationCoordinator` 仍在 app 里，
      Mac 端要用时再抽；Phase 0 不动它可以让 iOS 导航行为零风险。
- [x] 整理包源码与资源，修改包内资源查找；更新本地化提取、资源引用和相关仓库检查
      —— 8 个语义色进包（`Bundle.module`），35 条 Core 文案进包目录，
      `tests/test_localizations.py` 的扫描范围扩到两个根。
- [x] iOS target 改为链接包产品，移除旧 Core 源文件的直接 target membership
      —— 注意在本工程里这不是"取消 membership 复选框"，`FlatRadarCore` 是
      `PBXFileSystemSynchronizedRootGroup`，必须把组对象连同 target 的
      `fileSystemSynchronizedGroups` 条目一起删掉，否则包和 app 会各编一遍同一批源码。
- [x] 迁移平台无关单元测试并接入 CI —— 8 个文件 97 条进包，3 个文件 78 条留在 app
      （它们引用 `MapView` / `MainTabView` / `NativeMonthCalendar` 等 app 类型）。
      **迁移前后都是 175 条**，另新增 3 条包资源测试，共 178。

**完成判据**：包在 macOS 上构建并运行适用的单元测试；iOS Debug / Release 构建与现有相关测试
通过；iOS 登录 / 游客、列表、地图、通知、深链接及现有推送桥接完成冒烟验证。确认英文 / 中文、
浅色 / 深色资源无回退或缺失，没有重复类型或残留的旧源码编译路径。不能仅以 `swift build` 成功验收。

这一步只做结构迁移和必要适配，不改业务行为、不借机重写网络或 iOS 界面。发现原有行为问题单独记录，
避免混在迁移里难以判断回归来源。

### Phase 1 · 探针（已完成，2026-09-09）

**目的不是铺页面，是确认共享代码、身份、资源和运行环境能成立。**

- [x] 新建 macOS app target，最低版本定 **macOS 26**（新 app 没有存量用户，定低只是给自己上枷锁）
- [x] 依赖 Phase 0 的 `FlatRadarCore` 包产品；另建 Mac 应用入口与探针视图，不加入 iOS 视图或重复编译包源码
- [x] 编一次，把所有编译错误抄下来——**这就是边界审计的结果**（结果见下方「探针实测」）
- [x] 接入 Phase 0 的适配接口 —— `FlatRadarMac/PlatformInfo+macOS.swift`，`deviceName` 是常量
      `"Mac"`（不是主机名，见风险 4）。推送整块没接：不申请权限、不注册 token、不调后端。
      注入放在 `FlatRadarMacApp.init()` 而不是视图的 `.task`，保证早于任何网络调用。
- [x] 签名与独立 entitlements —— Apple Development 签名 + App Sandbox + hardened runtime +
      `network.client`。Bundle ID 沿用 `com.j.kong.FlatRadar`；本机没装 Designed for iPad 版，
      暂无共存冲突可测（容器 / URL scheme 的实测留到有第二个安装源时再做）。
- [x] 验证包资源进入 Mac app —— `FlatRadarMac.app/Contents/Resources/FlatRadarCore_FlatRadarCore.bundle`
      里有 `Assets.car` 和五种语言的 `.lproj`。
- [x] 做最小登录窗口 —— 见 `FlatRadarMac/FlatRadarMacApp.swift`：凭据输入 → 登录 → 拉一页房源 →
      显示 `已加载 / 总数`，外加错误框和钥匙串状态面板。
- [x] 建立 Mac scheme 与测试目标 —— `FlatRadarMacTests`（5 条）。它必须存在的理由就是
      「跑在哪儿」：`PlatformInfo.macOS` 只有 Mac app 看得见，而钥匙串的行为取决于宿主的
      签名和 entitlements，包测试和 iOS 测试都替代不了。守两件事：设备名是中性常量
      （风险 4），以及钥匙串在签名 + 沙盒 + 描述文件下真的能用。

**钥匙串：两个独立的问题，一个已修、一个卡住**

`--keychain-selftest` 是给这件事做的无头自检（跑的是签过名的真二进制，不是 `swift test`
的可执行文件——后者既不是这个 Bundle ID 也没有这套 entitlements，在那儿跑通证明不了什么）。

1. **`-25303 errSecNoSuchAttr`（已修，而且是 iOS 线上的洞）**
   `KeychainManager` 的三条查询都带 `kSecAttrService`，而那是 generic password 的属性，
   用在 `kSecClassInternetPassword` 上整条查询会被拒。后果不是报错是**静默**：`AuthStore`
   回退把 bearer token 明文写进 `UserDefaults`，登录照常成功、界面毫无异样。写失败的同时
   读也失败，所以连「上次存的还在不在」都查不出来——这个洞没有任何自曝途径。
   在 iPad 上跑 `KeychainTests` 撞出来的，去掉该属性后增 / 查 / 删全过。

2. **`-34018 errSecMissingEntitlement`（已解决）**
   macOS 的 data protection 钥匙串要求签名带 `application-identifier`，而只有声明
   `keychain-access-groups`（Keychain Sharing）才会去签发带它的描述文件；签发 Mac App
   Development 描述文件又要求**这台 Mac 已在开发者账号里注册**。

   实测对照（三种条件，都是签名 + 沙盒的真二进制，用 `--keychain-selftest` 跑）：

   | 配置 | 增 / 查 / 删 |
   |---|---|
   | data protection + 无描述文件 | ❌ -34018 |
   | 旧式文件式钥匙串 + 无描述文件 | ✅ 全过 |
   | **data protection + 有描述文件** | ✅ **全过** ← 现在这条 |

   中间那行是关键对照：它说明 -34018 是 data protection **特有**的，不是 App Sandbox
   本身的限制。当时也确实可以退回旧式钥匙串立刻跑通，但那违反 TN3137，而且**日后再切回
   data protection 时旧条目全部查不到**，表现为所有人静默登出——所以没退，改成注册设备。

   2026-09-09 已注册这台 Mac（Provisioning UDID `00008132-001870E01E03001C`），
   描述文件签发并嵌入，`com.apple.application-identifier` 到位。`FlatRadarMacTests`
   把这条钉成了自动化断言，不再依赖手跑。

**完成判据**（2026-09-09 实测状态）：

| 判据 | 状态 | 怎么验的 |
|---|---|---|
| 签名 + Sandbox 的 app 能登录并显示房源数量 | ✅ | 真实账号登录，窗口显示 `Listings 50 / 80` |
| Keychain 增 / 查 / 删均返回成功 | ✅ | `--keychain-selftest`；`FlatRadarMacTests` 也钉住了 |
| 没有触发 `UserDefaults` token 回退 | ✅ | 窗口显示 `none`；Mac 上那条回退根本不编译 |
| 重新启动能恢复会话 | ✅ | `--session-report` → `RESTORED`（真·进程重启，走钥匙串 + `/auth/me`） |
| 登出后不能恢复旧会话 | ✅ | 点 Sign Out 后 `--session-report` → `NO SESSION`；紧接着自检仍 `PASS`，排除「钥匙串坏了」这种解释 |
| 拒绝网络 / 凭据错误时显示可理解的错误 | ✅ | 手工输错密码验过，窗口显示后端给的具体原因 |
| 不得把凭据写入源码或日志 | ✅ | 自检和报告都只打结果与用户名，不打 token；密码用完即清 |

**七条全部通过，Phase 1 完成。** 其中登录 / 登出 / 错误提示三条需要真实凭据，
由维护者手工触发；其余四条走 `--keychain-selftest` 和 `--session-report` 两个无头模式，
以后每次动认证代码都能重跑，不依赖人记得验。

原文：签名且开启 Sandbox 的 macOS app 能从 `flatradar.app` 登录并显示房源数量；
Keychain 写入、读取、删除均返回成功，确认没有触发 `UserDefaults` token 回退；重新启动能恢复
会话，登出后不能恢复旧会话。拒绝网络或凭据错误时，窗口显示可理解的错误。不得把凭据写入源码或日志。

**探针实测（2026-09-09）**：把 `FlatRadarCore/` 直接编进 Mac target，编译器报出来的边界
比「Core 的平台依赖初步盘点」那张表**窄得多**：

| 阻塞点 | 位置 | 处理 |
|---|---|---|
| `import UIKit` 卡住模块依赖扫描 | `APIClient.swift`、`PushStore.swift` | 两个 import 全删，改注入 |
| `UIDevice.current.model / .systemVersion` | `APIClient.uploadCrashDiagnostic` | `PlatformInfo.hardwareModel / .systemVersion` |
| `UIDevice.current.systemVersion` | `PushStore.currentOSVersion` | 同上 |
| `UIApplication.registerForRemoteNotifications()` | `PushStore.requestPermissionAndRegister` | `PushPlatformBridge` |
| `PushDelegate.shared` ×3（Core 反向引用 app） | `PushStore.setup()` | `setup(bridge:)` 注入协议 |
| `UNAuthorizationStatus.ephemeral` | `PushStore.map(_:)` | `#if os(iOS)` 包住，Mac 落 `@unknown default` |
| `Host.current().name`（隐私坑，见风险 4） | `AuthStore.DeviceName` | `PlatformInfo.deviceName`，Mac 注入常量 `"Mac"` |

`APIClient` 的 `UIDevice` 本来就在 `#if os(iOS)` 里、`AuthStore` 本来就有 `#else` 分支，
两者都不拦编译——**盘点表里列的 8 行，真正拦路的只有 `PushStore` 一个文件**。

盘点表没预料到的那一条：**app 端的类型检查会超时**。Core 从「同模块」变成「跨模块」之后，
SwiftUI 那些巨型 `body` 表达式的求解成本上去了，4 个文件报
`unable to type-check this expression in reasonable time`。两类诱因和改法：

- 内联 `Binding(get:set:)`（4 处）→ 提成具名的 `Binding<T>` 计算属性
- `.alert(String? ?? String, ...)` / `Label(String? ?? String, ...)`（6 处）→ 先落到
  `let x: String` 再传进去，避免求解器把 `.alert` 的一堆重载逐个试

光靠这两类锚定不够，`SettingsView`（7 段 Form）、`MapView`（Map + 20 个 modifier）、
`ListingsView` 还需要把 `body` 按原有结构机械拆成 `@ViewBuilder` 属性。**内容零改动**：
按去缩进后的行做多重集比对，消失的行全部是上面两类被有意重写的表达式。

**重点验证**：

1. **Keychain**。`KeychainManager` 使用 `kSecAttrAccessibleAfterFirstUnlock`。按 Apple 文档，
   macOS 查询显式使用 `kSecUseDataProtectionKeychain: true`，以获得 data protection 钥匙串行为；
   此键在 iOS 上不改变行为。增、查、删必须一致使用，实际签名需包含有效的钥匙串访问组权限。
   Phase 1 配置并验证 Keychain Sharing 及最终签名 / provisioning，不以「勾了能力」代替运行验证。
   当前 `AuthStore` 写入失败会回退保存 token 到 `UserDefaults`，**登录成功不等于 Keychain 成功**；
   Mac 路径写入失败应明确报告会话未保存，不静默落入该回退。iOS 既有行为的调整单独验证。
   `BiometricAuthService` 另有增、查、删查询；若启用 Mac Touch ID，必须同样适配并测试，
   在完成前隐藏该入口，普通密码登录始终可用。
2. **网络**。App Sandbox 默认禁出站，要勾 `com.apple.security.network.client`。
3. **编译与隔离设置**。macOS target 显式使用 macOS SDK 和部署目标，避免继承项目级 iOS 设置。
   Core 的隔离 / 并发设置以包清单为准，两端 app 保留各自显式配置，并核对 Swift 语言模式和
   upcoming features 的兼容性；delegate 边界仍需单独检查。
4. **资源**。打包共享字符串和语义颜色，验证至少英文 / 中文及浅色 / 深色显示；权限说明和
   隐私声明按 Mac 实际能力配置，详见风险 5。

### Phase 2 · 第一屏（目标：这个项目的立意所在）

**先做表格与最小比较能力。** 如果键盘浏览、筛选候选和并排比较不如想象中好用，应该在铺地图、
日历之前知道。比较先放在同一窗口，不要求先完成多窗口与拖拽。

- [x] `NavigationSplitView`：左列表 / 右详情 —— 右栏走 `.inspector` 而不是第三栏，
      理由见 `MainWindow` 的文件头（第三栏是导航目的地，右栏是检视器）
- [x] 列表用**自绘的 `List`**，不是 SwiftUI 的 `Table` —— 换掉的三个理由（悬停整行浮起、
      选中改中性灰、去分隔线）都在 `ListingTable` 的文件头，根因是 `Table` 没有"行"这一层
      可以挂修饰符
- [x] **点列头排序** —— 列头自绘（`Table` 换掉了），排序走服务端，见 `ListingColumnComparator`
- [x] **↑↓ 翻列表，右边详情实时跟着变**
- [x] 多选（⌘ 点选 / ⇧ 连选），两套候选钉在侧栏 Pinned + 行首墨色菱形；
      「并排比较」的落点是 Phase 4 的多窗口（`ListingWindow`）
- [x] 基本筛选、⌘F 定位筛选、⌘R 刷新；菜单 / 右键复制链接和打开平台原站 ——
      筛选后来扩成了整块 `FilterPanel`（四列 + 平台 chip + 带值 token）
- [x] 登录 / 游客两种入口

**完成判据**：能只用键盘筛选、跨页浏览并固定两套房源比较；排序范围准确可见；快速切换选择
不会串详情，刷新后选中状态稳定。空列表、详情加载失败和分页失败均有明确状态及重试入口。

**排序与分页契约**：现有 `ListingsStore` 每页 50 条，`APIClient.getListings()` 没有排序参数。
仅排序已加载数组不能宣称是全部房源的排序。实现前核对后端 `docs/API.md` / `docs/openapi.json`：

- 优先对全部匹配结果进行服务端排序；若后端缺少能力，先补契约再实现。定义可排序字段、方向、
  空值顺序和以稳定 ID 打破同值排序，明确分页期间数据变化的处理方式。
- 探索期可以只排序已加载数据，但必须显示「已加载 N / 共 M 条；仅排序已加载结果」。
  全量拉取后本地排序仅在确认数据规模、接口限制和响应成本可接受后采用。
- 排序或筛选变化时重置分页、使旧请求失效；新页去重，加载失败可重试，追加后顺序仍符合当前规则。

**这里要新写导航状态**：分别保存多选 ID 集合、详情当前展示的 `ListingRoute?` 和固定比较的 ID。
单个 `ListingRoute?` 不足以表达多选。选择按稳定 ID 保存，刷新后仍存在的选择保留；已消失的选择
清理，固定比较项显示不可用状态，不自动换成另一套房。详情请求取消旧任务并校验当前 ID，防止旧响应
覆盖新选择。筛选和刷新不抢走键盘焦点。

两边只共享路由类型和 URL 解析；不改 iOS 的 `NavigationStack` / `listingsPath` 路径模型。
iPad 的 `NavigationSplitView` 改造是独立事项，不顺手做。

### Phase 3 · 铺开

- [x] 地图 —— POI 过滤和可达圈都和 iOS 共用包里那一份（`MapPOI` / `Reachability`）。
      **没有定位权限**：这一屏回答的是"这批房源分布在哪儿"，不是"我附近有什么"，
      不需要用户位置，所以既没申请权限也没要 Sandbox 的位置能力
- [x] 日历 —— 全部自绘（`CalendarMonth` + `CalendarPane`），`UICalendarView` 在 macOS 不存在
- [x] 通知列表 + SSE 实时流 —— SSE 在 Phase 4 提到了应用级（`AppFeed`），一个会话一条流
- [x] 设置页：`Settings {}` 场景（⌘,），四个 tab —— General（外观 / 反馈 / 条款 / 版本）、
      Account（改密码 / 导出 / 登出 / 删号 / 访客转正）、Notifications（权限状态 / 推送开关 /
      提醒开关 / admin 诊断）、Filters（`/me/filter` 编辑器）。
      **服务器地址没做**：iOS 那边早就不在界面上给了（`server_url` 只剩 `@AppStorage`，
      没有输入框），Mac 不新开这个口子。

**完成判据**：各页面可独立加载、重试，房源可在列表与地图间按 ID 定位；SSE 断线 / 睡眠唤醒后
能重连并补齐数据；游客不连接个人通知流。登出和切换服务器时，旧数据及未完成请求不进入新会话。

**2026-09-16 补勾。** 上面那些其实在 Phase 4 之前就做完了，复选框一直没打——
读这份文档的人（包括我自己）会以为还有一大摊活。「列表与地图间按 ID 定位」是最后补上的
一条，走右键菜单 / ⌘L 的「Show on Map」。**还没验的**：SSE 睡眠唤醒后的重连和补页，
以及切换服务器时的会话隔离——两条都要真实环境，留作手工验证。

### Phase 4 · 桌面交互扩展

在 Phase 2 已验证比较体验的基础上，扩展窗口、悬停和常驻能力。

- [x] **多窗口**：把一套房源拖出来单开窗口，两个并排比 —— `ListingWindow` +
      `WindowGroup(id:for:)`；拖出去走 AppKit 的 `NSDraggingSource`
      （`RowDragOut.swift`），SwiftUI 的 `.onDrag` 给不了"没人接"这个回调。
      双击、右键、⌘⇧O 是同一件事的另外三个入口。
- [x] **菜单栏命令**（`.commands`）：⌘1/2/3**/4** 切列表 / 地图 / 日历 / 通知；
      命令作用于当前窗口（`@FocusedValue`）。写这条时 Alerts 还没做，现在侧栏是
      四个条目，只给前三个快捷键会留下唯一一个没键盘入口的屏。
- [x] **右键菜单**：列表行（开窗 / 钉住 / 在地图上定位 / 去平台 / 复制链接）、
      地图标记（缩到这栋 / 缩到全部 / 开窗 / 在列表里定位 / 去平台 / 复制链接 / 分享）。
      **可达圈不在右键里**——选中一栋楼就自动画，见下。
- [x] **悬停预览**：地图 pin 划过出卡片（楼盘名 / 城市 / 各状态几套），
      列表行悬停出三个快捷动作（钉住 / 开窗 / 去平台），三个都有键盘等价入口。
- [x] **菜单栏常驻**：`MenuBarExtra`，显示匹配数 + 上次扫描时间 + 未读数。
      **默认关**，由设置页 General 里的开关打开——它同时决定"没有窗口时还维不维持
      SSE"，是个该让用户知情的后台承诺，不能默认就占着菜单栏。

最后一条和 iOS 那个"状态型小组件"是同一个东西，先做哪个都行，但**文案和口径要一致**。
菜单栏那一格因此复用了统计带的同一套口径函数：匹配数是服务端算的 `total`
（套了个人筛选就叫 `Matching filters`，没套叫 `Listings`），时间走
`ServerTime.relativeTime`。

**可达圈**：选中一栋楼自动画两个同心圆——步行 10 分钟（蓝实线，641m）、
骑车 10 分钟（紫虚线，1923m）。不放进右键菜单：你点一栋楼，问的就是"这儿周围
是什么样"，圈正是那个问题的答案，再多一步是多余的。

**两圈用同一个分钟数**，比较才是一句话：同样给 10 分钟，走能到哪儿、骑能到哪儿，
差的就是那三倍（15÷5）。一度把步行收到 5 分钟让内圈落在"楼下这一片"的量级上，
改回来了——分钟数不同的话，读者得先在脑子里把两个数换算到同一个基准，
而这张图本来是用来省掉那一步的。顺带也和 iOS 对齐了。

半径算法和绕路系数在包里（`Reachability`），和 iOS 的地图**共用一份**——两处各写
一份必然漂移，改了系数忘了另一边，两端的同一个圈会画出不同的大小，而且没人会发现。
分钟数不在共用范围内，是各端自己的取舍。

**POI 跟着一起开了**：放大到一个城区（跨度 ≤ 0.05° ≈ 5.5km）之后显示超市 /
车站 / 学校三类。这三类和可达圈是配套的——圈回答"十分钟能到哪儿"，POI 回答
"到了那儿有什么"；只画圈不画 POI，圈里是空的。类目和阈值在包里（`MapPOI`），
和 iOS 共用一份：**"哪几类 POI 和租不租得下去有关"是产品判断，不是两端各自的
界面口味**，一端加了 `.hospital` 另一端没加，就成了同一张图在两个设备上说不同的话。
刻意不含餐饮 / 咖啡 / 夜生活 / 零售——密度高且和"住不住得下去"没关系。

⚠️ **这是圆，不是等时圈。** 真等时圈（从一个点出发骑车 10 分钟能到哪儿）是一块
多边形，MapKit 只给路线（`MKDirections`），算不出来；后端也没有这个接口。
所以这里用直线半径除以 **1.3 的绕路系数**逼近——阿姆斯特丹到处是运河，直线 800m
常常是一公里多的路，不校正的话圈会系统性地过于乐观。宁可画保守：圈内一定到得了，
比圈内可能到不了要好。真要等时圈得后端先有那个接口。

### 分享链接与 Universal Link（2026-09-16）

分享出去的是 `https://<服务器>/l/<id>`，**一条链接同时满足两边**：收件人装了
FlatRadar，系统直接把它交给 app；没装就在浏览器里看一个公开的房源落地页。

为什么不是前两种：

| 分享什么 | 装了客户端 | 没装 |
|---|---|---|
| `h2smonitor://…`（iOS 原先） | ✅ 开 app | ❌ 死链 |
| 平台 https 网址（Mac 原先） | ❌ 开浏览器 | ✅ 打得开 |
| **`https://<服务器>/l/<id>`** | ✅ 开 app | ✅ 开网页 |

**这件事由四块拼成，少一块就静默失效**——系统不报错，链接只是"在浏览器里打开了"：

| 在哪儿 | 是什么 |
|---|---|
| 后端 `app/routes/site_meta.py` | `/.well-known/apple-app-site-association`：HTTPS、`application/json`、不重定向、不要鉴权、只认领 `/l/*` |
| 后端 `app/routes/share.py` | `/l/<id>` 公开落地页。房源没了给 **410** 不是 404 |
| 两端 entitlements | `com.apple.developer.associated-domains` = `applinks:flatradar.app` |
| 两端 app | `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`，解析走包里的 `ListingShare.listingID(fromUniversalLink:)` |

⚠️ **上线前置**：AASA 文件和 `/l/` 路由**必须先部署到 flatradar.app**，Universal Link
才会生效——系统是去那个域名抓 AASA 的，代码在本地改完不算数。部署后验证两条：
`curl -I https://flatradar.app/.well-known/apple-app-site-association` 要直接 200
且 `Content-Type: application/json`（Cloudflare 那层也不能改写它），以及在真机上
点一条 `https://flatradar.app/l/<id>` 看是不是进 app。

**`h2smonitor://` 在 Mac 上原先整条不通**，顺带修了：那份注册 scheme 的
`Info.plist` 的 `INFOPLIST_FILE` 只挂在 iOS target 上，Mac target 没有这一行，
所以 Mac app 从来没声明过这个 scheme——不只是分享，推送 payload 里的 `deep_link`
也一样落不了地。现在两个 target 共用同一份。

风险 6 那条「URL 与通知路由在未登录时暂存，认证后再执行」也落实了：没登录时链接
存进 `pendingDeepLink`，登录态一变就重放。「优先激活已显示该房源的窗口」是
`WindowGroup(id:for:)` 按 value 去重白送的。

**完成判据**：两个窗口的选择与临时筛选互不覆盖；打开更多窗口不重复恢复会话、不重复建立 SSE；
关闭一个窗口不影响另一个。关闭所有窗口后菜单栏仍可查看状态并重开窗口；⌘Q 完全退出并停止连接。
悬停操作均有键盘或菜单等价入口。

**验证结果（2026-09-16）**：

| 判据 | 怎么验的 |
|---|---|
| 两窗口选择 / 临时筛选互不覆盖 | `MultiWindowTests`（10 条）—— 选择、搜索、query、排序、钉住、store 各一条 |
| 不重复恢复会话 | `AppFeedTests.testRestoreOnce*`；并发那条钉住 `didRestore` 写在 `await` **之前** |
| 不重复建立 SSE | `AppFeed` 持一份 `NotificationsStore`；实测两个窗口打同一个指针，窗口计数 0→1→2 |
| 关一个不影响另一个 | 实测关掉两个窗口之一，计数 2→1，流不断 |
| 没窗口时菜单栏仍可用并能重开窗口 | `wantsStream` 的五条真值表 + 菜单栏面板实测 |
| ⌘Q 完全退出并停止连接 | SSE 的 `URLSession` 随进程消失；菜单栏面板里给了可见的 Quit |
| 悬停操作有键盘 / 菜单等价入口 | 钉住 ⌘D、开窗 ⌘⇧O、去平台 ⌘O、在地图上定位 ⌘L，tooltip 里都写了 |

### Stats 屏（2026-09-17）

侧栏第五个条目，⌘5。**这一屏和 iOS 的 Dashboard 反着做**：那边是七张 mini 卡 +
点开看 sheet，这边是十二张图一次铺开、不做钻取。理由是「点开看大图」本身就是
手机的妥协——屏幕放不下才要钻进去，而 Mac 的优势正是一次看全。
docs/DESIGN.md §6 对此也有一条：大数字卡和横滑 chip 排是手机成语。

**整屏的语义是「过去 N 天首次出现的那批房源」**，不是库存。后端十三个图的
`days` 参数过滤的都是 `first_seen`（`_listing_where()` 就一句
`WHERE first_seen >= cutoff`）。实测 days=30 合计 347 套，而库存是 892 套——
差得很远，所以屏幕顶上那句说明是必需的，不是装饰。

和列表屏那条 `StatsStrip` 的分工：strip 答「现在库存怎么样」，这一屏答
「新上的那批什么样」。两个问题，不重复。

- **选中一张图 → 右栏出完整明细**（标签 / 数量 / 占比）。卡里只画得下形状，
  城市那张还只画前 8 条；长尾在右栏。这是"多屏共用 inspector"第四次派上用场。
- **排序和上色的规则在包里**（`ChartPresentation`），和 iOS 共用：
  「价格区间不能按数量排」对两端一样成立，「同一个平台在任何图表下都是同一个
  颜色」是 DESIGN.md §1.2 的原话。
- `contract_dist` **不画**：线上只有一个值（`Indefinite`），一根柱子等于用一张图
  说"没有信息"。

⚠️ 两个容易做错的地方，都写了测试钉住：

1. **有序维度不许按数量重排。** 价格按数量排会变成
   `€1000-1200, €1200-1400, €1400-1600, >€1600, €800-900…`——一条乱序的价格轴，
   而且**看起来完全正常**，不崩不空，只是读出来的结论是错的。
   （iOS 的 `ChartDetailView` 目前就是这么排的，见 `ChartPresentation` 的注释。）
2. **意思相同的标签必须合并，不能只在显示时改名。** 后端发的是平台原话，
   `Occupied` 和 `Not available` 是两条，而 `ListingStatus.from` 把它们都归到
   `.occupied`。只改显示名的话，图上会出现两条都叫 Occupied 的柱子，
   Swift Charts 按分类值定位，两条落在同一格互相盖住——实测 311 被 30 盖掉。

### 桌面小组件（2026-09-17）

照设计稿 `FlatRadar Widgets.dc.html` **4a**（macOS · 通知中心一栏）做。设计稿那句
总纲决定了整个结构：

> 四个尺寸一套内容层级：**小号只回答一个问题**（今日新增多少 / 未读多少），
> **中号加最新三条**，**大号加 14 天趋势、三项统计与最近截止**。数字沿用 App 内的
> 等宽 tabular 字形，红色菱形＝新上架，绿点＝抓取在线。分组继续靠填充差而不是描边。

「小号只回答一个问题」是按**格**分的，不是按尺寸分的——那是两个问题，所以是两格：

| 格 | 尺寸 | 回答 |
|---|---|---|
| `StatusWidget`（What's new） | 小 / 中 / 大 | 今天有什么新的 |
| `UnreadWidget`（Unread） | 小 | 有多少我还没看 |
| `CalendarWidget`（Move-ins） | 中 / 大 | 下次什么时候有房 |

**iOS 那一端（4b / 4c）也做了**，见下面单独一节。

第三格不在设计稿里，是上一轮「是不是还可以做地图 base 的？或者日历 base 的？」的
答案；**排版跟着设计稿走**，三格摆在一起才是一套东西。为什么是日历不是地图：日历
是纯数字，画出来不要图片（地图得先有瓦片，而这个扩展不联网，只能由 app 渲染成 PNG
写进共享容器，多一条图片管线和一份缓存失效逻辑）；日历每天都在变，地图上那些点几周
才挪一次；一张 160pt 见方、撒着几百个点的荷兰地图在那个尺寸下只会糊成一团。

**「不做房源列表」这条被设计稿推翻了**，而且推翻得有道理。docs/NEXT.md 原来那一行写
的是「上次扫描时间 + 我的匹配数，不做房源列表」，设计稿的中号 / 大号都有一段 NEWEST
三行。三条不是列表，是"最近发生了什么"的证据——一个只有数字的小组件回答不了
「那 31 条是些什么」，而那恰恰是看到 31 之后的下一个问题。数据是**顺手来的**：
`AppFeed` 那个 `pageSize: 1` 的计数 store 提到 3，同一条 `/listings` 多带回两条，
它默认就按 `-first_seen` 排（写进契约的），第一页前三条正好是最新三条。

⚠️ **两处设计稿里有、而数据不存在的东西**

规矩是 `CalendarPane` 顶上写过的那条：「宁可不画，也不拿假数据把控件填满——一个永远
填不上的卡片比没有这张卡片更糟」。这次撞上两处，换的是内容不是形状：

| 设计稿 | 换成 | 为什么 |
|---|---|---|
| 大号第三格 `Watching 12` | `Matching filters 193` | 没有"关注列表"这个概念。`BrowseModel.pinned` 是「钉两套并排比」，上限 2、窗口级，不是一个能显示成 12 的东西 |
| 大号底部 `Lottery closes · … in 2d` | `Next move-in · 23 Sep · in 6d` | openapi 里 `deadline` / `closes` / `draw_at` **各出现 0 次**，listings 表只有 `available_from` 一个日期列而且只到日。抽签截止时刻整条不存在 |

第二条正是 `CalendarPane` 当初为同一张设计稿放弃「Next deadline 英雄卡」的那个理由，
同一个数据缺口第二次找上门。

**这几格不联网。** 数字全部由 app 算好、整份写进 App Group 容器
（`WidgetSnapshot` / `WidgetBridge`），小组件只负责画。让扩展自己取数得先往外挪三样
东西，每一样都是一处新的静默故障：

| 要什么 | 只能怎么拿 | 代价 |
|---|---|---|
| bearer token | 共享钥匙串组 | 这个仓库刚因为 token 落进 `UserDefaults` 吃过一次静默的亏（`KeychainManager` 顶部那段） |
| 服务器地址 | app 自己的 `UserDefaults[server_url]` | 扩展读到的是**它自己那份**，自建实例的用户会看到 flatradar.app 的数字 |
| 一整套口径 | 抄一份判断过去 | 就是「文案和口径要一致」禁止的那件事 |

⚠️ **旧了之后必须改口，这是最容易做错的一条。**

那几格显示 `scanned 4m ago`、`831 live`、一个绿点（设计稿定义的「抓取在线」）、
以及最后一根红柱子（今天）。这四样**全是对"现在"的断言**，而它们是拿当前时刻去减
快照里记的时间算的——app 有多久没跑，这些话就偏多少。所以 10 分钟以内照说，超过之后：

- 整句换成 `checked 3h ago`，**连 `831 live` 一起收回**；
- 绿点变灰，红柱子变灰，所有数字压成次要色。

不改口的后果不是"数据旧了"：桌面上写着 `scanned 3d ago` + 绿点，读者读出来的是
**「这个服务三天没扫了」**，而事实是「你这台 Mac 三天没开过 FlatRadar」——替后端背了
一口它没犯的锅，锅还摆在桌面上。

**文案继续往一份收**（`StatusWording`，在包里）。统计带、菜单栏、侧栏和三格小组件
调同一个函数。收拢时一共抓到**三处**漂移：

1. `StatsStrip` 没套筛选时写 `Showing`、菜单栏同一个数写 `Listings`，而
   `MenuBarStatus` 的注释写的又是第三种说法。统一成 `Listings`。
2. `SidebarView` 里 `"scanned \(ago)"` 是第四份裸字面量，没走共用那一份。
3. 大小写。`scanned` **存小写**，单独成行的地方（菜单栏、小组件）由
   `StatusWording.sentence(_:)` 把首字母提上去，侧栏那处不套——它是
   `7 platforms · scanned 4m ago`，大写会在一句话中间冒出来。
   大小写是排版，和段标题那个 `.textCase(.uppercase)` 同一类事；为它存两份
   字符串才是错的。

`pytest` 里有一条扫描，小组件源码里再出现裸的 `Text("…")` 就红（品牌名除外）。

**尺寸：设计稿的大号是 360×376，macOS 真正的大号是 329×345**（HIG 尺寸表），矮 31pt。
小号同理：稿子 170，系统 155。

第一版的让法是整屏按比例收一档（大数字 54→46、柱高 46→36、行高 33→30、段间距
14→10）。三条房源塞得进去，但**每一段都只能贴着彼此**，挤得没有呼吸。改成
**大号只放两条房源**，省出来的 36pt 全部还给尺寸和间距（大数字回 50、柱高回 42、
行高回稿子的 33、段间距回 12）。

中号仍然是三条，所以出现了「大号比中号少一条」——看起来反了，但不是：中号整个
右半边就是那一段，三条把它填满；大号要在同一块高度里排下**六段**东西（页眉、
大数字、柱子、三格统计、房源、底部胶囊）。少的是同一种信息的第三条，不是少一类
信息；大号比中号多的是柱子、统计和下一个可入住日。

三个**静默**的坑，构建全绿、运行不报错、症状统一是"那一格永远空着"：

1. **macOS 的 App Group 名必须带 team 前缀**（`HGXZB3UC25.group.…`）。写成 iOS 那样的
   裸 `group.…` 时 `containerURL(...)` **照样返回一个路径**，只有写那一步被沙盒拒掉。
   `FlatRadarMacTests/WidgetBridgeTests` 跑在带 entitlement 的宿主 app 里，
   实测过这个变异：五条挂三条。
2. **Info.plist 不能放进 `FlatRadarMacWidget/`**——那是个
   `PBXFileSystemSynchronizedRootGroup`，Xcode 会直接警告 Copy Bundle Resources 里有它。
   和 `d7971f5` 把 test plan 挪出 `FlatRadar/` 是同一类事，所以它在工程根上。
3. **appex 要真被嵌进 `.app`**（Copy Files，`dstSubfolderSpec = 13`）。少了这条阶段
   appex 照样构建得出来，只是系统不知道有这个小组件。
4. **`WidgetKind` 那三个串是桌面上那一格的身份**，改了等于把用户摆好的那格弄没
   （变空白，得手动删了重摆）。值本身钉在 `tests/test_widget_wiring.py` 里。

**日历那格的数据只在它真的摆在桌面上时才取。** `MainWindow` 里有一条量过的注释：
`/calendar` 回 691 条、211 KB，是四屏里最少打开的一屏，所以刻意做成按需拉。为了一个
多半没人摆的小组件把那个决定推翻掉，是拿所有人的冷启动带宽换少数人的一格。改成先问
一次系统「这一格装了没有」（`WidgetBridge.isInstalled`，一次异步 IPC），没装就一个
字节都不多要。

**每一档都渲染出来看过，深浅各一遍。** 为此把视图拆成 `…Face` / `…Layout` 两层——
`EnvironmentValues.widgetFamily` 是只读的，`previewContext` 在 Xcode 预览之外不生效，
尺寸档不当参数传就根本画不出小号那一版。看出来的问题没有一个是读代码能发现的：

- 大号在真实尺寸下**整个底部被切掉**（三条里的第三条和底部那个胶囊都没了）；
- 大号页眉写着 `831 live`，而它正下方就有一格 `Live now 831`，同一个数两遍；
- 未读那格的 `Status changes` 在 155pt 宽里被截成 `Status chang…`——**设计稿自己在更
  挤的那张卡上就写的是 `Status`**，照着改了；
- 早一版柱子平分整幅宽之后变成一排**药丸**（`Capsule` 的圆角跟着宽度走）；
- 早一版未读胶囊在中号里停在整格正中间，看起来像右边那列第一行的东西；
- 早一版日历大号没数据时在报 `Move-ins 0 / Bookable 0`——0 是个**结论**，而那时我们
  只是没拿到数据。

**深色只有一半是稿子上的。** 4b 那张深色 UNREAD 卡给了底 / 字 / 次要 / 红 / 蓝 / 棕
六个值，绿、绿点和几个填充色是按同一个位移推的——`WidgetPalette.dark` 的注释里
逐项写明了哪些是稿子上有的、哪些是推的，免得下次有人把推出来的当成规范。

### iOS 小组件（2026-09-17）

设计稿 4b（主屏 小 170 / 中 364 / 大 364×382）和 4c（锁屏 圆形 / 矩形 / 内联）。
新 target `FlatRadarWidget`，嵌进 `FlatRadar.app`。

**界面和 Mac 是同一份代码。** `FlatRadarWidgets/` 这个目录被两个 extension target
同时同步，各自只留一个入口文件和一份 entitlements。两张设计稿画的本来就是同一套
内容层级，各写一份的话下一次改配色要改两遍，而漏掉一遍不会有任何东西报错。

⚠️ **两端差异做成值，不是 `#if os(iOS)`**

这是这一节最该记住的一条。`#if` 是编译期的：在 macOS 上跑渲染脚本时，iOS 那几个
分支根本不进编译，于是「iOS 的小号排得下吗」这个问题**问不出来**。上一轮已经因为
同样的原因吃过一次亏——`widgetFamily` 是只读环境值，尺寸档不当参数传就画不出小号，
而第一次画出来就抓到两个只有看才看得见的毛病。

所以差异走 `WidgetSkin`（`.mac` / `.phone`，默认按当前平台取，渲染脚本可以指定
另一端）。锁屏那三种是唯一的例外，它们用的 `AccessoryWidgetBackground` 是 iOS
独有的 API——那几种在 macOS 上没有对应形态，留 `#if` 不影响验证。

**差在哪**（全在一处，别处只引用那几个常量）：

| | systemSmall | systemMedium | systemLarge |
|---|---|---|---|
| macOS | 155×155 | 329×155 | 329×**345** |
| iOS | 170×170 | 364×170 | 364×**382** |

大号差 37pt，所以 Mac 只排得下两条房源、数字也小一档，iOS 排得下三条。另外纸底
两端不同（Mac `#FBFAF7`，iOS `#F3F0E8`——后者就是 `Theme.pitchBackground`，
app 图标里窗户的填充色，iOS 的小组件贴着主屏图标，用同一个暖底）；中号标题
iOS 缩成 `TODAY`；未读在 4a 是三格统计里的一格，在 4b 是大数字右边一个红胶囊。

**iOS 大号那三格里有两格没有数据**：4b 写的是 `Live now / Watching / Closing`，
而「关注列表」这个概念不存在、抽签截止时刻在 openapi 里（`deadline` / `closes` /
`draw_at`）各出现 0 次。换成 `Matching filters` 和 `New this week`——后者是
`/stats/public/summary` 里本来就有的 `new_7d`，不用多发任何请求。

**iOS 小号按稿子没有那行带绿点的脚注**（它到柱子为止），所以「这是什么时候的数」
只剩数字底下那一行 `avg 16 · 831 live`。那一行因此也要会改口：过期时整句换成
`Checked 3h ago`，数字和红柱子一起变灰。不然那一格会拿一个三小时前的 `831 live`
充当现在。

**匹配数两端取自不同接口，这是有意的**：Mac 走 `/listings` 的 `total`（和菜单栏、
统计带同一个数），iOS 走 `/me/summary` 的 `matched_total`（和 Dashboard 上那张
「Your matches」卡同一个数）。小组件要先和**它旁边那个 app** 一致；两端那两个数
本来就不是同一个口径，这一点在两端统一之前不该由小组件来抹平。

**App Group 两端两种写法**：iOS 是 `group.com.j.kong.FlatRadar`，macOS 必须带 team
前缀（`HGXZB3UC25.group.…`）。写混了不报错，只是容器 URL 指向一个不存在的地方。
`tests/test_widget_wiring.py` 两端各钉一条。

接进 iOS 时 App ID 上没有 App Groups 能力，`xcodebuild -allowProvisioningUpdates`
自己去注册了组并更新了两个描述文件（`com.j.kong.FlatRadar` 和
`com.j.kong.FlatRadar.Widget`）。

**锁屏那三种（4c）没有渲染验证**：`AccessoryWidgetBackground` 只有 iOS 有，
macOS 上的渲染脚本画不出来，而锁屏挂件也没法用脚本截图。它们的内容层级和主屏
那几档同源（圆形只放锚点、矩形加未读和最新一条、内联一句话），但**排版只在真机
锁屏上验得了**，这一条必须说出来，不能当成验过。

### Phase 5 · 上架（可以无限期推迟）

**可以做完 Phase 4 再考虑，甚至永远本地跑。** Mac 截图、审核和商店元数据可以推迟；
应用内已有共享本地化、资源正确性和签名配置属于开发工作，不因推迟上架而跳过。

- [ ] 推送（见风险 3；可提前独立实施，不以上架为技术前提）
- [ ] Mac 图标（`1839ba6` 已经换成 Icon Composer 文档，它支持 macOS 变体）
- [ ] Mac 截图 + 单独审核

**完成判据**：若发布，归档及分发构建可安装启动，通过会话与推送冒烟验证；截图、元数据、语言和
隐私声明与实际功能一致。若只本地使用，本阶段保持未完成，不阻塞 Phase 0–4。

---

## 贯穿性风险

### 1. 默认 MainActor 隔离 × ObjC delegate ← 优先级最高

`3f5cd4a` 那个 2.1.0 线上启动无限崩溃就是它：本工程开了
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`，而 MetricKit 的回调在后台队列到达，
撞上 MainActor 隔离断言直接 trap。修法是给那个类显式标 `nonisolated`。

工程里现有四个 ObjC delegate，**只有一个标了 `nonisolated`**：

| | 标了吗 | 在包里吗 | macOS 上 |
|---|---|---|---|
| `CrashDiagnosticsCollector`（MetricKit） | ✅ | 否，留在 app | 重写或跳过 |
| `PushDelegate`（UIApplication + UNUserNotificationCenter） | ❌ | 否，留在 app | 要写 `NSApplicationDelegate` 版，实现 `PushPlatformBridge` |
| `NativeMonthCalendar.Coordinator`（UICalendarView） | ❌ | 否，留在 app | UIKit，不存在 |
| `UserLocationProvider`（CLLocationManager） | ❌ | 否，留在 app | 照搬，但回调线程要重新确认 |

四个 delegate **都不在包里**：它们全是平台桥接，按设计留在各自的 app。Phase 0 只是把
Core 对 `PushDelegate.shared` 的反向引用换成了 `PushPlatformBridge` 协议，
`PushDelegate` 自己的隔离标注一个字没动——那是独立的一件事，别混在迁移里。

既有运行未出错不能证明所有回调都有主线程保证。每个协议都需依据 SDK 的隔离标注、回调队列
约定和创建对象的线程分别判断；不能因为类叫 delegate 就一律加或去掉 `MainActor`。
确实允许后台调用的入口应明确隔离边界，再安全地转发到主 actor 更新状态，并验证 completion
按约定调用。iOS 和 macOS 都要覆盖通知、定位授权及失败回调。

### 2. Keychain

见 Phase 1。核心要求是统一使用 data protection 钥匙串、验证最终签名的访问权限，并直接验证
增 / 查 / 删及会话恢复。

**2026-09-09 进展**：`kSecUseDataProtectionKeychain` 已加进 `KeychainManager` 的三条查询
（`#if os(macOS)`——iOS 上这个键被忽略，但线上有真实用户而本地没有凭据能实测登录路径，
所以把影响面钉成零）。顺带修掉了一个让 iOS 钥匙串一直失败的非法属性，详见 Phase 1。
`AuthStore` 的 `UserDefaults` 回退现在只在 iOS 编译，Mac 路径写失败就是
`sessionSavedToKeychain == false`，由宿主如实显示；钥匙串写成功后还会清掉历史遗留的
明文副本。剩下的 -34018 卡在设备注册。`BiometricAuthService` 也在审计范围内；开启 Touch ID 前覆盖无生物识别
硬件、用户取消、认证失败、凭据失效和删除凭据。普通密码登录不能依赖生物识别可用性。

**2026-09-17：`BiometricMacTests` 删了。** 它基于一个错的假设——「查的时候只要属性
不要数据就不会弹认证」。macOS 上那条条目的 flag 是 `.userPresence`，明确允许密码和
Apple Watch 兜底，所以只要属性照样弹「输入密码 / 用手表解锁」。后果是整套 Mac 测试
**不能无人值守**：没人按框就是两条失败，而且因为它偶尔被最近一次手表解锁自动满足，
症状表现为"偶发失败、复现不了"（实测复现不了 9 轮）。删掉之后套件从 2.3–7.9 秒
掉到 0.097 秒——那几秒一直是弹窗在等人。`BiometricDiagnostics` 留着，但现在没有自动
调用方；要验那条路得在有 Touch ID 的机器上手跑，照 `--keychain-selftest` 接一个命令行
入口即可（还没做）。

### 3. 推送要后端配合

先按 Phase 1 确定的 Bundle ID 与签名配置启用 Mac 推送能力。Apple 支持同一 App Store 记录下
的平台使用相同 Bundle ID；普通提醒推送的 `apns-topic` 使用应用 Bundle ID，不能根据「原生 Mac」
推断 topic 必然不同。按实际选择核对 topic、签名权限、APNs 环境和设备 token 的归属。

**2026-09-16 已落地**，结论记在这里：

- **Bundle ID 共用**：Mac 和 iOS 都是 `com.j.kong.FlatRadar`，`apns-topic` 通用，同一把 `.p8`。
  后端据此**分不出** Mac 和 iOS，所以必须显式上报 `platform`。
- **客户端早就不硬编码了**：`registerDevice()` 读 `PlatformEnvironment.info.platformId`，
  iOS 注入 `"ios"`、Mac 注入 `"macos"`。上面这句「硬编码」是迁移前的状态。
- **后端 v1.41.0（`290a61e`）**：原先四处按平台分流、写法不一致——三处是 `!= "android"`
  的黑名单，`POST /devices/test` 是 `in ("ios",)` 的白名单，Mac 设备的测试推送会被**静默
  丢掉**（返回 `sent: 0`，不报错）。收成 `APNS_PLATFORMS = {"ios", "macos"}` 一个白名单，
  注册时对未知 `platform` 返回 400。数据库 `platform` 列本来就没有 CHECK 约束，不用迁移。
- **env**：debug 包报 `sandbox`。签名里的是 `com.apple.developer.aps-environment`
  （macOS 带前缀，iOS 是裸的 `aps-environment`），Debug 构建签成 `development`。
  `PushRegistrationTests` 从宿主进程的签名里读这个值，和代码报的 env 对账——
  也就是下面验收要求的「依据最终签名配置验证，不只凭 `DEBUG` 推断」。
- **拒绝权限在 Mac 上长得不一样**：权限请求是右上角一条横幅，**拖走即视为拒绝**；此后
  `requestAuthorization` 不弹框、也不返回 `false`，而是抛 `UNError.notificationsNotAllowed`
  （Code=1）。`PushStore` 原先只按 iOS 的返回值处理，Mac 上状态永远停在 `.notDetermined`。
  现在 catch 分支把它归为 `.denied`；Mac 登录后检测到 `.denied` 会弹一次窗，带「打开系统设置」
  （`x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=…`），
  从系统设置切回来自动重新注册。每次启动最多弹一次；弹窗带 Mac 惯例的「Don't remind me again」
  勾选框（`dialogSuppressionToggle`），勾上后跨启动不再弹，按这台 Mac 存。
  实测：链接落在 `anchor: id=com.j.kong.FlatRadar`，直接定位到 FlatRadar 那一页。
- **真机实测**（Debug 包）：`requestAuthorization granted=true` → `didRegister (32 bytes)`
  → `backend registered device_id=184 env=sandbox`。

推送不保证是唯一后端改动：全局排序、分页等也可能需要扩展。跨端行为先在后端 `docs/API.md`
约定，并同步作为接口事实来源的 `docs/openapi.json`，再各端实现。

**推送验收**：覆盖开发与分发环境、拒绝权限、token 早到 / 更新、登出后解除绑定，以及通知点击时
应用未启动 / 已有多个窗口的路由。APNs 环境依据最终签名配置验证，不只凭 `DEBUG` 推断。

### 4. `device_name` 的隐私坑 ← 容易踩，后果不小

当前 `AuthStore.swift` 中的 `DeviceName.current` 已有非 iOS 分支，返回 `Host.current().name ?? "Mac"`；
登录和注册都会使用它。系统主机名可能包含姓名等信息，所以这是**待复用代码里已经存在的风险**，
不是未来才可能发生的误用。换成 `Host.current().localizedName` 也不能解决。

**做法**：Phase 1 首次 Mac 登录前，将该分支替换为注入的中性值 `"Mac"`，测试登录与注册请求体
均不包含系统主机名。暂不增加自定义设备名，避免扩大功能和数据采集范围。

当前 `PrivacyInfo.xcprivacy` 已声明用户 ID、设备 ID、搜索历史等采集，不能描述成「不收集个人
信息」。准确目标是避免新增主机名及可能包含的姓名采集，并按实际 Mac 功能校准声明。

### 5. 本地化与共享资源

包资源随包产品进入两个 app，平台独有资源仍由各 app 打包。Phase 0 完成所有权划分与 iOS 验证，
Phase 1 再确认 Mac 的实际打包结果：

- `Localizable.xcstrings`：**实际做法与原计划相反，按数量定的。** app 目录有 430 个 key，
  Core 自己只用 35 个（几乎全在 `APIError.swift`）。把整本搬进包意味着 11165 行视图里
  每一处共享文案都要显式指定 bundle，成本比收益大一个量级。所以只把这 35 条（连同五语言
  译文）搬进包目录、Core 侧统一加 `bundle: .module`；app 目录裁掉其中 30 条只有 Core 用的，
  留下 `Lottery` / `Occupied` / `Reserved` —— 这 3 个 app 代码里也直接写了字面量。
  另外 4 个"共享"key（`Conflict` / `Login Failed` / `Too Many Requests` / `Direct book`）
  查下来只出现在**注释**里，不是真引用，一并裁掉。
  `tests/test_localizations.py` 的 `CATALOGS` 已扩到两个根，否则包里的文案缺译文没人看得见。
- `Assets.xcassets` 中共享语义颜色：8 个 token（`Status/` 5 个 + `Energy/` 3 个）已移入
  `Sources/FlatRadarCore/Resources/Colors.xcassets`，查找加 `bundle: .module`；
  `AccentColor` / `BrandLogo` 留在 app。这一项**当时就已经是断的**：`Color+Tokens.swift`
  在 `f7f77f7` 之后就住在 Core 里，却查 `Bundle.main` 的资源——包一独立编译立刻失效，
  而且 `Color(_:)` 查不到不报错，只显示黑色。新增
  `FlatRadarCoreTests/PackageResourcesTests.swift` 用 `UIColor(named:in:)` / `NSColor(named:bundle:)`
  逐个断言，把这种静默失败变成红测试。
- `InfoPlist.xcstrings` 与权限说明：只配置 Mac 实际使用的能力，尤其是定位；不能直接照搬 iOS 的键。
- `PrivacyInfo.xcprivacy`：依据 Mac 实际采集与 Required Reason API 使用检查打包内容。

共享语义颜色由包管理并从包 bundle 查找；移动资源时更新 iOS 引用、本地化工具和资源检查脚本。
每阶段检查浅色 / 深色、英文 / 中文；发布前验证全部五语言及窗口缩放时的截断与布局。

### 6. 应用级与窗口级状态（Phase 1 定义，后续逐步实现）

当前 iOS App 在应用层持有多个 Store，又在窗口视图的 `.task` 内初始化。不能直接复制为 Mac
多窗口生命周期，否则可能重复恢复会话、安装监听，或让不同窗口的筛选互相覆盖。

| 归属 | 内容 | 约束 |
|---|---|---|
| 应用级 | 服务器、账户、认证客户端、推送、个人筛选配置、通知数据与 SSE | 同一时刻一个服务器 / 账户；初始化和监听安装幂等；每个会话最多一条通知流 |
| 窗口级 | 当前页面、多选、详情焦点、排序、临时筛选、分页、地图视角、固定比较项 | 两个窗口独立；有查询状态的 `ListingsStore` 不直接作为全局单例共享 |
| 可选共享缓存 | 按服务器与房源 ID 保存的详情等 | 缓存不能夹带窗口选择；账户相关内容还需按会话隔离，切换时清理 |

- 登录恢复只执行一次；任何窗口登出、会话失效或切换服务器，都统一断流、清空所有窗口的账户数据，
  取消旧请求并使旧响应失效，再进入新会话。只清当前可见窗口不算完成。
- Phase 3 起，已登录且至少有一个内容窗口打开时维持 SSE，不因切换到其它应用就断开。
  最后一个窗口关闭且尚未启用菜单栏常驻时断流；重开窗口时重连并补页。
- Phase 4 启用菜单栏常驻后，没有内容窗口也可维持连接。睡眠 / 断网时允许断开，恢复后重新同步；
  ⌘Q 完全退出。游客始终不连接个人流。
- URL 与通知路由在未登录时暂存，认证后再执行；优先激活已显示该房源的窗口，否则打开详情窗口。
  Phase 2 尚无独立详情窗口时在主窗口展示；非法 URL 和不可用房源给出明确结果。

### 7. 两端回归门槛

「不降低 iOS 质量」以检查结果为准，不只作为原则：

- Phase 0 起运行包测试与 iOS 平台测试，并构建 iOS Debug / Release；Phase 1 起增加 Mac app 的
  Debug / Release 构建和平台测试。CI 确认各测试任务实际执行数量大于零。
- 共享隔离配置由包清单管理；平台无关测试集中在包内，不在两个 app target 中复制一套。
  平台集成测试使用各自 app 模块，对系统能力使用适配接口替身，并保留有签名的 Mac 运行验证。
- 按阶段增加有行为意义的测试：会话存取及失败、平台请求字段、URL 解析、排序分页、选择保持、
  详情响应乱序，以及登出 / 切服务器时旧请求不能污染新会话。
- Phase 3 / 4 验证 SSE 重连、单连接约束、多窗口互不覆盖和统一登出；手工验证键盘全流程与
  真实权限 / Keychain 行为。CI 中不使用生产账号完成这些验证。
- 若环境缺少所需 Xcode、macOS 版本或 iOS 模拟器，在本地或云端补齐对应检查并记录结果；
  未执行的检查标为未验证，不能用单端编译成功代替。

---

## 明确不做的

- **不改 iOS 端的导航结构。** iOS 那 30 个 `NavigationStack` 和 `listingsPath` 路径模型
  维持原样。iPad 的 `NavigationSplitView` 改造是 NEXT.md 里独立的一条，跟本项目无关。
- **不做 Catalyst。** 理由见开头。
- **不为 Mac 版降低 iOS 端的质量。** 任何"为了共享而把 iOS 端改难看"的取舍一律拒绝——
  iOS 端有真实用户，Mac 端没有。
- **不追求功能对等。** Mac 端不必有 iOS 端的每一个页面。管理员工具、打赏、崩溃诊断上传
  这些都可以永远不做。

## 完成的定义

这个项目**没有截止日期，也没有"发布"这个终点**。

单个阶段的完成判据写在各阶段里。整体上，能说"做成了"的标准只有一条：
**你自己在 Mac 上找房时，会打开它而不是打开网页端。**

## 依据与待验证项

- Apple：[kSecUseDataProtectionKeychain](https://developer.apple.com/documentation/security/ksecusedataprotectionkeychain)
  与 [TN3137：Mac 钥匙串实现](https://developer.apple.com/documentation/technotes/tn3137-on-mac-keychains)。
  签名访问权限与两套查询的实际行为按 Phase 1 验证。
- Swift：[SE-0466：默认 actor 隔离配置](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0466-control-default-actor-isolation.md)
  与 Apple：[包资源本地化](https://developer.apple.com/documentation/xcode/localizing-package-resources)。
  Phase 0 显式配置包的并发语义与资源 bundle，不依赖 app target 隐式提供。
- Apple：[为 App 记录添加平台](https://developer.apple.com/help/app-store-connect/create-an-app-record/add-platforms/)
  与 [向 APNs 发送通知请求](https://developer.apple.com/documentation/usernotifications/sending-notification-requests-to-apns)。
  Bundle ID、分发策略和实际推送链路按 Phase 1 / 5 验证。
- 本地 macOS SDK 的 `UserNotifications.framework/Headers/UNNotificationSettings.h` 将
  `UNAuthorizationStatusEphemeral` 标记为 `API_UNAVAILABLE(macos, watchos, tvos)`。
- 后端排序、分页语义及 `device_tokens.platform` 的当前约束尚未在本次审阅中核实，不能据此宣称
  后端无需改动；实施前读取后端契约和对应实现。
