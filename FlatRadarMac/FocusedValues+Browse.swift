import SwiftUI

/// 把当前窗口的 ``BrowseModel`` 暴露给菜单命令。
///
/// `Commands` 建在 `Scene` 层，拿不到窗口内部的 `@State`。SwiftUI 给的正解是
/// `focusedSceneValue`：命令读的是**当前聚焦那个窗口**的值，所以将来开多窗口时
/// ⌘R 刷新的是你正在看的那一个，不是随便某一个。
extension FocusedValues {
    @Entry var browseModel: BrowseModel?

    /// 右栏（`.inspector`）的显示开关，同样按窗口走。
    ///
    /// 为什么要传 `Binding` 而不是 `Bool`：菜单项要能**改**它，不只是读。
    /// 两个窗口各自收放右栏，⌥⌘I 作用在你正在看的那一个上。
    @Entry var inspectorVisible: Binding<Bool>?
}
