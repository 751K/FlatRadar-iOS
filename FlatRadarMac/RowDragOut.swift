import SwiftUI
import AppKit
import FlatRadarCore

/// 表格行的鼠标处理：单击 / ⌘ 点 / ⇧ 点 / 双击 / **拖出去开窗**。
///
/// 为什么要下到 AppKit
/// -----------------
/// Phase 4 第一条是「把一套房源**拖出来**单开窗口」。SwiftUI 的 `.onDrag` 给不了
/// 这件事：它只负责把数据交给**接收方**，而"拖到谁都不接的地方"——桌面、另一个
/// Space、窗口外的空白——在 SwiftUI 那边没有任何回调。
///
/// AppKit 有：`NSDraggingSource` 的
/// `draggingSession(_:endedAt:operation:)` 会在松手时告诉你最终的
/// `NSDragOperation`，`[]` 就表示**没有任何接收方**。Safari 把标签页拖出来成窗、
/// Xcode 把编辑器拖出去，走的都是这条路。
///
/// 顺带解决的两件事
/// --------------
/// 1. **双击**。SwiftUI 的 `.onTapGesture(count: 2)` 和单击手势会互相抢，
///    单击要等双击超时才触发，选中就有了肉眼可见的延迟。AppKit 的
///    `event.clickCount` 是一个数，没有这个问题。
/// 2. **修饰键**。原先是在 `.onTapGesture` 里读全局的 `NSEvent.modifierFlags`
///    ——读的是"现在按着什么"，不是"点下去那一刻按着什么"。快速 ⌘ 点再松开
///    ⌘ 的话，读到的可能已经是松开后的状态。事件自带的 `modifierFlags` 才是准的。
///
/// 右键不归它管：不重写 `rightMouseDown`，AppKit 会沿响应链往上走到 SwiftUI 那层，
/// `.contextMenu` 照常弹。
struct ListingRowMouse: NSViewRepresentable {

    let listing: Listing
    /// 点下去那一刻的修饰键。语义按 Finder：⌘ 加减选、⇧ 连选、裸点单选。
    let onClick: (NSEvent.ModifierFlags) -> Void
    let onDoubleClick: () -> Void
    /// 拖到了没有接收方的地方——开一个独立窗口。
    let onDragOutside: () -> Void
    /// 鼠标进 / 出这一行。
    ///
    /// **悬停也得归它管。** 第一版把这件事留给 SwiftUI 的 `.onHover`，实测整行的
    /// 悬停态直接没了——这个 `NSView` 盖在行上，SwiftUI 那层的 tracking area 就
    /// 收不到鼠标了。既然鼠标已经全交给 AppKit，进出也一起接。
    let onHoverChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = RowMouseView()
        v.configure(listing: listing,
                    onClick: onClick,
                    onDoubleClick: onDoubleClick,
                    onDragOutside: onDragOutside,
                    onHoverChange: onHoverChange)
        return v
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view as? RowMouseView)?.configure(listing: listing,
                                           onClick: onClick,
                                           onDoubleClick: onDoubleClick,
                                           onDragOutside: onDragOutside,
                                           onHoverChange: onHoverChange)
    }
}

private final class RowMouseView: NSView, NSDraggingSource {

    private var listing: Listing?
    private var onClick: ((NSEvent.ModifierFlags) -> Void)?
    private var onDoubleClick: (() -> Void)?
    private var onDragOutside: (() -> Void)?
    private var onHoverChange: ((Bool) -> Void)?

    /// 现在鼠标在不在这一行里。
    ///
    /// 自己记一份是因为 `updateTrackingAreas` 在滚动时会被反复调用，重建 tracking
    /// area 之后 AppKit 不会补发一次 `mouseEntered`——不自己对账的话，滚一下之后
    /// 鼠标底下那一行就再也不亮了。
    private var isInside = false

    /// 按下去的那一点（本视图坐标）。用来判断有没有走够距离算作拖拽。
    private var mouseDownPoint: NSPoint?
    /// 这一轮按下之后有没有已经发起拖拽。发起过就不再当作点击。
    private var draggingStarted = false

    /// 走多远才算拖，不算手抖。
    ///
    /// AppKit 自己的阈值散在各控件里没有公开常量；3pt 是实测的手感：
    /// 再小会在普通点击时误触发（trackpad 上单击几乎必然带 1–2pt 位移），
    /// 再大则要拖一截才有反馈，像卡住了。
    private static let dragThreshold: CGFloat = 3

    func configure(listing: Listing,
                   onClick: @escaping (NSEvent.ModifierFlags) -> Void,
                   onDoubleClick: @escaping () -> Void,
                   onDragOutside: @escaping () -> Void,
                   onHoverChange: @escaping (Bool) -> Void) {
        self.listing = listing
        self.onClick = onClick
        self.onDoubleClick = onDoubleClick
        self.onDragOutside = onDragOutside
        self.onHoverChange = onHoverChange
    }

    // MARK: - 悬停

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            // `.inVisibleRect` 让 AppKit 自己按可见区域维护这块矩形——表格是滚动的，
            // 写死 `bounds` 的话滚出视野的行还会继续接鼠标。
            //
            // `.activeInActiveApp` 而不是 `.activeInKeyWindow`：两个窗口并排比的
            // 时候，鼠标划过**非 key 的**那个窗口也该有悬停反馈，否则后面那个窗口
            // 看起来是死的。
            options: [.mouseEnteredAndExited, .mouseMoved, .inVisibleRect, .activeInActiveApp],
            owner: self))
        // 重建之后自己对一次账：AppKit 不会为新建的 tracking area 补发 enter。
        syncHover()
    }

    override func mouseEntered(with event: NSEvent) { setInside(true) }
    override func mouseExited(with event: NSEvent) { setInside(false) }

    /// 滚动、布局变化之后按**几何**重新判断一次鼠标在不在里面。
    private func syncHover() {
        guard let window, window.isKeyWindow || NSApp.isActive else { return }
        let local = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setInside(visibleRect.contains(local))
    }

    private func setInside(_ inside: Bool) {
        guard inside != isInside else { return }
        isInside = inside
        onHoverChange?(inside)
    }

    /// 窗口不在前台时第一下点击也要生效。
    ///
    /// 默认是 false：非活动窗口的第一次点击只用来激活窗口，被吃掉。而"两个窗口
    /// 并排比"正是这个功能的目的——在后面那个窗口里点一行要点两下才有反应，
    /// 整件事就不成立了。
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - 鼠标

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        draggingStarted = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !draggingStarted, let start = mouseDownPoint, let listing else { return }
        let now = convert(event.locationInWindow, from: nil)
        let moved = hypot(now.x - start.x, now.y - start.y)
        guard moved >= Self.dragThreshold else { return }
        draggingStarted = true
        beginDrag(listing, with: event)
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !draggingStarted else { return }
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            // 用**事件自带的**修饰键，不是全局的 `NSEvent.modifierFlags`。
            // 后者读的是"此刻"，不是"点下去那一刻"。
            onClick?(event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        }
    }

    // MARK: - 拖拽

    private func beginDrag(_ listing: Listing, with event: NSEvent) {
        let item = NSPasteboardItem()
        // 带上 URL 和纯文本：拖进 Safari 会打开这套房，拖进备忘录 / 邮件会得到
        // 一条链接。**这不是附带功能**——一个只能拖回自己窗口的拖拽在 Mac 上
        // 是坏的，用户会拖向别的 app 并期待它有意义。
        if let url = URL(string: listing.url) {
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
        } else {
            item.setString(listing.name, forType: .string)
        }

        let dragItem = NSDraggingItem(pasteboardWriter: item)
        let image = Self.dragImage(for: listing)
        // 让拖影跟在光标左上角附近，而不是从行的原位置起飞：行是整屏宽的，
        // 以它为框会让拖影的"抓点"离光标很远。
        let size = image.size
        let origin = convert(event.locationInWindow, from: nil)
        dragItem.setDraggingFrame(NSRect(x: origin.x - 12,
                                         y: origin.y - size.height / 2,
                                         width: size.width,
                                         height: size.height),
                                  contents: image)

        beginDraggingSession(with: [dragItem], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // 拖到别的 app：复制一条链接。拖在自己窗口里：什么都不做——
        // 表格没有"把一行放到另一行上"的语义，给一个 operation 只会画出
        // 一个骗人的绿加号。
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        // `[]` = 没有任何接收方接下它。那就是"拖到了空处"，开窗。
        //
        // 不能用坐标去判断"在不在窗口外"：把行拖到**本窗口自己的空白处**
        // 也应该开窗（Safari 拖标签到同一个窗口的内容区也会成窗），
        // 而那种情况下 screenPoint 是在窗口里的。真正的判据是"没人接"。
        guard operation == [] else { return }
        onDragOutside?()
    }

    // MARK: - 拖影

    /// 一张写着房源名和价格的小卡片。
    ///
    /// 不截行本身的图：这个 view 是覆盖在行上的**透明**层，截出来是空白。
    /// 而截父视图要跨 SwiftUI 的渲染层，拿到的是整屏宽的一条——拖着一条
    /// 1100pt 宽的白带满屏跑，看不出在拖什么。
    private static func dragImage(for listing: Listing) -> NSImage {
        let title = listing.name as NSString
        let subtitle = (ListingText.price(listing) ?? listing.city) as NSString

        let titleAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.labelColor,
        ]
        let subAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]

        let pad: CGFloat = 10
        let titleSize = title.size(withAttributes: titleAttrs)
        let subSize = subtitle.size(withAttributes: subAttrs)
        let width = min(max(titleSize.width, subSize.width) + pad * 2, 260)
        let height = titleSize.height + subSize.height + pad * 2

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
                     xRadius: 8, yRadius: 8).stroke()
        // AppKit 的坐标原点在左下，所以标题画在上面 = y 更大的那一行。
        title.draw(at: NSPoint(x: pad, y: pad + subSize.height), withAttributes: titleAttrs)
        subtitle.draw(at: NSPoint(x: pad, y: pad), withAttributes: subAttrs)
        image.unlockFocus()
        return image
    }
}
