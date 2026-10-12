#!/usr/bin/env node
// UI evidence: screenshots of the main screens on an iPhone-sized viewport
// (light + dark), plus a video of tab switching and opening a note.
//
// Usage: node script/capture-ui.mjs [--base http://127.0.0.1:3017] [--out /tmp/bw-ui] [--label before]
// Needs a running server and Playwright (npm:playwright via mise) + /usr/bin/chromium.
import { createRequire } from "node:module";
import { mkdirSync } from "node:fs";

const require = createRequire(import.meta.url);
const arg = (name, fallback) => {
  const i = process.argv.indexOf(`--${name}`);
  return i > 0 ? process.argv[i + 1] : fallback;
};
const base = arg("base", "http://127.0.0.1:3017");
const out = arg("out", "/tmp/bw-ui");
const label = arg("label", "now");
mkdirSync(out, { recursive: true });

let playwright;
for (const p of ["playwright", `${process.env.HOME}/.local/share/mise/installs/npm-playwright/latest/node_modules/playwright`]) {
  try { playwright = require(p); break; } catch {}
}
if (!playwright) {
  console.error("playwright not found: run `mise use -g npm:playwright` first");
  process.exit(2);
}

process.on("unhandledRejection", (e) => { console.error(e); process.exit(1); });
const browser = await playwright.chromium.launch({ executablePath: "/usr/bin/chromium" });
const device = { viewport: { width: 390, height: 844 }, deviceScaleFactor: 2, isMobile: true, hasTouch: true };
const pages = [["home", "/"], ["follows", "/follows"], ["relays", "/relays"], ["settings", "/settings"], ["search", "/search"], ["favorites", "/favorites"]];
const report = { shots: [], errors: [], warnings: [] };

for (const scheme of ["light", "dark"]) {
  const ctx = await browser.newContext({ ...device, colorScheme: scheme });
  const page = await ctx.newPage();
  page.on("console", (m) => m.type() === "error" && report.errors.push(`${scheme} ${page.url()} ${m.text()}`));
  page.on("pageerror", (e) => report.errors.push(`${scheme} ${page.url()} ${e.message}`));
  for (const [name, path] of pages) {
    await page.goto(base + path, { waitUntil: "domcontentloaded" });
    await page.waitForTimeout(500);
    const f = `${out}/${label}-${scheme}-${name}.png`;
    await page.screenshot({ path: f });
    report.shots.push(f);
  }
  // Note detail needs a responsive nostrd backend. Skip it when the daemon
  // cannot answer rather than hiding the rest of the UI evidence.
  if (process.argv.includes("--note")) {
    await page.goto(base + "/", { waitUntil: "domcontentloaded" });
    const href = await page.locator("a[href^='/notes/']").first().getAttribute("href").catch(() => null);
    if (href) {
      try {
        await page.goto(base + href, { waitUntil: "domcontentloaded", timeout: 7000 });
        await page.waitForTimeout(500);
        const f = `${out}/${label}-${scheme}-note.png`;
        await page.screenshot({ path: f });
        report.shots.push(f);
      } catch (e) { report.warnings.push(`${scheme} note detail unavailable: ${e.message.split("\n")[0]}`); }
    }
  }
  await ctx.close();
}

// motion: tabs + note push, recorded
const vctx = await browser.newContext({ ...device, colorScheme: "light", recordVideo: { dir: out, size: { width: 390, height: 844 } } });
const vp = await vctx.newPage();
await vp.goto(base + "/", { waitUntil: "domcontentloaded" });
await vp.waitForTimeout(600);
await vp.mouse.wheel(0, 900);
await vp.waitForTimeout(700);
for (const sel of ["フォロー", "リレー", "設定", "ホーム"]) {
  const tab = vp.locator(`[data-tab-label='${sel}'], md-navigation-tab[label='${sel}']`).first();
  if (await tab.count()) { await tab.click(); await vp.waitForLoadState("domcontentloaded"); await vp.waitForTimeout(700); }
}
// Verify the actual compose action without submitting a public post.
await vp.locator(".compose-fab").click();
await vp.waitForTimeout(500);
report.composeOpened = await vp.locator("#compose-dialog").evaluate((el) => el.open).catch(() => false);
await vp.screenshot({ path: `${out}/${label}-light-compose.png` });
report.shots.push(`${out}/${label}-light-compose.png`);
const video = await vp.video()?.path();
await vctx.close();
report.video = video;
await browser.close();
console.log(JSON.stringify(report, null, 2));
