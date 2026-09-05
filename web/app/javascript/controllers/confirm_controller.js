import { Controller } from "@hotwired/stimulus";

// data-confirm forms replay their submit through the shared confirmation
// dialog (destructive actions: delete note, unfollow, relay remove, lock).
export default class extends Controller {
  connect() {
    this.pending = null;
    this.dialog = document.getElementById("confirm-dialog");
    this.onSubmit = this.onSubmit.bind(this);
    document.addEventListener("submit", this.onSubmit, true);
  }

  disconnect() {
    document.removeEventListener("submit", this.onSubmit, true);
  }

  onSubmit(event) {
    const form = event.target;
    if (!form.matches("[data-confirm]")) return;
    if (form.dataset.confirmed === "1") {
      delete form.dataset.confirmed;
      return;
    }
    event.preventDefault();
    event.stopPropagation();
    this.pending = { form, submitter: event.submitter };
    const title = form.dataset.confirmTitle || "確認";
    const text = form.dataset.confirm || "実行しますか？";
    if (this.dialog) {
      this.dialog.querySelector("[data-confirm-title]").textContent = title;
      this.dialog.querySelector("[data-confirm-text]").textContent = text;
      this.dialog.show();
    } else if (window.confirm(text)) {
      this.replay();
    }
  }

  submit() {
    if (this.dialog) this.dialog.close();
    this.replay();
  }

  cancel() {
    this.pending = null;
    if (this.dialog) this.dialog.close();
  }

  replay() {
    const { form, submitter } = this.pending || {};
    this.pending = null;
    if (!form) return;
    form.dataset.confirmed = "1";
    if (submitter) form.requestSubmit(submitter);
    else form.requestSubmit();
  }
}
