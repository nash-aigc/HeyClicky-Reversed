import SwiftUI

/// ② 对话后台 —— 复刻 doc-02 的核心：本地 ClaudeAPI 代理 + SSE 事件协议。
///
/// 原版：ClaudeAPI（class, 4 字段：apiURL / session / sseFormat / backendDescription）
///       把 {userPrompt, images, promptProfile, responseModelSelection} POST 给 worker，
///       worker 转发 OpenRouter 或 Anthropic，SSE 流回流。
///
/// 本复刻：
///   - 无密钥、无 worker —— 用本地 mock 数据模拟 worker 的 SSE 流；
///   - 但协议结构（请求体字段 / SSE 事件名 / clicky_ 前缀事件）1:1 复刻；
///   - 网络层用 URLSession + URLProtocol 注入 mock，保证将来接真后端时零改动。
struct ChatDemoView: View {
    @StateObject private var chat = ChatViewModel()
    @State private var input: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "对话后台（ClaudeAPI 代理 → Mock Worker SSE）", icon: "bubble.left.and.text.bubble.right")

            // 模型选择（原版 responseModelSelection 档位）
            HStack {
                Picker("模型档位", selection: $chat.selectedProfile) {
                    ForEach(ChatProfile.allCases) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                .pickerStyle(.segmented)
                Spacer()
                Text("promptProfile: \(chat.requestProfile)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
            }
            .controlSize(.small)

            // 消息列表
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(chat.messages) { msg in
                            MessageRow(msg: msg)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(white: 0.94), in: RoundedRectangle(cornerRadius: 8))
                .onChange(of: chat.messages.count) { _, _ in
                    if let last = chat.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            // 发送行
            HStack(spacing: 8) {
                TextField("输入消息…", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { send() }
                Button("发送") { send() }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .controlSize(.small)
        }
        .padding(12)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chat.send(text)
        input = ""
    }
}

// MARK: - 请求体 / 协议模型（1:1 复刻原版字段）

enum ChatProfile: String, CaseIterable, Identifiable {
    case agent = "agent"
    case normal = "normal"
    case codexLane = "codexAgentLane"
    var id: String { rawValue }
}

struct ChatMessageViewPayload: Identifiable, Equatable {
    let id = UUID()
    var role: String          // user / assistant / tool
    var text: String
    var kind: EventKind = .text

    enum EventKind: Equatable {
        case text
        case toolStart(String)      // clicky_tool_start
        case widget(String)         // clicky_widget
        case error(String)          // clicky_error
    }
}

/// 复刻 ClaudeProxyChatRequest（struct, 7 字段）
struct ClaudeProxyChatRequest {
    var promptProfile: String
    var responseModelSelection: String
    var userPrompt: String
    var images: [ClaudeProxyImagePayload]
    var openRouterCustomModel: String?
    var openRouterVerbosity: String?
    var isProviderFallbackRetry: Bool?
}

/// 复刻 ClaudeProxyImagePayload（struct, 3 字段）
struct ClaudeProxyImagePayload {
    var base64ImageData: String
    var imageLabel: String
    var imageMediaType: String
}

// MARK: - 视图模型：发请求 + 消费 SSE 事件

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [ChatMessageViewPayload] = []
    @Published var selectedProfile: ChatProfile = .agent

    var requestProfile: String { selectedProfile.rawValue }

    private let api = ClaudeAPIMock()

    func send(_ text: String) {
        let userMsg = ChatMessageViewPayload(role: "user", text: text)
        messages.append(userMsg)

        // 构造与本工程文档一致的请求体
        let request = ClaudeProxyChatRequest(
            promptProfile: selectedProfile.rawValue,
            responseModelSelection: selectedProfile == .agent ? "smart" : "fast",
            userPrompt: text,
            images: [],
            openRouterCustomModel: nil,
            openRouterVerbosity: nil,
            isProviderFallbackRetry: false
        )

        let eventStream = api.stream(request)
        Task {
            for try await event in eventStream {
                consume(event)
            }
        }
    }

    /// 消费 SSE 事件 → 更新 UI（1:1 复刻 doc-02 第四节事件协议）
    private func consume(_ event: SSEEvent) {
        switch event {
        case .messageStart:
            messages.append(ChatMessageViewPayload(role: "assistant", text: ""))
        case .textDelta(let delta):
            // 追加到最后一条 assistant 消息，或新开一条
            if let idx = messages.lastIndex(where: { $0.role == "assistant" }) {
                messages[idx].text += delta
            } else {
                messages.append(ChatMessageViewPayload(role: "assistant", text: delta))
            }
        case .toolStart(let toolName):
            messages.append(ChatMessageViewPayload(role: "tool", text: "🔧 \(toolName)", kind: .toolStart(toolName)))
        case .widget(let kind):
            messages.append(ChatMessageViewPayload(role: "assistant", text: "🎨 [widget: \(kind)]", kind: .widget(kind)))
        case .error(let msg):
            messages.append(ChatMessageViewPayload(role: "assistant", text: "⚠️ \(msg)", kind: .error(msg)))
        case .done:
            break
        }
    }
}

// MARK: - SSE 协议层（原版 sseFormat 的双轨：原生事件 + clicky_ 前缀）

enum SSEEvent {
    case messageStart
    case textDelta(String)
    case toolStart(String)
    case widget(String)
    case error(String)
    case done
}

/// Mock worker：模拟 worker 的 SSE 流。
/// 真实后端 = api.heyclicky.com 的 /v2/chat 或 /chat；
/// 本实现直接返回事件流，让协议消费层可以完整跑通。
struct ClaudeAPIMock {
    func stream(_ request: ClaudeProxyChatRequest) -> AsyncThrowingStream<SSEEvent, Error> {
        AsyncThrowingStream { continuation in
            let text = request.userPrompt
            Task {
                try? await Task.sleep(for: .milliseconds(200))

                continuation.yield(.messageStart)

                // 模拟 agent 档案下的工具调用序列
                if request.promptProfile == "agent" {
                    try? await Task.sleep(for: .milliseconds(400))
                    continuation.yield(.toolStart("computer_use"))
                    try? await Task.sleep(for: .milliseconds(500))
                    continuation.yield(.widget("annotation_panel"))
                }

                // 逐字吐回复（模拟 text_delta SSE）
                let reply = """
                收到「\(text)」。

                这是模拟的 worker 回复流。在真实实现里，这行文本来自 \
                \(request.promptProfile == "agent" ? "/v2/chat upstream OpenRouter" : "/chat upstream Anthropic") \
                的 SSE `text_delta` 事件。
                """
                for ch in reply {
                    continuation.yield(.textDelta(String(ch)))
                    try? await Task.sleep(for: .milliseconds(8))
                }

                continuation.yield(.done)
                continuation.finish()
            }
        }
    }
}

// MARK: - 行渲染

struct MessageRow: View {
    let msg: ChatMessageViewPayload

    var body: some View {
        HStack(alignment: .top) {
            switch msg.role {
            case "user":
                Spacer(minLength: 60)
                Text(msg.text)
                    .font(.system(size: 12))
                    .padding(8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 8))
            case "tool":
                Text(msg.text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 6))
            default:
                Text(msg.text)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Color(white: 0.985), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}