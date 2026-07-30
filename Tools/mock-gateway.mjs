#!/usr/bin/env node
import http from "node:http";

const port = Number(process.env.WRIST_AGENT_PORT || 8787);
const tasks = new Map();
let turn = 0;

function json(response, status, body) {
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "cache-control": "no-store"
  });
  response.end(JSON.stringify(body));
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

export const server = http.createServer(async (request, response) => {
  const url = new URL(request.url, `http://${request.headers.host}`);

  if (request.method === "GET" && url.pathname === "/health") {
    return json(response, 200, { ok: true, service: "wristagent-mock" });
  }

  if (request.method === "POST" && url.pathname === "/v1/turns") {
    try {
      const body = await readJSON(request);
      if (!body.audio_base64 || body.audio_format !== "m4a") {
        return json(response, 400, { error: "audio_base64 and m4a audio_format are required" });
      }
      turn += 1;
      if (turn % 4 === 1) {
        return json(response, 200, responseBase({
          transcript: "我下午还有什么会？",
          reply: "下午有两场会议。最近一场是两点半的产品评审，四点还有周例会。"
        }));
      }
      if (turn % 4 === 2) {
        const taskID = `task_${Date.now()}`;
        tasks.set(taskID, { polls: 0 });
        return json(response, 200, responseBase({
          transcript: "整理昨天项目群里的决定和待办。",
          reply: "任务已经开始，整理完成后会告诉你。",
          state: "running",
          task_id: taskID
        }));
      }
      if (turn % 4 === 3) {
        return json(response, 200, responseBase({
          transcript: "提醒我下午五点提交周报。",
          reply: "已创建下午五点提交周报的提醒。",
          risk: "reversible",
          undo: {
            id: "undo_demo",
            label: "撤回提醒",
            expires_at: null
          }
        }));
      }
      return json(response, 200, responseBase({
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
      }));
    } catch {
      return json(response, 400, { error: "invalid JSON" });
    }
  }

  const undoMatch = url.pathname.match(/^\/v1\/undo\/([^/]+)$/);
  if (request.method === "POST" && undoMatch) {
    return json(response, 200, responseBase({
      reply: "提醒已撤回。",
      risk: "reversible",
      state: "cancelled"
    }));
  }

  const confirmationMatch = url.pathname.match(/^\/v1\/confirmations\/([^/]+)$/);
  if (request.method === "POST" && confirmationMatch) {
    const body = await readJSON(request).catch(() => null);
    if (!body || typeof body.approved !== "boolean") {
      return json(response, 400, { error: "approved boolean is required" });
    }
    return json(response, 200, responseBase({
      reply: body.approved ? "已经发送到飞船项目群。" : "已取消发送。",
      risk: "confirmation_required",
      state: body.approved ? "completed" : "cancelled"
    }));
  }

  const taskMatch = url.pathname.match(/^\/v1\/tasks\/([^/]+)$/);
  if (request.method === "GET" && taskMatch) {
    const taskID = taskMatch[1];
    const task = tasks.get(taskID);
    if (!task) return json(response, 404, { error: "task not found" });
    task.polls += 1;
    const completed = task.polls >= 2;
    return json(response, 200, {
      task_id: taskID,
      state: completed ? "completed" : "running",
      reply: completed ? "整理完成：三个决定和四个待办。" : null
    });
  }

  const cancelMatch = url.pathname.match(/^\/v1\/tasks\/([^/]+)\/cancel$/);
  if (request.method === "POST" && cancelMatch) {
    const taskID = cancelMatch[1];
    tasks.delete(taskID);
    return json(response, 200, {
      task_id: taskID,
      state: "cancelled",
      reply: "任务已取消。"
    });
  }

  return json(response, 404, { error: "not found" });
});

if (import.meta.url === `file://${process.argv[1]}`) {
  server.listen(port, "0.0.0.0", () => {
    console.log(`WristAgent mock gateway: http://0.0.0.0:${port}`);
  });
}
