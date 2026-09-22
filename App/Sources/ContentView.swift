import SwiftUI
import AppKit

/// 主界面 —— 四个功能 Tab，对应四篇文档。
/// 左侧展示实时覆盖层状态，右侧控制面板。
struct ContentView: View {
    @StateObject private var cursorState = CursorOverlayState()
    @State private var selectedTab: Tab = .cursor

    enum Tab: String, CaseIterable, Identifiable {
        case cursor   = "① 光标覆盖层"
        case chat     = "② 对话后台"
        case agent    = "③ 多 Agent 运行时"
        case hud      = "④ 悬浮图标 HUD"
        var id: String { rawValue }
    }

    var body: some View {
        HSplitView {
            // 左：实际覆盖层的实时预览（一个小尺寸模拟窗口）
            VStack(spacing: 0) {
                CursorPreview(state: cursorState)
                    .frame(minWidth: 400, idealWidth: 480)
            }

            // 右：控制面板
            VStack(alignment: .leading, spacing: 0) {
                // Tab 栏
                Picker("", selection: $selectedTab) {
                    ForEach(Tab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 8)

                Divider()

                // Tab 内容
                switch selectedTab {
                case .cursor:
                    CursorControlPanel(state: cursorState)
                case .chat:
                    ChatDemoView()
                case .agent:
                    AgentRuntimeView()
                case .hud:
                   HUDDemoView()
                }
            }
            .frame(minWidth: 380, idealWidth: 420)
        }
    }
}

// MARK: - 光标预览窗口（模拟 NSPanel 覆盖层的小版本）

struct CursorPreview: View {
    @ObservedObject var state: CursorOverlayState

    var body: some View {
        ZStack {
            // 模拟桌面背景
            Color(white: 0.18)
                .ignoresSafeArea()

            // 模拟桌面上的"应用窗口"
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(white: 0.92))
                .frame(width: 320, height: 220)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                .overlay(
                    VStack(spacing: 6) {
                        Text("模拟桌面")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("蓝色三角即光标")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                )

            // 光标（用跟原版相同的方式画，两个分支与真实覆盖层 CursorOverlayView 一致）
            if state.style.isActive {
                // 1. 高亮目标框
                if case .highlight(let target, let label, _) = state.style {
                    Rectangle()
                        .strokeBorder(Color.blue.opacity(0.85), lineWidth: 2.5)
                        .background(Color.blue.opacity(0.08))
                        .frame(width: target.width, height: target.height)
                        .position(x: target.midX, y: target.midY)
                    Text(label)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1.5)
                        .background(.black.opacity(0.75), in: Capsule())
                        .position(x: target.midX, y: target.minY - 12)
                }

                // 2. 指针三角 + 标签气泡
                if case .pointer(let px, let py, let label) = state.style {
                    CursorPointerShape()
                        .fill(Color.accentColor)
                        .frame(width: 14, height: 18)
                        .position(x: px, y: py)
                        .shadow(color: .black.opacity(0.4), radius: 3)

                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 9, weight: .medium, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1.5)
                            .background(.black.opacity(0.75), in: Capsule())
                            .position(x: px + 16, y: py - 6)
                    }
                }
            }
        }
    }
}

// MARK: - 光标控制面板

struct CursorControlPanel: View {
    @ObservedObject var state: CursorOverlayState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "坐标模拟（0-1000 归一化）", icon: "cursorarrow")

            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("X: \(Int(state.normalizedX))")
                    Slider(value: $state.normalizedX, in: 0...1000, step: 10)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Y: \(Int(state.normalizedY))")
                    Slider(value: $state.normalizedY, in: 0...1000, step: 10)
                }
            }

            Divider()

            HStack {
                Label("屏幕点", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.caption)
                Text("(\(Int(state.screenPoint.x)), \(Int(state.screenPoint.y)))")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("缩放因子", systemImage: "aspectratio.fill")
                    .font(.caption)
                Text("\(NSScreen.main?.backingScaleFactor ?? 1, specifier: "%.1f")×")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }

            Divider()

            SectionHeader(title: "光标模式", icon: "cursorarrow.click.2")
            HStack(spacing: 10) {
                CursorModeButton(label: "蓝色指针", systemImage: "cursorarrow", isActive: isActivePointer) {
                    activatePointer(label: "Agent thinking…")
                }
                CursorModeButton(label: "高亮框",   systemImage: "rectangle.dashed", isActive: isActiveHighlight) {
                    activateHighlight()
                }
                CursorModeButton(label: "隐藏",     systemImage: "eye.slash", isActive: !state.style.isActive) {
                    state.style = .idle
                }
            }

            Divider()

            SectionHeader(title: "协议格式", icon: "doc.text")
            VStack(alignment: .leading, spacing: 4) {
                CodeBlock(text: """
                    [POINT:860,50:search bar]
                    [HIGHLIGHT:100,200,300,150:target button]
                    [TARGET:500,500,60:submit btn]
                    """)
            }

            Spacer()
        }
        .padding(14)
        .onChange(of: state.normalizedX) { _, _ in recalcScreenPoint() }
        .onChange(of: state.normalizedY) { _, _ in recalcScreenPoint() }
        .onAppear { recalcScreenPoint() }
    }

    private var isActivePointer: Bool {
        if case .pointer = state.style { return true }
        return false
    }

    private var isActiveHighlight: Bool {
        if case .highlight = state.style { return true }
        return false
    }

    private func recalcScreenPoint() {
        guard let screen = NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        // 四步换算链（doc-01 第三节）
        // ① 归一化(0-1000) → 假设截图宽 1000px（此处仅演示比例，实际需要真实截图尺寸）
        //    实际：x_pixel = normalized.x / 1000.0 * screenshotWidthInPixels
        // ② 像素 → 屏幕点（除以 scale）
        let previewW: CGFloat = 480  // 预览窗口宽度
        let previewH: CGFloat = 300
        let pixelX = CGFloat(state.normalizedX) / 1000.0 * previewW * scale
        let pixelY = CGFloat(state.normalizedY) / 1000.0 * previewH * scale
        // ③ 屏幕点 = 像素 / scale
        let screenX = pixelX / scale
        let screenY = pixelY / scale
        // ④ SwiftUI 坐标（翻转 Y）：swiftUI.y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        let swiftUIY = (previewH) - screenY

        state.screenPoint = CGPoint(x: screenX, y: swiftUIY)
        // 高亮模式下只更新坐标显示，不切回指针（预览与真实覆盖层保持分层渲染语义）
        if case .highlight = state.style {
            return
        }
        state.style = .pointer(x: screenX, y: swiftUIY, label: state.labelText)
    }

    private func activatePointer(label: String) {
        state.labelText = label
        guard let screen = NSScreen.main else { return }
        let scale = screen.backingScaleFactor
        // 四步换算链（doc-01 第三节）
        let previewW: CGFloat = 480  // 预览窗口宽度
        let previewH: CGFloat = 300
        let pixelX = CGFloat(state.normalizedX) / 1000.0 * previewW * scale
        let pixelY = CGFloat(state.normalizedY) / 1000.0 * previewH * scale
        let screenX = pixelX / scale
        let screenY = pixelY / scale
        let swiftUIY = previewH - screenY

        state.screenPoint = CGPoint(x: screenX, y: swiftUIY)
        state.style = .pointer(x: screenX, y: swiftUIY, label: label)
    }

    private func activateHighlight() {
        // 高亮框直接落在预览坐标系（300 高的模拟桌面内），不经过坐标换算链
        state.style = .highlight(
            target: CGRect(x: 80, y: 60, width: 320, height: 40),
            label: "highlight target",
            screenIndex: 0
        )
    }
}

struct CursorModeButton: View {
    let label: String
    let systemImage: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: 16))
                Text(label)
                    .font(.system(size: 9, weight: .medium))
            }
            .frame(width: 64, height: 42)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color(white: 0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isActive ? Color.accentColor : .clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 通用组件

struct SectionHeader: View {
    let title: String
    let icon: String
    var body: some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

struct CodeBlock: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.green)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 6))
    }
}
