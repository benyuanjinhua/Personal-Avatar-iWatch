#!/usr/bin/env node
import http from "node:http";
import { appendFile, mkdir, readFile } from "node:fs/promises";
import { randomUUID } from "node:crypto";
import path from "node:path";
import { fileURLToPath } from "node:url";

const port = Number(process.env.WRIST_AGENT_PORT || 8787);
const tasks = new Map();
let turn = 0;
const webRoot = new URL("../Web/", import.meta.url);
const webAssets = new Map([
  ["/", ["index.html", "text/html; charset=utf-8"]],
  ["/web/index.html", ["index.html", "text/html; charset=utf-8"]],
  ["/web/styles.css", ["styles.css", "text/css; charset=utf-8"]],
  ["/web/app.js", ["app.js", "text/javascript; charset=utf-8"]]
]);

// ---- 链路追踪 ----
// trace_id 由客户端提供（body.trace_id 或 X-Trace-Id 头），缺省时网关生成。
// 每个模块一份 JSONL 日志（logs/trace/<module>.log），每行都带 trace_id，
// grep 一个 trace_id 即可跨模块还原整条链路。
const TRACE_ID_PATTERN = /^[A-Za-z0-9_-]{1,64}$/;
const TRACE_MODULES = ["h5-mock", "main-agent", "codex-cli"];
const TRACE_INDEX_LIMIT = 200;
const traceLogDir = process.env.WRIST_AGENT_TRACE_DIR
  || path.join(path.dirname(fileURLToPath(import.meta.url)), "..", "logs", "trace");
const traceIndex = new Map();
let traceLogDirReady;

function rememberTrace(entry) {
  if (!traceIndex.has(entry.trace_id)) {
    traceIndex.set(entry.trace_id, []);
    if (traceIndex.size > TRACE_INDEX_LIMIT) traceIndex.delete(traceIndex.keys().next().value);
  }
  traceIndex.get(entry.trace_id).push(entry);
}

async function traceLog(module, traceId, event, status = "ok", detail = null) {
  const entry = {
    ts: new Date().toISOString(),
    trace_id: traceId,
    module,
    event,
    status,
    ...(detail ? { detail } : {})
  };
  rememberTrace(entry);
  console.log(`[trace=${traceId}] ${module} ${event} ${status}`);
  try {
    traceLogDirReady ??= mkdir(traceLogDir, { recursive: true });
    await traceLogDirReady;
    await appendFile(path.join(traceLogDir, `${module}.log`), `${JSON.stringify(entry)}\n`);
  } catch (error) {
    console.error(`trace log write failed: ${error.message}`);
  }
}

function resolveTraceId(request, body) {
  const candidate = body?.trace_id ?? request.headers["x-trace-id"];
  if (candidate == null || candidate === "") return { traceId: `trc-${randomUUID().slice(0, 8)}` };
  if (typeof candidate !== "string" || !TRACE_ID_PATTERN.test(candidate)) {
    return { error: "trace_id must match [A-Za-z0-9_-]{1,64}" };
  }
  return { traceId: candidate };
}

function json(response, status, body, traceId = null) {
  const payload = traceId && body && typeof body === "object" ? { trace_id: traceId, ...body } : body;
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store",
    ...(traceId ? { "x-trace-id": traceId } : {})
  });
  response.end(JSON.stringify(payload));
}

function readJSON(request) {
  return new Promise((resolve, reject) => {
    let body = "";
    request.setEncoding("utf8");
    request.on("data", chunk => {
      body += chunk;
      if (body.length > 10_000_000) request.destroy();
    });
    request.on("end", () => {
      try {
        resolve(body ? JSON.parse(body) : {});
      } catch (error) {
        reject(error);
      }
    });
    request.on("error", reject);
  });
}

function responseBase(overrides) {
  return {
    turn_id: `turn_${Date.now()}`,
    transcript: "",
    reply: "",
    risk: "read_only",
    state: "completed",
    task_id: null,
    confirmation: null,
    undo: null,
    tts_audio_base64: null,
    ...overrides
  };
}

function scriptedTurn() {
  turn += 1;
  if (turn % 4 === 1) {
    return {
      intent: "read_only_query",
      payload: responseBase({
        transcript: "我下午还有什么会？",
        reply: "下午有两场会议。最近一场是两点半的产品评审，四点还有周例会。"
      })
    };
  }
  if (turn % 4 === 2) {
    const taskID = `task_${Date.now()}`;
    tasks.set(taskID, { polls: 0 });
    return {
      intent: "long_task",
      payload: responseBase({
        transcript: "整理昨天项目群里的决定和待办。",
        reply: "任务已经开始，整理完成后会告诉你。",
        state: "running",
        task_id: taskID
      })
    };
  }
  if (turn % 4 === 3) {
    return {
      intent: "reversible_action",
      payload: responseBase({
        transcript: "提醒我下午五点提交周报。",
        reply: "已创建下午五点提交周报的提醒。",
        risk: "reversible",
        undo: {
          id: "undo_demo",
          label: "撤回提醒",
          expires_at: null
        }
      })
    };
  }
  return {
    intent: "high_risk_send",
    payload: responseBase({
      transcript: "把刚才的总结发给项目群。",
      reply: "发送前请确认。",
      risk: "confirmation_required",
      state: "running",
      confirmation: {
        id: "confirm_demo",
        title: "发送项目总结",
        target: "飞船项目群 · 18 人",
        impact: "群成员会立即收到 3 个决定和 4 个待办。",
        actionLabel: "确认发送"
      }
    })
  };
}

function customTurn(text) {
  const reply = text.includes("天气")
    ? "杭州今天多云转晴，24 到 31 度，傍晚山区有阵雨（mock 数据）。"
    : `已完成「${text}」的处理（mock 回复）。`;
  return { intent: "custom_query", payload: responseBase({ transcript: text, reply }) };
}

export const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);

  if (request.method === "GET" && webAssets.has(url.pathname)) {
    const [file, contentType] = webAssets.get(url.pathname);
    const body = await readFile(new URL(file, webRoot));
    response.writeHead(200, {
      "content-type": contentType,
      "content-length": body.byteLength,
      "cache-control": "no-store"
    });
    return response.end(body);
  }

  if (request.method === "GET" && url.pathname === "/health") {
    return json(response, 200, { ok: true, service: "wristagent-mock" });
  }

  const traceQueryMatch = url.pathname.match(/^\/v1\/trace\/([^/]+)$/);
  if (request.method === "GET" && traceQueryMatch) {
    const traceId = decodeURIComponent(traceQueryMatch[1]);
    if (!TRACE_ID_PATTERN.test(traceId)) {
      return json(response, 400, { error: "trace_id must match [A-Za-z0-9_-]{1,64}" });
    }
    const entries = traceIndex.get(traceId) || [];
    const modules = Object.fromEntries(TRACE_MODULES.map(module => {
      const moduleEntries = entries.filter(entry => entry.module === module);
      return [module, {
        events: moduleEntries.length,
        ok: moduleEntries.length > 0 && moduleEntries.every(entry => entry.status === "ok")
      }];
    }));
    return json(response, entries.length ? 200 : 404, {
      trace_id: traceId,
      found: entries.length > 0,
      modules,
      entries
    });
  }

  if (request.method === "POST" && url.pathname === "/v1/turns") {
    try {
      const body = await readJSON(request);
      const resolved = resolveTraceId(request, body);
      if (resolved.error) return json(response, 400, { error: resolved.error });
      const { traceId } = resolved;
      const text = typeof body.text === "string" && body.text.trim() ? body.text.trim() : null;
      if (!text && (!body.audio_base64 || body.audio_format !== "m4a")) {
        await traceLog("h5-mock", traceId, "turn_rejected", "error", {
          reason: "text or audio_base64(m4a) is required"
        });
        return json(response, 400, { error: "text or audio_base64 with m4a audio_format is required" }, traceId);
      }
      await traceLog("h5-mock", traceId, "turn_received", "ok", { input: text ?? "<m4a audio>" });
      const { intent, payload } = text ? customTurn(text) : scriptedTurn();
      await traceLog("main-agent", traceId, "intent_parsed", "ok", { transcript: payload.transcript, intent });
      await traceLog("main-agent", traceId, "dispatch_codex_cli", "ok", { intent });
      await traceLog("codex-cli", traceId, "execution_started", "ok", { intent });
      await traceLog("codex-cli", traceId, "execution_completed", "ok", { result_state: payload.state, risk: payload.risk });
      await traceLog("main-agent", traceId, "reply_composed", "ok", { reply: payload.reply });
      return json(response, 200, payload, traceId);
    } catch {
      return json(response, 400, { error: "invalid JSON" });
    }
  }

  const undoMatch = url.pathname.match(/^\/v1\/undo\/([^/]+)$/);
  if (request.method === "POST" && undoMatch) {
    const resolved = resolveTraceId(request);
    if (resolved.error) return json(response, 400, { error: resolved.error });
    const { traceId } = resolved;
    await traceLog("main-agent", traceId, "undo_received", "ok", { undo_id: undoMatch[1] });
    await traceLog("codex-cli", traceId, "undo_executed", "ok", { undo_id: undoMatch[1] });
    return json(response, 200, responseBase({
      reply: "提醒已撤回。",
      risk: "reversible",
      state: "cancelled"
    }), traceId);
  }

  const confirmationMatch = url.pathname.match(/^\/v1\/confirmations\/([^/]+)$/);
  if (request.method === "POST" && confirmationMatch) {
    const body = await readJSON(request).catch(() => null);
    const resolved = resolveTraceId(request, body);
    if (resolved.error) return json(response, 400, { error: resolved.error });
    const { traceId } = resolved;
    if (!body || typeof body.approved !== "boolean") {
      await traceLog("main-agent", traceId, "confirmation_rejected", "error", { reason: "approved boolean is required" });
      return json(response, 400, { error: "approved boolean is required" }, traceId);
    }
    await traceLog("main-agent", traceId, "confirmation_received", "ok", {
      confirmation_id: confirmationMatch[1],
      approved: body.approved
    });
    await traceLog("codex-cli", traceId, body.approved ? "send_executed" : "send_cancelled", "ok", {
      confirmation_id: confirmationMatch[1]
    });
    return json(response, 200, responseBase({
      reply: body.approved ? "已经发送到飞船项目群。" : "已取消发送。",
      risk: "confirmation_required",
      state: body.approved ? "completed" : "cancelled"
    }), traceId);
  }

  const taskMatch = url.pathname.match(/^\/v1\/tasks\/([^/]+)$/);
  if (request.method === "GET" && taskMatch) {
    const resolved = resolveTraceId(request);
    if (resolved.error) return json(response, 400, { error: resolved.error });
    const { traceId } = resolved;
    const taskID = taskMatch[1];
    const task = tasks.get(taskID);
    if (!task) {
      await traceLog("main-agent", traceId, "task_polled", "error", { task_id: taskID, reason: "task not found" });
      return json(response, 404, { error: "task not found" }, traceId);
    }
    task.polls += 1;
    const completed = task.polls >= 2;
    await traceLog("main-agent", traceId, "task_polled", "ok", {
      task_id: taskID,
      state: completed ? "completed" : "running"
    });
    if (completed) await traceLog("codex-cli", traceId, "task_finished", "ok", { task_id: taskID });
    return json(response, 200, {
      task_id: taskID,
      state: completed ? "completed" : "running",
      reply: completed ? "整理完成：三个决定和四个待办。" : null
    }, traceId);
  }

  const cancelMatch = url.pathname.match(/^\/v1\/tasks\/([^/]+)\/cancel$/);
  if (request.method === "POST" && cancelMatch) {
    const resolved = resolveTraceId(request);
    if (resolved.error) return json(response, 400, { error: resolved.error });
    const { traceId } = resolved;
    const taskID = cancelMatch[1];
    tasks.delete(taskID);
    await traceLog("main-agent", traceId, "task_cancelled", "ok", { task_id: taskID });
    return json(response, 200, {
      task_id: taskID,
      state: "cancelled",
      reply: "任务已取消。"
    }, traceId);
  }

  return json(response, 404, { error: "not found" });
});

if (import.meta.url === `file://${process.argv[1]}`) {
  server.listen(port, "0.0.0.0", () => {
    console.log(`WristAgent Web iWatch mock: http://localhost:${port}`);
    console.log(`Trace logs: ${traceLogDir}/{${TRACE_MODULES.join(",")}}.log`);
  });
}
