import { $, setText } from "./dom.js";
import { cpuList, frequency, modeLabel, serviceSummary } from "./model.js";

export class StatusView {
  render(status) {
    const online = status.daemon_alive === "1";
    const summary = serviceSummary(status);
    const serviceChip = $("#serviceState");
    serviceChip.classList.toggle("online", online);
    $("b", serviceChip).textContent = online ? "在线" : "离线";

    setText("heroState", summary.title);
    setText("heroDetail", summary.detail);
    setText("versionText", `版本 ${status.version || "—"}`);
    setText("aboutVersion", status.version);
    setText("aboutAuthor", status.author || "silverpoetry");
    setText("modeValue", modeLabel(status.mode));
    setText("serialValue", status.transition_serial || "0");

    setText("sourceValue", status.source_name);
    setText("sourcePidValue", status.source_pid ? `${status.source_pid} / ${status.source_uid || "—"}` : "—");
    setText("sourceCpuValue", status.source_allowed);
    setText("sourceGroupValue", [status.source_cpuset, status.source_cpuctl].filter(Boolean).join(" / "));
    const sourceBadge = $("#sourceBadge");
    sourceBadge.textContent = status.source_pid ? "已跟踪" : "未记录";
    sourceBadge.classList.toggle("active", Boolean(status.source_pid));

    for (const [prefix, mask] of [
      ["all", status.all_mask], ["perf", status.perf_mask],
      ["mid", status.mid_mask], ["little", status.little_mask],
      ["render", status.render_mask], ["prime", status.prime_mask],
      ["secondary", status.secondary_mask], ["background", status.background_mask],
      ["littleSpare", status.little_spare_mask],
    ]) {
      setText(`${prefix}Mask`, mask && mask !== "-" ? `0x${mask}` : "—");
      setText(`${prefix}List`, cpuList(mask));
    }

    this.renderFrequencies(status.frequency_clusters);
    const frequencyBadge = $("#freqActiveValue");
    const active = status.frequency_active === "1";
    frequencyBadge.textContent = active ? "限频中" : "未限频";
    frequencyBadge.classList.toggle("active", active);

    setText("deviceValue", status.model || status.device);
    setText("osValue", [status.os, status.android ? `Android ${status.android}` : ""].filter(Boolean).join(" / "));
    setText("kernelValue", status.kernel);
    setText("selinuxValue", status.selinux);
  }

  renderFrequencies(serialized) {
    const container = $("#frequencyList");
    const rows = String(serialized || "").split(";").filter(Boolean);
    if (!rows.length) {
      const empty = document.createElement("p");
      empty.className = "empty-state";
      empty.textContent = "未发现调频策略";
      container.replaceChildren(empty);
      return;
    }
    container.replaceChildren(...rows.map((row) => {
      const [policy, cpus, current, minimum, maximum, hardware, governor] = row.split("|");
      const item = document.createElement("div");
      item.className = "frequency-row";
      const heading = document.createElement("div");
      const title = document.createElement("strong");
      const subtitle = document.createElement("small");
      const values = document.createElement("span");
      title.textContent = `CPU ${cpus || "—"}`;
      subtitle.textContent = [policy, governor].filter(Boolean).join(" · ");
      values.textContent = `${frequency(current)} · ${frequency(minimum)}–${frequency(maximum)} · 硬件 ${frequency(hardware)}`;
      heading.append(title, subtitle);
      item.append(heading, values);
      return item;
    }));
  }
}
