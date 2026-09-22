# 04 · 悬浮图标与 Agent 小组件

## 源文件与证据总览

| 类别 | 文件 / 符号 | 证据来源 |
|------|------------|---------|
| 现代 HUD 宿主 | `CodexHUDWindow.swift` + `CodexHUDHitRegions.swift` + `CodexHUDWindowManager` | __cstring 文件列表 + 二进制符号 |
| HUD 面板 | `CodexHUDPanel`, `CodexHUDHostingView`, `CodexHUDView`（`hudColumn`/`chipStack`/`accordionHandlePill`/`homeSpaceEntryPillButton`） | swift_symbols.json (members) |
| 单个 Agent 图标 | `FloatingAgentChip`（35 个恢复成员）, `FloatingAgentChipPalette` | swift_symbols.json (members) |
| 通知小组件 | `FloatingAgentNotificationChip`, `FloatingSkillCreatedCard` | swift_symbols.json (members) |
| 顶栏图标栈 | `HomeSpaceIconRail`（`agentRow(for:)`/`homeButton`/`newClickyButton`）+ `HomeSpaceCompactRail` | swift_symbols.json (members) + 二进制符号 |
| 对齐手柄 | `MultiAgentScrollingLabel`, `NotchActivitySurface`, `NotchAgentSurface` | 二进制符号 |
| 截图排除 | `ClickyWindowCapturePolicy.swift` + `excludedViewClasses` + `show_in_screen_recordings` | __cstring + __objc_methname |
| 旧版机制 | `FloatingSessionButtonManager` / `FloatingButtonView` | AGENTS.md（v1.0.51 二进制中无符号） |

---

## 一、核心洞察：右上角不是「多个窗口」，而是「一个 HUD 面板 + 一个图标栈」

**【已确证】** v1.0.51 右上角那串东西，本质上是**三层不同时代机制叠加**，而不是简单的多个 `NSWindow`：

1. **旧版（仅文档）**：`FloatingSessionButtonManager` 用单个 `NSPanel` 放一个 `FloatingButtonView`，只显示一个会话按钮——这是 AGENTS.md 记录的早期做法；
2. **现代（v1.0.51 实际存在）**：每屏一个 `CodexHUDPanel`，内部由 `CodexHUDView.chipStack` **垂直堆叠**多个 `FloatingAgentChip`（每个 chip = 一个 Codex 会话/Agent），右上角再挂 `accordionHandlePill` 折叠手柄和 `homeSpaceEntryPillButton` 回家入口；
3. **Home Space 图标栏**：主窗口内有一条 `HomeSpaceIconRail`（每个 Agent 一个 `avatarDisc`，带 Pin/Archive 上下文菜单），主窗口未获得焦点时折叠成小横条，点它或 `homeSpaceEntryPillButton` 才拉出完整面板。

**【已确证】旧层已从二进制中移除**：对 arm64 二进制做 `strings` 扫描，`FloatingSessionButton`/`FloatingButtonView` 的 mangled 符号**不存在**；而 `FloatingAgentChip`、`CodexHUDPanel`、`CodexHUDHostingView`、`CodexHUDWindowManager`、`FloatingAgentChipPalette`、`MultiAgentScrollingLabel` 全部存在（`$s9HeyClicky17FloatingAgentChip33_A320ACF455F7D1850E9F86A2C5D74059LLV…` 等）。也就是说「悬浮图标」体系已整体重构成 Codex HUD，AGENTS.md 描述的是旧架构。

---

## 二、每屏一个 NSPanel：不抢占焦点、不抢鼠标、跨 Space

**【已确证】** HUD 用 `NSPanel` 而非 `NSWindow`。面板对象（`CodexHUDPanel`）与宿主视图（`CodexHUDHostingView`）在二进制中作为类型存在；面板管理器按显示器缓存——`hudsByDisplayID` 是 `CodexHUDWindowManager` 的 stored property（reflstr 恢复名），证明**每个屏幕一个面板实例**，与开发笔记中 `OverlayWindow(screen:)` 每个屏幕一个窗口的覆盖层做法同源。

【推断】综合开发笔记（`02-光标与覆盖层.md` 的覆盖层表格）与 __objc_methname 中恢复的方法名，面板参数几乎必然是：

| 属性 | 值 | 原因 |
|---|---|---|
| `isOpaque` | `false` | 显示底下桌面 |
| `backgroundColor` | `.clear` | 同上 |
| `level` | `setLevel:`/`setLevelEnum:`（高） | 浮在普通窗口上 |
| `collectionBehavior` | `setCollectionBehavior:` 组合 | 跨 Space、全屏共存 |
| `hidesOnDeactivate` | `setHidesOnDeactivate:` | Agent 应用不激活时不隐藏 |
| key window | 能成为 key，但 `canBecomeKeyWindow` 逻辑约束 | 允许输入但不成为 main |

**【已确证】鼠标事件是「探针 + 命中区」策略而不是整体 `ignoresMouseEvents`**：`CodexHUDHitRegions.swift`、`CodexHUDHitRegionProbe`、`CodexHUDHitRegionReader`、`CodexHUDHitRegionGeometry`、`HomeSpaceConversationHitRegion` 都是二进制里恢复的类型；`__Key_codexHUDInteractionEnabled`/`__Key_codexHUDHitRegions` 是注入 `EnvironmentValues` 的两个 `@EnvironmentObject`-style key（`$s7SwiftUI17EnvironmentValuesV9HeyClickyE24__Key_codexHUDHitRegions33_…LLV`）。另外还观察到 `hoverTrackingArea`/`setAcceptsMouseMovedEvents:`/`mouseMoved:` 方法名，以及 `hoverDwell*`/`collapseSuppressedUntil`/`bubbleHide*` 探针系列（`bubbleHideCursorVisibilityProbeIntervalSeconds`、`bubbleHideFullscreenProbeInFlight`、`bubbleHideCachedFrontmostWindowIsFullscreen`）。

> 推论：面板本身可以整体忽略鼠标，但用 `CodexHUDHitRegionProbe` 在屏幕上记录「哪个几何区属于哪个 chip」，鼠标在这些区内时才临时把命中区切换为可交互——这样面板既能挡在别的窗口之上又不吃掉整块屏幕的点击。折叠/展开的收起原因用 enum 记录（cstring 中相邻排列：`escape_key`/`close_button`/`hover_out`/`app_switch`/`outside_click`/`sign_out`/`notch_takeover`/`onboarding_reveal`/`link_opened`/`update_check` 等）。此为【推断】，但命中区类型的命名与 InteractionEnabled key 的存在是【已确证】的。

---

## 三、FloatingAgentChip：一个 Agent = 一个可折叠小组件

**【已确证】** `FloatingAgentChip` 的 35 个恢复成员构成了完整的「折叠态 → 展开态」两级视图（全部为真机方法，二进制中可见）：

| 区段 | 恢复成员 | 作用 |
|---|---|---|
| 外壳 | `body` / `chipInteractiveBody` / `glyphTile` / `statusIndicatorDot` / `chipBackground` / `chipBorder` | 图标瓦片 + 状态点 + 背景边框 |
| 折叠预览 | `collapsedTileSize`（布局常量）、`collapsedFinalAnswerPreview(answerText:)`、`primaryLiveContent`、`liveTrackLine`、`pinnedHistoryDebugView` | 折叠时显示最近一条回答摘要与实时进度 |
| 展开内容 | `expandedContentStrip`、`expandedContentWidth`、`expandedHeaderRow`、`activityTimelineToggleLabel`、`fileDiffSummaryView` / `fileDiffFullListPopover` / `fileDiffRow(fileDiffItem:isCompact:)`（`fileDiffPopoverWidth`）、`suggestedNextActionsRow` / `suggestedNextActionButton(suggestedNextActionText:)`、`computerUseConsentView(requestText:)`、`extraEffortApprovalView` | 展开后的正文条带、文件改动列表、建议下一步、审批 |
| 追问 | `followUpRow` / `followUpInputBox` / `followUpIdleButton` / `followUpRecordingBox` / `followUpDispatchingBox` / `darkFollowUpBoxBackground` / `followUpCancelButton` / `followUpSendButton` / `followUpButton(title:systemImage:isActive:isProminent:action:)` / `retryFailedTaskButton` | 文字/语音追问与重试 |
| 结果操作 | `showMeButton` / `fullResponseToggleButton` / `copyFinalAnswerButton(answerText:)` / `__isFinalAnswerExpandedInline` / `__didCopyFinalAnswerToClipboard` / `__isFinalAnswerPreviewTruncated` | 展示、复制、展开完整回答 |
| 注入状态 | `_taskViewModel` / `_clickyRoster` / `_assignedPaletteIndex` / `_requiresExtraEffortApproval` / `_suggestedNextActions` / `_fileDiffItems` / `_isDismissedFromHUD` / `_persistedPreviewText` | 每个 chip 绑定一个会话与一个调色板 |

**一个 chip 就是一个 Agent**：`_taskViewModel` 持有一个会话、`_clickyRoster` 持有成员、`_assignedPaletteIndex` 决定图标颜色（`FloatingAgentChipPalette`）。`_persistedPreviewText` 让折叠态在没有新事件时仍能显示上一次的回答摘要。

---

## 四、多个图标如何共存：chipStack 垂直堆叠 + 每屏一个面板

**【已确证】** 同屏多 Agent 由 `CodexHUDView.chipStack` 完成——`chipStack` 是 `CodexHUDView` 的恢复成员，`hudColumn` 包裹整列；布局常量 `chipGroupTopInset`/`chipGroupTrailingInset`/`compactChipVerticalSpacing`/`accordionHandlePillWidth`/`accordionHandlePillHeight`/`accordionHandleHitAreaHeight`/`accordionHandleCornerRadius` 全部来自 reflstr。也就是说：

- 一个面板只有一个 `chipStack`，多个 `FloatingAgentChip` **在同一面板内**按 `compactChipVerticalSpacing` 垂直排布，而不是每个窗口一个 chip；
- `hudsByDisplayID` 让每个屏幕各有一个这样的面板，靠 `activeSpaceDidChangeObserver`/`windowKeyStateObservers`（均【已确证】reflstr 名称）响应空间与焦点变化；
- `CompanionManager` 侧（reflstr 名称全部【已确证】）负责选哪个会话显示：`_selectedCodexThreadID`、`_activeCodexFollowUpHUDDisplayID`、`_hiddenCodexThreadIDs`、`_activeCodexTaskCount`、`_unreadAgentNotifications`、`_scheduledAgentCrons`、`_codexHUDSuggestedAgents`、`_codexHUDSkillCreationNotices`、`_isCodexHUDAccordionCollapsed`、`_codexHUDAccordionTransitionStyle`。

`CodexHUDHitRegionProbe` 把 chip 位置上报为 `codexHUDHitRegions`（Environment 注入）供点击判定使用；`codexHUDHideTask`/`codexHUDFocusResetTask` 是管理器的后台任务，负责定时隐藏与焦点复位。均为【已确证】字符串。

---

## 五、折叠/展开的交互机制

**【已确证】** 折叠态 = `collapsedFinalAnswerPreview(answerText:)` 一个圆形瓦片（尺寸常量 `collapsedTileSize`），展开态 = `expandedContentStrip` 宽条带（`expandedContentWidth`，长回答按 `inlineReportCharacterLimit` 截断并给出「Show me / Copy answer / 展开」）。互动链条：

1. 鼠标悬停 chip → `chipInteractiveBody` 提供交互体，`__hoveredChipIdentifier`/`__pendingHoverClearTask` 追踪悬停项（reflstr）；
2. 悬停保持（`hoverDwell*` 系列探针）或点击 → 展开；展开是局部状态 `__isPinnedExpanded`（pin 固定）与 `__isFinalAnswerExpandedInline`（正文内联展开）两个布尔；
3. 收起原因由 enum 记录（`escape_key`/`close_button`/`hover_out`/`app_switch`/`outside_click` 等 cstring 相邻排列），所以「Esc 收起」「点外部收起」「切换 App 收起」可以各自独立处理；
4. 顶部 `accordionHandlePill`（宽度/高度/圆角常量均已恢复）提供整体折叠抓手，`homeSpaceEntryPillButton` 一键跳回主窗口；通知类则用 `FloatingAgentNotificationChip`（`notificationReportPreview`/`remoteTaskActionSection`/`remoteTaskFollowUpButton`）与 `FloatingSkillCreatedCard`（`headerRow`/`skillBox`）。

---

## 六、截图排除：模型截屏时看不到这些悬浮层

**【已确证】** 两条路径：

- 旧版：`ScreenshotManager.floatingButtonWindowToExcludeFromCaptures`（`NSWindow?`，AGENTS.md）——`captureScreen()` 把该窗口匹配到 `SCWindow` 后从捕获过滤器剔除；
- 新版：`ClickyWindowCapturePolicy.swift` + `excludedViewClasses`（cstring 中 `, excludedViewClasses: ` 可见）——按 AppKit 视图类名排除，模型截屏时 HUD/光标层不出现。

配套设置项 `show_in_screen_recordings` 与「Screenshot compatibility mode」（cstring 日志 `📸 Screenshot compatibility mode enabled / force-exited by hotkey summon (issue #270)`）控制这些层能否出现在系统录屏里；`shouldRestoreCodexHUDAfterSystemCaptureCompatibilityMode`/`…AfterSecureCommerceCompatibilityMode` 表明模式退出后要恢复 HUD。开发笔记同源印证：覆盖层「截图时按 bundle id 排除」。

---

## 七、类型 → 角色 → 源文件

| 类型 | 角色 | 源文件 |
|---|---|---|
| `CodexHUDPanel` | NSPanel 子类（每屏一个） | `CodexHUDWindow.swift` |
| `CodexHUDHostingView` | NSHostingView 宿主 | `CodexHUDWindow.swift` |
| `CodexHUDWindowManager` + `ScreenHUD` | 面板生命周期/枚举 | `CodexHUDWindow.swift` |
| `CodexHUDView` | SwiftUI 根视图（hudColumn/chipStack） | `CodexHUDWindow.swift` |
| `CodexHUDHitRegions` / `CodexHUDHitRegionProbe` / `CodexHUDHitRegionReader` | 命中区探针 | `CodexHUDHitRegions.swift` |
| `FloatingAgentChip` + `FloatingAgentChipPalette` | 单个 Agent 小组件 | （members 关联，未恢复文件名） |
| `FloatingAgentNotificationChip` / `FloatingSkillCreatedCard` | 通知小组件 / 技能创建卡片 | （members 关联） |
| `HomeSpaceIconRail` / `HomeSpaceCompactRail` | Home Space 图标栏/折叠栏 | `HomeSpaceIconRail.swift` |
| `MultiAgentScrollingLabel` / `NotchActivitySurface` / `NotchAgentSurface` | 多 Agent 词条、灵动岛活动/Agent 面 | `NotchActivitySurface.swift` |
| `HandoffIndicatorPanel` / `HandoffIndicatorChipView` | 交接指示器 | `HandoffIndicatorWindow.swift` |
| `NotchWindowManager` / `NotchPresenter` | 灵动岛窗口管理 | `NotchWindowManager.swift` |
| `HomeSpaceWindowManager` | Home Space 窗口管理 | `HomeSpaceWindowManager.swift` |
| `WindowPositionManager` | 窗口定位 | `WindowPositionManager.swift` |
| `FloatingSessionButtonManager` / `FloatingButtonView` | 旧版单按钮（仅文档） | `FloatingSessionButton.swift`（AGENTS.md） |

---

## 八、重构草图：复刻「每屏一个 HUD 面板 + 垂直 chip 栈」

以下为**【推断】重建代码**（v1.0.51 二进制只有符号没有实现，仅供复刻参考）：

```swift
import AppKit
import SwiftUI

// 每个屏幕一个面板，chip 垂直堆叠
final class CodexHUDWindowManager {
    private var hudsByDisplayID: [CGDirectDisplayID: CodexHUDPanel] = [:]

    func ensurePanel(for screen: NSScreen) -> CodexHUDPanel {
        let id = screen.displayID()
        if let p = hudsByDisplayID[id] { return p }
        let panel = CodexHUDPanel(screen: screen)
        hudsByDisplayID[id] = panel
        return panel
    }

    func showChips(_ models: [AgentSession], on screen: NSScreen) {
        let panel = ensurePanel(for: screen)
        panel.hostingView.rootView =
            CodexHUDView(chipStack: models.map { FloatingAgentChip(model: $0) })
        panel.orderFrontRegardless()   // Agent 应用未激活也可见
    }
}

// 非激活也能显示的高层浮动面板
final class CodexHUDPanel: NSPanel {
    private let targetScreen: NSScreen
    let hostingView = NSHostingView(rootView: AnyView(EmptyView()))

    init(screen: NSScreen) {
        self.targetScreen = screen
        let vf = screen.visibleFrame
        super.init(contentRect: NSRect(x: vf.maxX - 60, y: vf.maxY - 60,
                                       width: 60, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = false
        level = .statusBar                  // 高于普通窗口
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = hostingView
        // 位置：主屏可见区右上角（FloatingSessionButtonManager 同款语义）
        setFrameOrigin(NSPoint(x: vf.maxX - frame.width,
                               y: vf.maxY - frame.height))
    }
}

// 折叠 → 展开两级结构（对应 chipInteractiveBody/expandedContentStrip）
struct CodexHUDView: View {
    let chipStack: [FloatingAgentChip]
    @State private var isAccordionCollapsed = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {   // compactChipVerticalSpacing
            if !isAccordionCollapsed { ForEach(chipStack) { $0 } }
            accordionHandlePill
        }
        .padding(.top, 6)      // chipGroupTopInset
        .padding(.trailing, 6) // chipGroupTrailingInset
        .animation(.easeInOut(duration: 0.25), value: isAccordionCollapsed)
    }
}
```

要点：`orderFrontRegardless()`（objc 方法名已恢复）保证 Agent 应用未激活时面板仍然可见；`nonactivatingPanel` + `hidesOnDeactivate=false` 保证不抢激活状态；跨 Space 靠 `canJoinAllSpaces`；从 `visibleFrame` 顶边对齐取得「右上角」。

---

## 九、GUI 验证状态（2026-09-22）

**【✅ 已验证】** 本模块对应的 Tab ④（悬浮图标 HUD）已通过 macos-use MCP 完成 GUI 验证。

### 已验证功能

| 功能 | 状态 | 验证方式 |
|------|------|---------|
| 手风琴折叠/展开 | ✅ | 点击"折叠"按钮 → 所有 chip 消失，pill 文字从"手风琴展开"变为"手风琴已折叠"；点击"展开"恢复 |
| 新 Agent chip（addChip） | ✅ | 点击"新 Agent chip" → chip 数 3→4，pill 文字更新；4 个 "C" 字母圆瓦片可见 |
| 清空所有 chip（removeAll） | ✅ | 点击"清空" → 所有 chip 消失，pill 从"4 个 chip"变为"0 个 chip" |
| 悬停展开（hover-as-click） | ✅ | 合成点击等效触发 `.onHover { isExpanded = true }` → collapsedTile 展开为 expandedContentStrip |
| expandedContentStrip 内容 | ✅ | 展开态确认包含：Agent 名称、relativeTime、preview（lineLimit 2）、follow-up TextField、arrow.up.circle.fill 发送按钮 |
| 折叠态瓦片（collapsedTile） | ✅ | 34×34 Circle + palette 渐变首字母 + 8×8 status dot（green/gray）|

### 未验证功能（MCP 行为限制，非代码缺陷）

| 功能 | 原因 |
|------|------|
| follow-up TextField 打字 | macos-use MCP 每次动作后恢复光标位置 → `onHover(false)` 触发 → expandedContentStrip 立即折叠 → TextField 失焦。这是 MCP 指针还原行为的副作用，不是代码 bug |
| status dot 绿/灰 | SwiftUI Circle shape 无 AX 属性，无法通过 Accessibility 树验证 |
| 面板"每屏一个"真实效果 | 复刻版用单个模拟桌面窗口演示；真实 CodexHUDPanel（每屏一个 NSPanel）可在预览区 orderFront 查看 |

### 代码说明

- `HUDDemoView.swift:33` 的折叠按钮文案：展开态显示"折叠"，折叠态显示"展开"。
- `accordionHandlePill`（`HUDDemoView.swift:154-163`）本身的 Button action 为空——整体折叠由父级 `HUDDockState.toggleCollapse()` 控制，pill 仅作视觉手柄。
- "向下移动"/"向上移动"按钮是 macOS 系统级滚动条分页控件（26×26 AXButton），**不是**应用代码功能，不要误归因。

---

## 关键结论

- 【已确证】「多个图标」= 每屏一个 `CodexHUDPanel`（`hudsByDisplayID`）内由 `chipStack` 垂直堆叠多个 `FloatingAgentChip`，外加 Home Space 侧栏的 `HomeSpaceIconRail` 与灵动岛的 `Notch*` 层。
- 【已确证】v1.0.51 二进制中不存在 `FloatingSessionButton`/`FloatingButtonView` 符号，旧版单按钮机制仅存于 AGENTS.md。
- 【已确证】截图排除 = `excludedViewClasses` + `show_in_screen_recordings`（`ClickyWindowCapturePolicy.swift`），旧版另有 `floatingButtonWindowToExcludeFromCaptures`。
- 【推断】面板级参数（透明、高 level、跨 Space、不激活）与命中区「探针切换交互」机制，有 objc 方法名与 `CodexHUDHitRegion*` 类型支撑但无源码级实现。
