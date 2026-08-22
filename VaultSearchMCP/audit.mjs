// 审计日志：记录查询词、命中文档 ID、读取范围与错误码。
// 红线：不把笔记正文复制进日志（设计 §4.4 / §8）。

import fs from "node:fs";
import path from "node:path";

export class AuditLog {
  constructor(logPath) {
    this.logPath = logPath ?? null;
  }

  write(entry) {
    if (!this.logPath) return;
    const record = { ts: new Date().toISOString(), ...entry };
    try {
      fs.mkdirSync(path.dirname(this.logPath), { recursive: true });
      fs.appendFileSync(this.logPath, `${JSON.stringify(record)}\n`, "utf8");
    } catch (error) {
      // 审计失败不阻断请求，但要在 stderr 留痕，不能静默。
      process.stderr.write(`[vault-mcp] audit write failed: ${error.message}\n`);
    }
  }

  search({ query, hitNoteIds, errorCode }) {
    this.write({ tool: "vault_search", query, hits: hitNoteIds ?? [], error: errorCode ?? null });
  }

  read({ noteId, range, truncated, errorCode }) {
    this.write({
      tool: "vault_read",
      note_id: noteId,
      range: range ?? null,
      truncated: truncated ?? false,
      error: errorCode ?? null
    });
  }

  captureIdea({ noteId, contentChars, errorCode }) {
    this.write({
      tool: "vault_capture_idea",
      note_id: noteId ?? null,
      content_chars: contentChars ?? null,
      error: errorCode ?? null
    });
  }
}
