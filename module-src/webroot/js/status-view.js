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
    setText("versionText", `v${status.version || "—"} · github: silverpoetry`);
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
      ["render", status.render_mask], ["secondary", status.secondary_mask],
    ]) {
      setText(`${prefix}Mask`, mask && mask !== "-" ? `0x${mask}` : "—");
      setText(`${prefix}List`, cpuList(mask));
    }

    const policyLabel = [status.frequency_policy_name, status.frequency_cpus ? `CPU ${status.frequency_cpus}` : ""].filter(Boolean).join(" · ");
    setText("freqPolicyValue", policyLabel);
    setText("freqCurrentValue", frequency(status.frequency_current_khz));
    setText("freqMaxValue", frequency(status.frequency_max_khz));
    const frequencyBadge = $("#freqActiveValue");
    const active = status.frequency_active === "1";
    frequencyBadge.textContent = active ? "活动" : "未活动";
    frequencyBadge.classList.toggle("active", active);

    setText("deviceValue", status.model || status.device);
    setText("osValue", [status.os, status.android ? `Android ${status.android}` : ""].filter(Boolean).join(" / "));
    setText("kernelValue", status.kernel);
    setText("selinuxValue", status.selinux);
  }
}
