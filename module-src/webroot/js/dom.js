export const $ = (selector, root = document) => root.querySelector(selector);
export const $$ = (selector, root = document) => Array.from(root.querySelectorAll(selector));

export function setText(id, value, fallback = "—") {
  const node = document.getElementById(id);
  if (node) node.textContent = value || fallback;
}

export function setValue(id, value) {
  const node = document.getElementById(id);
  if (node && value !== undefined && value !== null) node.value = String(value);
}

export function setChecked(id, checked) {
  const node = document.getElementById(id);
  if (node) node.checked = Boolean(checked);
}
