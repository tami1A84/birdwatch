import { Controller } from "@hotwired/stimulus";

// FAB → compose dialog.
export default class extends Controller {
  open() {
    const dialog = document.getElementById("compose-dialog");
    if (!dialog) return;
    dialog.show();
    requestAnimationFrame(() => {
      const field = dialog.querySelector("[data-compose-target='text']");
      if (field) field.focus();
    });
  }

  close() {
    document.getElementById("compose-dialog")?.close();
  }
}
