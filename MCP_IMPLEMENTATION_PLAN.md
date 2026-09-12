# Enchanted — MCP 工具呼叫與 Agentic Loop 實作計劃

## 目標

在 Enchanted（原生 SwiftUI，iOS + macOS）加入 MCP（Model Context Protocol）支援，讓使用者可以：

1. 連接遠端 MCP 伺服器，使用伺服器提供的工具（tools）
2. LLM 自動判斷何時需要呼叫工具，執行後再將結果回傳 LLM 繼續推理（agentic loop）
3. 支援進階 MCP 功能：OAuth 授權、sampling、elicitation、session resumption、progress notifications

---

## 架構概覽

### 核心組件

```
┌─────────────────────────────────────────────────────────┐
│  UI (ChatView)                                          │
│    - 顯示對話、工具執行進度、工具結果                     │
│    - 工具執行中止按鈕                                    │
└────────────┬────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────┐
│  AgentLoop                                              │
│    - 接收 LLM 回應，檢查 tool_calls                      │
│    - 呼叫 MCPToolManager 執行工具                        │
│    - 將工具結果 append 到 messages，再呼叫 LLM            │
│    - 有 max iterations 安全上限                          │
└────────────┬────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────┐
│  MCPToolManager                                         │
│    - 管理多個 MCP 伺服器連接                              │
│    - tools/list → 產生 OpenAI tools schema               │
│    - tools/call → 路由到正確的伺服器                      │
│    - 暫存 tool schemas 供 LLM 請求使用                   │
└────────────┬────────────────────────────────────────────┘
             │
┌────────────▼────────────────────────────────────────────┐
│  MCPClient (per server)                                 │
│    - JSON-RPC 2.0 over Streamable HTTP (SSE)            │
│    - 管理 session ID、連線重試                           │
│    - 處理 sampling / elicitation / progress 回呼         │
│    - OAuth 授權流程                                      │
└─────────────────────────────────────────────────────────┘
```

### 技術選型

| 項目 | 選擇 | 理由 |
|------|------|------|
| MCP 傳輸 | Streamable HTTP（JSON-RPC 2.0 over SSE） | MCP 規範標準；比 stdio 更適合 iOS |
| HTTP 客戶端 | URLSession（原生） | 已有 Foundation，不需額外依賴 |
| SSE 解析 | 自寫 AsyncSequence parser | 單向 streaming，Swift Concurrency 天然適合 |
| 模型資料 | SwiftData | Enchanted 現有架構 |
| 工具結果快取 | 記憶體 dictionary（有時限） | 避免重複執行相同工具 |

---

## 核心實作：工具呼叫與 Agentic Loop

### Step 1 — MCP 伺服器連接

使用者在「設定」頁新增 MCP 伺服器（URL、名稱、可選 custom headers）。

連接流程：

```
App 啟動 / 使用者新增伺服器
  → POST {mcp_url}  with initialize request (JSON-RPC)
  → 收到 capabilities + server info
  → POST {mcp_url}  with tools/list
  → 儲存工具清單（name, description, inputSchema）
```

需要儲存的伺服器資料模型：

```swift
struct MCPServerConfig: Identifiable {
    let id: UUID
    var name: String
    var url: String          // Streamable HTTP endpoint
    var authToken: String?   // Bearer token / OAuth token
    var isEnabled: Bool
    var headers: [String: String]
}

struct MCPTool {
    let serverId: UUID
    let name: String
    let description: String
    let inputSchema: [String: Any] // JSON Schema
}
```

### Step 2 — 工具 Schema 轉換

MCP 的 `inputSchema` 本身就是 JSON Schema，轉成 OpenAI `tools` 格式：

```swift
extension MCPTool {
    func toOpenAITool() -> [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": name,
                "description": description,
                "parameters": inputSchema  // 已是 JSON Schema，直接用
            ]
        ]
    }
}
```

每次呼叫 LLM 時，把所有啟用的伺服器的工具合併，作為 `tools` 參數傳入。

### Step 3 — Agentic Loop（核心迴圈）

```
while (maxIterations not exceeded) {

    1. 呼叫 LLM，帶上完整 messages + tools schema
    2. 解析回應：
       - 如果有 tool_calls → 執行工具（Step 4）
       - 如果只有 content → 回傳給使用者，迴圈結束
    3. 將 LLM 的回應（含 tool_calls）append 到 messages
    4. 將每個工具的執行結果（tool result）append 到 messages
    5. 回到步驟 1

}
```

實作細節：

```swift
@MainActor
class AgentLoop: ObservableObject {
    @Published var isRunning = false
    @Published var currentToolCall: String?   // 正在執行的工具名，顯示進度
    @Published var iterationCount = 0

    private let maxIterations = 15  // 安全上限，防止無限迴圈
    private var cancellable: Task<Void, Never>?

    func run(messages: [ChatMessage],
             tools: [[String: Any]],
             llmService: LLMService) async -> [ChatMessage] {

        isRunning = true
        defer { isRunning = false }

        var workingMessages = messages
        iterationCount = 0

        while iterationCount < maxIterations {
            iterationCount += 1

            let response = await llmService.chatCompletion(
                messages: workingMessages,
                tools: tools
            )

            guard let choice = response.choices.first else { break }

            // 沒有 tool_calls → 任務完成
            let toolCalls = choice.message.toolCalls
            if toolCalls.isEmpty {
                workingMessages.append(choice.message)
                break
            }

            // 有 tool_calls → 執行工具
            workingMessages.append(choice.message)

            for toolCall in toolCalls {
                currentToolCall = toolCall.function.name
                let result = await mcpToolManager.execute(
                    name: toolCall.function.name,
                    arguments: toolCall.function.arguments
                )

                workingMessages.append(ChatMessage(
                    role: .tool,
                    toolCallId: toolCall.id,
                    content: result.content
                ))
            }

            currentToolCall = nil
        }

        return workingMessages
    }

    func cancel() {
        cancellable?.cancel()
        isRunning = false
    }
}
```

安全考量：

- `maxIterations` 限制防止 LLM 無限呼叫工具
- 使用者可隨時按「停止」中斷迴圈
- 工具執行逾時（30 秒預設）
- 每次工具呼叫紀錄於對話歷史，可追溯

### Step 4 — 工具執行與結果回傳

```swift
class MCPToolManager: ObservableObject {
    private var clients: [UUID: MCPClient] = [:]   // serverId -> client

    func execute(name: String, arguments: String) async -> ToolResult {
        // 1. 找到擁有該工具的伺服器
        guard let (serverId, tool) = findTool(name: name) else {
            return ToolResult(content: "Tool '\(name)' not found")
        }

        // 2. 路由到正確的 MCPClient
        guard let client = clients[serverId] else {
            return ToolResult(content: "Server not connected")
        }

        // 3. 執行 tools/call
        do {
            let result = try await client.callTool(
                name: name,
                arguments: arguments
            )
            return result
        } catch {
            return ToolResult(content: "Tool error: \(error.localizedDescription)")
        }
    }
}
```

---

## 進階 MCP 功能

### OAuth 授權

**是什麼：** MCP 伺服器可以要求使用者授權（類似第三方登入）。MCP 規範基於 RFC 9728（OAuth 2.0 for HTTP）和 RFC 8414（OAuth Server Metadata Discovery）。

**用戶會看到：** 當連接需要授權的 MCP 伺服器時：
1. App 內顯示「需要授權」說明頁面，解釋該伺服器要求哪些權限
2. 點「授權」→ 跳轉內建瀏覽器（SFSafariViewController / ASWebAuthenticationSession）
3. 在瀏覽器完成授權 → 自動回跳 App → 顯示「已連接」

**實作：**
- 解析伺服器回應的 401 → 讀取 `WWW-Authenticate` header 找 metadata URL
- 發現 OAuth endpoints（authorization_endpoint, token_endpoint）
- 執行 Authorization Code + PKCE 流程（SFSafariViewController）
- 儲存 access_token + refresh_token 於 Keychain
- token 過期前自動 refresh

**工作量：** 約 1–2 週（OAuth 2.0 流程 + PKCE + token management + UI）

---

### Sampling

**是什麼：** MCP 伺服器可以「反過來要求 LLM 執行一次推論」。伺服器發送 `sampling/createMessage` 請求，客戶端詢問使用者是否同意，同意後把 LLM 回應傳回伺服器。

**用戶會看到：**
1. 伺服器執行某個工具時需要額外的 AI 輔助
2. App 彈出提示：「伺服器 XXX 請求使用 AI 生成一段文字，是否允許？」
3. 使用者點「允許」→ 後台自動用當前模型推論 → 結果傳回伺服器
4. 使用者點「拒絕」→ 伺服器收到拒絕錯誤

**實作：**
- `MCPClient` 收到 `sampling/createMessage` JSON-RPC 請求
- 顯示彈窗（確認 + 預覽伺服器要求的 prompt 摘要）
- 用當前模型（或指定模型）執行推論
- 將回應傳回伺服器（最多 limitedTokens 限制以防濫用）
- 設定中可設定 sampling 預設行為（自動允許 / 每次詢問 / 禁止）

**工作量：** 約 1 週（JSON-RPC handler + UI 彈窗 + 安全限制）

---

### Elicitation

**是什麼：** 伺服器可以向使用者請求輸入資料（例如表單、選擇、確認）。伺服器提供 JSON Schema 定義欄位，客戶端動態產生表單 UI。

**用戶會看到：**
1. 伺服器執行工具過程中需要使用者補充資訊
2. App 彈出一個動態表單（根據 JSON Schema 自動產生輸入欄位）
3. 使用者填寫後送出 → 資料傳回伺服器繼續執行

範例：伺服器要你填寫一個搜尋表單（關鍵字、語言、最大結果數）或確認一筆操作（「確定要刪除 10 筆資料嗎？」）。

**實作：**
- 解析 `elicitation/create` 請求中的 JSON Schema
- 動態產生 SwiftUI 表單：`TextField`（字串）、`Toggle`（布林）、`Picker`（enum）、`Stepper`（數字）
- 複雜 schema 用 ScrollView 包裝
- 使用者提交或取消
- 伺服器可能給出 URL 類型的 elicitation（例如 OAuth 授權頁面）→ 用 SFSafariViewController 打開

**工作量：** 約 1.5–2 週（JSON Schema → SwiftUI 動態表單 + 驗證 + URL elicitation 處理）

---

### Session Resumption

**是什麼：** MCP Streamable HTTP 連接有 session ID。App 重啟後，可以用先前的 session ID 恢復連接，而不必重新執行 `initialize` + `tools/list`。伺服器可能要求客戶端重播某些 JSON-RPC 請求。

**用戶會看到：** 使用者幾乎感受不到差異，但：

1. 關閉 App 重開後，MCP 伺服器狀態「瞬間恢復」，不需要等待重新初始化
2. 工具清單立即可用
3. 如果伺服器要求重播，App 會自動處理（背景進行）

**實作：**
- 伺服器在 `initialize` 回應中提供 `Mcp-Session-Id` header
- 客戶端將 session ID + 相關 metadata 存入 UserDefaults 或 SwiftData
- 重啟時帶 `Mcp-Session-Id` header 發送請求
- 如果伺服器回 404（session 過期）→ 自動 fallback 到完整初始化流程
- 設定中顯示「已連接的 MCP 伺服器」及 session 狀態

**工作量：** 約 0.5–1 週（session ID 持久化 + fallback 邏輯）

---

### Progress Notifications

**是什麼：** 長時間執行的工具或 sampling 請求，伺服器可以發送進度更新（`notifications/progress`），讓客戶端顯示即時進度。

**用戶會看到：**
1. 執行耗時工具時（例如爬取資料庫、大量搜尋）：
   - 工具名下方出現進度指示器（「正在搜尋... 45%」）
   - 可選擇取消
2. sampling 請求排隊中：顯示「等待 AI 推論...」
3. 多個工具連續執行時：顯示目前在執行第幾個（「2/5 工具執行中」）

**實作：**
- `MCPClient` 監聽 JSON-RPC 通知：`method: "notifications/progress"`
- 解析 `progressToken`、`progress`（整數）、`total`（可選整數）、`message`（可選字串）
- 更新 `AgentLoop` 的 published properties → UI 自動更新
- 支援取消（發送取消通知給伺服器）

**工作量：** 約 0.5 週（JSON-RPC 通知監聽 + UI 進度指示器）

---

## 里程碑計劃

### Phase 1 — 基礎 MCP 連接與工具呼叫（2–3 週）

- [ ] MCPClient：JSON-RPC 2.0 over Streamable HTTP
- [ ] `initialize` + `tools/list` 請求
- [ ] 工具 schema 轉 OpenAI tools 格式
- [ ] `tools/call` 執行
- [ ] 設定頁：新增 / 編輯 / 刪除 / 啟停 MCP 伺服器
- [ ] 基本 Agentic Loop（LLM → tool_calls → 執行 → LLM）
- [ ] max iterations 限制 + 取消按鈕

### Phase 2 — 進階 MCP 功能（2–3 週）

- [ ] Session resumption（session ID 持久化）
- [ ] Progress notifications（即時進度顯示）
- [ ] Sampling（伺服器反向請求 LLM）
- [ ] Elicitation（動態表單 UI）
- [ ] OAuth 授權流程（PKCE + token 持久化）

### Phase 3 — 完善與穩定（1 週）

- [ ] 錯誤處理與重試機制
- [ ] 工具執行逾時
- [ ] 多伺服器並行支援穩定化
- [ ] 工具結果快取
- [ ] 本地化（zh-TW, zh-Hans, en）

---

## 風險與注意事項

| 風險 | 緩解 |
|------|------|
| MCP 伺服器 API 不穩定（規範仍在演進） | 關注明確版本，做好版本判斷 |
| 無限迴圈（LLM 反覆呼叫工具） | maxIterations 硬上限 + 使用者可隨時中斷 |
| 安全：伺服器惡意要求 sampling | sampling 一律需使用者確認 |
| 效能：大量 tool_calls 拖慢回應 | 工具並行執行 + 結果快取 |
| Swift MCP client 庫不存在 | 自寫核心（JSON-RPC + HTTP），不依賴第三方 |
| OAuth 流程在 iOS SafariWebView 的 edge cases | 使用 ASWebAuthenticationSession（系統級） |

---

## 與 joey-mcp-client 的比較

| 項目 | joey (Flutter/Dart) | Enchanted (Swift) |
|------|---------------------|-------------------|
| MCP client | `mcp_dart`（已有） | 自寫 Swift |
| 工具 schema | Dify MCP 格式 | OpenAI tools 格式（相同 JSON Schema） |
| agentic loop | 自動執行至完成 | 自動執行至完成 |
| OAuth | 已實作 | 需自寫（ASWebAuthenticationSession） |
| 跨平台 | iOS/Android/macOS/Win/Linux | iOS/macOS（原生品質） |
| LLM provider | OpenRouter（單一） | 任何 OpenAI-compatible（多 provider） |

參考價值：joey 的 MCP 連線管理、工具 schema 轉換、agentic loop 結構設計可照搬思路。
