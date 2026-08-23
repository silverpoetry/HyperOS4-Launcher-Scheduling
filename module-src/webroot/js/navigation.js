import { $, $$ } from "./dom.js";

function isInteractive(target) {
  return Boolean(target.closest("button,input,select,pre,.thread-table"));
}

export class SwipeNavigation {
  constructor({ pageCount, onPageChange }) {
    this.pageCount = pageCount;
    this.onPageChange = onPageChange;
    this.index = 0;
    this.drag = null;
    this.shell = $("#swipeShell");
    this.track = $("#pageTrack");
  }

  mount() {
    $$(".nav-tab").forEach((tab) => tab.addEventListener("click", () => this.setPage(Number(tab.dataset.index))));
    this.shell.addEventListener("touchstart", (event) => this.onTouchStart(event), { passive: true });
    this.shell.addEventListener("touchmove", (event) => this.onTouchMove(event), { passive: false });
    this.shell.addEventListener("touchend", () => this.onTouchEnd(), { passive: true });
    this.shell.addEventListener("touchcancel", () => this.onTouchEnd(), { passive: true });
    this.setPage(0, false);
  }

  setPage(index, animate = true) {
    this.index = Math.max(0, Math.min(this.pageCount - 1, index));
    this.track.classList.toggle("no-transition", !animate);
    this.shell.style.setProperty("--page-index", String(this.index));
    this.shell.style.setProperty("--drag-offset", "0px");
    $$(".nav-tab").forEach((tab, tabIndex) => tab.classList.toggle("active", tabIndex === this.index));
    requestAnimationFrame(() => this.track.classList.remove("no-transition"));
    this.onPageChange?.(this.index);
  }

  onTouchStart(event) {
    if (event.touches.length !== 1 || isInteractive(event.target)) return;
    const touch = event.touches[0];
    this.drag = { x: touch.clientX, y: touch.clientY, started: performance.now(), offset: 0, horizontal: false };
    this.track.classList.add("dragging");
  }

  onTouchMove(event) {
    if (!this.drag || event.touches.length !== 1) return;
    const touch = event.touches[0];
    let dx = touch.clientX - this.drag.x;
    const dy = touch.clientY - this.drag.y;
    if (!this.drag.horizontal) {
      if (Math.abs(dx) < 8) return;
      if (Math.abs(dx) <= Math.abs(dy) * 1.15) {
        this.cancelDrag();
        return;
      }
      this.drag.horizontal = true;
    }
    if ((this.index === 0 && dx > 0) || (this.index === this.pageCount - 1 && dx < 0)) dx *= 0.25;
    this.drag.offset = dx;
    this.shell.style.setProperty("--drag-offset", `${dx}px`);
    event.preventDefault();
  }

  onTouchEnd() {
    if (!this.drag) return;
    const threshold = Math.min(window.innerWidth * 0.18, 150);
    const velocity = Math.abs(this.drag.offset) / Math.max(1, performance.now() - this.drag.started);
    let target = this.index;
    if (this.drag.horizontal && (Math.abs(this.drag.offset) > threshold || velocity > 0.55)) {
      target += this.drag.offset < 0 ? 1 : -1;
    }
    this.cancelDrag();
    this.setPage(target);
  }

  cancelDrag() {
    this.drag = null;
    this.track.classList.remove("dragging");
    this.shell.style.setProperty("--drag-offset", "0px");
  }
}
