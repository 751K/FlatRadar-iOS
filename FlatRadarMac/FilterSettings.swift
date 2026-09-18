import SwiftUI
import FlatRadarCore

/// 通知筛选（`/me/filter`）的编辑页。移植自 iOS `FilterEditView` + `FilterChoiceList`，
/// 维度、分组、校验规则、平台适用范围提示都照搬；交互按 Mac 改：
///
/// - 多选维度不推新页面，点「Edit…」弹出**浮层**（带搜索、勾选框、清空）；
/// - 平台七项直接铺成两列勾选框；
/// - Save / Revert 固定在底栏，有改动时才亮。
///
/// ⚠️ 后端只有**一份**筛选器。以后 Listings 屏的筛选浮层改的也是这一份，
/// 那边要复用这里的 ``FilterDimension``，不要再抄一张表。
struct FilterSettings: View {

    @Environment(AuthStore.self) private var auth
    @Environment(MeFilterStore.self) private var store

    @State private var draft = ListingFilter.empty
    @State private var baseline = ListingFilter.empty

    // 数字框用字符串做中介——要能分辨「空」和「写了但不是数字」。
    @State private var maxRentText = ""
    @State private var minAreaText = ""
    @State private var minFloorText = ""
    @State private var baselineNumbers = ["", "", ""]

    @State private var options = FilterOptions.empty
    @State private var loadingOptions = false
    @State private var optionsError: String?
    @State private var loadedFor: String?

    @State private var showResetConfirm = false
    @State private var justSaved = false

    var body: some View {
        Group {
            if auth.isUser {
                editor
            } else {
                Form {
                    Section {
                        Text(auth.isAdmin
                             ? "Notification filters belong to user accounts."
                             : "Sign in with an account to choose which new listings notify you.")
                            .foregroundStyle(.secondary)
                    }
                }
                .formStyle(.grouped)
                .frame(height: 160)
            }
        }
    }

    // MARK: - 编辑器

    private var editor: some View {
        VStack(spacing: 0) {
            Form {
                summarySection
                priceSection
                platformSection
                locationSection
                propertySection
                eligibilitySection
                perksSection
            }
            .formStyle(.grouped)

            Divider()
            footerBar
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        .frame(height: 640)
        // 切走再切回来这个 tab 会重新出现——有未保存的改动时不能拿服务端的旧值盖掉。
        .task(id: auth.userInfo?.name) {
            if loadedFor != auth.userInfo?.name || !hasChanges {
                loadFromAuth()
            }
            if options.sources.isEmpty { await loadOptions() }
        }
        .confirmationDialog("Reset filter to none?", isPresented: $showResetConfirm,
                            titleVisibility: .visible) {
            Button("Reset", role: .destructive) { resetAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All conditions will be cleared. After you save, every new listing will notify you.")
        }
    }

    // MARK: - Sections

    /// 顶部先说清楚「现在这套条件是什么」——十一个维度分散在下面，没有这一行
    /// 得逐项看才知道自己设了什么。
    private var summarySection: some View {
        Section {
            VStack(alignment: .leading, spacing: 3) {
                if preview.isEmpty {
                    Text("Every new listing").font(.headline)
                    Text("No conditions set — you'll be notified about everything.")
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(preview.summaryParts.count) conditions").font(.headline)
                    Text(verbatim: preview.summary).foregroundStyle(.secondary)
                }
            }
        } footer: {
            Text("A listing must match every condition to notify you.")
        }
    }

    private var priceSection: some View {
        Section {
            numberRow("Max rent", text: $maxRentText, unit: "€/mo")
            numberRow("Min area", text: $minAreaText, unit: "m²")
            numberRow("Min floor", text: $minFloorText, unit: nil)
            if !minFloorText.isEmpty, let note = scopeNote("floor") { noteLabel(note) }
        } header: {
            Text("Price & Space")
        } footer: {
            if numberErrors.isEmpty {
                Text("Empty = no limit. Floor 0 = ground floor.")
            } else {
                Text(verbatim: numberErrors.joined(separator: "\n")).foregroundStyle(.red)
            }
        }
    }

    /// 平台是其它维度的前提（一个维度对哪些平台生效取决于这里选了谁），所以放在
    /// 城市前面、直接铺开，不收进浮层。
    private var platformSection: some View {
        Section {
            if loadingOptions && options.sources.isEmpty {
                ProgressView().frame(maxWidth: .infinity)
            } else if options.sources.isEmpty {
                Text(optionsError ?? String(localized: "No platforms available")).foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                    GridItem(.flexible(), alignment: .leading)],
                          alignment: .leading, spacing: 6) {
                    ForEach(options.sources, id: \.self) { source in
                        Toggle(Platform.displayName(source), isOn: sourceBinding(source))
                            .toggleStyle(.checkbox)
                    }
                }
            }
        } header: {
            Text("Platforms")
        } footer: {
            Text(draft.allowedSources.isEmpty
                 ? "Nothing selected = every platform can notify you."
                 : "Only these platforms can trigger your notifications.")
        }
    }

    private var locationSection: some View {
        Section {
            choiceRow(.cities)
            choiceRow(.neighborhoods)
        } header: {
            Text("Location")
        } footer: {
            if options.neighborhoods.isEmpty && !loadingOptions && optionsError == nil {
                Text("Neighborhoods appear once listings in your cities have been indexed.")
            }
        }
    }

    private var propertySection: some View {
        Section("Property") {
            choiceRow(.types)
            choiceRow(.finishing)
            Picker("Min energy label", selection: $draft.allowedEnergy) {
                Text("Any").tag("")
                ForEach(options.energy.isEmpty ? energyLabels : options.energy, id: \.self) {
                    Text($0).tag($0)
                }
            }
            if !draft.allowedEnergy.isEmpty {
                Text("Labels better than \(draft.allowedEnergy) also pass.")
                    .font(.callout).foregroundStyle(.secondary)
                if let note = scopeNote("energy") { noteLabel(note) }
            }
        }
    }

    private var eligibilitySection: some View {
        Section {
            choiceRow(.tenant)
            choiceRow(.occupancy)
            choiceRow(.contract)
        } header: {
            Text("Eligibility")
        } footer: {
            Text("Tenant and occupancy are checked strictly: a listing that doesn't state them is filtered out.")
        }
    }

    private var perksSection: some View {
        Section("Perks") {
            choiceRow(.offer)
        }
    }

    // MARK: - 底栏

    private var footerBar: some View {
        HStack(spacing: 10) {
            Button("Reset All…") { showResetConfirm = true }
                .disabled(preview.isEmpty)

            Spacer()

            Group {
                if let err = store.errorMessage {
                    Label(err, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                } else if store.isSaving {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Saving…") }
                } else if hasChanges {
                    Text("Unsaved changes").foregroundStyle(.secondary)
                } else if justSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
            }
            .font(.callout)
            .lineLimit(2)

            Button("Revert") { loadFromAuth() }
                .disabled(!hasChanges || store.isSaving)
            Button("Save") { Task { await save() } }
                .keyboardShortcut(.defaultAction)
                .disabled(!hasChanges || !numberErrors.isEmpty || store.isSaving)
        }
    }

    // MARK: - 行

    private func numberRow(_ title: LocalizedStringKey, text: Binding<String>, unit: String?) -> some View {
        LabeledContent(title) {
            HStack(spacing: 6) {
                TextField("Any", text: text)
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .frame(width: 90)
                // 没有单位的那一行（Min floor）也放一个同尺寸的占位。空字符串的 Text
                // 没有行高，那一行会被排成另一种高度，输入框掉到标签下面去。
                Text(unit ?? "m²").foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
                    .opacity(unit == nil ? 0 : 1)
                    .accessibilityHidden(unit == nil)
            }
        }
    }

    private func choiceRow(_ dim: FilterDimension) -> some View {
        FilterChoiceRow(
            dim: dim,
            choices: dim.choices(options),
            selection: Binding(get: { draft[keyPath: dim.path] },
                               set: { draft[keyPath: dim.path] = $0 }),
            appliesTo: options.dimSources[dim.backendKey] ?? [],
            selectedSources: draft.allowedSources)
    }

    /// 图标只在出问题时出现：`isWarning` 是「这条对你选的平台一个都不生效」。
    @ViewBuilder
    private func noteLabel(_ note: PlatformScope.Note) -> some View {
        if note.isWarning {
            Label(note.text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout).foregroundStyle(.orange)
        } else {
            Text(verbatim: note.text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func scopeNote(_ backendKey: String) -> PlatformScope.Note? {
        PlatformScope.note(appliesTo: options.dimSources[backendKey] ?? [],
                           selectedSources: draft.allowedSources)
    }

    private func sourceBinding(_ source: String) -> Binding<Bool> {
        Binding(
            get: { draft.allowedSources.contains(source) },
            set: { on in
                if on {
                    if !draft.allowedSources.contains(source) { draft.allowedSources.append(source) }
                } else {
                    draft.allowedSources.removeAll { $0 == source }
                }
            })
    }

    // MARK: - 派生状态

    /// 把三个数字框并进 draft 的样子。顶部摘要、Reset 是否可用都看它——否则刚输入的
    /// 「Max rent 900」要等保存后才反映到摘要里。
    private var preview: ListingFilter {
        var f = draft
        f.maxRent = Double(maxRentText.trimmingCharacters(in: .whitespaces))
        f.minArea = Double(minAreaText.trimmingCharacters(in: .whitespaces))
        f.minFloor = Int(minFloorText.trimmingCharacters(in: .whitespaces))
        return f
    }

    private var hasChanges: Bool {
        draft != baseline || [maxRentText, minAreaText, minFloorText] != baselineNumbers
    }

    /// 数字框写了东西但解析不出来——必须拦住。
    ///
    /// iOS 旧版直接 `Double(text)`，「90O」（字母 O）解析成 nil，「最高 €900」被静默
    /// 存成「不限价」，用户从此收到所有价位的推送。认不出的输入不能当成一个确定的答案。
    private var numberErrors: [String] {
        var errs: [String] = []
        func check(_ text: String, _ name: String, allowZero: Bool, integer: Bool = false) {
            let t = text.trimmingCharacters(in: .whitespaces)
            guard !t.isEmpty else { return }
            guard let v = Double(t), !integer || Int(t) != nil else {
                errs.append("\(name): \"\(t)\" is not \(integer ? "a whole number" : "a number").")
                return
            }
            if v < 0 || (!allowZero && v == 0) { errs.append(String(localized: "\(name) must be greater than 0.")) }
        }
        check(maxRentText, "Max rent", allowZero: false)
        check(minAreaText, "Min area", allowZero: false)
        // `minFloor` 是 Int：「2.5」过得了 `Double` 却会被 `Int(...)` 读成 nil，
        // 于是悄悄变成「不限楼层」——和上面那个「90O」是同一种坑。
        check(minFloorText, "Min floor", allowZero: true, integer: true)
        return errs
    }

    // MARK: - 读写

    private func loadFromAuth() {
        let f = auth.userInfo?.listingFilter ?? .empty
        apply(f)
        loadedFor = auth.userInfo?.name
        store.errorMessage = nil
        justSaved = false
    }

    private func apply(_ f: ListingFilter) {
        draft = f
        baseline = f
        maxRentText = f.maxRent.map { String(Int($0)) } ?? ""
        minAreaText = f.minArea.map { String(Int($0)) } ?? ""
        minFloorText = f.minFloor.map(String.init) ?? ""
        baselineNumbers = [maxRentText, minAreaText, minFloorText]
    }

    private func loadOptions() async {
        loadingOptions = true
        optionsError = nil
        defer { loadingOptions = false }
        do {
            options = try await APIClient.shared.getFilterOptions()
        } catch {
            optionsError = String(localized: "Couldn't load options: \(error.localizedDescription)")
        }
    }

    private func resetAll() {
        draft = .empty
        maxRentText = ""
        minAreaText = ""
        minFloorText = ""
    }

    /// 存完用**后端回来的**那份覆盖本地：服务端会规范化（大小写、energy 白名单），
    /// 不这么做的话「有没有改过」会一直判断成有。
    private func save() async {
        guard numberErrors.isEmpty else { return }
        guard let resp = await store.save(preview) else { return }
        auth.updateLocalFilter(resp.filter)
        apply(resp.filter)
        justSaved = true
    }
}

// MARK: - 一个多选维度的行 + 浮层

private struct FilterChoiceRow: View {

    let dim: FilterDimension
    let choices: [String]
    @Binding var selection: [String]
    let appliesTo: [String]
    let selectedSources: [String]

    @State private var showPicker = false

    var body: some View {
        LabeledContent(dim.title) {
            HStack(spacing: 8) {
                Group {
                    if selection.isEmpty {
                        Text("Any").foregroundStyle(.secondary)
                    } else {
                        Text(verbatim: ListingFilter.brief(selection.map(dim.display)))
                    }
                }
                .lineLimit(1)
                .truncationMode(.tail)

                Button("Edit…") { showPicker = true }
                    .disabled(choices.isEmpty && selection.isEmpty)
                    .popover(isPresented: $showPicker, arrowEdge: .trailing) {
                        FilterChoicePicker(dim: dim, choices: choices, selection: $selection,
                                           appliesTo: appliesTo, selectedSources: selectedSources)
                    }
            }
        }
    }
}

/// 移植自 iOS `FilterChoiceList`。保留它那三件事：
///
/// 1. **搜索**——取值多于八项时给搜索框；
/// 2. **清空**——一键清掉本维度；
/// 3. **看得见已失效的取值**——用户存下来的值可能已经不在后端的候选里（平台改了写法、
///    房源全下架）。它们仍然**在过滤**，只渲染候选的话既看不见也删不掉，用户看到的
///    选择和实际生效的条件就不是同一份。这里并进列表、单独标注。
private struct FilterChoicePicker: View {

    let dim: FilterDimension
    let choices: [String]
    @Binding var selection: [String]
    let appliesTo: [String]
    let selectedSources: [String]

    @State private var query = ""

    private var allChoices: [String] {
        let known = Set(choices)
        return choices + selection.filter { !known.contains($0) }
    }

    private var stale: Set<String> { Set(selection).subtracting(choices) }

    private var filtered: [String] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return allChoices }
        return allChoices.filter {
            $0.localizedCaseInsensitiveContains(q) || dim.display($0).localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(dim.title).font(.headline)
                Spacer()
                Button("Clear") { selection = [] }
                    .disabled(selection.isEmpty)
            }

            if allChoices.count > 8 {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
            }

            List {
                if filtered.isEmpty {
                    Text(query.isEmpty ? "No options available" : "No match")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filtered, id: \.self) { choice in
                        Toggle(isOn: binding(choice)) {
                            VStack(alignment: .leading, spacing: 1) {
                                // 只改显示；勾选、比对、回传用的都是后端原值——
                                // 把 "student only" 大写后存回去，后端白名单就匹配不上。
                                Text(verbatim: dim.display(choice))
                                if stale.contains(choice) {
                                    Text("No current listings use this value")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
            }
            .listStyle(.plain)
            .frame(minHeight: 180)

            if let hint = dim.hint(choices) {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
            if let note = PlatformScope.note(appliesTo: appliesTo, selectedSources: selectedSources) {
                if note.isWarning {
                    Label(note.text, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                } else {
                    Text(verbatim: note.text).font(.callout).foregroundStyle(.secondary)
                }
            }
            Text("Nothing selected = this condition is not applied.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(width: 320, height: 420)
        // 浮层挂在 `LabeledContent` 的右半边上，会继承那边的**右对齐**——
        // 实测搜索框的占位字和底下的说明文字全靠右了。这里拨回来。
        .multilineTextAlignment(.leading)
    }

    private func binding(_ choice: String) -> Binding<Bool> {
        Binding(
            get: { selection.contains(choice) },
            set: { on in
                if on {
                    if !selection.contains(choice) { selection.append(choice) }
                } else {
                    selection.removeAll { $0 == choice }
                }
            })
    }
}

// MARK: - 维度表

/// 一个多选维度的四件事：显示名 / 后端维度名 / 候选取自 `FilterOptions` 的哪个字段 /
/// 存进 `ListingFilter` 的哪个字段。
///
/// 四件事必须一致，而写错了**不会有任何报错**：`backendKey` 用来查 `dim_sources`，
/// 写成别的维度，平台适用范围的提示就指到别处去；`path` 写串了，勾「城市」存进的是
/// 「街区」。这张表对应 iOS `FilterEditView` 里私有的 `FilterDim`，
/// `FlatRadarMacTests/FilterDimensionTests` 按后端 JSON 键把四件事逐行对账。
struct FilterDimension {
    let backendKey: String
    let title: LocalizedStringKey
    let choices: (FilterOptions) -> [String]
    let path: WritableKeyPath<ListingFilter, [String]>
    var display: (String) -> String = FeatureText.display

    /// 只有房型用得上：Holland2Stay 的房型字段是房间数，取值直接是 "1" "2" "3"，
    /// 和别的平台的 "Studio" 并排时看不出是什么意思。只补一句说明，不改写取值——
    /// 回传用的是后端原值。
    func hint(_ choices: [String]) -> LocalizedStringKey? {
        guard backendKey == "type" else { return nil }
        return choices.contains { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
            ? "Plain numbers are room counts." : nil
    }

    static let cities = FilterDimension(
        backendKey: "city", title: "Cities", choices: { $0.cities }, path: \.allowedCities)
    static let neighborhoods = FilterDimension(
        backendKey: "neighborhood", title: "Neighborhoods", choices: { $0.neighborhoods },
        path: \.allowedNeighborhoods)
    static let types = FilterDimension(
        backendKey: "type", title: "Types", choices: { $0.types }, path: \.allowedTypes,
        display: FeatureText.displayType)
    static let finishing = FilterDimension(
        backendKey: "finishing", title: "Finishing", choices: { $0.finishing },
        path: \.allowedFinishing)
    static let tenant = FilterDimension(
        backendKey: "tenant", title: "Tenant", choices: { $0.tenant }, path: \.allowedTenant)
    static let occupancy = FilterDimension(
        backendKey: "occupancy", title: "Occupancy", choices: { $0.occupancy },
        path: \.allowedOccupancy, display: FeatureText.displayOccupancy)
    static let contract = FilterDimension(
        backendKey: "contract", title: "Contract", choices: { $0.contract },
        path: \.allowedContract)
    static let offer = FilterDimension(
        backendKey: "offer", title: "Offer", choices: { $0.offer }, path: \.allowedOffer)

    static let all: [FilterDimension] = [
        .cities, .neighborhoods, .types, .finishing, .tenant, .occupancy, .contract, .offer,
    ]
}
