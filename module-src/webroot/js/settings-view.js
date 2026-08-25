import { $, $$, setChecked, setValue } from "./dom.js";
import { placementOptions } from "./model.js";

const FIELD_SCHEMA = [
  ["frequencyPercent", "frequency_percent", 40, 100],
  ["frequencyTimeout", "frequency_timeout_ms", 300, 5000],
  ["appCompletionTimeout", "app_completion_timeout_ms", 500, 5000],
  ["sourcePlacement", "source_placement", 1, 8],
  ["sourceNiceSuppression", "source_nice_suppression", 0, 40],
  ["launcherPlacement", "launcher_placement", 1, 7],
  ["rasterPlacement", "raster_placement", 1, 7],
  ["resmgrPlacement", "resmgr_placement", 1, 7],
  ["fencePlacement", "fence_placement", 1, 7],
  ["systemuiCriticalPlacement", "systemui_critical_placement", 1, 7],
  ["systemuiMaintenancePlacement", "systemui_maintenance_placement", 1, 7],
  ["systemuiTimeout", "systemui_timeout_ms", 300, 5000],
  ["boostDuration", "boost_duration_ms", 1, 1000],
  ["uclampRaster", "uclamp_raster", 0, 1024],
  ["uclampUi", "uclamp_ui", 0, 1024],
  ["uclampRust", "uclamp_rust", 0, 1024],
  ["uclampResmgr", "uclamp_resmgr", 0, 1024],
];

const TOGGLE_SCHEMA = [
  ["masterToggle", "master_policy", "master"],
  ["sourceToggle", "source_policy", "source"],
  ["auxToggle", "auxiliary_policy", "auxiliary"],
  ["launcherToggle", "launcher_policy", "launcher"],
  ["systemuiToggle", "systemui_policy", "systemui"],
  ["frequencyToggle", "frequency_policy", "frequency"],
];

export class SettingsView {
  constructor(onDirtyChange) {
    this.onDirtyChange = onDirtyChange;
    this.baseline = "";
  }

  mount() {
    $$("[data-page='settings'] input, [data-page='settings'] select").forEach((control) => {
      control.addEventListener("input", () => this.reportDirty());
      control.addEventListener("change", () => this.reportDirty());
    });
  }

  render(status) {
    this.renderPlacementOptions(status);
    for (const [id, key] of TOGGLE_SCHEMA) setChecked(id, status[key] !== "disabled");
    for (const [id, key] of FIELD_SCHEMA) setValue(id, status[key]);
    this.baseline = this.snapshot();
    this.reportDirty();
  }

  renderPlacementOptions(status) {
    const options = placementOptions(status);
    for (const select of $$('select[data-placement]')) {
      const previous = select.value;
      const allowed = select.dataset.placement === "source" ? null : new Set([1, 2, 3, 4, 5, 6, 7]);
      select.replaceChildren(...options.filter((item) => !allowed || allowed.has(item.value)).map((item) => {
        const option = document.createElement("option");
        option.value = String(item.value);
        option.textContent = `${item.label} · ${item.cpus}`;
        return option;
      }));
      if (previous) select.value = previous;
    }
  }

  reset() {
    if (!this.baseline) return;
    const values = JSON.parse(this.baseline);
    for (const [id, value] of Object.entries(values)) {
      const control = document.getElementById(id);
      if (control.type === "checkbox") control.checked = value;
      else control.value = value;
    }
    this.reportDirty();
  }

  isDirty() {
    return Boolean(this.baseline) && this.snapshot() !== this.baseline;
  }

  configurationTokens() {
    const tokens = [];
    for (const [id, , key] of TOGGLE_SCHEMA) tokens.push(`${key}=${$("#" + id).checked ? "enabled" : "disabled"}`);
    for (const [id, key, minimum, maximum, allowed] of FIELD_SCHEMA) {
      const control = $("#" + id);
      const value = Number(control.value);
      if (!Number.isInteger(value) || value < minimum || value > maximum ||
          (allowed && !allowed.includes(value))) {
        const label = control.closest("label")?.querySelector("span")?.textContent || key;
        throw new Error(`${label}超出范围`);
      }
      tokens.push(`${key}=${value}`);
    }
    return tokens;
  }

  snapshot() {
    const values = {};
    for (const [id] of TOGGLE_SCHEMA) values[id] = $("#" + id).checked;
    for (const [id] of FIELD_SCHEMA) values[id] = $("#" + id).value;
    return JSON.stringify(values);
  }

  reportDirty() {
    this.onDirtyChange?.(this.isDirty());
  }
}
