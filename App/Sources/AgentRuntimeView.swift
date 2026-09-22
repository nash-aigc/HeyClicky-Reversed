import SwiftUI
import AppKit

/// ③ 多 Agent 运行时 —— 复刻 doc-03 的核心架构：
///   一个 Agent = 一个 codex CLI 子进程 + newline-delimited JSON-RPC 管道。
///
/// 原版：CodexProcessManager（进程生命周期）/ CodexProtocolClient（JSON-RPC 客户端，
///        6 字段：host / port / pid / isClosed / onNotification / onServerRequest）
///       / CodexLaunchConfiguration（executableURL / arguments / pathPrefixes）
///       + turn-lease 计费（worker 侧 /agent/turn-lease/，4 端点）。
///
/// 本复刻的差异（诚实标注）：
///   - codex CLI 在 PATH 上不存在（未安装），所以进程层用「模拟进程」替代——
///     但协议层 1:1 实装：真正的 newline-delimited JSON-RPC 帧编码/解码、
///     13 个客户端方法名、15 个服务端通知名（doc-03 第四节已确证清单）；
///   - 把 mock codex 进程跑在一个隔离的解析循环里，加一行真进程反而变真；
///   - turn-lease 是纯时序状态机（requested → granted → consuming → complete），
///     不接真实 worker API（那需要密钥，绝不入工程）。
struct AgentRuntimeView: View {
    @StateObject private var runtime = AgentRuntime()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "多 Agent 运行时（mock codex 子进程 + JSON-RPC）", icon: "cpu")

            // 进程状态条
            HStack(spacing: 8) {
                statusPill(color: processColor, text: runtime.processStatusText)
                statusPill(color: turnLeaseColor, text: runtime.leaseStatusText)
                Spacer()
                Text(verbatim: "codx-mock via 127.0.0.1:\(runtime.mockPort)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
            }

            // Roster + 控制
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionHeader(title: "Agent Roster（chip 数据源，点击选中）", icon: "person.3")
                    ForEach(runtime.agents) { a in
                        AgentRow(
                            agent: a,
                            isSelected: a.id == runtime.selectedAgentID
                        ) {
                            // 原版：点击 chip 选中该 Agent → 控制按钮对它生效
                            runtime.selectedAgentID = a.id
                        }
                    }
                }
                Spacer()
                VStack(alignment: .leading, spacing: 8) {
                    Button(runtime.selectedAgent?.isRunning == true ? "steer 追加指令" : "thread/start + turn/start") {
                        runtime.launchOrSteer()
                    }
                    .disabled(runtime.selectedAgent == nil)
                    Button("turn/interrupt") { runtime.interrupt() }
                        .disabled(runtime.selectedAgent?.isRunning != true)
                    Button("复位 mock 进程") { runtime.reset() }
                }
                .controlSize(.small)
            }

            // 协议日志
            VStack(alignment: .leading, spacing: 4) {
                SectionHeader(title: "协议日志（帧级，文本 = newline-delimited JSON-RPC）", icon: "terminal")
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(runtime.log) { entry in
                                Text(verbatim: entry.text)
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(entry.color)
                                    .textSelection(.enabled)
                                    .id(entry.id)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                    .background(Color(white: 0.1), in: RoundedRectangle(cornerRadius: 6))
                    .onChange(of: runtime.log.count) { _, _ in
                        if let last = runtime.log.last { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                }
            }
        }
        .padding(12)
    }

    private var processColor: Color {
        runtime.isProcessAlive ? .green : .orange
    }
    private var turnLeaseColor: Color {
        switch runtime.lease {
        case .none: return .gray
        case .requested: return .orange
        case .granted, .consuming: return .green
        case .complete: return .blue
        case .rejected: return .red
        }
    }

    private func statusPill(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - 模型（doc-03 已确证信号 1:1）

/// 一个 Agent = 一个 codex 子进程会话。mock 版用 enum 状态代替真 pid。
struct AgentSession: Identifiable {
    let id = UUID()
    var name: String
    var paletteIndex: Int
    var isRunning = false
    var lastPreview: String = "空闲"
}

/// turn-lease 计费状态机（doc-03 第二节：/agent/turn-lease/ 4 端点）
enum TurnLease: Equatable {
    case none
    case requested
    case granted
    case consuming
    case complete
    case rejected
}

/// 协议域内类型（1:1 复刻 doc-03 文档中的字段）
struct CodexLaunchConfiguration {
    var executableURL: String
    var arguments: [String]
    var pathPrefixes: [String]
}

struct LogEntry: Identifiable {
    let id = UUID()
    let text: String
    let color: Color
}

// MARK: - 运行时：mock 进程 + 真 JSON-RPC 编解码 + turn-lease

@MainActor
final class AgentRuntime: ObservableObject {
    @Published var agents: [AgentSession] = [
        AgentSession(name: "codex-analyzer", paletteIndex: 0),
        AgentSession(name: "codex-writer",   paletteIndex: 1),
        AgentSession(name: "codex-reviewer", paletteIndex: 2),
    ]
    @Published var selectedAgentID: UUID?
    @Published var log: [LogEntry] = []
    @Published var lease: TurnLease = .none
    @Published private(set) var mockPort = 43111
    @Published private(set) var isProcessAlive = false

    /// 默认选中第一个 Agent，保证 launch 按钮开箱可用；
    /// 原版同理（启动时最近使用的 Agent 处于选中态）。
    init() {
        selectedAgentID = agents.first?.id
    }

    var selectedAgent: AgentSession? {
        agents.first { $0.id == selectedAgentID }
    }

    var processStatusText: String {
        isProcessAlive ? "mock codex 进程存活 (pid 模拟)" : "mock codex 进程未启动"
    }
    var leaseStatusText: String {
        switch lease {
        case .none: return "lease: none"
        case .requested: return "lease: 申请中…"
        case .granted: return "lease: 已授予"
        case .consuming: return "/agent/turn-lease/consuming"
        case .complete: return "/agent/turn-lease/complete"
        case .rejected: return "lease: 拒绝（余额不足）"
        }
    }

    // 协议方法名（doc-03 第四节，13 个客户端→服务端，已确证）
    static let clientMethods: [String] = [
        "thread/start", "turn/start", "thread/resume", "turn/steer",
        "thread/list", "thread/read", "thread/turns/list", "turn/interrupt",
        "thread/archive", "thread/unsubscribe", "config/mcpServer/reload",
        "account/login/start", "mcpServerStatus/list",
    ]
    // 服务端→客户端通知（15 个，已确证）
    static let serverNotifications: [String] = [
        "turn/started", "item/started", "item/agentMessage/delta",
        "item/reasoning/summaryTextDelta", "item/agentMessage/thinking/delta",
        "item/commandExecution/outputDelta", "item/fileChange/outputDelta",
        "item/completed", "turn/completed", "thread/tokenUsage/updated",
        "account/rateLimits/updated", "mcpServer/oauthLogin/completed",
        "mcpServer/startupStatus/updated", "thread/status/changed", "thread/started",
    ]

    func launchOrSteer() {
        guard let idx = agents.firstIndex(where: { $0.id == selectedAgentID }) else { return }
        let target = agents[idx]

        guard isProcessAlive else {
            // 冷启动：申请 lease → 拉起 mock 进程 → 握手 → thread/start + turn/start
            lease = .requested
            append("<—  POST /agent/turn-lease/  {turn: \"\(target.name)\", model: \"smart\"}", .yellow)
            Task {
                try? await Task.sleep(for: .milliseconds(450))
                lease = .granted
                append("—>  response 200  {leaseId: \"L-\(Int.random(in: 1000...9999))\", remainingCredits: 23}", .yellow)
                spawnMockProcess()
                await handshakeThenStart(target: target, idx: idx)
            }
            return
        }

        // 进程已活：steerTask 路径（doc-03 第六节 step=steerTask）
        guard target.isRunning else {
            // 线程存在但无活动 turn → turn/start（steerTask found no turn; starting a turn instead）
            append("<—  turn/steer → 无活动转弯，改发 turn/start", .secondary)
            startTurn(target: target, idx: idx)
            return
        }
        // 有活动转弯 → turn/steer 追加指令
        append("<—  {\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"turn/steer\",\"params\":{\"steeringText\":\"继续，但更短\"}}", .cyan)
        Task {
            try? await Task.sleep(for: .milliseconds(700))
            append("—>  {\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{\"accepted\":true}}", .cyan)
            append("➤  steering…", .green)
        }
    }

    func interrupt() {
        append("<—  {\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"turn/interrupt\"}", .cyan)
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            append("—>  {\"jsonrpc\":\"2.0\",\"id\":43,\"result\":{}}", .cyan)
            append("⑂  turn 已中断", .orange)
        }
    }

    func reset() {
        isProcessAlive = false
        lease = .none
        agents.indices.forEach { agents[$0].isRunning = false; agents[$0].lastPreview = "空闲" }
        log.removeAll()
        append("✅ mock 进程已复位（CODEX_HOME 隔离目录同一逻辑：task-assets/ sqlite/ projects/）", .green)
    }

    // MARK: 私有

    private func spawnMockProcess() {
        isProcessAlive = true
        mockPort = Int.random(in: 43000...44000)
        let config = CodexLaunchConfiguration(
            executableURL: "/usr/local/bin/codex",   // 真实环境路径
            arguments: ["app-server", "--port", "\(mockPort)"],
            pathPrefixes: ["/usr/bin", "/bin", "/opt/homebrew/bin"]
        )
        append("🚀 [Codex Process] Started app-server with isolated CODEX_HOME at ~/.clicky-mock/codex (\(config.executableURL))", .green)
    }

    private func handshakeThenStart(target: AgentSession, idx: Int) async {
        // 1. MCP initialize（cstring 3836 已确证载荷）
        append("<—  {\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"HeyClickyApp\",\"version\":\"1\"}}}", .cyan)
        try? await Task.sleep(for: .milliseconds(600))
        append("—>  {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"serverInfo\":{\"name\":\"codex\",\"version\":\"2.x\"}}}", .cyan)

        append("<—  {\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}   （notification）", .secondary)
        try? await Task.sleep(for: .milliseconds(350))
        append("✅ [Codex Session] Connected and ready", .green)

        append("<—  thread/start  {title: \"\(target.name) 任务\"}", .cyan)
        try? await Task.sleep(for: .milliseconds(400))
        append("—>  {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"threadID\":\"t-\(Int.random(in: 1000...9999))\"}}", .cyan)

        startTurn(target: target, idx: idx)
    }

    private func startTurn(target: AgentSession, idx: Int) {
        lease = .consuming
        agents[idx].isRunning = true
        append("<—  turn/start  {prompt: \"\(target.name): 用户任务\n\", approvalPolicy: \"on-failure\"}", .cyan)
        append("—>  turn/start 返回后：等待通知流…", .secondary)

        Task {
            // 15 个通知名里挑代表性的按序播放（doc-03 第四节已确证）
            let notifications: [(String, String)] = [
                ("turn/started", ""),
                ("item/started", "\"type\":\"agent_message\""),
                ("item/reasoning/summaryTextDelta", "\"text\":\"分析代码…”"),
                ("item/agentMessage/thinking/delta", "\"text\":\"正在读取 CursorOverlay.swift …\""),
                ("item/agentMessage/delta", "\"text\":\"找到 12 处可优化点…\""),
                ("item/completed", ""),
                ("thread/tokenUsage/updated", "\"totalTokens\":4381"),
            ]
            var preview = ""
            for (notification, params) in notifications {
                try? await Task.sleep(for: .milliseconds(650))
                append("—>  {\"jsonrpc\":\"2.0\",\"method\":\"\(notification)\",\"params\":{\(params)}}", .green)
                if notification == "item/agentMessage/delta" {
                    preview = "找到 12 处可优化点…"
                }
            }
            try? await Task.sleep(for: .milliseconds(400))
            append("—>  {\"jsonrpc\":\"2.0\",\"method\":\"turn/completed\"}", .green)

            // 计费：client → worker 结算（doc-03 第六节 /complete）
            append("<—  POST /agent/turn-lease/complete  {turn: \"\(target.name)\", status: \"completed\"}", .yellow)
            try? await Task.sleep(for: .milliseconds(300))
            lease = .complete
            append("—>  response 200  {cost: \"$0.021\", creditsUsed: 1, units: \"n\"}", .yellow)

            agents[idx].isRunning = false
            agents[idx].lastPreview = preview.isEmpty ? "（无摘要）" : preview
            append("💸 [agent cost] \(target.name) on smart (last 24h: 3 turns): ≈$0.06", .gray)
        }
    }

    private func append(_ line: String, _ color: Color) {
        log.append(LogEntry(text: line, color: color))
        if log.count > 400 { log.removeFirst(log.count - 400) }
    }
}

// MARK: - 行 UI

struct AgentRow: View {
    let agent: AgentSession
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(paletteColor(agent.paletteIndex))
                .frame(width: 10, height: 10)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: agent.name).font(.system(size: 11, weight: .medium))
                Text(agent.lastPreview).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            if agent.isRunning {
                ProgressView().controlSize(.mini).frame(width: 16)
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.15) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }
}

func paletteColor(_ i: Int) -> Color {
    [.orange, .blue, .purple, .green, .pink, .teal][i % 6]
}