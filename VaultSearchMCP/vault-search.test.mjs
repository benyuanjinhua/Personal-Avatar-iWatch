import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import { fileURLToPath } from "node:url";

import { captureIdea, DEFAULT_LIMITS } from "./vault.mjs";
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

test("明确记录意图创建 Jackson/Idea Markdown，包含时间、原文与上下文", () => {
  const now = new Date("2026-08-22T12:34:56.789Z");
  const result = captureIdea(config, {
    intent: "record_idea",
    content: "做一个能把散步时灵感自动串起来的视图",
    context: "讨论个人知识管理时想到"
  }, {
    now: () => now,
    randomUUID: () => "11111111-1111-4111-8111-111111111111"
  });

  assert.equal(result.note_id,
    "Jackson/Idea/20260822-123456.789Z-11111111-1111-4111-8111-111111111111.md");
  const body = fs.readFileSync(path.join(vaultRoot, result.note_id), "utf8");
  assert.ok(body.includes("记录时间：2026-08-22T12:34:56.789Z"));
  assert.ok(body.includes("## 原始想法\n\n做一个能把散步时灵感自动串起来的视图"));
  assert.ok(body.includes("## 上下文\n\n讨论个人知识管理时想到"));
});

test("连续记录使用唯一文件名，不互相覆盖", () => {
  const first = handlers.toolCaptureIdea({ intent: "record_idea", content: "第一条" });
  const second = handlers.toolCaptureIdea({ intent: "record_idea", content: "第二条" });
  assert.notEqual(first.note_id, second.note_id);
  assert.ok(fs.readFileSync(path.join(vaultRoot, first.note_id), "utf8").includes("第一条"));
  assert.ok(fs.readFileSync(path.join(vaultRoot, second.note_id), "utf8").includes("第二条"));
});

test("空内容、非法参数和非记录意图均不创建文件", () => {
  const ideaDir = path.join(vaultRoot, "Jackson", "Idea");
  const before = fs.readdirSync(ideaDir).length;
  assert.throws(() => handlers.toolCaptureIdea({ intent: "record_idea", content: "  " }),
    error => error.code === "INVALID_ARGUMENT");
  assert.throws(() => handlers.toolCaptureIdea({ intent: "ordinary_chat", content: "今天天气如何" }),
    error => error.code === "INVALID_ARGUMENT");
  assert.throws(() => handlers.toolCaptureIdea({ intent: "record_idea", content: "想法", context: 42 }),
    error => error.code === "INVALID_ARGUMENT");
  assert.equal(fs.readdirSync(ideaDir).length, before);
});

test("写入失败返回可判定错误，MCP 响应不得假报成功", () => {
  const brokenRoot = fs.mkdtempSync(path.join(os.tmpdir(), "vault-mcp-write-fail-"));
  try {
    fs.writeFileSync(path.join(brokenRoot, "Jackson"), "阻挡目录创建");
    const broken = createHandlers({ ...makeConfig(), vaultRoot: brokenRoot });
    assert.throws(() => broken.toolCaptureIdea({ intent: "record_idea", content: "不会写入" }),
      error => error.code === "WRITE_FAILED");
    const response = handleRequest(broken, {
      jsonrpc: "2.0", id: 8, method: "tools/call",
      params: { name: "vault_capture_idea", arguments: { intent: "record_idea", content: "不会写入" } }
    });
    assert.equal(response.result.isError, true);
    assert.ok(response.result.content[0].text.includes("[WRITE_FAILED]"));
    assert.ok(!response.result.content[0].text.includes("note_id"));
  } finally {
    fs.rmSync(brokenRoot, { recursive: true, force: true });
  }
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
    assert.deepEqual(list.result.tools.map(t => t.name), ["vault_search", "vault_read", "vault_capture_idea"]);
    const captureTool = list.result.tools.find(tool => tool.name === "vault_capture_idea");
    for (const voiceCommand of ["我有个方法", "帮我记录", "我有个观点"]) {
      assert.ok(captureTool.description.includes(voiceCommand), `工具契约必须覆盖语音指令：${voiceCommand}`);
    }

    send({ jsonrpc: "2.0", id: 3, method: "tools/call", params: { name: "vault.search", arguments: { query: "WatchConnectivity" } } });
    const call = await waitFor(3);
    const text = call.result.content[0].text;
    assert.ok(text.includes("UNTRUSTED_VAULT_CONTENT"), "内容必须带不可信标记");
    assert.ok(text.includes("Projects/watch-plan.md"));
  } finally {
    child.kill();
  }
});
