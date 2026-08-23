(() => {
  "use strict";

  const MODULE_DIR = "/data/adb/modules/hyperos4_recents_source_app_yield";
  const WEBUI = `${MODULE_DIR}/webui.sh`;
  const PAGE_TITLES = ["运行状态", "策略管理", "诊断信息", "关于模块"];
  const $ = (selector, root = document) => root.querySelector(selector);
  const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

  let callbackId = 0;
  let pageIndex = 0;
  let latestStatus = {};
  let snackbarTimer = 0;
  let statusTimer = 0;
  let diagnosticsLoaded = false;
  let drag = null;
  let statusRequest = null;

  const mock = {
    policy: "enabled",
    thread_policy: "enabled",
    profile: "2",
    mode: "recents",
    epoch: "18",
    transition_serial: "42",
    version: "3.3",
    device: "sheng",
    model: "Xiaomi Pad 6S Pro 12.4",
    os: "OS4.0",
    android: "17",
    kernel: "6.1.99-android14",
    selinux: "Enforcing",
    daemon_pid: "1842",
    daemon_alive: "1",
    watcher_pids: "1871",
    launcher_pid: "3021",
    all_mask: "ff",
    perf_mask: "fc",
    mid_mask: "7c",
    little_mask: "3",
    source_pid: "9174",
    source_uid: "10236",
    source_name: "com.android.settings",
    source_cpuset: "/background",
    source_cpuctl: "/background",
    source_allowed: "0-7",
    pending_pid: "",
    pending_uid: "",
    pending_name: "",
  };

  function serializeMockStatus() {
    return Object.entries(mock).map(([key, value]) => `${key}=${value}`).join("\n");
  }

  async function mockExec(command) {
    await new Promise((resolve) => setTimeout(resolve, 90));
    if (command === `${WEBUI} status`) return { errno: 0, stdout: serializeMockStatus(), stderr: "" };
    if (command === `${WEBUI} info`) return { errno: 0, stdout: serializeMockStatus(), stderr: "" };
    if (command === `${WEBUI} threads`) {
      return { errno: 0, stdout: "1.ui\t3060\t2-7\t384\n1.raster\t3061\t4-7\t512\nIplrVkResMgr\t3091\t2-6\t256\nIplrVkFenceWait\t3092\t0-3\t0", stderr: "" };
    }
    if (command.startsWith(`${WEBUI} logs`)) {
      return { errno: 0, stdout: "20:41:18 mode=entering source=com.android.settings pid=9174\n20:41:18 source-app -> background\n20:41:18 mode=recents launcher-threads boosted\n20:41:19 mode=leaving source-app restored", stderr: "" };
    }
    if (command === `${WEBUI} diagnostics`) {
      return { errno: 0, stdout: `[status]\n${serializeMockStatus()}\n\n[threads]\n1.ui\t3060\t2-7\t384\n1.raster\t3061\t4-7\t512\n\n[recent log]\n20:41:18 mode=recents`, stderr: "" };
    }
    const parts = command.split(" ");
    if (parts[1] === "set-policy") mock.policy = parts[2];
    if (parts[1] === "set-thread-policy") mock.thread_policy = parts[2];
    if (parts[1] === "set-profile") mock.profile = parts[2];
    return { errno: 0, stdout: "ok=1\nmessage=Setting applied", stderr: "" };
  }

  function ksuExec(command, options = {}) {
    if (!window.ksu || typeof window.ksu.exec !== "function") return mockExec(command);
    return new Promise((resolve, reject) => {
      const callback = `launcher_scheduling_exec_${Date.now()}_${callbackId++}`;
      window[callback] = (errno, stdout, stderr) => {
        delete window[callback];
        resolve({ errno: Number(errno), stdout: String(stdout || ""), stderr: String(stderr || "") });
      };
      try {
        window.ksu.exec(command, JSON.stringify(options), callback);
      } catch (error) {
        delete window[callback];
        reject(error);
      }
    });
  }

  async function run(action, argument = "") {
    const allowed = new Set(["status", "info", "threads", "logs", "diagnostics", "restart", "clear-log"]);
    const argumentActions = new Set(["set-policy", "set-thread-policy", "set-profile"]);
    if (!allowed.has(action) && !argumentActions.has(action)) throw new Error("不支持的操作");
    const safeArguments = {
      "set-policy": new Set(["enabled", "disabled"]),
      "set-thread-policy": new Set(["enabled", "disabled"]),
      "set-profile": new Set(["1", "2"]),
    };
    if (argumentActions.has(action) && !safeArguments[action].has(argument)) throw new Error("无效的参数");
    if (action === "logs") argument = "120";
    const result = await ksuExec(`${WEBUI} ${action}${argument ? ` ${argument}` : ""}`);
    if (result.errno !== 0) throw new Error(result.stderr.trim() || `命令执行失败 (${result.errno})`);
    return result.stdout;
  }

  function parseKeyValues(text) {
    const output = {};
    text.split(/\r?\n/).forEach((line) => {
      const separator = line.indexOf("=");
      if (separator < 1) return;
      output[line.slice(0, separator)] = line.slice(separator + 1);
    });
    return output;
  }

  function text(id, value, fallback = "—") {
    const element = document.getElementById(id);
    if (element) element.textContent = value || fallback;
  }

  function maskToCpuList(mask) {
    if (!mask || mask === "-") return "—";
    try {
      let value = BigInt(`0x${mask.replace(/^0x/i, "")}`);
      const cpus = [];
      for (let cpu = 0; value > 0n && cpu < 128; cpu += 1, value >>= 1n) {
        if (value & 1n) cpus.push(cpu);
      }
      if (!cpus.length) return "无 CPU";
      const ranges = [];
      let start = cpus[0];
      let end = start;
      for (let index = 1; index <= cpus.length; index += 1) {
        if (cpus[index] === end + 1) {
          end = cpus[index];
        } else {
          ranges.push(start === end ? `${start}` : `${start}-${end}`);
          start = cpus[index];
          end = start;
        }
      }
      return `CPU ${ranges.join(", ")}`;
    } catch (_) {
      return "无法解析";
    }
  }

  function displayMode(mode) {
    return ({ app: "应用", entering: "接管", home: "桌面", recents: "最近任务", leaving: "返回" })[mode] || mode || "未知";
  }

  function renderStatus(status) {
    latestStatus = status;
    const online = status.daemon_alive === "1";
    const policyEnabled = status.policy !== "disabled";
    const threadEnabled = status.thread_policy !== "disabled";
    const connection = $("#connectionPill");
    connection.classList.toggle("online", online);
    connection.classList.toggle("offline", !online);
    $("span", connection).textContent = online ? "服务在线" : "服务离线";

    const badge = $(".status-badge", $("#heroCard"));
    badge.classList.toggle("online", online && policyEnabled);
    badge.classList.toggle("offline", !online || !policyEnabled);
    text("heroStatus", !online ? "服务未运行" : policyEnabled ? "调度策略运行中" : "调度策略已暂停");
    text("heroDescription", policyEnabled
      ? "根据桌面转场阶段分配应用与 Launcher 的 CPU 资源。"
      : "模块仍已加载，但不会在桌面转场期间调整应用与 Launcher。", "");
    text("modeValue", displayMode(status.mode));
    text("daemonMetric", online ? "在线" : "离线");
    text("daemonDetail", status.daemon_pid ? `PID ${status.daemon_pid}` : "无守护进程");
    text("threadMetric", threadEnabled ? "启用" : "关闭");
    text("profileDetail", `档位 ${status.profile || "—"}`);
    text("perfMetric", maskToCpuList(status.perf_mask).replace("CPU ", ""));
    text("perfDetail", status.perf_mask && status.perf_mask !== "-" ? `mask ${status.perf_mask}` : "等待拓扑推导");
    text("epochChip", `Epoch ${status.epoch || "—"}`);

    $$(".life-step", $("#lifecycle")).forEach((step) => step.classList.toggle("active", step.dataset.mode === status.mode));
    const sourceName = status.source_name || "暂无记录";
    text("sourceName", sourceName);
    text("sourcePid", status.source_pid ? `PID ${status.source_pid} · UID ${status.source_uid || "—"}` : "PID —");
    text("sourceAllowed", status.source_allowed || "—");
    text("sourceCpuset", status.source_cpuset || "cpuset 未记录");
    text("sourceAvatar", status.source_name ? status.source_name.split(".").pop().slice(0, 2).toUpperCase() : "—");
    text("deviceValue", status.model || status.device);
    text("osValue", [status.os, status.android ? `Android ${status.android}` : ""].filter(Boolean).join(" · "));
    text("kernelValue", status.kernel);

    $("#policyToggle").checked = policyEnabled;
    $("#threadToggle").checked = threadEnabled;
    $$("[data-profile]").forEach((button) => {
      const selected = button.dataset.profile === status.profile;
      button.classList.toggle("selected", selected);
      button.setAttribute("aria-checked", String(selected));
      button.disabled = !threadEnabled;
    });
    renderTopology("all", status.all_mask);
    renderTopology("perf", status.perf_mask);
    renderTopology("mid", status.mid_mask);
    renderTopology("little", status.little_mask);

    text("versionDetail", status.version);
    text("selinuxDetail", status.selinux);
    text("launcherPidDetail", status.launcher_pid);
    text("watcherPidDetail", status.watcher_pids);
    text("pendingDetail", status.pending_name ? `${status.pending_name} · PID ${status.pending_pid || "—"}` : "无");
    text("serialDetail", status.transition_serial);
    text("aboutVersion", `Version ${status.version || "—"}`);
  }

  function renderTopology(prefix, mask) {
    text(`${prefix}Mask`, mask && mask !== "-" ? `0x${mask.replace(/^0x/i, "")}` : "—");
    text(`${prefix}CpuList`, maskToCpuList(mask));
  }

  function renderThreads(output) {
    const table = $("#threadTable");
    table.replaceChildren();
    const lines = output.split(/\r?\n/).filter(Boolean);
    if (!lines.length) {
      const empty = document.createElement("div");
      empty.className = "empty-state";
      empty.textContent = "未找到受控的 Launcher 线程";
      table.append(empty);
      return;
    }
    const header = document.createElement("div");
    header.className = "thread-row thread-header";
    ["线程", "TID", "CPU", "uclamp.min"].forEach((label) => {
      const cell = document.createElement("span");
      cell.textContent = label;
      header.append(cell);
    });
    table.append(header);
    lines.forEach((line) => {
      const row = document.createElement("div");
      row.className = "thread-row";
      const fields = line.split("\t");
      while (fields.length < 4) fields.push("—");
      fields.slice(0, 4).forEach((field) => {
        const cell = document.createElement("span");
        cell.textContent = field || "—";
        row.append(cell);
      });
      table.append(row);
    });
  }

  function setBusy(active, label = "正在应用设置") {
    const overlay = $("#busyOverlay");
    $("span", overlay).textContent = label;
    overlay.classList.toggle("show", active);
    overlay.setAttribute("aria-hidden", String(!active));
  }

  function notify(message, error = false) {
    clearTimeout(snackbarTimer);
    const bar = $("#snackbar");
    $("span", bar).textContent = message;
    bar.classList.toggle("error", error);
    bar.classList.add("show");
    snackbarTimer = window.setTimeout(() => bar.classList.remove("show"), 2600);
  }

  function refreshStatus({ quiet = false } = {}) {
    if (statusRequest) return statusRequest;
    statusRequest = (async () => {
      try {
        const status = { ...latestStatus, ...parseKeyValues(await run("status")) };
        renderStatus(status);
        return status;
      } catch (error) {
        $("#connectionPill").classList.remove("online");
        $("#connectionPill").classList.add("offline");
        $("#connectionPill span").textContent = "读取失败";
        if (!quiet) notify(error.message, true);
        throw error;
      } finally {
        statusRequest = null;
      }
    })();
    return statusRequest;
  }

  async function refreshInfo({ quiet = false } = {}) {
    try {
      const status = { ...latestStatus, ...parseKeyValues(await run("info")) };
      renderStatus(status);
      return status;
    } catch (error) {
      if (!quiet) notify(error.message, true);
      throw error;
    }
  }

  async function refreshThreads() {
    try {
      renderThreads(await run("threads"));
    } catch (error) {
      renderThreads("");
      notify(error.message, true);
    }
  }

  async function refreshLogs() {
    try {
      const output = await run("logs");
      $("#logOutput").textContent = output.trim() || "当前没有事件日志";
    } catch (error) {
      $("#logOutput").textContent = `读取失败：${error.message}`;
      notify(error.message, true);
    }
  }

  async function refreshDiagnostics() {
    await refreshStatus({ quiet: true }).catch(() => {});
    await refreshInfo({ quiet: true }).catch(() => {});
    await Promise.allSettled([refreshThreads(), refreshLogs()]);
    diagnosticsLoaded = true;
  }

  async function applySetting(action, value, label) {
    setBusy(true, label);
    try {
      await run(action, value);
      await refreshStatus({ quiet: true });
      notify("设置已生效");
    } catch (error) {
      notify(error.message, true);
      await refreshStatus({ quiet: true }).catch(() => {});
    } finally {
      setBusy(false);
    }
  }

  function setPage(index, animate = true) {
    pageIndex = Math.max(0, Math.min(PAGE_TITLES.length - 1, index));
    const track = $("#swipeTrack");
    track.classList.toggle("no-transition", !animate);
    track.style.setProperty("--page-index", String(pageIndex));
    track.style.setProperty("--drag-offset", "0px");
    text("screenTitle", PAGE_TITLES[pageIndex]);
    $$(".nav-tab").forEach((tab, tabIndex) => {
      const selected = tabIndex === pageIndex;
      tab.classList.toggle("active", selected);
      if (selected) tab.setAttribute("aria-current", "page");
      else tab.removeAttribute("aria-current");
    });
    $$(".swipe-page").forEach((page, pageNumber) => page.setAttribute("aria-hidden", String(pageNumber !== pageIndex)));
    if (pageIndex === 2 && !diagnosticsLoaded) refreshDiagnostics();
    window.setTimeout(() => track.classList.remove("no-transition"), 0);
  }

  function ignoreSwipeTarget(target) {
    return Boolean(target.closest("button, input, label, pre, .thread-table, .segmented-control"));
  }

  function onTouchStart(event) {
    if (event.touches.length !== 1 || ignoreSwipeTarget(event.target)) return;
    const touch = event.touches[0];
    drag = { x: touch.clientX, y: touch.clientY, time: performance.now(), horizontal: false, offset: 0 };
    $("#swipeTrack").classList.add("dragging");
  }

  function onTouchMove(event) {
    if (!drag || event.touches.length !== 1) return;
    const touch = event.touches[0];
    let dx = touch.clientX - drag.x;
    const dy = touch.clientY - drag.y;
    if (!drag.horizontal) {
      if (Math.abs(dx) < 8) return;
      if (Math.abs(dx) <= Math.abs(dy) * 1.15) {
        drag = null;
        $("#swipeTrack").classList.remove("dragging");
        return;
      }
      drag.horizontal = true;
    }
    if ((pageIndex === 0 && dx > 0) || (pageIndex === PAGE_TITLES.length - 1 && dx < 0)) dx *= 0.28;
    drag.offset = dx;
    $("#swipeTrack").style.setProperty("--drag-offset", `${dx}px`);
    event.preventDefault();
  }

  function onTouchEnd() {
    if (!drag) return;
    const elapsed = Math.max(1, performance.now() - drag.time);
    const velocity = Math.abs(drag.offset) / elapsed;
    const threshold = Math.min(window.innerWidth * 0.18, 150);
    let target = pageIndex;
    if (drag.horizontal && (Math.abs(drag.offset) > threshold || velocity > 0.55)) target += drag.offset < 0 ? 1 : -1;
    drag = null;
    $("#swipeTrack").classList.remove("dragging");
    setPage(target);
  }

  async function copyDiagnostics() {
    setBusy(true, "正在生成诊断信息");
    try {
      const output = await run("diagnostics");
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(output);
      } else {
        const area = document.createElement("textarea");
        area.value = output;
        area.style.position = "fixed";
        area.style.opacity = "0";
        document.body.append(area);
        area.select();
        document.execCommand("copy");
        area.remove();
      }
      notify("诊断信息已复制");
    } catch (error) {
      notify(`复制失败：${error.message}`, true);
    } finally {
      setBusy(false);
    }
  }

  function bindEvents() {
    $$(".nav-tab").forEach((tab) => tab.addEventListener("click", () => setPage(Number(tab.dataset.index))));
    $("#refreshButton").addEventListener("click", async () => {
      $("#refreshButton").classList.add("loading");
      try {
        if (pageIndex === 2) await refreshDiagnostics();
        else await refreshStatus();
      } finally {
        $("#refreshButton").classList.remove("loading");
      }
    });
    $("#policyToggle").addEventListener("change", (event) => applySetting("set-policy", event.target.checked ? "enabled" : "disabled", "正在切换应用退避策略"));
    $("#threadToggle").addEventListener("change", (event) => applySetting("set-thread-policy", event.target.checked ? "enabled" : "disabled", "正在切换逐线程策略"));
    $$("[data-profile]").forEach((button) => button.addEventListener("click", () => applySetting("set-profile", button.dataset.profile, "正在切换动画提升强度")));
    $("#restartButton").addEventListener("click", async () => {
      setBusy(true, "正在重新加载服务");
      try {
        await run("restart");
        await refreshStatus({ quiet: true });
        notify("服务已重新加载");
      } catch (error) {
        notify(error.message, true);
      } finally {
        setBusy(false);
      }
    });
    $("#threadRefreshButton").addEventListener("click", refreshThreads);
    $("#logRefreshButton").addEventListener("click", refreshLogs);
    $("#copyButton").addEventListener("click", copyDiagnostics);
    $("#clearLogButton").addEventListener("click", async () => {
      try {
        await run("clear-log");
        await refreshLogs();
        notify("日志已清空");
      } catch (error) {
        notify(error.message, true);
      }
    });
    const shell = $("#swipeShell");
    shell.addEventListener("touchstart", onTouchStart, { passive: true });
    shell.addEventListener("touchmove", onTouchMove, { passive: false });
    shell.addEventListener("touchend", onTouchEnd, { passive: true });
    shell.addEventListener("touchcancel", onTouchEnd, { passive: true });
    document.addEventListener("visibilitychange", () => {
      if (!document.hidden && pageIndex === 0) refreshStatus({ quiet: true }).catch(() => {});
    });
  }

  async function initialize() {
    try {
      window.ksu?.enableEdgeToEdge?.(true);
    } catch (_) {}
    bindEvents();
    setPage(0, false);
    await refreshStatus().catch(() => {});
    await refreshInfo({ quiet: true }).catch(() => {});
    statusTimer = window.setInterval(() => {
      if (!document.hidden && pageIndex === 0) refreshStatus({ quiet: true }).catch(() => {});
    }, 5000);
    window.addEventListener("beforeunload", () => window.clearInterval(statusTimer), { once: true });
  }

  initialize();
})();
