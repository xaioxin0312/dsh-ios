#!/usr/bin/env node
/**
 * apply_live_progress_inject.cjs —— +ios24.8 单包专用前端注入（幂等）
 *
 * 把 dsh-ios-live-progress.js（DSH Web UI 内嵌实时进度面板）注入到
 * dsh-web-frontend/dist，并在 index.html 的 <head> 内、所有 module 之前
 * 补一个同步 <script> 引用。
 *
 * 为什么单独一份：shims/apply_frontend_inject.cjs 会被
 * shims/make_fix_ios15.py 内嵌进 fix-ios15.sh，改它会连锁改变 +ios15
 * 稳定底座 deb 的 SHA（违反「稳定包逐字节不动」）。因此本脚本只服务
 * one-package 单包，共享 shim 一个字节都不碰。
 *
 * 用法:
 *   node apply_live_progress_inject.cjs <dist 目录> <面板源文件>
 *
 * 退出码: 0=成功/已是最新；1=失败
 */
'use strict';
const fs = require('node:fs');
const path = require('node:path');

function fail(m) { process.stderr.write(`[FAIL] ${m}\n`); process.exit(1); }
const dist = process.argv[2];
const src = process.argv[3];
if (!dist || !src) fail('用法: apply_live_progress_inject.cjs <dist> <面板源文件>');

const index = path.join(dist, 'index.html');
const assets = path.join(dist, 'assets');
const name = path.basename(src);
if (!fs.existsSync(index)) fail(`找不到 ${index}`);
if (!fs.existsSync(src)) fail(`找不到面板源 ${src}`);
if (!/\.js$/.test(name)) fail('面板源必须是 .js');

fs.mkdirSync(assets, { recursive: true });
const dst = path.join(assets, name);
fs.copyFileSync(src, dst);
process.stdout.write(`  [ OK ] assets/${name} (${fs.statSync(dst).size} 字节)\n`);

let html = fs.readFileSync(index, 'utf8');
const tag = `    <script src="./assets/${name}"></script>`;
if (!html.includes(name)) {
    const m = html.match(/(<head(?:\s[^>]*)?>)/);
    if (!m) fail('index.html 找不到 <head> 标签');
    html = html.slice(0, m.index + m[1].length) + '\n' + tag +
           html.slice(m.index + m[1].length);
    fs.writeFileSync(index, html, 'utf8');
    process.stdout.write(`  [ OK ] index.html 注入 ${name} 引用（<head> 内）\n`);
} else {
    process.stdout.write(`  [ == ] index.html 已含 ${name} 引用，跳过\n`);
}

// 结果校验
html = fs.readFileSync(index, 'utf8');
if (!html.includes(name)) fail(`index.html 缺 ${name} 引用`);
if (!fs.existsSync(dst)) fail(`缺 assets/${name}`);
const firstModule = html.indexOf('type="module"');
if (firstModule !== -1 && html.indexOf(name) > firstModule) {
    fail(`${name} 引用落在 <script type="module"> 之后`);
}
// 面板必须真的连本机进度端点，防止注入了空壳
const body = fs.readFileSync(dst, 'utf8');
for (const needle of ['127.0.0.1:8091', '/events', '/progress']) {
    if (!body.includes(needle)) fail(`面板缺 ${needle}（疑似空壳/旧版）`);
}
process.stdout.write('  [ OK ] +ios24.8 实时进度面板注入完成并校验通过\n');
