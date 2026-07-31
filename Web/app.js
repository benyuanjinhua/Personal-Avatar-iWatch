const cases = [
  ["只读查询", "返回日程且无需确认"],
  ["长任务", "轮询直到任务完成"],
  ["可撤回操作", "创建提醒后执行撤回"],
  ["高风险确认", "确认后才发送消息"]
];

const $ = id => document.getElementById(id);
let current = 0;
let busy = false;
let response = null;
const passed = new Set();

function log(message) {
  const time = new Date().toLocaleTimeString("zh-CN", { hour12: false });
  $("events").textContent = `[${time}] ${message}\n${$("events").textContent === "等待开始…" ? "" : $("events").textContent}`;
}

function renderCases() {
  $("cases").innerHTML = cases.map(([name, detail], index) => `
    <div class="case ${index === current ? "active" : ""} ${passed.has(index) ? "passed" : ""}">
      <span>${passed.has(index) ? "✓" : String(index + 1).padStart(2, "0")}</span>
      <span><strong>${name}</strong><br>${detail}</span>
      <span class="state">${passed.has(index) ? "PASS" : index === current ? "READY" : "WAIT"}</span>
    </div>`).join("");
  $("test-summary").textContent = `${passed.size} / 4`;
}

function setWatch(phase, title, detail) {
  $("orb").className = `orb ${phase}`;
  $("orb-symbol").textContent = phase === "running" ? "•••" : phase === "confirmation" ? "!" : phase === "completed" ? "✓" : "✦";
  $("title").textContent = title;
  $("detail").textContent = detail;
}

async function request(path, options) {
  const result = await fetch(path, options);
  if (!result.ok) throw new Error(`${result.status} ${await result.text()}`);
  return result.json();
}

async function submitTurn() {
  setWatch("running", "正在听懂", "模拟语音已发送到 Gateway");
  $("main-action").textContent = "处理中…";
  response = await request("/v1/turns", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ audio_base64: "d2ViLWl3YXRjaC1tb2Nr", audio_format: "m4a", concise_reply: true })
  });
  $("transcript").hidden = false;
  $("transcript").textContent = `“${response.transcript}”`;
  log(`POST /v1/turns → ${response.state} / ${response.risk}`);

  if (response.state === "running" && response.task_id) return pollTask(response.task_id);
  if (response.confirmation) return showConfirmation(response.confirmation);
  if (response.undo) return showUndo(response.undo);
  complete(response.reply);
}

async function pollTask(taskID) {
  setWatch("running", "任务已开始", response.reply);
  for (let attempt = 1; attempt <= 5; attempt += 1) {
    await new Promise(resolve => setTimeout(resolve, 350));
    const task = await request(`/v1/tasks/${encodeURIComponent(taskID)}`);
    log(`GET /v1/tasks/${taskID} #${attempt} → ${task.state}`);
    if (task.state !== "running") return complete(task.reply || "任务已完成");
  }
  throw new Error("长任务轮询超时");
}

function showUndo(undo) {
  setWatch("completed", "完成了", response.reply);
  $("main-action").textContent = "下一项";
  $("secondary-action").hidden = false;
  $("secondary-action").textContent = undo.label;
  $("secondary-action").onclick = () => act(() => answerUndo(undo.id));
}

async function answerUndo(id) {
  const undone = await request(`/v1/undo/${encodeURIComponent(id)}`, { method: "POST" });
  log(`POST /v1/undo/${id} → ${undone.state}`);
  complete(undone.reply);
}

function showConfirmation(confirmation) {
  setWatch("confirmation", confirmation.title, "这是高风险操作，请检查影响范围");
  $("confirmation").hidden = false;
  $("confirmation-target").textContent = confirmation.target;
  $("confirmation-impact").textContent = confirmation.impact;
  $("main-action").textContent = confirmation.actionLabel;
  $("secondary-action").hidden = false;
  $("secondary-action").textContent = "取消操作";
  $("main-action").onclick = () => act(() => answerConfirmation(confirmation.id, true));
  $("secondary-action").onclick = () => act(() => answerConfirmation(confirmation.id, false));
}

async function answerConfirmation(id, approved) {
  const result = await request(`/v1/confirmations/${encodeURIComponent(id)}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ confirmation_id: id, approved })
  });
  log(`POST /v1/confirmations/${id} approved=${approved} → ${result.state}`);
  complete(result.reply);
}

function complete(reply) {
  setWatch("completed", "完成了", reply);
  passed.add(current);
  current = Math.min(current + 1, cases.length - 1);
  response = null;
  $("confirmation").hidden = true;
  $("secondary-action").hidden = true;
  $("main-action").textContent = passed.size === cases.length ? "全部通过" : "下一项";
  $("main-action").onclick = () => act(submitTurn);
  renderCases();
}

async function act(action) {
  if (busy || passed.size === cases.length) return;
  busy = true;
  try { await action(); }
  catch (error) {
    setWatch("confirmation", "没有完成", error.message);
    $("connection").textContent = "● ERROR";
    log(`ERROR ${error.message}`);
  } finally { busy = false; }
}

async function runScenario() {
  reset();
  for (let index = 0; index < cases.length; index += 1) {
    await act(submitTurn);
    if (response?.undo) await act(() => answerUndo(response.undo.id));
    if (response?.confirmation) await act(() => answerConfirmation(response.confirmation.id, true));
  }
}

function reset() {
  current = 0; busy = false; response = null; passed.clear();
  setWatch("", "有什么要我做？", "点一下，然后直接说");
  $("connection").textContent = "● ONLINE";
  $("transcript").hidden = true;
  $("confirmation").hidden = true;
  $("secondary-action").hidden = true;
  $("main-action").textContent = "开始说话";
  $("main-action").onclick = () => act(submitTurn);
  $("events").textContent = "等待开始…";
  renderCases();
}

$("run-scenario").onclick = runScenario;
$("reset").onclick = reset;
reset();
