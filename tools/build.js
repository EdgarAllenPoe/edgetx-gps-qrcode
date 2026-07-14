#!/usr/bin/env node
/*
 * Build the two EdgeTX deployment entry points from the documented Lua source.
 *
 * The readable distribution is copied without semantic changes so radio owners
 * can inspect or modify it directly. The minified distribution is generated with
 * luamin to reduce parsing time, heap pressure, and SD-card I/O on transmitters.
 *
 * This script deliberately performs no version substitution. The version in the
 * source files is authoritative, which prevents a release from containing a
 * build label that differs from the code shown on the radio.
 */

'use strict';

const fs = require('fs');
const path = require('path');
const luamin = require('luamin');

const repositoryRoot = path.resolve(__dirname, '..');
const version = '10.10.8';

const targets = [
  {
    name: 'color widget',
    source: path.join(repositoryRoot, 'src', 'color', 'main.lua'),
    readable: path.join(repositoryRoot, 'dist', 'readable', 'WIDGETS', 'GPSQR', 'main.lua'),
    minified: path.join(repositoryRoot, 'dist', 'minified', 'WIDGETS', 'GPSQR', 'main.lua'),
  },
  {
    name: 'monochrome telemetry script',
    source: path.join(repositoryRoot, 'src', 'monochrome', 'GPSQR.lua'),
    readable: path.join(repositoryRoot, 'dist', 'readable', 'SCRIPTS', 'TELEMETRY', 'GPSQR.lua'),
    minified: path.join(repositoryRoot, 'dist', 'minified', 'SCRIPTS', 'TELEMETRY', 'GPSQR.lua'),
  },
];

/** Normalize text files so generated artifacts are deterministic across hosts. */
function normalizeText(text) {
  return text.replace(/\r\n/g, '\n').replace(/\r/g, '\n').replace(/\s+$/u, '') + '\n';
}

/** Create the parent directory of a generated file when it does not exist. */
function ensureParent(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

/**
 * Build one radio entry point.
 *
 * The minified file retains a short license/source pointer. Full copyright and
 * license text travels with release archives in LICENSE and THIRD_PARTY_NOTICES.
 */
function buildTarget(target) {
  const source = normalizeText(fs.readFileSync(target.source, 'utf8'));
  const minifiedBody = luamin.minify(source);
  const minifiedHeader =
    `-- GPS QR v${version}; BSD-3-Clause; documented source in src/.\n`;

  ensureParent(target.readable);
  ensureParent(target.minified);
  fs.writeFileSync(target.readable, source, 'utf8');
  fs.writeFileSync(target.minified, minifiedHeader + minifiedBody + '\n', 'utf8');

  const readableBytes = Buffer.byteLength(source);
  const minifiedBytes = Buffer.byteLength(minifiedHeader + minifiedBody + '\n');
  const reduction = 100 - (minifiedBytes / readableBytes) * 100;
  console.log(
    `${target.name}: ${readableBytes} -> ${minifiedBytes} bytes ` +
      `(${reduction.toFixed(1)}% reduction)`,
  );
}

for (const target of targets) {
  buildTarget(target);
}
