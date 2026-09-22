import SwiftUI
import AppKit

/// ④ 悬浮图标与 Agent 小组件 —— 复刻 doc-04 的核心架构：
///   每屏一个 CodexHUDPanel（透明 NSPanel，不抢焦点），内部 chipStack 垂直堆叠
///   多个 FloatingAgentChip，外加 accordionHandlePill 折叠手柄与 Home Space 入口。
///
/// 原版：CodexHUDPanel / CodexHUDHostingView / CodexHUDWindowManager(hudsByDisplayID)
///       / CodexHUDView(hudColumn/chipStack) / FloatingAgentChip(35 个恢复成员)
///       / FloatingAgentChipPalette / CodexHUDHitRegions(命中区探针)。
///
/// 本复刻的差异（诚实标注）：
///   - 用一个「模拟桌面」窗口演示 chip 栈（真正每屏一个 NSPanel 也实现了，
///     见 HUDDockPanel —— 可在预览区把它 orderFront 出来看真实效果）；
///   - 命中区探针（CodexHUDHitRegionProbe 在鼠标经过时把命中区切为可交互）
///     简化成纯 SwiftUI 的 hover 处理——文档里那套 Environment 注入的
///     codexHUDHitRegions 机制，本复刻保留数据结构，不接 CGEvent 监控；
///   - 折叠/展开两级结构 1:1（collapsedTileSize 圆形瓦片 ↔ expandedContentStrip
///     宽条带），收起原因 enum（escape_key/close_button/hover_out/app_switch…）
///     原样保留。
struct HUDDemoView: View {
    @StateObject private var hud = HUDDockState()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "HUD 悬浮图标（chipStack 垂直堆叠 + 命中区）", icon: "square.stack.3d.up")

            HStack(spacing: 8) {
                statusPill("每屏一 panel", systemImage: "display", color: .blue)
                statusPill("\(hud.chips.count) 个 chip", systemImage: "square.stack.3d.up", color: .purple)
                statusPill(hud.isCollapsed ? "手风琴已折叠" : "手风琴展开", systemImage: "arrow.down.right.and.arrow.up.left", color: hud.isCollapsed ? .orange : .green)
                Spacer()
                Button(hud.isCollapsed ? "展开" : "折叠") { hud.toggleCollapse() }
                    .controlSize(.small)
            }

            // 模拟桌面上的 HUD 面板（真实面板 CodexHUDPanel 的迷你版）
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(white: 0.2))
                    .overlay(
                        VStack {
                            Text("模拟桌面（每屏一 panel）")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }.padding(.top, 4)
                    )

                CodexHUDChipStack(chips: hud.chips, isCollapsed: hud.isCollapsed)
                    .padding(.top, 10)
                    .padding(.trailing, 10)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            // 动作
            HStack(spacing: 8) {
                Button("新 Agent chip") { hud.addChip() }
                Button("完成一个任务（预览更新）") { hud.completeRandomTask() }
                Spacer()
                Button("清空") { hud.removeAll() }
            }
            .controlSize(.small)

            // 命中区说明
            CodeBlock(text: """
                CodexHUDHitRegions — 面板整体忽略鼠标，但探针把每个 chip 的几何区记录为命中区，
                鼠标进入才临时把该区切为可交互（hoverDwell* 系列探针决定悬停展开）。
                收起原因 enum: escape_key / close_button / hover_out / app_switch / outside_click …
                """)
        }
        .padding(12)
    }

    private func statusPill(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - 状态：chip 数据 + 手风琴

@MainActor
final class HUDDockState: ObservableObject {
    @Published var chips: [HUDChipModel] = [
        HUDChipModel(name: "codex-analyzer", paletteIndex: 0, preview: "已找到 12 处可优化点…"),
        HUDChipModel(name: "codex-writer",   paletteIndex: 1, preview: "正在写 README…"),
        HUDChipModel(name: "codex-reviewer", paletteIndex: 2, preview: "已提出 3 条审查意见"),
    ]
    @Published var isCollapsed = false

    var collapseReason: String = "close_button"   // doc-04 第五节收起原因 enum

    func addChip() {
        let names = ["codex-research", "codex-notifier", "codex-assistant"]
        let palette = chips.count % 6
        chips.append(HUDChipModel(
            name: names[chips.count % names.count],
            paletteIndex: palette,
            preview: "等待任务…"
        ))
    }

    func completeRandomTask() {
        guard !chips.isEmpty else { return }
        let idx = Int.random(in: 0..<chips.count)
        let previews = ["已完成：输出已写入 workspace", "完成：修正了 3 个 bug", "完成：生成报告", "完成：回复了通知"]
        chips[idx].preview = previews.randomElement() ?? "完成"
        chips[idx].previewUpdatedAt = Date()
    }

    func removeAll() {
        chips.removeAll()
    }

    func toggleCollapse() {
        isCollapsed.toggle()
        collapseReason = isCollapsed ? "close_button" : "accordion_handle"
    }
}

/// 一个 chip = 一个 Agent 会话（doc-04 第三节：FloatingAgentChip 绑定一个会话）
struct HUDChipModel: Identifiable {
    let id = UUID()
    var name: String
    var paletteIndex: Int
    var preview: String
    var previewUpdatedAt: Date = .distantPast
}

// MARK: - 折叠态 → 展开态（两级结构 1:1）

struct CodexHUDChipStack: View {
    let chips: [HUDChipModel]
    let isCollapsed: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {   // compactChipVerticalSpacing
            if !isCollapsed {
                ForEach(chips) { chip in
                    FloatingAgentChipReplica(chip: chip)
                }
            }
            accordionHandlePill
        }
        .padding(.top, 6)        // chipGroupTopInset
        .padding(.trailing, 6)   // chipGroupTrailingInset
        .animation(.easeInOut(duration: 0.22), value: isCollapsed)
    }

    private var accordionHandlePill: some View {
        // accordionHandlePillWidth/Height/CornerRadius（已确证布局常量）
        Button(action: { /* 整体折叠由父级控制，这里仅展示 */ }) {
            Image(systemName: isCollapsed ? "chevron.up.circle" : "chevron.down.circle")
                .font(.system(size: 12))
                .frame(width: 26, height: 26)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

/// FloatingAgentChip 复刻：折叠 = 圆形瓦片 + 状态点；展开 = 宽条带（预览 + follow-up）
struct FloatingAgentChipReplica: View {
    @State var chip: HUDChipModel
    @State private var isExpanded = false
    @State private var followUp = ""
    @FocusState private var followUpFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if isExpanded {
                expandedContentStrip
            } else {
                collapsedTile
            }
        }
        .onHover { hovering in
            // hoverDwell* 简化版：悬停即展开
            if hovering { isExpanded = true } else { isExpanded = false }
        }
        .animation(.easeInOut(duration: 0.18), value: isExpanded)
    }

    // 折叠态：collapsedTileSize 圆形瓦片
    private var collapsedTile: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(paletteColor(chip.paletteIndex).gradient)
                .frame(width: 34, height: 34)
                .overlay(
                    Text(String(chip.name.prefix(1)).uppercased())
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                )
            Circle()
                .fill(chip.isLive ? .green : .gray)
                .frame(width: 8, height: 8)
                .overlay(Circle().stroke(.white, lineWidth: 1))
                .offset(x: 2, y: -2)
        }
    }

    // 展开态：expandedContentStrip 宽条带
    private var expandedContentStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(paletteColor(chip.paletteIndex).gradient)
                    .frame(width: 14, height: 14)
                Text(verbatim: chip.name)
                    .font(.system(size: 10, weight: .semibold))
                Spacer()
                Text(relativeTime(chip.previewUpdatedAt))
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
            }
            Text(chip.preview)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                // followUpRow（doc-04：文字/语音追问）
                TextField("Follow-up…", text: $followUp)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 9))
                    .controlSize(.small)
                Button {
                    if !followUp.isEmpty {
                        chip.preview = "已追问：\(followUp)"
                        followUp = ""
                    }
                } label: {
                    Image(systemName: "arrow.up.circle.fill")
                }
                .buttonStyle(.plain)
                .controlSize(.small)
            }
        }
        .padding(8)
        .frame(width: 200)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.92))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
        )
    }

    private func relativeTime(_ d: Date) -> String {
        guard d > .distantPast else { return "·" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: d, relativeTo: Date())
    }
}

extension HUDChipModel {
    var isLive: Bool { previewUpdatedAt > .distantPast }
}
