import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const { chromium } = require('playwright');

const docs = [
  'whitepaper',
  'compendium',
  'barbell_note',
  'research_frontier',
];

const root = path.resolve(import.meta.dirname, '..');
const browser = await chromium.launch({
  headless: true,
  executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
});

try {
  const page = await browser.newPage({ viewport: { width: 1440, height: 1000 } });
  for (const name of docs) {
    const source = path.join(root, 'docs', `${name}.html`);
    const output = path.join(root, 'docs', `${name}.pdf`);
    await page.goto(pathToFileURL(source).href, { waitUntil: 'networkidle' });
    await page.emulateMedia({ media: 'print', colorScheme: 'light' });
    await page.pdf({
      path: output,
      format: 'Letter',
      printBackground: true,
      preferCSSPageSize: true,
      margin: { top: '0', right: '0', bottom: '0', left: '0' },
    });
    console.log(`Exported ${path.relative(root, output)}`);
  }
} finally {
  await browser.close();
}
