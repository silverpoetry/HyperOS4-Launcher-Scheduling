import { $ } from "./dom.js";

let snackbarTimer = 0;

export function notify(message, error = false) {
  clearTimeout(snackbarTimer);
  const snackbar = $("#snackbar");
  $("span", snackbar).textContent = message;
  snackbar.classList.toggle("error", error);
  snackbar.classList.add("show");
  snackbarTimer = window.setTimeout(() => snackbar.classList.remove("show"), 2400);
}

export function setBusy(active, label = "处理中") {
  const overlay = $("#busy");
  overlay.classList.toggle("visible", active);
  overlay.setAttribute("aria-hidden", String(!active));
  $("span", overlay).textContent = label;
}
