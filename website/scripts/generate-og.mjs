import { chromium } from "playwright";
import { fileURLToPath } from "node:url";

const source = new URL("../og-image.html", import.meta.url);
const output = fileURLToPath(new URL("../public/og.png", import.meta.url));
const browser = await chromium.launch({ headless: true });

try {
	const page = await browser.newPage({
		viewport: { width: 1200, height: 630 },
		deviceScaleFactor: 1,
	});
	await page.goto(source.href);
	await page.evaluate(() => document.fonts.ready);
	await page.screenshot({ path: output });
	console.log(`Generated ${output}`);
} finally {
	await browser.close();
}
