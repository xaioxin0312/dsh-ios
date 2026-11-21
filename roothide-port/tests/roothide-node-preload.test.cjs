'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const cp = require('node:child_process');
const { promisify } = require('node:util');
const { join } = require('node:path');
const { tmpdir } = require('node:os');
const { pathToFileURL } = require('node:url');

assert.equal(process.versions.node.split('.')[0], '24', 'use Node 24');
const root = fs.realpathSync(fs.mkdtempSync(join(tmpdir(), 'dsh-rh-node-')));
const bin = `${root}/bin`;
const dsh = `${root}/usr/lib/dsh`;
const preload = `${dsh}/roothide-node-preload.cjs`;
fs.mkdirSync(bin, { recursive: true });
fs.mkdirSync(dsh, { recursive: true });
fs.copyFileSync(join(__dirname, '../roothide-node-preload.cjs'), preload);
fs.writeFileSync(`${dsh}/fixture.cjs`, 'module.exports = 24');
fs.writeFileSync(`${dsh}/fixture.mjs`, 'export const n = 24; export const url = import.meta.url;');
fs.writeFileSync(`${dsh}/fork.cjs`, "process.send(require('/var/jb/usr/lib/dsh/fixture.cjs')); process.disconnect();");
fs.writeFileSync(`${bin}/sh`, '#!/bin/sh\nprintf "%s\\n" "$PATH" "$HOME" "$PWD" "$1" "$2" "$3" "$4"\n', { mode: 0o755 });
fs.writeFileSync(`${bin}/git`, '#!/bin/sh\nprintf "%s\\n" "$PATH" "$HOME" "$PWD" "$1" "$2"\n', { mode: 0o755 });
process.env.DSH_JBROOT = root;
process.env.DSH_HOME = `${root}/var/mobile/.dsh`;
process.env.PATH = `${bin}:/usr/bin:/bin`;
require(preload);

test('real and legacy fs, CJS, and ESM stay coherent', async () => {
  const legacy = '/var/jb/usr/lib/dsh/fixture.cjs';
  assert.equal(require(legacy), 24);
  assert.equal(require.resolve(legacy), `${dsh}/fixture.cjs`);
  assert.equal(fs.readFileSync(Buffer.from(legacy), 'utf8'), 'module.exports = 24');
  assert.equal(await fs.promises.readFile(pathToFileURL(legacy), 'utf8'), 'module.exports = 24');
  assert.equal(fs.realpathSync.native(legacy), `${dsh}/fixture.cjs`);
  assert.equal(fs.realpathSync('/rootfs' + dsh), dsh);
  assert.equal(fs.existsSync('/var/jboot/fixture.cjs'), false);
  const esm = await import('file:///var/jb/usr/lib/dsh/fixture.mjs?test=1#hash');
  assert.equal(esm.n, 24);
  assert.match(esm.url, /\?test=1#hash$/);
  assert.equal((await import('/var/jb/usr/lib/dsh/fixture.mjs')).n, 24);
});

test('bootstrap git resolves actual exec and cwd, but receives virtual paths', () => {
  const env = { PATH: process.env.PATH, HOME: '/var/mobile' };
  const actual = cp.execFileSync('git', [`${root}/repo`, '--path=/var/mobile/test'], {
    env, cwd: pathToFileURL('/var/jb/usr/lib/dsh'), encoding: 'utf8',
  });
  assert.deepEqual(actual.trimEnd().split('\n'), ['/bin:/rootfs/usr/bin:/rootfs/bin', '/rootfs/var/mobile', dsh, '/repo', '--path=/rootfs/var/mobile/test']);
  assert.equal(env.PATH, process.env.PATH);
});

test('exec delegates once; sh -c source is opaque and positional paths are mapped', async () => {
  const env = { PATH: process.env.PATH, HOME: '/var/mobile' };
  const code = '/var/jb/path must remain opaque';
  const opts = { env, cwd: '/var/jb/usr/lib/dsh' };
  const { stdout } = await promisify(cp.exec)(code, opts);
  assert.deepEqual(stdout.split('\n').slice(0, 5), ['/bin:/rootfs/usr/bin:/rootfs/bin', '/rootfs/var/mobile', dsh, '-c', code]);
  const output = cp.execFileSync('/bin/sh', ['-c', code, 'arg0', '/var/jb/file'], { ...opts, encoding: 'utf8' });
  assert.deepEqual(output.trimEnd().split('\n').slice(3), ['-c', code, 'arg0', '/file']);
});

test('Node keeps process.execPath and does not translate inline source', async () => {
  assert.notEqual(process.execPath, `${dsh}/bin/node`);
  const body = '/var/jb/.source';
  const child = cp.spawnSync(process.execPath, ['-e', body], { encoding: 'utf8' });
  assert.equal(child.status, 1);
  assert.ok(child.stderr.split('\n').includes(body), child.stderr);
  const output = cp.execFileSync(process.execPath, ['-e', 'process.stdout.write("ok")'], { encoding: 'utf8' });
  assert.equal(output, 'ok');
  const fork = cp.fork('/var/jb/usr/lib/dsh/fork.cjs', [], { execArgv: [], silent: true });
  const result = await new Promise((resolve, reject) => {
    fork.on('message', resolve);
    fork.on('error', reject);
    fork.on('exit', (n) => { if (n !== 0) reject(new Error(`fork exit: ${n}`)); });
  });
  assert.equal(result, 24);
});

test.after(() => fs.rmSync(root, { recursive: true, force: true }));
