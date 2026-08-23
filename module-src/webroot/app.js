(() => {
  "use strict";

  const MODULE_DIR = "/data/adb/modules/hyperos4_recents_source_app_yield";
  const WEBUI = `${MODULE_DIR}/webui.sh`;
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));
  const pages = ["status", "settings", "diagnostics"];
  let callbackId = 0;
  let pageIndex = 0;
  let latest = {};
  let drag = null;
  let snackbarTimer = 0;
  let pollTimer = 0;

  const mock = {
    version: "4.1", author: "github: silverpoetry", policy: "enabled",
    source_policy: "enabled", aux_policy: "enabled", thread_policy: "enabled",
    frequency_policy_state: "enabled", frequency_percent: "78",
    frequency_timeout_ms: "1500", app_fallback_ms: "2000",
    launcher_placement: "2", fence_placement: "2", boost_duration_ms: "1", uclamp_raster: "928",
    uclamp_ui: "768", uclamp_rust: "512", uclamp_resmgr: "384",
    mode: "recents", daemon_pid: "1842", daemon_alive: "1", launcher_pid: "3021",
    transition_serial: "42", all_mask: "ff", perf_mask: "f8", mid_mask: "78",
    little_mask: "7", source_pid: "9174", source_uid: "10341",
    source_name: "com.tencent.jkchess", source_allowed: "0-2",
    source_cpuset: "/background", source_cpuctl: "/background",
    frequency_active: "0", frequency_policy: "policy0", frequency_cpus: "0 1 2",
    frequency_current_khz: "2016000", frequency_max_khz: "2016000",
    model: "Xiaomi Pad 6S Pro 12.4", device: "sheng", os: "OS4.0",
    android: "17", kernel: "6.1.99-android14", selinux: "Enforcing",
  };

  const serialize = (object) => Object.entries(object).map(([key, value]) => `${key}=${value}`).join("\n");

  async function mockExec(command) {
    await new Promise((resolve) => setTimeout(resolve, 80));
    if (command === `${WEBUI} status` || command === `${WEBUI} info`) return { errno: 0, stdout: serialize(mock), stderr: "" };
    if (command === `${WEBUI} threads`) return { errno: 0, stdout: "1.raster\t3061\t3-7\t0\t1024\n1.ui\t3060\t3-6\t0\t1024\nrt-launcher-mai\t3072\t3-6\t0\t1024", stderr: "" };
    if (command.startsWith(`${WEBUI} logs`)) return { errno: 0, stdout: "mode=entering\nfrequency-limited percent=78 policies=1\nmode=recents\nfrequency-restored", stderr: "" };
    if (command === `${WEBUI} diagnostics`) return { errno: 0, stdout: `[status]\n${serialize(mock)}\n\n[recent log]\nmode=recents`, stderr: "" };
    if (command.startsWith(`${WEBUI} save-config `)) {
      const values = command.split(" ").slice(2);
      [mock.policy, mock.source_policy, mock.aux_policy, mock.thread_policy,
        mock.frequency_policy_state, mock.frequency_percent, mock.frequency_timeout_ms,
        mock.app_fallback_ms, mock.launcher_placement, mock.fence_placement, mock.boost_duration_ms,
        mock.uclamp_raster, mock.uclamp_ui, mock.uclamp_rust, mock.uclamp_resmgr] = values;
    }
    return { errno: 0, stdout: "ok=1", stderr: "" };
  }

  function ksuExec(command) {
    if (!window.ksu || typeof window.ksu.exec !== "function") return mockExec(command);
    return new Promise((resolve, reject) => {
      const callback = `launcher_scheduling_${Date.now()}_${callbackId++}`;
      window[callback] = (errno, stdout, stderr) => {
        delete window[callback];
        resolve({ errno: Number(errno), stdout: String(stdout || ""), stderr: String(stderr || "") });
      };
      try {
        window.ksu.exec(command, "{}", callback);
      } catch (error) {
        delete window[callback];
        reject(error);
      }
    });
  }

  async function run(action, args = []) {
    const allowed = new Set(["status", "info", "threads", "logs", "diagnostics", "save-config", "restart", "clear-log"]);
    if (!allowed.has(action)) throw new Error("不支持的操作");
    const safe = args.every((value) => /^(enabled|disabled|[0-9]+)$/.test(String(value)));
    if (!safe) throw new Error("参数无效");
    if (action === "logs") args = ["120"];
    const result = await ksuExec(`${WEBUI} ${action}${args.length ? ` ${args.join(" ")}` : ""}`);
    if (result.errno !== 0) throw new Error(result.stderr.trim() || `命令失败 (${result.errno})`);
    return result.stdout;
  }

  function parse(text) {
    const result = {};
    text.split(/\r?\n/).forEach((line) => {
      const index = line.indexOf("=");
      if (index > 0) result[line.slice(0, index)] = line.slice(index + 1);
    });
    return result;
  }

  function setText(id, value, fallback = "—") {
    const node = document.getElementById(id);
    if (node) node.textContent = value || fallback;
  }

  function setInput(id, value) {
    const node = document.getElementById(id);
    if (node && document.activeElement !== node) node.value = value ?? "";
  }

  function cpuList(mask) {
    if (!mask || mask === "-") return "—";
    try {
      let value = BigInt(`0x${mask.replace(/^0x/i, "")}`);
      const cpus = [];
      for (let cpu = 0; value > 0n && cpu < 128; cpu += 1, value >>= 1n) if (value & 1n) cpus.push(cpu);
      return cpus.length ? `CPU ${cpus.join(",")}` : "—";
    } catch (_) {
      return "—";
    }
  }

  function frequency(khz) {
    const value = Number(khz);
    if (!Number.isFinite(value) || value <= 0) return "—";
    return value >= 1000000 ? `${(value / 1000000).toFixed(3)} GHz` : `${Math.round(value / 1000)} MHz`;
  }

  function modeName(mode) {
    return ({ app: "应用", entering: "进入动画", home: "桌面", recents: "最近任务", leaving: "返回动画" })[mode] || mode || "—";
  }

  function render(status) {
    latest = status;
    const online = status.daemon_alive === "1";
    const service = $("#serviceState");
    service.classList.toggle("online", online);
    $("b", service).textContent = online ? "在线" : "离线";
    setText("versionText", `v${status.version || "—"} · github: silverpoetry`);
    setText("policyValue", status.policy === "disabled" ? "关闭" : "启用");
    setText("modeValue", modeName(status.mode));
    setText("daemonValue", online ? `PID ${status.daemon_pid || "—"}` : "未运行");
    setText("launcherPidValue", status.launcher_pid);
    setText("serialValue", status.transition_serial);
    setText("sourceValue", status.source_name);
    setText("sourcePidValue", status.source_pid ? `${status.source_pid} / ${status.source_uid || "—"}` : "—");
    setText("sourceCpuValue", status.source_allowed);
    setText("sourceGroupValue", [status.source_cpuset, status.source_cpuctl].filter(Boolean).join(" / "));
    setText("freqPolicyValue", status.frequency_policy);
    setText("freqCpuValue", status.frequency_cpus ? `CPU ${status.frequency_cpus.replace(/ /g, ",")}` : "—");
    setText("freqCurrentValue", frequency(status.frequency_current_khz));
    setText("freqMaxValue", frequency(status.frequency_max_khz));
    setText("freqActiveValue", status.frequency_active === "1" ? frequency(status.frequency_applied_khz) : "否");
    [["all", status.all_mask], ["perf", status.perf_mask], ["mid", status.mid_mask], ["little", status.little_mask]].forEach(([prefix, mask]) => {
      setText(`${prefix}Mask`, mask && mask !== "-" ? `0x${mask}` : "—");
      setText(`${prefix}List`, cpuList(mask));
    });
    setText("deviceValue", status.model || status.device);
    setText("osValue", [status.os, status.android ? `Android ${status.android}` : ""].filter(Boolean).join(" / "));
    setText("kernelValue", status.kernel);
    setText("selinuxValue", status.selinux);

    $("#policyToggle").checked = status.policy !== "disabled";
    $("#sourceToggle").checked = status.source_policy !== "disabled";
    $("#auxToggle").checked = status.aux_policy !== "disabled";
    $("#threadToggle").checked = status.thread_policy !== "disabled";
    $("#frequencyToggle").checked = status.frequency_policy_state !== "disabled";
    setInput("frequencyPercent", status.frequency_percent);
    setInput("frequencyTimeout", status.frequency_timeout_ms);
    setInput("appFallback", status.app_fallback_ms);
    setInput("launcherPlacement", status.launcher_placement);
    setInput("fencePlacement", status.fence_placement);
    setInput("boostDuration", status.boost_duration_ms);
    setInput("uclampRaster", status.uclamp_raster);
    setInput("uclampUi", status.uclamp_ui);
    setInput("uclampRust", status.uclamp_rust);
    setInput("uclampResmgr", status.uclamp_resmgr);
  }

  function renderThreads(output) {
    const table = $("#threadTable");
    table.replaceChildren();
    const lines = output.split(/\r?\n/).filter(Boolean);
    if (!lines.length) {
      const empty = document.createElement("p");
      empty.textContent = "未找到线程";
      table.append(empty);
      return;
    }
    const header = document.createElement("div");
    header.className = "thread-row thread-header";
    ["线程", "TID", "CPU", "uclamp.min", "uclamp.max"].forEach((value) => {
      const cell = document.createElement("span"); cell.textContent = value; header.append(cell);
    });
    table.append(header);
    lines.forEach((line) => {
      const row = document.createElement("div"); row.className = "thread-row";
      const fields = line.split("\t"); while (fields.length < 5) fields.push("—");
      fields.slice(0, 5).forEach((value) => { const cell = document.createElement("span"); cell.textContent = value || "—"; row.append(cell); });
      table.append(row);
    });
  }

  function busy(active, label = "处理中") {
    $("#busy").classList.toggle("show", active);
    $("#busy span").textContent = label;
  }

  function notify(message, error = false) {
    clearTimeout(snackbarTimer);
    const bar = $("#snackbar");
    $("span", bar).textContent = message;
    bar.classList.toggle("error", error);
    bar.classList.add("show");
    snackbarTimer = setTimeout(() => bar.classList.remove("show"), 2400);
  }

  async function refreshStatus(showError = true) {
    try {
      const status = { ...latest, ...parse(await run("status")) };
      render(status);
      return status;
    } catch (error) {
      if (showError) notify(error.message, true);
      throw error;
    }
  }

  async function refreshInfo(showError = true) {
    try {
      const status = { ...latest, ...parse(await run("info")) };
      render(status);
    } catch (error) {
      if (showError) notify(error.message, true);
    }
  }

  async function refreshThreads() {
    try { renderThreads(await run("threads")); }
    catch (error) { renderThreads(""); notify(error.message, true); }
  }

  async function refreshLogs() {
    try { $("#logOutput").textContent = (await run("logs")).trim() || "无日志"; }
    catch (error) { $("#logOutput").textContent = error.message; notify(error.message, true); }
  }

  function numberValue(id, min, max) {
    const value = Number($(id).value);
    if (!Number.isInteger(value) || value < min || value > max) throw new Error(`${$(id).closest("label").querySelector("span").textContent}超出范围`);
    return String(value);
  }

  async function saveSettings() {
    let args;
    try {
      args = [
        $("#policyToggle").checked ? "enabled" : "disabled",
        $("#sourceToggle").checked ? "enabled" : "disabled",
        $("#auxToggle").checked ? "enabled" : "disabled",
        $("#threadToggle").checked ? "enabled" : "disabled",
        $("#frequencyToggle").checked ? "enabled" : "disabled",
        numberValue("#frequencyPercent", 40, 100), numberValue("#frequencyTimeout", 300, 5000),
        numberValue("#appFallback", 500, 5000), numberValue("#launcherPlacement", 1, 2),
        numberValue("#fencePlacement", 1, 2),
        numberValue("#boostDuration", 1, 1000), numberValue("#uclampRaster", 0, 1024),
        numberValue("#uclampUi", 0, 1024), numberValue("#uclampRust", 0, 1024),
        numberValue("#uclampResmgr", 0, 1024),
      ];
    } catch (error) {
      notify(error.message, true); return;
    }
    busy(true, "保存设置");
    try {
      await run("save-config", args);
      await refreshStatus(false);
      await refreshInfo(false);
      notify("设置已保存");
    } catch (error) { notify(error.message, true); }
    finally { busy(false); }
  }

  function setPage(index, animate = true) {
    pageIndex = Math.max(0, Math.min(pages.length - 1, index));
    const track = $("#pageTrack");
    track.classList.toggle("no-transition", !animate);
    track.style.setProperty("--page-index", String(pageIndex));
    track.style.setProperty("--drag-offset", "0px");
    $$(".nav-item").forEach((item, itemIndex) => item.classList.toggle("active", itemIndex === pageIndex));
    setTimeout(() => track.classList.remove("no-transition"), 0);
    if (pageIndex === 2) Promise.allSettled([refreshThreads(), refreshLogs()]);
  }

  function interactive(target) { return Boolean(target.closest("button,input,select,pre,.thread-table")); }
  function onTouchStart(event) {
    if (event.touches.length !== 1 || interactive(event.target)) return;
    const touch = event.touches[0];
    drag = { x: touch.clientX, y: touch.clientY, time: performance.now(), offset: 0, horizontal: false };
    $("#pageTrack").classList.add("dragging");
  }
  function onTouchMove(event) {
    if (!drag || event.touches.length !== 1) return;
    const touch = event.touches[0]; let dx = touch.clientX - drag.x; const dy = touch.clientY - drag.y;
    if (!drag.horizontal) {
      if (Math.abs(dx) < 8) return;
      if (Math.abs(dx) <= Math.abs(dy) * 1.15) { drag = null; $("#pageTrack").classList.remove("dragging"); return; }
      drag.horizontal = true;
    }
    if ((pageIndex === 0 && dx > 0) || (pageIndex === pages.length - 1 && dx < 0)) dx *= .25;
    drag.offset = dx; $("#pageTrack").style.setProperty("--drag-offset", `${dx}px`); event.preventDefault();
  }
  function onTouchEnd() {
    if (!drag) return;
    const threshold = Math.min(innerWidth * .18, 150);
    const speed = Math.abs(drag.offset) / Math.max(1, performance.now() - drag.time);
    let target = pageIndex;
    if (drag.horizontal && (Math.abs(drag.offset) > threshold || speed > .55)) target += drag.offset < 0 ? 1 : -1;
    drag = null; $("#pageTrack").classList.remove("dragging"); setPage(target);
  }

  async function copyDiagnostics() {
    busy(true, "读取诊断");
    try {
      const output = await run("diagnostics");
      await navigator.clipboard.writeText(output);
      notify("已复制");
    } catch (error) { notify(error.message, true); }
    finally { busy(false); }
  }

  function bind() {
    $$(".nav-item").forEach((item) => item.addEventListener("click", () => setPage(Number(item.dataset.index))));
    $("#refreshButton").addEventListener("click", async () => {
      $("#refreshButton").classList.add("loading");
      try { await refreshStatus(); await refreshInfo(false); }
      finally { $("#refreshButton").classList.remove("loading"); }
    });
    $("#saveButton").addEventListener("click", saveSettings);
    $("#threadRefreshButton").addEventListener("click", refreshThreads);
    $("#logRefreshButton").addEventListener("click", refreshLogs);
    $("#copyButton").addEventListener("click", copyDiagnostics);
    $("#clearLogButton").addEventListener("click", async () => { try { await run("clear-log"); await refreshLogs(); notify("日志已清空"); } catch (error) { notify(error.message, true); } });
    $("#restartButton").addEventListener("click", async () => { busy(true, "重载服务"); try { await run("restart"); await refreshStatus(false); notify("服务已重载"); } catch (error) { notify(error.message, true); } finally { busy(false); } });
    const shell = $("#swipeShell");
    shell.addEventListener("touchstart", onTouchStart, { passive: true });
    shell.addEventListener("touchmove", onTouchMove, { passive: false });
    shell.addEventListener("touchend", onTouchEnd, { passive: true });
    shell.addEventListener("touchcancel", onTouchEnd, { passive: true });
  }

  async function initialize() {
    try { window.ksu?.enableEdgeToEdge?.(true); } catch (_) {}
    bind(); setPage(0, false);
    await refreshStatus().catch(() => {}); await refreshInfo(false);
    pollTimer = setInterval(() => { if (!document.hidden && pageIndex === 0) refreshStatus(false).catch(() => {}); }, 5000);
    addEventListener("beforeunload", () => clearInterval(pollTimer), { once: true });
  }

  initialize();
})();
