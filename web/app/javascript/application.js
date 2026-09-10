// birdwatch — entry point
import "@material/web/button/filled-button.js";
import "@material/web/button/outlined-button.js";
import "@material/web/button/text-button.js";
import "@material/web/button/filled-tonal-button.js";
import "@material/web/iconbutton/icon-button.js";
import "@material/web/fab/fab.js";
import "@material/web/dialog/dialog.js";
import "@material/web/labs/navigationbar/navigation-bar.js";
import "@material/web/labs/navigationtab/navigation-tab.js";

import { Application } from "@hotwired/stimulus";
import LiveController from "./controllers/live_controller";
import ComposeController from "./controllers/compose_controller";
import ConfirmController from "./controllers/confirm_controller";
import NavController from "./controllers/nav_controller";
import FavoritesController from "./controllers/favorites_controller";

const app = Application.start();
app.register("live", LiveController);
app.register("compose", ComposeController);
app.register("confirm", ConfirmController);
app.register("nav", NavController);
app.register("favorites", FavoritesController);

// ----- shared helpers (toast + favorites) ---------------------------------

export function toast(message) {
  const bar = document.getElementById("app-toast");
  if (!bar) return;
  bar.textContent = message;
  bar.classList.add("toast--show");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => bar.classList.remove("toast--show"), 3500);
}

const FAV_KEY = "birdwatch.favorites";

function favorites() {
  try {
    const raw = JSON.parse(localStorage.getItem(FAV_KEY) || "[]");
    return Array.isArray(raw) ? raw.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
}

function isFavorite(id) {
  return favorites().includes(id);
}

function toggleFavorite(id) {
  const list = favorites();
  const i = list.indexOf(id);
  if (i >= 0) {
    list.splice(i, 1);
    toast("お気に入りから削除しました");
  } else {
    list.unshift(id);
    if (list.length > 200) list.pop();
    toast("お気に入りに追加しました");
  }
  localStorage.setItem(FAV_KEY, JSON.stringify(list));
  document.querySelectorAll(`[data-fav-toggle="${id}"]`).forEach((btn) => {
    btn.dataset.fav = isFavorite(id) ? "1" : "0";
  });
  return i < 0;
}

window.Birdwatch = { toast, favorites, isFavorite, toggleFavorite };

// star buttons on note detail (delegated — the section is replaced live)
document.addEventListener("click", (e) => {
  const btn = e.target.closest("[data-fav-toggle]");
  if (btn) toggleFavorite(btn.dataset.favToggle);
});

// flash → snackbar
document.querySelectorAll("[data-toast]").forEach((el) => {
  toast(el.dataset.toast);
});

// favorite stars reflect storage on load
document.querySelectorAll("[data-fav-toggle]").forEach((btn) => {
  btn.dataset.fav = isFavorite(btn.dataset.favToggle) ? "1" : "0";
});

// broken avatar images → person fallback (capture phase: error
// doesn't bubble)
document.addEventListener("error", (e) => {
  const img = e.target;
  if (img instanceof HTMLImageElement) {
    img.closest(".avatar")?.classList.add("avatar--fallback");
  }
}, true);

// ----- back = reverse transition -------------------------------------------
// Cross-document view transitions: tag history traversals so the CSS can
// play the forward transition in reverse (see application.css). Note pages
// additionally tag "push": opening a note plays the iOS-style slide-from-
// right instead of the default M3 fade.
const NOTE_PAGE = /\/notes\//;

document.addEventListener("pageswap", (e) => {
  if (!e.viewTransition) return;
  const type = e.activation?.navigationType;
  const dest = e.activation?.entryResult?.url;
  const push = NOTE_PAGE.test(new URL(dest ?? "", location.href).pathname) ||
    (type === "traverse" && NOTE_PAGE.test(location.pathname));
  if (type === "traverse") {
    e.viewTransition.types.add("back");
    sessionStorage.setItem("birdwatch.vt", "back");
  } else {
    sessionStorage.setItem("birdwatch.vt", "forward");
  }
  sessionStorage.setItem("birdwatch.push", push ? "1" : "0");
  if (push) e.viewTransition.types.add("push");
});

document.addEventListener("pagereveal", (e) => {
  if (!e.viewTransition) return;
  if (sessionStorage.getItem("birdwatch.vt") === "back") {
    e.viewTransition.types.add("back");
    sessionStorage.setItem("birdwatch.vt", "forward");
  }
  if (sessionStorage.getItem("birdwatch.push") === "1") {
    e.viewTransition.types.add("push");
    sessionStorage.removeItem("birdwatch.push");
  }
});
