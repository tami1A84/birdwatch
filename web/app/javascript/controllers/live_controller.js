import { Controller } from "@hotwired/stimulus";

// Live daemon frames over SSE (/live). On the home feed it prepends fresh
// kind-1 notes (fetched as HTML fragments so rendering stays server-side);
// on a note detail page it refreshes the comments/reactions section when a
// live comment (kind 1111) or reaction (kind 7) targets the open note.
export default class extends Controller {
  static values = { thread: String };

  connect() {
    this.source = new EventSource("/live");
    this.source.onmessage = (e) => {
      let frame;
      try {
        frame = JSON.parse(e.data);
      } catch {
        return;
      }
      this.handle(frame);
    };
  }

  disconnect() {
    if (this.source) this.source.close();
  }

  handle(frame) {
    if (frame.ev === "event") {
      this.onEvent(frame.event);
    } else if (frame.ev === "profiles") {
      this.onProfiles(frame.profiles || []);
    } else if (frame.ev === "error" && frame.message) {
      window.Birdwatch?.toast?.(frame.message);
    }
  }

  async onEvent(event) {
    if (!event) return;
    if (event.kind === 1) {
      await this.prependCard(event);
    } else if (event.kind === 1111 || event.kind === 7) {
      await this.refreshSection(event);
    }
  }

  async prependCard(event) {
    const feed = this.element.querySelector("[data-feed]") || (this.element.classList.contains("feed") ? this.element : null);
    if (!feed) return;
    if (feed.querySelector(`[data-note-id="${event.id}"]`)) return;

    const res = await fetch(`/notes/${encodeURIComponent(event.id)}/card`);
    if (!res.ok) return;
    const html = await res.text();
    feed.insertAdjacentHTML("afterbegin", html);
    const card = feed.firstElementChild;
    if (card) card.classList.add("note-card--enter");
  }

  async refreshSection(event) {
    const threadId = this.threadValue;
    if (!threadId) return;
    const tags = event.tags || [];
    const targets = tags.some((t) => Array.isArray(t) && (t[0] === "E" || t[0] === "e") && t[1] === threadId);
    if (!targets) return;

    const section = document.querySelector("[data-thread-section]");
    if (!section) return;
    const res = await fetch(`/notes/${encodeURIComponent(threadId)}/section`);
    if (!res.ok) return;
    section.innerHTML = await res.text();
    // re-bind favorite stars rendered by the fragment
    document.querySelectorAll("[data-fav-toggle]").forEach((btn) => {
      btn.dataset.fav = window.Birdwatch?.isFavorite?.(btn.dataset.favToggle) ? "1" : "0";
    });
  }

  onProfiles(profiles) {
    for (const p of profiles) {
      if (!p || !p.pubkey) continue;
      const name = p.display_name || p.name || "";
      if (!name) continue;
      document
        .querySelectorAll(`[data-pubkey="${p.pubkey}"] [data-profile-name]`)
        .forEach((el) => { el.textContent = name; });
    }
  }
}
