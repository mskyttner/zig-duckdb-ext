#!/usr/bin/env node
// Tiny standalone HTTP server for one extension file, run as its own OS process by
// verify_wasm_load.cjs (never in-process with it — see that file's own comment on why).
//
//   node serve_extension.cjs <extension-wasm-path> <port>
//
// Prints exactly one line, `LISTENING`, once bound, then serves forever until killed.
'use strict';

const http = require('http');
const fs = require('fs');

const [extPath, portArg] = process.argv.slice(2);
const extBytes = fs.readFileSync(extPath);
const port = Number(portArg);

http.createServer((req, res) => {
    if (req.url.endsWith('.duckdb_extension.wasm')) {
        res.writeHead(200, { 'Content-Type': 'application/wasm', 'Access-Control-Allow-Origin': '*' });
        res.end(extBytes);
        return;
    }
    res.writeHead(404, { 'Access-Control-Allow-Origin': '*' });
    res.end('not found');
}).listen(port, () => console.log('LISTENING'));
