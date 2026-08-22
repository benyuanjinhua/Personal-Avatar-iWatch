// Vault 访问层：单根目录、路径安全校验与文件准入策略。
// 设计依据 TECHNICAL_DESIGN_V2_1 §4.4：MVP 只读；只允许 .md 与显式附件类型；
// 忽略 .obsidian/、回收站、密钥文件、隐藏目录；真实路径不返回前端。

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { fileURLToPath } from "node:url";

export class VaultError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "VaultError";
    this.code = code;
  }
}

export const ERROR_CODES = Object.freeze({
  VAULT_UNAVAILABLE: "VAULT_UNAVAILABLE",
  INVALID_NOTE_ID: "INVALID_NOTE_ID",
  PATH_DENIED: "PATH_DENIED",
  NOT_FOUND: "NOT_FOUND",
  INVALID_ARGUMENT: "INVALID_ARGUMENT",
  WRITE_FAILED: "WRITE_FAILED"
});

// 硬编码密钥类文件拒绝名单，配置不可放宽。
const DENIED_EXTENSIONS = new Set([
  ".pem", ".key", ".p12", ".pfx", ".der", ".kdbx", ".keychain", ".jks", ".gpg", ".asc"
]);
const DENIED_BASENAME_PREFIXES = ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"];

export const DEFAULT_LIMITS = Object.freeze({
  maxResults: 20,
  defaultResults: 10,
  snippetMaxChars: 300,
  readMaxChars: 20000,
  maxQueryChars: 256,
  maxNoteIdChars: 512,
  maxIdeaChars: 10000,
  maxIdeaContextChars: 2000,
  maxIndexFileBytes: 2 * 1024 * 1024,
  maxIndexFiles: 20000,
  indexTtlMs: 30000
});

export const IDEA_DIRECTORY = "Jackson/Idea";

function compactTimestamp(date) {
  return date.toISOString().replace(/[-:]/g, "").replace("T", "-").replace("Z", "Z");
}

// Idea 写入是唯一获准的 Vault 写操作：目标目录固定、文件排他创建，调用方不能传路径。
export function captureIdea(config, args, dependencies = {}) {
  if (args?.intent !== "record_idea") {
    throw new VaultError(ERROR_CODES.INVALID_ARGUMENT,
      "仅接受用户明确记录灵感时的 intent=record_idea；普通对话不得写入");
  }
  if (typeof args.content !== "string" || args.content.trim() === "") {
    throw new VaultError(ERROR_CODES.INVALID_ARGUMENT, "灵感正文不能为空");
  }
  const content = args.content.trim();
  if (content.length > config.limits.maxIdeaChars) {
    throw new VaultError(ERROR_CODES.INVALID_ARGUMENT, "灵感正文超长");
  }
  if (args.context !== undefined && typeof args.context !== "string") {
    throw new VaultError(ERROR_CODES.INVALID_ARGUMENT, "context 必须是字符串");
  }
  const context = args.context?.trim() ?? "";
  if (context.length > config.limits.maxIdeaContextChars) {
    throw new VaultError(ERROR_CODES.INVALID_ARGUMENT, "context 超长");
  }

  const root = resolveVaultRoot(config);
  const ideaDirectory = path.join(root, ...IDEA_DIRECTORY.split("/"));
  try {
    fs.mkdirSync(ideaDirectory, { recursive: true, mode: 0o700 });
    const realDirectory = fs.realpathSync(ideaDirectory);
    if (realDirectory !== root && !realDirectory.startsWith(root + path.sep)) {
      throw new VaultError(ERROR_CODES.PATH_DENIED, "Idea 目录指向 Vault 外部");
    }

    const now = dependencies.now?.() ?? new Date();
    const id = dependencies.randomUUID?.() ?? crypto.randomUUID();
    const fileName = `${compactTimestamp(now)}-${id}.md`;
    const noteId = `${IDEA_DIRECTORY}/${fileName}`;
    const markdown = [
      "# Idea",
      "",
      `- 记录时间：${now.toISOString()}`,
      `- ID：${id}`,
      "",
      "## 原始想法",
      "",
      content,
      ...(context ? ["", "## 上下文", "", context] : []),
      ""
    ].join("\n");
    fs.writeFileSync(path.join(realDirectory, fileName), markdown, { encoding: "utf8", flag: "wx", mode: 0o600 });
    return { note_id: noteId, recorded_at: now.toISOString(), id };
  } catch (error) {
    if (error instanceof VaultError) throw error;
    throw new VaultError(ERROR_CODES.WRITE_FAILED, `灵感写入失败: ${error.message}`);
  }
}

export function loadConfig(env = process.env) {
  const configPath = env.VAULT_MCP_CONFIG
    ?? path.join(path.dirname(fileURLToPath(import.meta.url)), "config.json");
  let fileConfig = {};
  if (fs.existsSync(configPath)) {
    fileConfig = JSON.parse(fs.readFileSync(configPath, "utf8"));
  }
  const config = {
    vaultRoot: env.VAULT_MCP_ROOT ?? fileConfig.vaultRoot ?? null,
    auditLogPath: env.VAULT_MCP_AUDIT ?? fileConfig.auditLogPath ?? null,
    allowedExtensions: fileConfig.allowedExtensions ?? [".md"],
    limits: { ...DEFAULT_LIMITS, ...(fileConfig.limits ?? {}) }
  };
  config.allowedExtensions = config.allowedExtensions
    .map(ext => ext.toLowerCase())
    .filter(ext => !DENIED_EXTENSIONS.has(ext));
  return config;
}

// 返回 Vault 根目录的 realpath；不可用时抛 VAULT_UNAVAILABLE，绝不静默降级。
export function resolveVaultRoot(config) {
  if (!config.vaultRoot) {
    throw new VaultError(ERROR_CODES.VAULT_UNAVAILABLE,
      "Vault 未配置（需要 VAULT_MCP_ROOT 或 config.json 的 vaultRoot）");
  }
  let real;
  try {
    real = fs.realpathSync(config.vaultRoot);
  } catch {
    throw new VaultError(ERROR_CODES.VAULT_UNAVAILABLE,
      "Vault 根目录不可访问，任务应降级处理，本工具不返回伪造结果");
  }
  if (!fs.statSync(real).isDirectory()) {
    throw new VaultError(ERROR_CODES.VAULT_UNAVAILABLE, "Vault 根路径不是目录");
  }
  return real;
}

function isCleanRelativeSegments(segments) {
  return segments.every(seg =>
    seg !== "" && seg !== "." && seg !== ".." && !seg.startsWith("."));
}

function isDeniedFileName(baseName) {
  const lower = baseName.toLowerCase();
  if (DENIED_EXTENSIONS.has(path.extname(lower))) return true;
  return DENIED_BASENAME_PREFIXES.some(prefix => lower === prefix || lower.startsWith(`${prefix}.`));
}

// note_id / path_prefix 共用的相对路径形式校验（不触碰文件系统）。
export function validateRelativePath(noteId, limits, { requireExtension, allowedExtensions }) {
  if (typeof noteId !== "string" || noteId.length === 0) {
    throw new VaultError(ERROR_CODES.INVALID_NOTE_ID, "note_id 必须是非空字符串");
  }
  if (noteId.length > limits.maxNoteIdChars) {
    throw new VaultError(ERROR_CODES.INVALID_NOTE_ID, "note_id 超长");
  }
  if (noteId.includes("\0") || noteId.includes("\\")) {
    throw new VaultError(ERROR_CODES.INVALID_NOTE_ID, "note_id 含非法字符");
  }
  if (path.posix.isAbsolute(noteId) || /^[a-zA-Z]:/.test(noteId)) {
    throw new VaultError(ERROR_CODES.PATH_DENIED, "拒绝绝对路径");
  }
  const segments = noteId.split("/");
  if (!isCleanRelativeSegments(segments)) {
    throw new VaultError(ERROR_CODES.PATH_DENIED, "拒绝路径穿越、隐藏目录与 .obsidian/ 等配置目录");
  }
  const baseName = segments[segments.length - 1];
  if (isDeniedFileName(baseName)) {
    throw new VaultError(ERROR_CODES.PATH_DENIED, "拒绝密钥类文件");
  }
  if (requireExtension && !allowedExtensions.includes(path.extname(baseName).toLowerCase())) {
    throw new VaultError(ERROR_CODES.PATH_DENIED, "文件类型不在允许列表内");
  }
  return segments;
}

// 把 note_id 解析成 Vault 内真实文件路径；realpath 包含性检查阻断符号链接逃逸。
export function resolveNotePath(vaultRootReal, noteId, config) {
  const segments = validateRelativePath(noteId, config.limits, {
    requireExtension: true,
    allowedExtensions: config.allowedExtensions
  });
  const absolute = path.join(vaultRootReal, ...segments);
  let real;
  try {
    real = fs.realpathSync(absolute);
  } catch {
    throw new VaultError(ERROR_CODES.NOT_FOUND, "笔记不存在");
  }
  if (real !== vaultRootReal && !real.startsWith(vaultRootReal + path.sep)) {
    throw new VaultError(ERROR_CODES.PATH_DENIED, "拒绝指向 Vault 外的符号链接");
  }
  if (!fs.statSync(real).isFile()) {
    throw new VaultError(ERROR_CODES.NOT_FOUND, "note_id 不是普通文件");
  }
  return real;
}

// 遍历 Vault，产出可索引文件的 note_id（相对路径）。跳过隐藏目录、符号链接与超大文件。
export function* walkVault(vaultRootReal, config) {
  const stack = [""];
  let fileCount = 0;
  while (stack.length > 0) {
    const relDir = stack.pop();
    const absDir = path.join(vaultRootReal, relDir);
    let entries;
    try {
      entries = fs.readdirSync(absDir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const entry of entries) {
      if (entry.name.startsWith(".") || entry.isSymbolicLink()) continue;
      const relPath = relDir === "" ? entry.name : `${relDir}/${entry.name}`;
      if (entry.isDirectory()) {
        stack.push(relPath);
        continue;
      }
      if (!entry.isFile()) continue;
      if (isDeniedFileName(entry.name)) continue;
      if (!config.allowedExtensions.includes(path.extname(entry.name).toLowerCase())) continue;
      const absPath = path.join(vaultRootReal, relPath);
      let stat;
      try {
        stat = fs.statSync(absPath);
      } catch {
        continue;
      }
      if (stat.size > config.limits.maxIndexFileBytes) continue;
      fileCount += 1;
      if (fileCount > config.limits.maxIndexFiles) return;
      yield { noteId: relPath, absPath, mtimeMs: stat.mtimeMs, size: stat.size };
    }
  }
}
