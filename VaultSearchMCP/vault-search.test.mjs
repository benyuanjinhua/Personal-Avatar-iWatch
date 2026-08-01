import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { DEFAULT_LIMITS } from "./vault.mjs";
import { createHandlers, handleRequest } from "./server.mjs";

const here = path.dirname(fileURLToPath(import.meta.url));
let vaultRoot;
let outsideDir;
let auditPath;
let handlers;
let config;

function makeConfig(overrides = {}) {
  return {
    vaultRoot,
    auditLogPath: auditPath,
    allowedExtensions: [".md"],
    limits: { ...DEFAULT_LIMITS, indexTtlMs: 3600000, readMaxChars: 200, ...overrides }
  };
}

before(() => {
  vaultRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vault-mcp-test-"));
  outsideDir = fs.mkdtempSync(path.join(os.tmpdir(), "vault-mcp-outside-"));
  auditPath = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "vault-mcp-audit-")), "audit.jsonl");

  fs.mkdirSync(path.join(vaultRoot, "Projects"), { recursive: true });
  fs.mkdirSync(path.join(vaultRoot, ".obsidian"), { recursive: true });
  fs.mkdirSync(path.join(vaultRoot, ".trash"), { recursive: true });

  fs.writeFileSync(path.join(vaultRoot, "Projects", "watch-plan.md"),
    "# Watch 计划\nWristAgent 手表项目使用 WatchConnectivity 传输音频。秘密口令是 tangerine-42。");
  fs.writeFileSync(path.join(vaultRoot, "diary.md"),
    "今天研究了 Obsidian Vault 的全文检索方案，决定用 SQLite FTS5。");
  fs.writeFileSync(path.join(vaultRoot, "long-note.md"), `开头${"甲".repeat(500)}结尾`);
  fs.writeFileSync(path.join(vaultRoot, ".obsidian", "app.json"), '{"secretSetting":true}');
  fs.writeFileSync(path.join(vaultRoot, ".trash", "deleted.md"), "被删除的笔记 tangerine");
  fs.writeFileSync(path.join(vaultRoot, "server.pem"), "FAKE-PRIVATE-KEY tangerine");
  fs.writeFileSync(path.join(vaultRoot, "id_rsa.md"), "假装是笔记的密钥文件");
  fs.writeFileSync(path.join(outsideDir, "secret-outside.md"), "Vault 外的机密 tangerine");
  fs.symlinkSync(path.join(outsideDir, "secret-outside.md"), path.join(vaultRoot, "escape-link.md"));

  config = makeConfig();
  handlers = createHandlers(config);
});

after(() => {
  fs.rmSync(vaultRoot, { recursive: true, force: true });
  fs.rmSync(outsideDir, { recursive: true, force: true });
  fs.rmSync(path.dirname(auditPath), { recursive: true, force: true });
});

test("英文与中文检索都能命中指定笔记", () => {
  const english = handlers.toolSearch({ query: "WatchConnectivity" });
  assert.equal(english.results.length, 1);
  assert.equal(english.results[0].note_id, "Projects/watch-plan.md");
  assert.ok(english.results[0].snippet.includes("WatchConnectivity"));

  const chinese = handlers.toolSearch({ query: "全文检索" });
  assert.equal(chinese.results.length, 1);
  assert.equal(chinese.results[0].note_id, "diary.md");
});

test("path_prefix 生效且 limit 受硬上限约束", () => {
  const scoped = handlers.toolSearch({ query: "tangerine", path_prefix: "Projects/" });
  assert.deepEqual(scoped.results.map(r => r.note_id), ["Projects/watch-plan.md"]);

  assert.throws(() => handlers.toolSearch({ query: "tangerine", limit: 0 }), /正整数/);
  const capped = handlers.toolSearch({ query: "tangerine", limit: 999999 });
  assert.ok(capped.results.length <= DEFAULT_LIMITS.maxResults);
});

test("隐藏目录、回收站与密钥文件不进索引", () => {
  const hits = handlers.toolSearch({ query: "tangerine" });
  const ids = hits.results.map(r => r.note_id);
  assert.ok(!ids.some(id => id.startsWith(".obsidian") || id.startsWith(".trash")));
  assert.ok(!ids.includes("server.pem"));
  assert.ok(!ids.includes("escape-link.md"));
});

test("路径穿越与越权读取全部被拒绝", () => {
  const denied = [
    "../secret-outside.md",
    "Projects/../../secret-outside.md",
    "/etc/hosts",
    ".obsidian/app.json",
    ".trash/deleted.md",
    "server.pem",
    "id_rsa.md",
    "escape-link.md"
  ];
  for (const noteId of denied) {
    assert.throws(() => handlers.toolRead({ note_id: noteId }),
      error => ["PATH_DENIED", "NOT_FOUND"].includes(error.code),
      `应拒绝 ${noteId}`);
  }
});

test("vault_read 返回内容并按字符上限截断，支持 offset 续读", () => {
  const first = handlers.toolRead({ note_id: "long-note.md" });
  assert.equal(first.truncated, true);
  assert.equal(first.content.length, 200);
  assert.ok(first.content.startsWith("开头"));

  const rest = handlers.toolRead({ note_id: "long-note.md", offset: first.next_offset });
  assert.equal(rest.range[0], 200);

  const whole = handlers.toolRead({ note_id: "diary.md" });
  assert.equal(whole.truncated, false);
  assert.ok(whole.content.includes("SQLite FTS5"));
});

test("Vault 不可用时明确报错，不伪造结果", () => {
  const broken = createHandlers({ ...makeConfig(), vaultRoot: path.join(outsideDir, "does-not-exist") });
  assert.throws(() => broken.toolSearch({ query: "anything" }), /VAULT_UNAVAILABLE|不可访问/);
  assert.throws(() => broken.toolRead({ note_id: "diary.md" }), error => error.code === "VAULT_UNAVAILABLE");

  const response = handleRequest(broken, {
    jsonrpc: "2.0", id: 7, method: "tools/call",
    params: { name: "vault_search", arguments: { query: "anything" } }
  });
  assert.equal(response.result.isError, true);
  assert.ok(response.result.content[0].text.includes("VAULT_UNAVAILABLE"));
});

test("审计日志记录查询词/命中 ID/读取范围，但不含笔记正文", () => {
  handlers.toolSearch({ query: "WatchConnectivity" });
  handlers.toolRead({ note_id: "Projects/watch-plan.md" });
  const lines = fs.readFileSync(auditPath, "utf8").trim().split("\n").map(line => JSON.parse(line));

  const searchEntry = lines.findLast(entry => entry.tool === "vault_search" && !entry.error);
  assert.equal(searchEntry.query, "WatchConnectivity");
  assert.deepEqual(searchEntry.hits, ["Projects/watch-plan.md"]);

  const readEntry = lines.findLast(entry => entry.tool === "vault_read" && !entry.error);
  assert.equal(readEntry.note_id, "Projects/watch-plan.md");
  assert.ok(Array.isArray(readEntry.range));

  const raw = fs.readFileSync(auditPath, "utf8");
  assert.ok(!raw.includes("tangerine-42"), "审计日志不得包含笔记正文");
});

test("MCP stdio 端到端：initialize / tools/list / tools/call", async () => {
  const child = spawn(process.execPath, [path.join(here, "server.mjs")], {
    env: { ...process.env, VAULT_MCP_ROOT: vaultRoot, VAULT_MCP_AUDIT: auditPath },
    stdio: ["pipe", "pipe", "pipe"]
  });
  const responses = [];
  let buffer = "";
  child.stdout.on("data", chunk => {
    buffer += chunk;
    let idx;
    while ((idx = buffer.indexOf("\n")) >= 0) {
      const line = buffer.slice(0, idx).trim();
      buffer = buffer.slice(idx + 1);
      if (line) responses.push(JSON.parse(line));
    }
  });
  const send = message => child.stdin.write(`${JSON.stringify(message)}\n`);
  const waitFor = id => new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error(`timeout waiting response ${id}`)), 10000);
    const poll = setInterval(() => {
      const found = responses.find(r => r.id === id);
      if (found) { clearTimeout(timer); clearInterval(poll); resolve(found); }
    }, 20);
  });

  try {
    send({ jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } } });
    const init = await waitFor(1);
    assert.equal(init.result.serverInfo.name, "vault-search-mcp");
    send({ jsonrpc: "2.0", method: "notifications/initialized" });

    send({ jsonrpc: "2.0", id: 2, method: "tools/list" });
    const list = await waitFor(2);
    assert.deepEqual(list.result.tools.map(t => t.name), ["vault_search", "vault_read"]);

    send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "vault.search", arguments: { query: "WatchConnectivity" } } });
    const call = await waitFor(3);
    const text = call.result.content[0].text;
    assert.ok(text.includes("UNTRUSTED_VAULT_CONTENT"), "内容必须带不可信标记");
    assert.ok(text.includes("Projects/watch-plan.md"));
  } finally {
    child.kill();
  }
});
