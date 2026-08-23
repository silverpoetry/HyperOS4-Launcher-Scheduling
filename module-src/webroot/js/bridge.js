import { MOCK_LOG, MOCK_STATUS, MOCK_THREADS, WEBUI_COMMAND } from "./constants.js";

const ACTIONS = new Set(["status", "info", "threads", "logs", "diagnostics", "configure", "restart", "clear-log"]);
const CONFIG_TOKEN = /^[a-z_]+=(?:enabled|disabled|[0-9]+)$/;
let callbackSequence = 0;

function serialize(object) {
  return Object.entries(object).map(([key, value]) => `${key}=${value}`).join("\n");
}

function applyMockConfiguration(tokens) {
  const mapping = {
    master: "master_policy",
    source: "source_policy",
    auxiliary: "auxiliary_policy",
    launcher: "launcher_policy",
    frequency: "frequency_policy",
  };
  for (const token of tokens) {
    const separator = token.indexOf("=");
    const key = token.slice(0, separator);
    const value = token.slice(separator + 1);
    MOCK_STATUS[mapping[key] || key] = value;
  }
}

async function mockRun(action, args) {
  await new Promise((resolve) => setTimeout(resolve, 60));
  if (action === "status" || action === "info") return serialize(MOCK_STATUS);
  if (action === "threads") return MOCK_THREADS;
  if (action === "logs") return MOCK_LOG;
  if (action === "diagnostics") return `[status]\n${serialize(MOCK_STATUS)}\n\n[threads]\n${MOCK_THREADS}\n\n[recent log]\n${MOCK_LOG}`;
  if (action === "configure") applyMockConfiguration(args);
  return "ok=1";
}

function executeKernelSu(command) {
  return new Promise((resolve, reject) => {
    const callback = `launcherScheduling_${Date.now()}_${callbackSequence++}`;
    window[callback] = (errno, stdout, stderr) => {
      delete window[callback];
      const code = Number(errno);
      if (code === 0) resolve(String(stdout || ""));
      else reject(new Error(String(stderr || "").trim() || `命令失败 (${code})`));
    };
    try {
      window.ksu.exec(command, "{}", callback);
    } catch (error) {
      delete window[callback];
      reject(error);
    }
  });
}

export class ModuleBridge {
  async run(action, args = []) {
    if (!ACTIONS.has(action)) throw new Error("不支持的操作");
    if (action === "configure" && !args.every((token) => CONFIG_TOKEN.test(token))) {
      throw new Error("配置参数无效");
    }
    if (action !== "configure" && args.some((value) => !/^[0-9]+$/.test(String(value)))) {
      throw new Error("命令参数无效");
    }
    if (!window.ksu || typeof window.ksu.exec !== "function") return mockRun(action, args);
    const suffix = args.length ? ` ${args.join(" ")}` : "";
    return executeKernelSu(`${WEBUI_COMMAND} ${action}${suffix}`);
  }
}
