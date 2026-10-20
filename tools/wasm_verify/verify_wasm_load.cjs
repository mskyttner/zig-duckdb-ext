#!/usr/bin/env node
// Loads a built wasm32-emscripten SIDE_MODULE extension into a real duckdb-wasm-family
// engine (official duckdb-wasm or any fork — haybarn-wasm included — as long as it ships
// the same `dist/duckdb-node-blocking.cjs` layout) and runs real SQL through it.
//
//   node verify_wasm_load.cjs <engine-dist-dir> <extension-wasm-path>
//
// `engine-dist-dir` is a duckdb-wasm `packages/duckdb-wasm/dist` directory (what
// fetch_engine.sh extracts). The extension's own filename, minus `.duckdb_extension.wasm`,
// is the name `LOAD`ed.
//
// Serves the extension itself from a throwaway local HTTP server and points
// `custom_extension_repository` at it — the documented, working deployment path (see
// docs/v2-migration-plan.md's WASM section). `registerFileBuffer` + direct-path `LOAD`
// is not used here: it hangs in this exact binding today, a known upstream bug
// (duckdb/duckdb-wasm#2279), not a defect in the built extension.
//
// The server runs as its own OS process (serve_extension.cjs), not in-process with this
// script — confirmed directly, the hard way: the Node "blocking" bindings fetch an
// extension via a worker_threads Worker while the main thread blocks on `Atomics.wait`
// (per duckdb/duckdb-wasm#2279's own description), so an HTTP server sharing that main
// thread's event loop can never service the very request that thread is frozen waiting
// on — a same-process server deadlocks every time, not occasionally.
//
// A random port per run sidesteps that same bug's other half (a failed/garbage load
// attempt gets cached per name+repository and poisons every later LOAD under that pair,
// even in a fresh process) — not needed for a normal, successful run, but cheap
// insurance against a flaky first attempt leaving the next run stuck.
'use strict';

const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

function fail(msg) {
    console.error(`FAILED: ${msg}`);
    process.exit(1);
}

async function main() {
    const [distDirArg, extPathArg] = process.argv.slice(2);
    if (!distDirArg || !extPathArg) {
        console.error('usage: verify_wasm_load.cjs <engine-dist-dir> <extension-wasm-path>');
        process.exit(2);
    }
    // Resolved to absolute: a relative `distDir` passed straight to `require()` below would
    // be treated as a module name to resolve via node_modules, not a relative file path.
    const distDir = path.resolve(distDirArg);
    const extPath = path.resolve(extPathArg);

    const extBase = path.basename(extPath).replace(/\.duckdb_extension\.wasm$/, '');
    if (extBase === path.basename(extPath)) {
        fail(`${extPath} does not end in .duckdb_extension.wasm`);
    }

    const port = 20000 + Math.floor(Math.random() * 20000);
    const server = spawn(process.execPath, [path.join(__dirname, 'serve_extension.cjs'), extPath, String(port)], {
        stdio: ['ignore', 'pipe', 'inherit'],
    });
    await new Promise((resolve, reject) => {
        server.once('error', reject);
        server.once('exit', code => reject(new Error(`serve_extension.cjs exited early (code ${code})`)));
        server.stdout.once('data', chunk => {
            if (chunk.toString().includes('LISTENING')) resolve();
            else reject(new Error(`unexpected serve_extension.cjs output: ${chunk}`));
        });
    });

    try {
        const duckdb = require(path.join(distDir, 'duckdb-node-blocking.cjs'));
        const bundles = {
            mvp: {
                mainModule: path.join(distDir, 'duckdb-mvp.wasm'),
                mainWorker: path.join(distDir, 'duckdb-node-mvp.worker.cjs'),
            },
        };
        const logger = new duckdb.ConsoleLogger();
        const db = await duckdb.createDuckDB(bundles, logger, duckdb.NODE_RUNTIME);
        await db.instantiate(() => {});
        db.open({ allowUnsignedExtensions: true });
        const conn = db.connect();

        conn.query(`SET custom_extension_repository = 'http://127.0.0.1:${port}'`);
        console.log(`LOAD ${extBase} (repository http://127.0.0.1:${port})...`);
        conn.query(`LOAD ${extBase}`);
        console.log('LOAD succeeded');

        const bigintSafe = (k, v) => (typeof v === 'bigint' ? v.toString() : v);

        const hello = conn.query(`SELECT zig_hello('ci') AS greeting`).toArray()[0].toJSON();
        if (hello.greeting !== 'Hello, ci!') {
            fail(`zig_hello('ci') returned ${JSON.stringify(hello)}, expected {"greeting":"Hello, ci!"}`);
        }
        console.log(`zig_hello('ci') = ${JSON.stringify(hello, bigintSafe)}`);

        const sum = conn.query(`SELECT zig_add_numbers(2, 3) AS sum`).toArray()[0].toJSON();
        if (String(sum.sum) !== '5') {
            fail(`zig_add_numbers(2, 3) returned ${JSON.stringify(sum, bigintSafe)}, expected {"sum":5}`);
        }
        console.log(`zig_add_numbers(2, 3) = ${JSON.stringify(sum, bigintSafe)}`);

        conn.close();
        console.log(`verify_wasm_load: PASSED — ${extBase} loads and runs against ${distDir}`);
    } finally {
        server.kill();
    }
}

main().catch(e => {
    console.error('FATAL:', e && e.stack ? e.stack : e);
    process.exit(1);
});
