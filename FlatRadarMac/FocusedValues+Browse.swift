import SwiftUI

/// 把当前窗口的 ``BrowseModel`` 暴露给菜单命令。
///
/// `Commands` 建在 `Scene` 层，拿不到窗口内部的 `@State`。SwiftUI 给的正解是
/// `focusedSceneValue`：命令读的是**当前聚焦那个窗口**的值，所以将来开多窗口时
/// ⌘R 刷新的是你正在看的那一个，不是随便某一个。
extension FocusedValues {
    @Entry var browseModel: BrowseModel?
}
