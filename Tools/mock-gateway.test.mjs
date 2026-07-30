import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { server } from "./mock-gateway.mjs";

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

test("turn endpoint validates audio", async () => {
  const response = await fetch(`${baseURL}/v1/turns`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({})
  });
  assert.equal(response.status, 400);
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
