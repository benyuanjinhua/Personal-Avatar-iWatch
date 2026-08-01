// 检索实现：SQLite FTS5 优先（node:sqlite 内建，零外部依赖），
// CJK 查询或 FTS 无命中时回退子串扫描。不在 MVP 引入云端向量库。

import fs from "node:fs";
import { DatabaseSync } from "node:sqlite";
import {
  ERROR_CODES,
  VaultError,
  resolveVaultRoot,
  validateRelativePath,
  walkVault
} from "./vault.mjs";

const CJK_PATTERN = /[\u3040-\u30ff\u3400-\u9fff\uf900-\ufaff]/;

function escapeLike(term) {
  return term.replaceAll("\\", "\\\\").replaceAll("%", "\\%").replaceAll("_", "\\_");
}

// 用户查询是不可信输入：拆词后逐词加引号，防止 FTS5 查询语法注入。
function buildFtsQuery(terms) {
  return terms.map(term => `"${term.replaceAll('"', '""')}"`).join(" AND ");
}

function makeSnippet(body, terms, maxChars) {
  const lowerBody = body.toLowerCase();
  let hit = -1;
  for (const term of terms) {
    const index = lowerBody.indexOf(term.toLowerCase());
    if (index >= 0 && (hit < 0 || index < hit)) hit = index;
  }
  const start = Math.max(0, (hit < 0 ? 0 : hit) - Math.floor(maxChars / 4));
  const slice = body.slice(start, start + maxChars).replaceAll(/\s+/g, " ").trim();
  return `${start > 0 ? "…" : ""}${slice}${start + maxChars < body.length ? "…" : ""}`;
}

export class VaultIndex {
  constructor(config) {
    this.config = config;
    this.db = new DatabaseSync(":memory:");
    this.db.exec(`
      CREATE TABLE docs (
        note_id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        body TEXT NOT NULL,
        mtime_ms REAL NOT NULL
      );
      CREATE VIRTUAL TABLE docs_fts USING fts5(note_id UNINDEXED, title, body, tokenize='unicode61');
    `);
    this.lastIndexedAt = 0;
    this.indexedCount = 0;
  }

  // 全量重建索引；Vault 不可用时向上抛错，不返回旧的或伪造的结果。
  rebuild() {
    const root = resolveVaultRoot(this.config);
    this.db.exec("DELETE FROM docs; DELETE FROM docs_fts;");
    const insertDoc = this.db.prepare("INSERT INTO docs VALUES (?, ?, ?, ?)");
    const insertFts = this.db.prepare("INSERT INTO docs_fts VALUES (?, ?, ?)");
    let count = 0;
    for (const file of walkVault(root, this.config)) {
      let body;
      try {
        body = fs.readFileSync(file.absPath, "utf8");
      } catch {
        continue;
      }
      const title = file.noteId.split("/").at(-1).replace(/\.[^.]+$/, "");
      insertDoc.run(file.noteId, title, body, file.mtimeMs);
      insertFts.run(file.noteId, title, body);
      count += 1;
    }
    this.indexedCount = count;
    this.lastIndexedAt = Date.now();
    return count;
  }

  ensureFresh() {
    if (Date.now() - this.lastIndexedAt > this.config.limits.indexTtlMs) {
      this.rebuild();
    }
  }

  search(query, limit, pathPrefix) {
    const { limits } = this.config;
    if (typeof query !== "string" || query.trim().length === 0) {
      throw new VaultError(ERROR_CODES.INVALID_ARGUMENT, "query 必须是非空字符串");
    }
    if (query.length > limits.maxQueryChars) {
      throw new VaultError(ERROR_CODES.INVALID_ARGUMENT, "query 超长");
    }
    let effectiveLimit = limits.defaultResults;
    if (limit !== undefined && limit !== null) {
      if (!Number.isInteger(limit) || limit < 1) {
        throw new VaultError(ERROR_CODES.INVALID_ARGUMENT, "limit 必须是正整数");
      }
      effectiveLimit = Math.min(limit, limits.maxResults);
    }
    let prefixFilter = null;
    if (pathPrefix !== undefined && pathPrefix !== null && pathPrefix !== "") {
      validateRelativePath(pathPrefix.replace(/\/$/, ""), limits, { requireExtension: false });
      prefixFilter = pathPrefix.endsWith("/") ? pathPrefix : `${pathPrefix}/`;
    }

    this.ensureFresh();
    const terms = query.split(/[\s,;，；、。！？!?]+/u).filter(Boolean);
    if (terms.length === 0) {
      throw new VaultError(ERROR_CODES.INVALID_ARGUMENT, "query 不含有效检索词");
    }

    let rows = [];
    if (!CJK_PATTERN.test(query)) {
      rows = this.db.prepare(`
        SELECT f.note_id, d.title, d.body, d.mtime_ms
        FROM docs_fts f JOIN docs d ON d.note_id = f.note_id
        WHERE docs_fts MATCH ? ORDER BY bm25(docs_fts) LIMIT ?
      `).all(buildFtsQuery(terms), limits.maxResults * 2);
    }
    if (rows.length === 0) {
      const conditions = terms.map(() =>
        "(d.body LIKE '%' || ? || '%' ESCAPE '\\' OR d.title LIKE '%' || ? || '%' ESCAPE '\\')");
      const params = terms.flatMap(term => [escapeLike(term), escapeLike(term)]);
      rows = this.db.prepare(`
        SELECT d.note_id, d.title, d.body, d.mtime_ms FROM docs d
        WHERE ${conditions.join(" AND ")} ORDER BY d.mtime_ms DESC LIMIT ?
      `).all(...params, limits.maxResults * 2);
    }
    if (prefixFilter) {
      rows = rows.filter(row => row.note_id.startsWith(prefixFilter));
    }

    return rows.slice(0, effectiveLimit).map(row => ({
      note_id: row.note_id,
      title: row.title,
      snippet: makeSnippet(row.body, terms, limits.snippetMaxChars),
      modified_at: new Date(row.mtime_ms).toISOString()
    }));
  }
}
