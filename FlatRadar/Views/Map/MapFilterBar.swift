import SwiftUI

/// 地图底部浮层的左右内缩。
///
/// 取值对齐**浮动 tab bar 的左右边界**——iOS 26 的 tab bar 不再贴边，而是一颗
/// 内缩的胶囊。底部这几行控件若还按 12pt 贴着屏幕边，会比 tab bar 各突出一截，
/// 三条边界参差不齐。
///
/// 系统没有公开这个内缩值，所以这里是**目测对齐**的常量，不是读来的。
/// 哪天 tab bar 的内缩变了，改这一处。
enum MapLayout {
    static let horizontalInset: CGFloat = 20

    /// 地图浮动控件的尺寸，按可用宽度分两档。
    ///
    /// iPhone 上的 44×44 是 **HIG 的最小可点击区域**——那是"再大就挤不下了"
    /// 的下限，不是舒适值。iPad 上横向有一千多点，继续用这个下限，按钮既小又
    /// 离手远，实际很难点中。
    ///
    /// 判据用 horizontal size class 而不是屏幕宽度：这里要回答的是"这个窗口挤
    /// 不挤"，而 Split View 下把 iPad 拖窄时 size class 会变 compact，那时候确实
    /// 该退回小尺寸。这跟 MainTabView 里用宽度是两个问题——那边要防的是 Stage
    /// Manager 下 size class 仍报 regular 但装不下六个 tab。
    struct ControlMetrics {
        let diameter: CGFloat
        let symbolSize: CGFloat
        let chipPaddingH: CGFloat
        let chipPaddingV: CGFloat
        let badgePaddingH: CGFloat
        let badgePaddingV: CGFloat

        // 只分档**尺寸和留白**，不分档字号。
        //
        // 曾经这里还有 chipFontSize / badgeFont 一组，宽屏各放大一档。查过 HIG
        // 之后撤掉了：Apple 的默认/最小字号表里 iOS 和 iPadOS 是**同一行**
        // （默认 17pt、最小 11pt），Dynamic Type 的字号表标题也是 "iOS, iPadOS
        // Dynamic Type sizes"——一张表管两个平台，没有 iPad 专属字阶。
        //
        // 更要紧的是按设备加一档会和 Dynamic Type 打架：想要更大的字是**用户**
        // 在系统设置里表达的，已经调大过的人会被放大两次。大屏多出来的空间，
        // 规范给的用法是放更多内容 / 分栏，不是把同样的东西印大。
        //
        // 直径 44 / 52 取的是 Apple 的标准按钮档位（Mini 28 · Small 32 ·
        // Regular 44 · Large 52 · Extra large 64）。44 是 HIG 明写的最小命中
        // 区域下限，52 是上面一档；中间的 56 不在这组里，是拍出来的。
        static let compact = ControlMetrics(
            diameter: 44, symbolSize: 17,
            chipPaddingH: 13, chipPaddingV: 9,
            badgePaddingH: 12, badgePaddingV: 8)

        static let regular = ControlMetrics(
            diameter: 52, symbolSize: 20,
            chipPaddingH: 17, chipPaddingV: 12,
            badgePaddingH: 16, badgePaddingV: 11)

        static func of(_ sizeClass: UserInterfaceSizeClass?) -> ControlMetrics {
            sizeClass == .regular ? .regular : .compact
        }
    }
}

/// 地图筛选：状态 chip 条 + 其余条件的 sheet。
///
/// 为什么状态筛选长成「图例」的样子
/// --------------------------------
/// 颜色、名称、数量、开关四件事挤在同一个控件里。分成「图例」和「筛选器」两块的
/// 话，用户得先看懂颜色，再去别处找对应的开关。
///
/// 数字很重要：生产实测 235 条里 Occupied 117、Reserved 48——不把数字摆出来，
/// 「这张图七成是租不到的」这件事就只能靠用户自己数。
struct MapStatusChips: View {
    @Environment(MapStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hSizeClass

    private var metrics: MapLayout.ControlMetrics { .of(hSizeClass) }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            GlassGroup(spacing: 6) {
                HStack(spacing: 6) {
                    ForEach(ListingStatus.byPriority) { kind in
                        let count = store.statusCounts[kind] ?? 0
                        // 「未知状态」只在真的出现时才占位置——它默认开着，平时是 0，
                        // 常驻一个空 chip 只是噪音；真冒出来时反而最该被看见。
                        if kind != .other || count > 0 {
                            chip(kind, count: count)
                        }
                    }
                }
            }
        }
        // 不加 scrollClipDisabled：加了 chip 会画到 ScrollView 边界之外，被屏幕
        // 边缘从字中间硬切开，看着像布局坏了而不是「可以左右滑」。
        .padding(.horizontal, MapLayout.horizontalInset)
    }

    private func chip(_ kind: ListingStatus, count: Int) -> some View {
        let on = store.activeStatuses.contains(kind)
        return Button {
            if on { store.activeStatuses.remove(kind) }
            else  { store.activeStatuses.insert(kind) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(on ? kind.color : Color.secondary.opacity(0.55))
                    .frame(width: 8, height: 8)
                Text(kind.label)
                    // 语义字体：原来是写死的 14.5pt，绕过了 Dynamic Type——
                    // 用户把系统字号调大，这条 chip 纹丝不动。
                    .font(.subheadline)
                    .fontWeight(on ? .semibold : .medium)
                    .fixedSize()
                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .monospacedDigit()
                    .fixedSize()
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background((on ? kind.color : Color.primary).opacity(0.14),
                                in: Capsule())
            }
            // 选中态只给**文字**上色，玻璃保持中性。
            //
            // 之前是给玻璃 tint：绿橙蓝紫灰五档底色亮度差很多，前景色只好一档
            // 一档去凑，凑到最后是「颜色太浓」和「数字看不见」。文字上色没有这个
            // 问题——色相由状态决定，对比度由系统的中性玻璃保证，两件事解耦。
            .foregroundStyle(on ? kind.color : Color.secondary)
            .padding(.horizontal, metrics.chipPaddingH)
            .padding(.vertical, metrics.chipPaddingV)
            .liquidGlass(Capsule(), interactive: true)
            .opacity(on ? 1 : 0.8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(kind.label), \(count) listings")
        .accessibilityValue(on ? "Shown" : "Hidden")
        .accessibilityHint("Double tap to toggle")
    }
}

/// 城市 / 平台 / 租金 / 面积。状态那四五档留在图上的 chip 条里，
/// 因为它是最常动的一个，塞进 sheet 等于每次都要多两步。
struct MapFilterSheet: View {
    @Environment(MapStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var store = store
        NavigationStack {
            Form {
                Section {
                    Picker("City", selection: $store.cityFilter) {
                        Text("All").tag("")
                        ForEach(store.cityOptions, id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Platform", selection: $store.sourceFilter) {
                        Text("All").tag("")
                        ForEach(store.sourceOptions, id: \.self) {
                            Text(Platform.displayName($0)).tag($0)
                        }
                    }
                }

                Section {
                    LabeledContent("Max rent") {
                        TextField("Any", text: $store.maxRentText)
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Min area") {
                        TextField("Any", text: $store.minAreaText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                    }
                } footer: {
                    // 读不出价格 ≠ 超预算。说清楚，免得用户以为漏了。
                    Text("Listings whose rent or area cannot be read are kept rather than hidden.")
                }

                Section {
                    Button("Reset", role: .destructive) { store.resetFilters() }
                }
            }
            .navigationTitle("Filter map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
