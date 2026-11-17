import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const adminDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../src/public/admin');

test('R6: panel admina — app.js kompiluje się bez błędu składni (regresja po Unexpected token)', () => {
  const src = fs.readFileSync(path.join(adminDir, 'app.js'), 'utf8');
  assert.doesNotThrow(() => new vm.Script(src, { filename: 'app.js' }), 'app.js musi przejść parsowanie JS');
});

test('R6: index.html istnieje i referuje tylko do istniejących assetów', () => {
  const html = fs.readFileSync(path.join(adminDir, 'index.html'), 'utf8');
  assert.ok(html.includes('id="view"'), 'index.html zawiera #view');
  for (const m of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
    if (m[1].startsWith('data:') || m[1].startsWith('http')) continue;
    assert.ok(fs.existsSync(path.join(adminDir, m[1])), `brak assetu: ${m[1]}`);
  }
});
