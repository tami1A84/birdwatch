import { Controller } from "@hotwired/stimulus";

// FAB → compose dialog. Also drives the photo picker preview: the picked
// file shows as a rounded thumbnail with a quiet remove button until the
// form submits (the upload itself rides the multipart POST — see
// NotesController#append_uploaded_image).
const IMAGE_OK = /^image\/(png|jpeg|gif|webp)$/;
const MAX_IMAGE = 10 * 1024 * 1024;

export default class extends Controller {
  connect() {
    this.#bind();
  }

  open() {
    const dialog = document.getElementById("compose-dialog");
    if (!dialog) return;
    dialog.show();
    this.#resetPreview(dialog);
    requestAnimationFrame(() => {
      const field = dialog.querySelector("[data-compose-target='text']");
      if (field) field.focus();
    });
  }

  close() {
    document.getElementById("compose-dialog")?.close();
  }

  // Bind once: the dialog lives outside this controller's element (the FAB),
  // so Stimulus actions can't reach it — plain listeners instead.
  #bound = false;
  #bind() {
    if (this.#bound) return;
    this.#bound = true;
    const dialog = document.getElementById("compose-dialog");
    const input = dialog?.querySelector("[data-compose-target='image']");
    if (!dialog || !input) return;
    input.addEventListener("change", () =>
      this.#showPreview(dialog, input.files?.[0]));
    dialog.querySelector("[data-compose-clear]")?.addEventListener("click", () => {
      input.value = "";
      this.#resetPreview(dialog);
    });
  }

  #showPreview(dialog, file) {
    const row = dialog.querySelector("[data-compose-preview-row]");
    const input = dialog.querySelector("[data-compose-target='image']");
    if (!row || !input) return;
    if (!file) return;
    if (!IMAGE_OK.test(file.type) || file.size > MAX_IMAGE) {
      input.value = "";
      window.Birdwatch?.toast("PNG / JPEG / GIF / WebP（10MBまで）");
      return;
    }
    if (this.#url) URL.revokeObjectURL(this.#url);
    this.#url = URL.createObjectURL(file);
    row.querySelector("[data-compose-preview]").src = this.#url;
    row.querySelector("[data-compose-name]").textContent = file.name;
    row.hidden = false;
  }

  #url = null;
  #resetPreview(dialog) {
    const row = dialog.querySelector("[data-compose-preview-row]");
    if (!row) return;
    row.hidden = true;
    if (this.#url) {
      URL.revokeObjectURL(this.#url);
      this.#url = null;
    }
  }
}
