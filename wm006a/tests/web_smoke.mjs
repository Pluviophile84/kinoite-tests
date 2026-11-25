import assert from "node:assert/strict";
import { pathToFileURL } from "node:url";

const modulePath = process.env.PLAYWRIGHT_MODULE;
const { chromium } = await import(modulePath ? pathToFileURL(modulePath).href : "playwright");
const browser = await chromium.launch({
  executablePath: process.env.CHROME_BIN,
  chromiumSandbox: true,
  headless: true,
});
const address = process.argv[2] ?? "http://127.0.0.1:4173";
const commits = [];
const frameDelays = [];

function median(values) {
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.floor(sorted.length / 2)].toFixed(1);
}

try {
  for (let run = 0; run < 5; run += 1) {
    const page = await browser.newPage({ viewport: { width: 1024, height: 768 } });
    await page.goto(address);
    await page.getByRole("checkbox", { name: "Select LAB-100" }).waitFor();
    assert.equal(await page.locator("tbody tr").count(), 100);
    commits.push(await page.evaluate(() => performance.getEntriesByName("roster-rendered")[0].startTime));

    if (run === 0) {
      const first = page.getByRole("checkbox", { name: "Select LAB-001" });
      const last = page.getByRole("checkbox", { name: "Select LAB-100" });
      await first.check();
      await last.check();
      assert.equal(await page.getByText("2 selected").count(), 1);
      await page.getByRole("button", { name: "Clear" }).click();
      assert.equal(await page.getByText("0 selected").count(), 1);
      await page.getByRole("button", { name: "Test local IPC" }).click();
      assert.equal(await page.getByRole("status").innerText(), "IPC requires the desktop application.");
      for (let sample = 0; sample < 15; sample += 1) {
        const result = await first.evaluate((checkbox) => new Promise((resolve) => {
          const expected = !checkbox.checked;
          const start = performance.now();
          checkbox.click();
          requestAnimationFrame(() => requestAnimationFrame(() => {
            resolve({ matches: checkbox.checked === expected, ms: performance.now() - start });
          }));
        }));
        assert.equal(result.matches, true);
        frameDelays.push(result.ms);
      }
    }
    await page.close();
  }
  console.log(`Chromium ${browser.version()}: 100 rows, first/last selection, clear, and desktop-required status passed.`);
  console.log(`Navigation to React commit (5 pages): median ${median(commits)} ms, range ${Math.min(...commits).toFixed(1)}–${Math.max(...commits).toFixed(1)} ms.`);
  console.log(`Scripted selection to second animation callback (15 samples): median ${median(frameDelays)} ms, range ${Math.min(...frameDelays).toFixed(1)}–${Math.max(...frameDelays).toFixed(1)} ms.`);
} finally {
  await browser.close();
}
