import { Controller } from "@hotwired/stimulus";

// Bottom navigation: highlight the active tab (or none) and navigate on
// activation. md-navigation-tab has no href of its own, so the tab carries
// data-href and this controller navigates on navigation-bar-activated.
export default class extends Controller {
  connect() {
    const bar = this.element.querySelector("md-navigation-bar");
    if (!bar) return;
    bar.activeIndex = Number(this.element.dataset.navIndexValue ?? -1);
    bar.addEventListener("navigation-bar-activated", (e) => {
      const tab = e.detail?.tab;
      const href = tab?.dataset?.href;
      if (href && new URL(href, window.location.origin).pathname !== window.location.pathname) {
        window.location.assign(href);
      }
    });
  }
}
