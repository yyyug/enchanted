# Feature Backlog — Enchanted vs Joey MCP Client

Comparison against [benkaiser/joey-mcp-client](https://github.com/benkaiser/joey-mcp-client)
(cloned locally as `joey-mcp-client/`, excluded from git).

Last updated: 2026-09-14

---

## Done in this round

| Item | Where |
|---|---|
| Max tool calls setting (5/10/20/50/100/Unlimited, default 12) | `MCPModels.swift`, `MCPServerSettingsView.swift`, `ConversationStore.runAgenticLoop` |
| MCP settings reordered: servers + add button first, then options | `MCPServerSettingsView.swift` |
| Per-server enable toggle + connection status dot/text in the list | `MCPServerSettingsView.swift`, `MCPServerStore.setEnabled/isConnected` |
| Custom headers editor (`Key: Value`, values may contain colons) | `MCPServerEditorView`, `MCPServerConfig.parseHeaders/headersText` |
| OAuth Client ID / Client Secret manual override | `MCPServerEditorView`, `MCPOAuthClient.registerIfNeeded` |
| Per-server System Prompt (merged into the global prompt) | `MCPServerEditorView`, `MCPServerStore.enabledSystemPrompts`, `ConversationStore.combinedSystemPrompt` |
| Live "Test Connection" button (uses current URL/headers/token) | `MCPServerStore.testConnection`, `MCPServerEditorView` |
| MCP debug screen (state, session, tool schemas, reconnect) | `MCPDebugView.swift` |
| VoiceOver Magic Tap: start dictation / stop + send | `ChatView_iOS.handleMagicTap` |
| Regenerate reply + delete a single message | `MessageListView` context menu, `ConversationStore.regenerateResponse/deleteMessage` |
| Conversation full-text search (title + message content) | `ConversationHistoryListView` |
| Share conversation as Markdown (native share sheet) | `ChatView_iOS` header `ShareLink` |
| Screen stays awake while generating (wakelock) | `ConversationStore.setIdleTimerDisabled` |
| Camera capture for image input | `ChatView_iOS` (`CameraPicker`), `INFOPLIST_KEY_NSCameraUsageDescription` |
| `reconnect` now clears the tool-result cache | `MCPServerStore.reconnect` |
| **Per-conversation MCP selection + per-conversation sessions** | `ConversationMCPServer.swift`, `MCPServerStore.activate`, `ConversationStore.activateMCP/setSelectedServers`, `MCPConversationPickerView.swift` |
| **New-conversation default set (memory)** | `MCPServerStore.defaultServerIDs`, `MCPDefaultServersView` |
| **Tool chip in the chat header** | `ChatView_iOS` |

### Per-conversation MCP — design notes

- Selection lives in the `ConversationMCPServer` join entity (SwiftData), not as an
  array on `ConversationSD`, so a deleted server can be cleaned up precisely.
- MCP **session ids are owned by the conversation**, not the server config
  (`MCPServerConfig.sessionId` was removed). Two conversations using the same server
  therefore get independent sessions and cannot leak state into each other.
- Only the **active conversation's** servers stay connected: `selectConversation`
  deactivates everything, then `activateMCP` connects just that conversation's set.
- A conversation whose selection was never configured inherits the default set
  (Settings → MCP Servers → Tool Execution → New Conversation Default). If the user has
  never configured a default, it falls back to *all enabled servers*, preserving the
  pre-existing behaviour on upgrade.
- Per-server system prompts are now scoped to the conversation's selected servers
  (`MCPServerStore.systemPrompts(for:)`).

---

## Backlog

### B1. Per-conversation MCP server selection + session (item 5) — ✅ DONE
See "Per-conversation MCP — design notes" above.

Remaining follow-up: Joey additionally copies the server set when duplicating a
conversation; Enchanted has no duplicate-conversation feature at all.

---

### B2. True session resumption (item 7) — Deferred
**Current behaviour:** `sessionId` is persisted in the server config and sent as the
`Mcp-Session-Id` header on every request including `initialize`. SSE resumption via
`Last-Event-ID` is implemented (`MCPClient.startServerStream`). Expiry (HTTP 404 or
JSON-RPC `-32002`) triggers `clearSessionId()` + re-initialize.

**Why it is deferred:** the MCP spec requires `initialize` to be the first request on a
new connection, so a client cannot skip it after a restart. What Joey does extra is
*optimistic* resumption — send `tools/list` with the stored session id and fall back to
`initialize` on failure. That is an optimization only; it does not change correctness.

**Plan (if wanted):** in `MCPServerStore.connect`, when `server.sessionId != nil`, try
`client.listTools()` first; on `isSessionExpired`, fall back to the full
`initialize()` path. Guard behind a try/catch so a failed resume is transparent.

---

### B3. Inline media from MCP tool results (item 8) — Deferred
**Joey:** images/audio returned by tools render inline in the transcript, with
full-screen pinch-zoom.

**Enchanted today:** `MCPClient.formatResult` flattens non-text content to
`[image result]` / `[resource result]` strings (`MCPClient.swift`).

**Plan**
1. Extend `MCPToolResult` to carry structured media (`[MCPMediaAttachment]`) instead of
   only `content: String`.
2. Propagate media through `runAgenticLoop` and attach it to the produced assistant
   `MessageSD` (new `attachments: [Data]?` with `.externalStorage`).
3. Render attachments in `ChatMessageView` with a tap-to-zoom overlay.

**Risk:** model + storage change; needs care with the 60 s tool cache key.

---

### B4. Auto-generated conversation titles (item 15) — Deferred
**Plan**
1. Add `titleGenerated: Bool = false` to `ConversationSD`.
2. After the first successful completion, if `!titleGenerated` and the name still equals
   the first prompt, issue a short completion asking for a ≤6-word title.
3. Provider-agnostic option: use the non-streaming `chatCompletion` when the service
   conforms to `ChatCompletionProviding` (OpenAI), otherwise skip. A cross-provider
   implementation needs a small streaming-collect helper, which is why this is deferred.

---

### B5. MCP prompts browsing (`prompts/list`, `prompts/get`) — Deferred
Add `listPrompts()` / `getPrompt(name:arguments:)` to `MCPClient`, plus a picker sheet
that fills arguments and inserts the resulting prompt into the composer.

### B6. MCP resources browsing (`resources/list`, `resources/read`) — Deferred
Add client methods + a browser screen. Note Joey also lacks this UI (only an internal
`readResource`), so we are at parity today.

### B7. iOS on-device tools — Deferred (largest item)
Joey ships ~22 local tools in `local_tool_service.dart`: time, location, contacts
(search/get/create/update/delete), SMS compose, phone call, email compose, device info,
open URL, alarm, calendar (CRUD), reminders (CRUD).

**Plan:** a `LocalToolService` exposing the same `MCPTool` shape so local tools merge
with remote ones in `availableTools`. Frameworks: EventKit (calendar/reminders),
Contacts, CoreLocation, `MFMessageComposeViewController`, `tel:` / `mailto:` URLs,
`UNUserNotificationCenter`. Requires new `INFOPLIST_KEY_NS*UsageDescription` entries.
Gate each tool behind an explicit permission prompt.

### B8. Other parity gaps
| Feature | Notes |
|---|---|
| Token usage + cost per message/conversation | Joey tracks usage/cost via OpenRouter; we would derive from provider responses |
| Model picker modality filters + sorting (price/context/name) | we have search only |
| Audio attachments / inline audio recording | we have images + camera only |
| In-app browser (`SFSafariViewController`) | for links in markdown |
| Mermaid diagram rendering | markdown block extension |
| Data-sharing consent dialog before connecting | Joey shows one before MCP/OpenRouter |
| Conversation import/export JSON | Joey has backup/restore |
| Per-conversation system prompt | Joey has global + per-server; per-conversation not implemented there either |

---

## Deliberately not copied

- **Freemium / entitlement gating** (free = 1 MCP server, local tools Premium). Enchanted
  is not gated.
- **Plaintext secret storage.** Joey stores headers and OAuth client secrets in SQLite
  in the clear. Enchanted already keeps OAuth tokens in the Keychain
  (`MCPTokenStore`); the remaining follow-up is to move *header* secrets there too
  (see B9 below).

### B9. Move secret headers to the Keychain — Follow-up
`MCPServerConfig.headers` is persisted as JSON in `UserDefaults`. Follow the
`MCPTokenStore` pattern (Keychain with UserDefaults fallback) for values whose key looks
sensitive (`Authorization`, `*-key`, `*-token`, `*-secret`), keeping only non-secret
headers in the config blob.
