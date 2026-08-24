import { $, $$, setChecked, setValue } from "./dom.js";

const FIELD_SCHEMA = [
  ["frequencyPercent", "frequency_percent", 40, 100],
  ["frequencyTimeout", "frequency_timeout_ms", 300, 5000],
  ["appFallback", "app_fallback_ms", 500, 5000],
  ["launcherPlacement", "launcher_placement", 1, 6],
  ["rasterPlacement", "raster_placement", 1, 6],
  ["resmgrPlacement", "resmgr_placement", 1, 6],
  ["fencePlacement", "fence_placement", 1, 6],
  ["systemuiCriticalPlacement", "systemui_critical_placement", 1, 6],
  ["systemuiMaintenancePlacement", "systemui_maintenance_placement", 1, 6],
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
    for (const [id, key] of TOGGLE_SCHEMA) setChecked(id, status[key] !== "disabled");
    for (const [id, key] of FIELD_SCHEMA) setValue(id, status[key]);
    this.baseline = this.snapshot();
    this.reportDirty();
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
    for (const [id, key, minimum, maximum] of FIELD_SCHEMA) {
      const control = $("#" + id);
      const value = Number(control.value);
      if (!Number.isInteger(value) || value < minimum || value > maximum) {
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
