/**
 * Sideways-scrolling controls (segmented controls, tab rows) hide their scrollbar, so nothing says
 * they scroll. This sets data-overflow="start|end|both" on them while content is cut off on that
 * side; the CSS turns it into an edge fade. Nothing is set when the control fits.
 */
const SELECTOR = ".seg, .admin-tabs";

function update(el: HTMLElement) {
  const max = el.scrollWidth - el.clientWidth;
  const start = el.scrollLeft > 1;
  const end = max - el.scrollLeft > 1;
  const next = max <= 1 ? null : start && end ? "both" : start ? "start" : end ? "end" : null;
  if (next) {
    if (el.dataset.overflow !== next) el.dataset.overflow = next;
  } else if (el.dataset.overflow) {
    delete el.dataset.overflow;
  }
}

export function installScrollFade() {
  if (typeof document === "undefined") return;
  const seen = new WeakSet<Element>();
  const resize = new ResizeObserver((entries) => entries.forEach((e) => update(e.target as HTMLElement)));
  let queued = false;
  const scan = () => {
    queued = false;
    document.querySelectorAll<HTMLElement>(SELECTOR).forEach((el) => {
      if (!seen.has(el)) {
        seen.add(el);
        resize.observe(el);
      }
      update(el);
    });
  };
  const schedule = () => {
    if (!queued) {
      queued = true;
      requestAnimationFrame(scan);
    }
  };
  // scroll does not bubble: listen in the capture phase
  document.addEventListener("scroll", (e) => {
    const el = e.target;
    if (el instanceof HTMLElement && el.matches(SELECTOR)) update(el);
  }, true);
  const start = () => {
    new MutationObserver(schedule).observe(document.body, { childList: true, subtree: true, characterData: true });
    window.addEventListener("resize", schedule);
    schedule();
  };
  if (document.body) start();
  else document.addEventListener("DOMContentLoaded", start);
}
