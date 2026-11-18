/*
 * port-probe.cjs — DSH Web 动态端口探测器（+ios24.11）。
 *
 * 由 dsh-daemon 通过 node-safe（Node 24 零 JIT）调用：
 *   node-safe port-probe.cjs <basePort>
 * 从 basePort 起逐个尝试 bind 127.0.0.1，选第一个空闲端口，打印到 stdout。
 * 只用 net 模块（零依赖），不分配可执行内存（A11 的 --jitless 下不 SIGBUS）。
 *
 * 设计：绝大多数设备 3080 空闲 -> 立即返回 3080，行为与旧版完全一致；
 * 只有当 3080 被别的进程占用时才递增，避免「端口冲突导致 DSH 起不来」。
 */
'use strict';
const net = require('net');

const base = Number(process.argv[2] || 3080);
const MAX_TRY = 64; // 3080..3143，足够覆盖常见冲突

function tryBind(port, cb) {
  const s = net.createServer();
  let settled = false;
  const finish = (free) => {
    if (settled) return;
    settled = true;
    try { s.close(); } catch (e) { /* noop */ }
    cb(free);
  };
  s.once('error', () => finish(false));
  s.once('listening', () => finish(true));
  try { s.listen(port, '127.0.0.1'); }
  catch (e) { finish(false); }
}

(function next(i) {
  const p = base + i;
  if (i >= MAX_TRY || p > 65535) {
    process.stdout.write(String(base));
    return;
  }
  tryBind(p, (free) => {
    if (free) process.stdout.write(String(p));
    else next(i + 1);
  });
})(0);
