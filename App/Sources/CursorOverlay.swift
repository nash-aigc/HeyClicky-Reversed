import SwiftUI
import AppKit

/// 覆盖层视图 —— 在 NSPanel 里用 SwiftUI 绘制"假光标"。
/// 原版用 BlueCursorView / PointerCursorView / IBeamCursorNSView 等多个视图，
/// 这里用枚举统一成一个可切换的状态机。
enum CursorStyle: Equatable {
    case pointer(x: CGFloat, y: CGFloat, label: String)
    case highlight(target: CGRect, label: String, screenIndex: Int)
    case idle

    var isActive: Bool { self != .idle }
}

final class CursorOverlayState: ObservableObject {
    /// 所有屏幕共享一份状态（按主屏幕坐标）。
    @Published var style: CursorStyle = .idle
    @Published var labelText: String = ""
    /// 0-1000 归一化坐标，由协议层或模拟器写入
    @Published var normalizedX: Double = 500
    @Published var normalizedY: Double = 500
    /// 实际屏幕点（归一化 → 像素 → backingScale → 屏幕点），由 convert() 计算
    @Published var screenPoint: CGPoint = .zero
}

/// 全屏透明窗口：每屏一个实例，SwiftUI 绘制光标。
final class CursorPanel: NSPanel {
    let hostingView: NSHostingView<CursorOverlayView>
    let overlayState: CursorOverlayState

    init(screen: NSScreen) {
        let state = CursorOverlayState()
        self.overlayState = state
        self.hostingView = NSHostingView(rootView: CursorOverlayView(state: state))

        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isOpaque = false
        backgroundColor = .clear
        ignoresMouseEvents = true           // 绝不拦截点击
        level = .statusBar + 100            // 浮在所有普通窗口之上
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        titlebarAppearsTransparent = true
        titleVisibility = .hidden

        // 截图排除：自身截图/屏幕录制时隐藏这个窗口
        // NSWindow.Level 极高 + sharingType 可控，但更可靠的是
        // 在屏幕快照期间临时隐藏——原版用的就是这个策略。
        contentView = hostingView
        orderFront(nil)
    }
}

/// 覆盖层的 SwiftUI 内容：画一个带文字的指针三角 + 底下一条淡色高亮框
struct CursorOverlayView: View {
    @ObservedObject var state: CursorOverlayState
    @State private var pulse: Double = 0

    var body: some View {
        GeometryReader { _ in
            ZStack {
                // 1. 高亮目标框
                if case .highlight(let target, let label, _) = state.style {
                    Rectangle()
                        .strokeBorder(Color.blue.opacity(0.85), lineWidth: 2.5)
                        .background(Color.blue.opacity(0.08))
                        .frame(width: target.width, height: target.height)
                        .position(x: target.midX, y: target.midY)
                    Text(label)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.ultraThinMaterial, in: Capsule())
                        .position(x: target.midX, y: target.minY - 14)
                }

                // 2. 光标三角 + 标签气泡
                if case .pointer(let px, let py, let label) = state.style {
                    CursorPointerShape()
                        .fill(Color.accentColor)
                        .frame(width: 18, height: 24)
                        .position(x: px, y: py)
                        .shadow(color: .black.opacity(0.35), radius: 4, x: 1, y: 2)
                        .animation(.snappy(duration: 0.15), value: state.normalizedX)
                        .animation(.snappy(duration: 0.15), value: state.normalizedY)

                    if !label.isEmpty {
                        Text(label)
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.black.opacity(0.7), in: Capsule())
                            .position(x: px + 20, y: py - 8)
                    }
                }
            }
            // 呼吸动画（空闲时脉动小圆点）
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulse = 1
                }
            }
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)             // 和 NSPanel.ignoresMouseEvents 双保险
    }
}

/// 指针三角形状——复刻原版 BlueCursorView 的蓝色三角
struct CursorPointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        // 三角：尖端在左上角 (0, 0)，右边展开到 (width, height)
        p.move(to: CGPoint(x: 0, y: 0))
        p.addLine(to: CGPoint(x: rect.width, y: rect.height * 0.55))
        p.addLine(to: CGPoint(x: rect.width * 0.5, y: rect.height))
        p.closeSubpath()
        return p
    }
}
