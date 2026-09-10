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

- [ ] `NavigationSplitView`：左列表 / 右详情
- [ ] 列表用 SwiftUI 的 `Table`：城市、价格、面积、房型、能效、平台、状态各占一列
- [ ] **点列头排序**（`Table` 的 `sortOrder`），实现下文排序与分页契约
- [ ] **↑↓ 翻列表，右边详情实时跟着变**（Mail / Reeder 那套）
- [ ] 多选（⌘ 点选及键盘扩选），将两套候选固定在同一窗口并排比较，支持替换和移除
- [ ] 基本筛选、⌘F 定位筛选、⌘R 刷新；通过菜单 / 右键复制链接和打开平台原站
- [ ] 登录 / 游客两种入口

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

- [ ] 地图（复用 POI 过滤和可达圈计算逻辑；交互、定位权限说明及 Sandbox 位置权限按 Mac 配置）
- [ ] 日历（`NativeMonthCalendar` 用的是 `UICalendarView`，**macOS 上不存在**，要另找或自绘）
- [ ] 通知列表 + SSE 实时流
- [ ] 设置页（服务器地址、筛选器编辑、登出）

**完成判据**：各页面可独立加载、重试，房源可在列表与地图间按 ID 定位；SSE 断线 / 睡眠唤醒后
能重连并补齐数据；游客不连接个人通知流。登出和切换服务器时，旧数据及未完成请求不进入新会话。

### Phase 4 · 桌面交互扩展

在 Phase 2 已验证比较体验的基础上，扩展窗口、悬停和常驻能力。

- [ ] **多窗口**：把一套房源拖出来单开窗口，两个并排比
- [ ] **菜单栏命令**（`.commands`）：补充 ⌘1/2/3 切列表 / 地图 / 日历；命令作用于当前窗口
- [ ] **右键菜单**：扩展在地图上定位、画可达圈等操作
- [ ] **悬停预览**：地图 pin 划过出卡片，列表行悬停出快捷操作
- [ ] **菜单栏常驻**：右上角显示当前匹配数 + 上次扫描时间

最后一条和 iOS 那个"状态型小组件"是同一个东西，先做哪个都行，但**文案和口径要一致**。

**完成判据**：两个窗口的选择与临时筛选互不覆盖；打开更多窗口不重复恢复会话、不重复建立 SSE；
关闭一个窗口不影响另一个。关闭所有窗口后菜单栏仍可查看状态并重开窗口；⌘Q 完全退出并停止连接。
悬停操作均有键盘或菜单等价入口。

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

### 3. 推送要后端配合

先按 Phase 1 确定的 Bundle ID 与签名配置启用 Mac 推送能力。Apple 支持同一 App Store 记录下
的平台使用相同 Bundle ID；普通提醒推送的 `apns-topic` 使用应用 Bundle ID，不能根据「原生 Mac」
推断 topic 必然不同。按实际选择核对 topic、签名权限、APNs 环境和设备 token 的归属。

当前客户端 `APIClient.registerDevice()` 硬编码 `platform: "ios"`，需要与平台适配一并修改。
原盘点称后端 `device_tokens.platform` 只接受 `ios` / `android`；本次未审阅后端，实施前核对
校验、数据库约束、发送通道和 topic 选择，再决定兼容迁移。保留 iOS 注册和投递行为。

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
