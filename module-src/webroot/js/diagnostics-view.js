import { $ } from "./dom.js";

export class DiagnosticsView {
  renderThreads(output) {
    const table = $("#threadTable");
    table.replaceChildren();
    const lines = String(output).split(/\r?\n/).filter(Boolean);
    if (!lines.length) {
      const empty = document.createElement("p");
      empty.className = "empty-state";
      empty.textContent = "未找到 Launcher 目标线程";
      table.append(empty);
      return;
    }
    table.append(this.threadRow(["线程", "TID", "CPU", "uclamp.min", "uclamp.max"], true));
    for (const line of lines) {
      const fields = line.split("\t");
      while (fields.length < 5) fields.push("—");
      table.append(this.threadRow(fields.slice(0, 5), false));
    }
  }

  threadRow(fields, header) {
    const row = document.createElement("div");
    row.className = `thread-row${header ? " thread-header" : ""}`;
    for (const value of fields) {
      const cell = document.createElement("span");
      cell.textContent = value || "—";
      row.append(cell);
    }
    return row;
  }

  renderLogs(output) {
    $("#logOutput").textContent = String(output).trim() || "无日志";
  }
}
