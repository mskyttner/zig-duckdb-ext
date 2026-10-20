#!/usr/bin/env node
// Loads a built wasm32-emscripten SIDE_MODULE extension into a real duckdb-wasm engine's
// browser bundle, inside a real headless browser (Playwright/Chromium), and runs real SQL
// through it. The Node-bindings counterpart to this is verify_wasm_load.cjs; this one closes
// the gap that one can't: a real browser's fetch/Worker/dlopen path, not Node's.
//
//   node verify_wasm_load_browser.cjs <engine-dist-dir> <extension-wasm-path>
//
// `engine-dist-dir` is a duckdb-wasm `packages/duckdb-wasm/dist` directory (what
// fetch_engine.sh extracts) — needs its browser bundle files (`duckdb-mvp.wasm`,
// `duckdb-browser-mvp.worker.js`, `duckdb-browser.mjs`), not the Node ones.
//
// Unlike verify_wasm_load.cjs, the static server here runs in-process with this script:
// the duckdb-wasm engine runs inside the browser's own separate process, driven remotely
// by Playwright, so there's no shared event loop to deadlock (that problem — see
// verify_wasm_load.cjs's own comment — is specific to the Node "blocking" bindings running
// in the same process as whatever tries to serve their fetches).
//
// Needs Chromium installed (`npx playwright install chromium`, or `--with-deps chromium`
// on a bare CI runner) — not done here, since it's a slow, one-time, environment-wide step.
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');

function fail(msg) {
    console.error(`FAILED: ${msg}`);
    process.exit(1);
}

async function main() {
    const [distDirArg, extPathArg] = process.argv.slice(2);
    if (!distDirArg || !extPathArg) {
        console.error('usage: verify_wasm_load_browser.cjs <engine-dist-dir> <extension-wasm-path>');
        process.exit(2);
    }
    const distDir = path.resolve(distDirArg);
    const extPath = path.resolve(extPathArg);
    const extBytes = fs.readFileSync(extPath);
    const extBase = path.basename(extPath).replace(/\.duckdb_extension\.wasm$/, '');
    if (extBase === path.basename(extPath)) {
        fail(`${extPath} does not end in .duckdb_extension.wasm`);
    }

    const browserDir = path.join(__dirname, 'browser');
    const engineFiles = ['duckdb-mvp.wasm', 'duckdb-browser-mvp.worker.js', 'duckdb-browser.mjs'];
    const mime = { '.html': 'text/html', '.js': 'application/javascript', '.mjs': 'application/javascript', '.wasm': 'application/wasm' };

    const server = http.createServer((req, res) => {
        const url = req.url.split('?')[0];
        if (url.endsWith('.duckdb_extension.wasm')) {
            res.writeHead(200, { 'Content-Type': 'application/wasm', 'Access-Control-Allow-Origin': '*' });
            res.end(extBytes);
            return;
        }
        const name = url === '/' ? '/index.html' : url;
        const fromEngine = engineFiles.includes(name.slice(1));
        const filePath = fromEngine ? path.join(distDir, name) : path.join(browserDir, name);
        fs.readFile(filePath, (err, data) => {
            if (err) {
                res.writeHead(404);
                res.end('not found: ' + filePath);
                return;
            }
            res.writeHead(200, { 'Content-Type': mime[path.extname(name)] || 'application/octet-stream', 'Access-Control-Allow-Origin': '*' });
            res.end(data);
        });
    });
    const port = await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.listen(0, () => resolve(server.address().port));
    });

    const { chromium } = require('playwright');
    const browser = await chromium.launch();
    try {
        const page = await browser.newPage();
        const consoleErrors = [];
        page.on('pageerror', err => consoleErrors.push(err.message));

        await page.goto(`http://127.0.0.1:${port}/index.html?name=${encodeURIComponent(extBase)}`, { waitUntil: 'load' });
        await page.waitForFunction(() => document.getElementById('result').textContent !== 'PENDING', { timeout: 30000 });
        const resultText = await page.textContent('#result');

        if (resultText.startsWith('ERROR')) {
            fail(`page reported: ${resultText}${consoleErrors.length ? '\n  page errors: ' + consoleErrors.join('; ') : ''}`);
        }

        const result = JSON.parse(resultText);
        if (result.hello?.greeting !== 'Hello, ci!') {
            fail(`zig_hello('ci') returned ${JSON.stringify(result.hello)}, expected {"greeting":"Hello, ci!"}`);
        }
        if (result.sum !== 5) {
            fail(`zig_add_numbers(2, 3) returned ${JSON.stringify(result.sum)}, expected 5`);
        }
        console.log(`zig_hello('ci') = ${JSON.stringify(result.hello)}`);
        console.log(`zig_add_numbers(2, 3) = ${result.sum}`);
        console.log(`verify_wasm_load_browser: PASSED — ${extBase} loads and runs in a real headless browser against ${distDir}`);
    } finally {
        await browser.close();
        server.close();
    }
}

main().catch(e => {
    console.error('FATAL:', e && e.stack ? e.stack : e);
    process.exit(1);
});
