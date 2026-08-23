import { ModuleBridge } from "./bridge.js";
import { PAGE_NAMES } from "./constants.js";
import { $, setText } from "./dom.js";
import { DiagnosticsView } from "./diagnostics-view.js";
import { notify, setBusy } from "./feedback.js";
import { parseKeyValue } from "./model.js";
import { SwipeNavigation } from "./navigation.js";
import { SettingsView } from "./settings-view.js";
import { StatusView } from "./status-view.js";

class Application {
  constructor() {
    this.bridge = new ModuleBridge();
    this.statusView = new StatusView();
    this.diagnosticsView = new DiagnosticsView();
    this.settingsView = new SettingsView((dirty) => this.updateBottomActions(dirty));
    this.navigation = new SwipeNavigation({
      pageCount: PAGE_NAMES.length,
      onPageChange: (index) => this.onPageChange(index),
    });
    this.status = {};
    this.pageIndex = 0;
    this.pollTimer = 0;
    this.statusRequest = null;
  }

  async initialize() {
    try { window.ksu?.enableEdgeToEdge?.(true); } catch (_) {}
    this.bindActions();
    this.settingsView.mount();
    this.navigation.mount();
    await this.refreshAll(true);
    this.pollTimer = window.setInterval(() => {
      if (!document.hidden && this.pageIndex === 0) this.refreshStatus(false).catch(() => {});
    }, 5000);
    window.addEventListener("beforeunload", () => window.clearInterval(this.pollTimer), { once: true });
  }

  bindActions() {
    $("#refreshButton").addEventListener("click", async () => {
      const button = $("#refreshButton");
      button.classList.add("loading");
      try { await this.refreshAll(true); } finally { button.classList.remove("loading"); }
    });
    $("#saveButton").addEventListener("click", () => this.saveSettings());
    $("#resetButton").addEventListener("click", () => this.settingsView.reset());
    $("#threadRefreshButton").addEventListener("click", () => this.refreshThreads(true));
    $("#logRefreshButton").addEventListener("click", () => this.refreshLogs(true));
    $("#copyButton").addEventListener("click", () => this.copyDiagnostics());
    $("#clearLogButton").addEventListener("click", () => this.clearLogs());
    $("#restartButton").addEventListener("click", () => this.restartService());
  }

  async refreshStatus(showError) {
    if (this.statusRequest) return this.statusRequest;
    this.statusRequest = (async () => {
      try {
        this.status = { ...this.status, ...parseKeyValue(await this.bridge.run("status")) };
        this.statusView.render(this.status);
        return this.status;
      } catch (error) {
        if (showError) notify(error.message, true);
        throw error;
      } finally {
        this.statusRequest = null;
      }
    })();
    return this.statusRequest;
  }

  async refreshAll(showError) {
    try {
      const [, info] = await Promise.all([this.refreshStatus(false), this.bridge.run("info")]);
      this.status = { ...this.status, ...parseKeyValue(info) };
      this.statusView.render(this.status);
      if (!this.settingsView.isDirty()) this.settingsView.render(this.status);
    } catch (error) {
      if (showError) notify(error.message, true);
    }
  }

  async refreshThreads(showError) {
    try { this.diagnosticsView.renderThreads(await this.bridge.run("threads")); }
    catch (error) { this.diagnosticsView.renderThreads(""); if (showError) notify(error.message, true); }
  }

  async refreshLogs(showError) {
    try { this.diagnosticsView.renderLogs(await this.bridge.run("logs", ["120"])); }
    catch (error) { this.diagnosticsView.renderLogs(error.message); if (showError) notify(error.message, true); }
  }

  async saveSettings() {
    let tokens;
    try { tokens = this.settingsView.configurationTokens(); }
    catch (error) { notify(error.message, true); return; }
    setBusy(true, "保存设置");
    try {
      await this.bridge.run("configure", tokens);
      await this.refreshAll(false);
      this.settingsView.render(this.status);
      notify("设置已保存");
    } catch (error) {
      notify(error.message, true);
    } finally {
      setBusy(false);
    }
  }

  async copyDiagnostics() {
    setBusy(true, "读取诊断");
    try {
      await navigator.clipboard.writeText(await this.bridge.run("diagnostics"));
      notify("诊断已复制");
    } catch (error) {
      notify(error.message, true);
    } finally {
      setBusy(false);
    }
  }

  async clearLogs() {
    try {
      await this.bridge.run("clear-log");
      await this.refreshLogs(false);
      notify("日志已清空");
    } catch (error) {
      notify(error.message, true);
    }
  }

  async restartService() {
    setBusy(true, "重载服务");
    try {
      await this.bridge.run("restart");
      await this.refreshAll(false);
      notify("服务已重载");
    } catch (error) {
      notify(error.message, true);
    } finally {
      setBusy(false);
    }
  }

  onPageChange(index) {
    this.pageIndex = index;
    this.updateBottomActions(this.settingsView.isDirty());
    if (PAGE_NAMES[index] === "diagnostics") {
      Promise.allSettled([this.refreshThreads(false), this.refreshLogs(false)]);
    }
  }

  updateBottomActions(dirty) {
    const actions = $("#bottomActions");
    const visible = this.pageIndex === 1 && dirty;
    actions.classList.toggle("visible", visible);
    actions.setAttribute("aria-hidden", String(!visible));
  }
}

new Application().initialize().catch((error) => {
  setText("heroState", "初始化失败");
  notify(error.message, true);
});
