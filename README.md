# HeyClicky — 逆向还原工程（封闭源码 macOS App → 可读项目）

> 把 `/Applications/HeyClicky.app`（v1.0.51，build 61，2026-09-19 从 App Store 获取）**从二进制逆向还原为一份人能读懂、能照着实现的项目资料**。
> 目标不是拿到一份可以重新编译的源码，而是把「这个产品是怎么做出来的」讲清楚：**每个功能的实现方法 + 实现策略**，以及支撑这些策略的**可验证证据**。
>
> 本仓库没有任何原版代码。所有内容均来自对 Mach-O 二进制静态分析（反射元数据 + 字符串表 + 符号表），逐条标注证据等级：【已确证】（二进制中有直接证据）/【推断】（有强烈旁证但不构成直接证据）。

---

## 目标产物

| 文件 | 内容 | 状态 |
|------|------|------|
| [README.md](README.md) | 本文件：项目总览、架构地图、证据方法论 | ✅ |
| [README/01-光标与覆盖层.md](README/01-光标与覆盖层.md) | 蓝色光标 + 全屏覆盖层 + 坐标换算链 + 屏幕标注 | ✅ |
| [README/02-对话后端.md](README/02-对话后端.md) | 对话后台三明治架构 + SSE 协议 + Supabase 认证 + 计费 | ✅ |
| [README/03-多Agent运行时.md](README/03-多Agent运行时.md) | 多 Agent 运行时（Codex 子进程 + JSON-RPC 协议 + turn-lease 计费 + Computer Use） | ✅ |
| [README/04-悬浮图标与Agent小组件.md](README/04-悬浮图标与Agent小组件.md) | 右上角图标栈（Codex HUD + FloatingAgentChip + Home Space） | ✅ |

四个功能文档各自独立成篇，可单独阅读；本文档负责把四篇串成一张完整的架构图。

---

## 一、这个东西是什么

**【已确证】** `HeyClicky`（bundle id `com.humansongs.clicky`）是一个 **macOS 菜单栏 AI 陪伴应用**（`LSUIElement=true`，无 Dock 图标，常驻菜单栏），是 MIT 开源项目 `farzaa/clicky` 的闭源商业后继。关键元数据：

| 项 | 值 |
|---|---|
| 版本 | 1.0.51 (build 61) |
| 最低系统 | macOS 14.2 |
| 架构 | 通用二进制 x86_64 + arm64（本文所有证据取自 arm64 切片） |
| 模块 | `HeyClicky`（mangling 前缀 `$s9HeyClicky`），入口类型 `leanring_buddyApp`（内部 target 名为 `leanring-buddy`——拼写即原始 Xcode 工程名） |
| 签名 | Apple Development / Team `2UDAY4J48G`，`runtime` 硬化（Library Validation），无 Apple 公证票证（开发者侧分发） |
| 体积 | 主二进制 77.5 MB（文本段 `__TEXT` 30.9 MB，内含大量内嵌 Swift 库） |

它不是普通的"聊天客户端"：它同时是一个**能替你操作电脑的 Agent 宿主**（能画光标、能控制键盘鼠标、能跑 Codex 子进程），一个**多 Agent 任务面板**，一个**语音/听写前端**，和一个**带积分计费的 BFF 客户端**。这四层正好对应四篇文档。

---

## 二、架构总览：六个子系统

从静态证据恢复出的整个 App 结构：

```
┌─────────────────────────────────────────────────────────────────┐
│                        HeyClicky (macOS App)                     │
│                                                                 │
│  ┌──────────┐   ┌───────────┐   ┌───────────────────────────┐  │
│  │ UI 壳     │   │ Agent 运行时│   │  本地能力层                 │  │
│  │ doc-01/04│   │  doc-03    │   │  doc-02                    │  │
│  │          │   │           │   │                            │  │
│  │ 覆盖层    │   │ Codex 子进程│   │ ClaudeAPI SSE 代理          │  │
│  │ (光标/标注)│   │ (每 Agent  │   │ (语音/文字/拍照对话)          │  │
│  │          │   │  一条 JSON- │   │  Supabase 认证              │  │
│  │ CodexHUD │   │  RPC 管道)  │   │  Realtime/Deepgram 直连     │  │
│  │ 图标栈    │   │ turn-lease │   │  Billing 计费               │  │
│  │ HomeSpace│   │  计费闭环   │   │  遥测 (PostHog/Sentry)      │  │
│  │          │   │ cua-driver │   │                            │  │
│  └──────────┘   └───────────┘   └───────────────────────────┘  │
│       │                │                       │               │
│       ▼                ▼                       ▼               │
│  NSPanel 全屏/悬浮  codex CLI (JSON-RPC)   api.heyclicky.com    │
│  (每个屏幕一个)       (隔离 CODEX_HOME)    (worker BFF)         │
│                                              │                 │
│                              ┌───────────────┴─────────┐       │
│                              ▼                         ▼       │
│                        OpenRouter / Anthropic     Supabase     │
│                        (模型上游)                  (身份/配额)   │
└─────────────────────────────────────────────────────────────────┘
```

**一句话架构**：本地 App = **一套玻璃 UI（覆盖层 + HUD）+ 一个 Agent 运行时（Codex 子进程）+ 一个 BFF 客户端（对话/语音/计费）**，云端 = **一个负责路由与收税的 worker（api.heyclicky.com）+ Supabase（身份）+ 模型上游**。

### 各子系统与文档的对应

| 子系统 | 一句话职责 | 关键设计决策（详见对应文档） | 文档 |
|--------|-----------|------------------------------|------|
| **覆盖层系统** | 在屏幕上画出"假的"蓝色光标和标注 | 不是 `NSCursor`，而是**每屏一个全屏透明 `NSPanel`** + SwiftUI 绘制；`ignoresMouseEvents=true` 绝不拦截点击；四步坐标换算链（归一化→像素→屏幕点→SwiftUI 坐标） | 01 |
| **对话后台** | 普通对话（语音/文字/拍照） | **三明治 BFF**：本地 `ClaudeAPI` 只是转发层，模型 key 全在 worker；SSE 用「原生 Anthropic 事件透传 + `clicky_` 前缀自定义事件」双轨；Realtime 语音用 worker 铸造的 ephemeral token 直连 OpenAI | 02 |
| **Agent 运行时** | 多 Agent 并行干活 | **一个 Agent = 一个 `codex` CLI 子进程 + 一条新行分隔 JSON-RPC 管道**（`CodexProcessManager`/`CodexProtocolClient`）；13 个方法 + 15 个通知 + 3 个审批请求；turn-lease 四段计费闭环；本地 `cua-driver` 守护进程 + YAML/REGO 双重策略控权限 | 03 |
| **图标小组件** | 右上角一排 Agent 图标 | 不是多个窗口，而是**每屏一个 `CodexHUDPanel` + `chipStack` 垂直堆叠**多个 `FloatingAgentChip`；鼠标事件用「命中区探针」而非整体忽略；Home Space 主窗口内还有一条 `HomeSpaceIconRail` | 04 |

### 六个子系统的证据规模

恢复自二进制反射元数据（`swiftmeta.py`）与字符串表：

| 证据类别 | 规模 |
|---|---|
| 名义类型（struct/class/enum） | **2212 个**（902 struct / 546 enum / 154 class / 37 multipayload_enum / 573 未分类） |
| 存储属性（字段） | **7500+ 个**（每个带类型与顺序） |
| 类型→源文件映射 | **152 个**（`XxxType → XxxType.swift` 一一名对应，如 `OverlayWindow → OverlayWindow.swift`） |
| cstring 字符串表 | 13239 行（端点、JSON 键名、协议方法名、日志、提示词块全部在此） |
| 反射字符串 | 113530 行（`__swift5_reflstr`，恢复成员名/布局常量的主要来源） |
| 方法名 | `__objc_methname` 154 KB + Swift 符号（`swift_symbols.json`，by_type 587 组） |

---

## 三、四个功能的实现策略（TL;DR）

### 1. 鼠标指针：全屏覆盖层里画出来的"假光标"（doc-01）

**实现策略**：把系统光标这个概念彻底架空。每屏一个全屏透明无边框 `NSPanel`，`ignoresMouseEvents=true` 不拦截任何点击，`level` 极高浮在所有窗口之上、跨 Space 常驻，SwiftUI 在窗口里按模型输出的 `[POINT:x,y:label]` 协议画光标（三角/指针/转圈/停止/波形/气泡/高亮框全都有）。

**最值得偷师的点**：
- 光标能附带**任意 SwiftUI 内容**（逐字气泡、高亮目标框）——系统光标做不到；
- **坐标换算四步链**（模型 0-1000 归一化 → 截图像素 → ÷backingScaleFactor → 翻转 Y 轴）——多屏 + Retina 下最容易翻车的地方，他们用 `:screenN` 后缀选屏；
- **截图排除**：按 bundle id 把覆盖层从自己截屏里藏掉，模型永远看不到自己的光标，避免"模型跟着自己画的光标走"的循环。

### 2. 对话后台：薄客户端 + 收税 worker（doc-02）

**实现策略**：本地 `ClaudeAPI` 是一个只有 4 个存储属性的**代理 struct**，把 `{promptProfile, responseModelSelection, userPrompt, images}` 转成 JSON POST 给 `api.heyclicky.com`；worker 负责注入计费/配额/模型路由后转发 OpenRouter（`/v2/chat`）或 Anthropic（`/chat`）；SSE 流原样回流，客户端逐字渲染。

**最值得偷师的点**：
- **BFF 代理**：模型 key 永远不落地客户端，改模型、上配额、下策略都不需要发版；
- **SSE 双轨协议**：透传 Anthropic 原生事件 + `clicky_` 前缀自定义事件（`clicky_tool_start`/`clicky_widget`/`clicky_error`）；
- **临时密钥**：语音（OpenAI Realtime）和听写（Deepgram）都用「worker 铸造 ephemeral token → 客户端直连上游」，泄露了也只是一次性门票；
- **三件事共用一个身份**：Supabase JWT 同时服务认证、计费、追踪。

### 3. 多 Agent：每个 Agent 是一个 Codex 子进程（doc-03）

**实现策略**：不自己实现 agent 循环，而是**每个 Agent 派生一个官方 `codex` CLI 子进程**，配隔离的 `CODEX_HOME`，用 stdin/stdout 新行分隔 JSON-RPC 通信。三个类型分工：`CodexProcessManager`（进程生命周期）、`CodexProtocolClient`（协议编解码 + 请求 ID 关联）、`CodexLaunchConfiguration`（可执行路径/参数/PATH）。协议是 2025-06-18 版 Codex 协议：13 个客户端方法 + 15 个服务端通知 + 3 个审批请求（命令执行/文件改动/权限）。

**最值得偷师的点**：
- **借力成熟 CLI 而非造轮子**：agent 循环、工具调用、diff 生成全部由 codex 承担，App 只做进程管理与协议透传；
- **turn-lease 四段计费闭环**：`/agent/turn-lease/` → `/continue`（需 `extraEffortApprovalMode`）→ `/status`（轮询）→ `/complete`，`creditsUsed/costUSD/costLimitUSD` 全部由服务器裁决——**积分是云端资产，客户端无权威**；
- **本地权限控制用双重策略**：`cua-driver` 守护进程 + YAML 白名单（cua-driver-policy.yaml）+ REGO 规则（cua-driver-managed-policy.rego，默认 `deny`，显式封禁 cmd+L/标签页切换等危险快捷键）——**宁可默认拒绝，不可默认放行**；
- **系统提示词用注入块装配**：`<user_memory>`/`<attached_skill>`/`<active_skills>`/`<RECENT_COMPANION_CONTEXT>`/`<COMPUTER_USE_REQUEST>`，把记忆、技能、最近上下文、操作授权拼成一段指令。

### 4. 右上角图标：一个面板 + 一个堆叠列（doc-04）

**实现策略**：不是"多个独立窗口"，而是**每屏一个 `CodexHUDPanel`，内部 `chipStack` 垂直堆叠多个 `FloatingAgentChip`**（一个 chip = 一个 Agent 会话），右上角挂折叠手柄与 Home Space 入口。鼠标事件用 `CodexHUDHitRegionProbe` 命中区探针：面板本身不拦截鼠标，只有指针落在某个 chip 的几何区时才切换为可交互——**既能浮在别的窗口之上，又不吃掉整块屏幕的点击**。

**最值得偷师的点**：
- 每屏一个面板按 `displayID` 缓存（`hudsByDisplayID`），多屏天然支持；
- 单个 chip 有完整的折叠→展开两级视图（预览摘要→正文+文件 diff+建议下一步+审批+追问框），35 个恢复成员证明这是一个"可编程小组件"，不是一张静态图标；
- 旧机制（`FloatingSessionButtonManager`，AGENTS.md 时代）已被**整体重构成 Codex HUD**——逆向时能清楚看到架构演进。

---

## 四、证据方法论：无源码，如何恢复出一个"项目"

整个工程没有任何原版代码。恢复手段是**三类静态分析**，全部可复现（脚本在 `_tools/`）：

### 1. Swift 反射元数据（`_tools/swiftmeta.py`）→ `_raw/swift_types.json`

`strip` 删得掉符号表，删不掉 Swift 的**反射元数据**：

- `__swift5_types`：每个名义类型一个描述符（flags/name/fieldDescriptor 相对指针）；
- `__swift5_fieldmd`：每个类型一个 FieldDescriptor，逐字段列出**存储属性名 + 类型（mangled）+ 顺序**；
- 相对指针的偏移基准和字段成员地址解析按官方 `swift/RemoteInspection/Records.h` 实现（FieldDescriptor.MangledTypeName 从 +0、FieldName 从 +8 起算，均以成员自身地址为基准）；
- 类型名 → 源文件名映射（`infer_file_map`）：利用 `#file` 字面量残留在 cstring 中（`"HeyClicky/OverlayWindow.swift"`）与类型名同域相邻配对，仅保留唯一候选的匹配。

**输出**：2212 个类型、7500+ 字段、152 个类型→文件映射。**这是整个工程的主干**——没有它，"还原项目"无从谈起。

### 2. 字符串表（`_tools/extract_sections.py`）→ `_raw/__TEXT-__cstring.strings.txt` 等

字符串是**编译时无法消除的产物**，直接泄露接口面：

- API 端点（`https://api.heyclicky.com`、`/v2/chat`、`/agent/turn-lease/`）；
- JSON 键名（`user_prompt`/`response_model_selection`/`credits_used`/`cost_usd`）；
- 协议方法名/通知名/审批名（`thread/start`、`turn/started`、`item/commandExecution/requestApproval`）；
- 日志格式串（反过来透露解析逻辑，如 `📥 SSE event: %@`）；
- 系统提示词注入块、正则（`^\[POINT:\s*`）、策略文件名、UserDefaults key。

### 3. 符号表与 ObjC 方法名（`_tools/swiftsyms.py` + `__objc_methname`）→ `_raw/swift_symbols.json`

虽然 `strip` 掉了一部分，但**未 strip 的符号 + Objective-C 方法名段**保留了方法/属性/嵌套类型的名字，用于验证反射元数据并恢复成员级方法名（如 `FloatingAgentChip` 的 35 个方法）。

### 证据分级纪律

- **【已确证】**：字符串表/反射元数据/符号表中存在直接证据（给出 cstring 行号）；
- **【推断】**：有强烈旁证但不构成直接证据（如"方法体内部逻辑"——方法体不在任何反射元数据里，只能由日志串、JSON 键、调用顺序推断）。

> 想复现：`_tools/swiftmeta.py` 的调用方式、数据格式与官方布局依据都写在脚本 docstring 里；`_raw/` 下每一份 `.bin` 都有配套 `.strings.txt` 方便人读。

---

## 五、为什么这个产品"有创意"：四个策略级观察

1. **把"系统能力"画出来，而不是调系统 API**。光标、高亮、标注都是 SwiftUI 画在透明 `NSPanel` 上的——这让它们获得了系统光标完全没有的**可编程性**（随文气泡、随目标高亮、跨屏存在）。代价是要自己管坐标换算、截图排除、焦点策略，换来的体验差异完全值回票价。

2. **Agent 运行时是"借壳上市"**。多 Agent 不自己实现推理循环，而是**每一个 Agent = 一个官方 codex CLI 子进程**。这既获得完整 agent 能力（工具、diff、审批），又把复杂度隔离在进程边界外——App 崩溃最多丢一个 Agent，不会连坐。同时把"谁可以用多少积分"的裁决权全部收进云端 worker（turn-lease）。

3. **BFF 是商业模型的物理体现**。模型 key、配额、计费、模型路由、策略（model-policy/tool-policy）全在 `api.heyclicky.com`。客户端是"持票乘客"（Supabase JWT），服务器是"检票员"。这让它能在不发布新版本的情况下改模型、涨价、上限制。

4. **本地权限控制走"默认拒绝 + 双重策略"**。Computer Use 权限不是 App 内一个开关，而是 cua-driver 守护进程 + YAML 白名单 + REGO 策略三层，且 REGO 显式封禁高危快捷键。**把"危险操作"当作安全策略问题而非 UI 问题**——这是做"替你操作电脑"产品的地基。

---

## 六、还原过程中无法确证的部分（诚实清单）

1. **方法体内部逻辑**：反射元数据只有字段和类型，没有方法体。`ClaudeAPI` 如何拼装请求体、`CodexProtocolClient` 如何做行缓冲、覆盖层如何订阅截图事件——这些只能由日志串、JSON 键、调用顺序推断。**要恢复方法体需要真正的反编译器**（如 IDA Pro / Ghidra / Hopper），当前资料不含反汇编。
2. **worker 端实现**：没有任何服务端代码。配额数学、模型路由规则、提示词档案清单均不可证。
3. **部分布局常量**：坐标、尺寸、动画参数大多只能从 reflstr 恢复名字，拿不到数值。
4. **具体模型选择**：`responseModelSelection` 的档位值、Realtime 使用的具体模型版本，只能推断。
5. **Info.plist 中的在线密钥**（PostHog key / Sentry DSN / Supabase anon JWT）：已脱敏，不在任何还原资料中，请勿外传、勿提交。

---

## 七、阅读指南

按你的兴趣挑起点：

- 好奇"**模型怎么在屏幕上画光标**" → 直接读 [01](README/01-光标与覆盖层.md)，重点看第三节坐标换算链（最容易复现的部分）。
- 好奇"**多 Agent 怎么调起来的**" → 读 [03](README/03-多Agent运行时.md)，重点看第二节（进程管理三类型）和第八节（turn-lease 计费闭环）。
- 好奇"**右上角图标是不是多个窗口**" → 读 [04](README/04-悬浮图标与Agent小组件.md)，结论：不是，是一个面板 + 一个堆叠列。
- 好奇"**对话为什么没有本地模型**" → 读 [02](README/02-对话后端.md)，重点看第一节的三明治图。

顺序建议：**01 → 04 → 03 → 02**（从看得见的 UI 到看不见的运行时与后端）。

---

## 附：工程结构

```
HeyClicky-Reversed/
├── README.md                        ← 你在这里
├── README/
│   ├── 01-光标与覆盖层.md
│   ├── 02-对话后端.md
│   ├── 03-多Agent运行时.md
│   └── 04-悬浮图标与Agent小组件.md
├── _raw/                            ← 从 Mach-O 提取的全部原始证据
│   ├── swift_types.json             ← 2212 类型 / 7500+ 字段（主证据）
│   ├── swift_symbols.json           ← 符号表 / 成员名
│   └── __TEXT-__cstring.strings.txt ← 13239 行字符串表（端点/协议/提示词）
│       （另有每段的 .bin + .strings.txt 成对）
└── _tools/                          ← 可复现的提取脚本
    ├── macho.py                     ← Mach-O 解析库
    ├── extract_sections.py          ← 按段提取数据/字符串
    ├── swiftmeta.py                 ← Swift 反射元数据恢复器
    └── swiftsyms.py                 ← Swift 符号恢复器
```
