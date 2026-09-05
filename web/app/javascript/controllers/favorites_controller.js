import { Controller } from "@hotwired/stimulus";

// Favorites page: note ids live in localStorage; fetch each card fragment
// from the server (which renders from the daemon-backed cache).
export default class extends Controller {
  static targets = ["list", "empty"];

  async connect() {
    const ids = window.Birdwatch?.favorites?.() || [];
    if (ids.length === 0) return;

    this.emptyTarget?.remove?.();
    const { isFavorite } = window.Birdwatch || {};
    for (const id of ids) {
      const res = await fetch(`/notes/${encodeURIComponent(id)}/card`);
      if (!res.ok) continue; // note no longer known — id kept for the daemon
      const html = await res.text();
      this.listTarget.insertAdjacentHTML("beforeend", html);
    }
    // reflect stored favorite state on the stars
    this.listTarget.querySelectorAll("[data-fav-toggle]").forEach((btn) => {
      if (isFavorite) btn.dataset.fav = isFavorite(btn.dataset.favToggle) ? "1" : "0";
    });
    // hide the empty state only if something actually rendered
    if (!this.listTarget.querySelector(".note-card") && this.hasEmptyTarget) {
      this.listTarget.appendChild(this.emptyTarget);
    }
  }
}
