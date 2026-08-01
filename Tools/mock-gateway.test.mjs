import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { after, before, test } from "node:test";
import { server } from "./mock-gateway.mjs";

const traceLogDir = process.env.WRIST_AGENT_TRACE_DIR
  || path.join(import.meta.dirname, "..", "logs", "trace");
let baseURL;

before(async () => {
  await new Promise(resolve => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  baseURL = `http://127.0.0.1:${address.port}`;
});

after(async () => {
  await new Promise(resolve => server.close(resolve));
});

test("health endpoint responds", async () => {
  const response = await fetch(`${baseURL}/health`);
  assert.equal(response.status, 200);
  assert.equal((await response.json()).ok, true);
});

test("web iWatch mock and its assets are served", async () => {
  const page = await fetch(`${baseURL}/`);
  assert.equal(page.status, 200);
  assert.match(page.headers.get("content-type"), /^text\/html/);
  assert.match(await page.text(), /运行全链路 testcase/);

  const app = await fetch(`${baseURL}/web/app.js`);
  assert.equal(app.status, 200);
  assert.match(await app.text(), /\/v1\/confirmations\//);
});

test("turn endpoint validates audio", async () => {
  const response = await fetch(`${baseURL}/v1/turns`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({})
  });
  assert.equal(response.status, 400);
});

test("caller trace id propagates across every module", async () => {
  const traceId = `223lkjl${Date.now()}`;
  const response = await fetch(`${baseURL}/v1/turns`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "杭州天气咋样", trace_id: traceId })
  });
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("x-trace-id"), traceId);
  const body = await response.json();
  assert.equal(body.trace_id, traceId);
  assert.equal(body.transcript, "杭州天气咋样");
  assert.match(body.reply, /天气|多云/);

  const lookup = await fetch(`${baseURL}/v1/trace/${traceId}`).then(result => result.json());
  assert.equal(lookup.found, true);
  for (const module of ["h5-mock", "main-agent", "codex-cli"]) {
    assert.equal(lookup.modules[module].ok, true, `${module} should log the trace`);
    assert.ok(lookup.modules[module].events > 0);
    const logFile = await readFile(path.join(traceLogDir, `${module}.log`), "utf8");
    assert.ok(logFile.includes(traceId), `${module}.log should contain the trace id`);
  }
});

test("missing trace id is generated, malformed trace id is rejected", async () => {
  const generated = await fetch(`${baseURL}/v1/turns`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "现在几点" })
  }).then(result => result.json());
  assert.match(generated.trace_id, /^trc-[0-9a-f-]{8}$/);

  const rejected = await fetch(`${baseURL}/v1/turns`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ text: "现在几点", trace_id: "bad id!" })
  });
  assert.equal(rejected.status, 400);
});

test("turn, long task and confirmation flows are executable", async () => {
  const submit = () => fetch(`${baseURL}/v1/turns`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ audio_base64: "ZGVtbw==", audio_format: "m4a" })
  }).then(response => response.json());

  const first = await submit();
  assert.equal(first.state, "completed");

  const second = await submit();
  assert.equal(second.state, "running");
  assert.ok(second.task_id);

  await fetch(`${baseURL}/v1/tasks/${second.task_id}`);
  const completedTask = await fetch(`${baseURL}/v1/tasks/${second.task_id}`).then(response => response.json());
  assert.equal(completedTask.state, "completed");

  const third = await submit();
  assert.equal(third.risk, "reversible");
  assert.ok(third.undo.id);

  const undone = await fetch(`${baseURL}/v1/undo/${third.undo.id}`, {
    method: "POST"
  }).then(response => response.json());
  assert.equal(undone.state, "cancelled");

  const fourth = await submit();
  assert.equal(fourth.risk, "confirmation_required");
  assert.ok(fourth.confirmation.id);

  const confirmed = await fetch(`${baseURL}/v1/confirmations/${fourth.confirmation.id}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ confirmation_id: fourth.confirmation.id, approved: true })
  }).then(response => response.json());
  assert.equal(confirmed.state, "completed");
});
