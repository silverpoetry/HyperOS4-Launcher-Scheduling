export function parseKeyValue(text) {
  const result = {};
  for (const line of String(text).split(/\r?\n/)) {
    const separator = line.indexOf("=");
    if (separator > 0) result[line.slice(0, separator)] = line.slice(separator + 1);
  }
  return result;
}

export function modeLabel(mode) {
  return ({
    booting: "启动中",
    app: "应用前台",
    entering: "进入桌面",
    home: "桌面",
    recents: "最近任务",
    leaving: "返回应用",
  })[mode] || mode || "未知";
}

export function cpuList(mask) {
  if (!mask || mask === "-") return "—";
  const value = Number.parseInt(mask, 16);
  if (!Number.isSafeInteger(value)) return "—";
  const cpus = [];
  for (let cpu = 0; cpu < 32; cpu += 1) {
    if ((value & (2 ** cpu)) !== 0) cpus.push(cpu);
  }
  return cpus.length ? `CPU ${cpus.join(", ")}` : "—";
}

export function frequency(khz) {
  const value = Number(khz);
  if (!Number.isFinite(value) || value <= 0) return "—";
  return value >= 1_000_000 ? `${(value / 1_000_000).toFixed(2)} GHz` : `${Math.round(value / 1000)} MHz`;
}

export function serviceSummary(status) {
  if (status.daemon_alive !== "1") return { title: "服务离线", detail: "守护进程未运行" };
  if (status.master_policy === "disabled") return { title: "策略关闭", detail: `服务在线 · ${modeLabel(status.mode)}` };
  return { title: "运行中", detail: `PID ${status.daemon_pid || "—"} · ${modeLabel(status.mode)}` };
}
