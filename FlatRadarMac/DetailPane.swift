import SwiftUI
import AppKit
import FlatRadarCore

/// 右栏：固定比较 + 当前焦点的详情。
///
/// 为什么比较和详情同屏
/// ------------------
/// 文档立意那一段：租房本质是**比较**任务，而比较需要把候选并排放。所以固定下来的
/// 两套永远在上面，↑↓ 浏览时下面的详情跟着动 —— 一边翻一边跟已经定下的两套对照，
/// 不用进出详情页。这是 Mac 版存在的理由，不是锦上添花。
struct DetailPane: View {

    let model: BrowseModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if !model.pinned.isEmpty { comparison }
                focusedDetail
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 固定比较

    private var comparison: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Comparing", systemImage: "pin.fill").font(.headline)
                Spacer()
                Button("Clear") { model.pinned.removeAll() }
                    .buttonStyle(.link)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(model.pinnedListings, id: \.id) { entry in
                    pinnedCard(id: entry.id, listing: entry.listing)
                }
                if model.pinned.count == 1 {
                    // 明确告诉用户还差一套，而不是留一块空白。
                    VStack {
                        Image(systemName: "plus.rectangle.on.rectangle")
                            .font(.title2).foregroundStyle(.tertiary)
                        Text("Pin one more").font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 120)
                    .background(.quaternary.opacity(0.25),
                                in: RoundedRectangle(cornerRadius: 8))
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private func pinnedCard(id: Listing.ID, listing: Listing?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                if let l = listing {
                    Text(l.name).font(.callout.weight(.medium)).lineLimit(2)
                } else {
                    // 刷新后房源下架了。**不自动换成另一套**——那会让用户以为
                    // 自己还在比较原来那两套。
                    Text("No longer available")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 4)
                Button {
                    model.togglePin(id)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
            }
            if let l = listing {
                Text(l.city).font(.caption).foregroundStyle(.secondary)
                LabeledRow("Price", l.priceRaw)
                LabeledRow("Area", l.normalizedAreaText)
                LabeledRow("Energy", l.energyText)
                LabeledRow("Available", l.availableFrom.map(ServerTime.displayDate))
                statusChip(l)
            } else {
                Text(id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 焦点详情

    @ViewBuilder
    private var focusedDetail: some View {
        if let l = model.listing(model.focused) {
            VStack(alignment: .leading, spacing: 10) {
                Text(l.name).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    Text(l.city).foregroundStyle(.secondary)
                    if let b = l.buildingText, !b.isEmpty {
                        Text("·").foregroundStyle(.tertiary)
                        Text(b).foregroundStyle(.secondary)
                    }
                }
                .font(.callout)

                statusChip(l)

                Divider()

                LabeledRow("Price", l.priceRaw)
                LabeledRow("Area", l.normalizedAreaText)
                LabeledRow("Type", l.typeText)
                LabeledRow("Floor", l.floorText)
                LabeledRow("Energy", l.energyText)
                LabeledRow("Contract", l.contractText)
                LabeledRow("Platform", Platform.displayName(l.source))
                LabeledRow("Available", l.availableFrom.map(ServerTime.displayDate))

                Divider()

                HStack {
                    Button(model.pinned.contains(l.id) ? "Unpin" : "Pin for Comparison") {
                        model.togglePin(l.id)
                    }
                    Button("Open on \(Platform.displayName(l.source))") {
                        if let url = URL(string: l.url) { NSWorkspace.shared.open(url) }
                    }
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(l.url, forType: .string)
                    }
                }
                .controlSize(.small)
            }
        } else {
            ContentUnavailableView("No Selection", systemImage: "sidebar.right",
                                   description: Text("Pick a listing on the left, or use ↑↓."))
                .frame(maxWidth: .infinity, minHeight: 200)
        }
    }

    private func statusChip(_ l: Listing) -> some View {
        let s = ListingStatus.from(l.status)
        return Label {
            Text(s.label).font(.caption.weight(.medium))
        } icon: {
            Circle().fill(s.color).frame(width: 7, height: 7)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(s.color.opacity(0.15), in: Capsule())
    }
}

/// 「标签 值」一行。值缺失时显示 `—`，不是留空——留空看不出是"没有"还是"没加载"。
private struct LabeledRow: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value?.isEmpty == true ? nil : value
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(.secondary)
                .frame(width: 74, alignment: .leading)
            Text(value ?? "—").font(.callout)
            Spacer(minLength: 0)
        }
    }
}
