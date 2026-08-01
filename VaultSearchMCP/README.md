# VaultSearchMCP — Obsidian Vault 只读 MCP Search

实现 TECHNICAL_DESIGN_V2_1 §4.4 / §9(`VaultSearchMCP`) / §10 P2（ESS-31）：
把本地 Obsidian Vault 以标准 MCP（stdio, JSON-RPC 2.0）暴露为两个**只读**工具，
仅在 Codex 判断需要本地知识时调用，不是默认上下文。

## 工具

| 工具 | 参数 | 说明 |
|---|---|---|
| `vault_search` | `query`（必填）、`limit?`、`path_prefix?` | 全文检索，返回 `note_id`、标题、截断摘要 |
| `vault_read` | `note_id`（必填）、`offset?` | 读取单篇笔记，超过字符上限截断并返回 `next_offset` |

设计文档中的写法是 `vault.search` / `vault.read`。正式注册名使用下划线，
因为部分模型侧工具协议对工具名有 `^[a-zA-Z0-9_-]+$` 约束；`tools/call`
同时受理点号别名，语义完全一致。

## 安全边界（MVP）

- **单根只读**：根目录固定为一个 Vault（`VAULT_MCP_ROOT` 或 `config.json` 的 `vaultRoot`）；`note_id` 是 Vault 内相对路径，真实绝对路径不返回前端。
- **路径防穿越**：拒绝绝对路径、`..`、反斜杠、控制字符；对解析结果做 `realpath` 包含性检查，阻断符号链接逃逸。
- **文件准入**：默认只允许 `.md`（`allowedExtensions` 可显式追加附件类型）；`.obsidian/`、`.trash/`、一切点号开头的隐藏目录/文件一律忽略；`.pem`/`.key`/`id_rsa*` 等密钥类文件被硬编码拒绝，配置不可放宽。
- **结果限额**：条数上限（默认 10，硬上限 20）、摘要与正文字符上限；超限截断并显式标记 `truncated`。
- **不可信标记**：所有返回内容包裹 `<<<UNTRUSTED_VAULT_CONTENT …>>>` 标记，提示模型侧按参考资料而非指令处理。
- **审计**：JSONL 记录查询词、命中 `note_id`、读取范围、错误码；**不**写入笔记正文。
- **明确降级**：Vault 未配置/不可达时返回 `VAULT_UNAVAILABLE` 错误并提示降级，绝不伪造搜索结果。

## 检索实现

Node ≥ 22.5 内建 `node:sqlite`（含 FTS5），零外部依赖：

1. 启动后按需全量建立内存 FTS5 索引，TTL（默认 30s）过期自动重建。
2. 英文查询走 FTS5 `MATCH`（查询词逐词加引号，防语法注入），按 bm25 排序。
3. 中文等 CJK 查询（unicode61 分词器不分汉字）与 FTS 零命中时回退子串扫描。
4. 笔记规模或语义需求出现后再考虑本地向量索引；MVP 不引入云端向量库。

## 运行

```bash
export VAULT_MCP_ROOT=/path/to/YourVault
export VAULT_MCP_AUDIT=/path/to/logs/vault-audit.jsonl   # 省略则关闭审计
node VaultSearchMCP/server.mjs
```

或复制 `config.example.json` 为 `config.json`（已 gitignore）。环境变量优先于配置文件。

Codex CLI 挂载示例（`~/.codex/config.toml`）：

```toml
[mcp_servers.vault]
command = "node"
args = ["/path/to/Personal-Avatar-iWatch/VaultSearchMCP/server.mjs"]
env = { VAULT_MCP_ROOT = "/path/to/YourVault" }
```

## 测试

```bash
cd VaultSearchMCP && npm test   # 等价于 node --test vault-search.test.mjs
```

覆盖：中英文检索命中、`path_prefix` 与 limit 上限、隐藏目录/回收站/密钥文件不进索引、
路径穿越与符号链接逃逸拒绝、读取截断与 `offset` 续读、Vault 不可用显式降级、
审计日志不含正文、MCP stdio 端到端（initialize → tools/list → tools/call）。
