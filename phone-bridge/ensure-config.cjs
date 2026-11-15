#!/usr/bin/env node
/*
 * ensure-config.cjs —— 把内置手机工具链自动注册成 DSH 的 MCP 客户端
 *
 * 用户要求「启动 DSH 让 DSH 操作手机，能够直接调用相关工具链」。
 * 原先要用户手动装插件 + 手填 cordis.patch.yml；这里在 APP/保活包安装后，
 * 由 bridge daemon（以 mobile 身份）在启动时幂等写入：
 *
 *   $DSH_HOME/cordis.patch.yml
 *   $DSH_HOME/profiles/<profile>/cordis.patch.yml
 *
 * 写入的块：
 *   - insert:
 *       - id: dsh-ios-phone-bridge-mcp
 *         name: '@deepseek-ai/dsh-mcp-client'
 *         config: { url: http://127.0.0.1:8091/mcp, ... }
 *
 * 为什么必须保持「顶层数组」：真机上曾因 cordis.patch.yml 顶层非数组
 * 直接 fatal。本脚本用与 shims/dsh-home-heal.cjs 同样的判定逻辑；自愈脚本
 * 只删 id=im-qqbot / xmanrui-dsh-im 两个旧块，用户/本脚本写的块一律保留。
 *
 * 用法: node ensure-config.cjs <DSH_HOME> [on|off|status]
 *   on      幂等注册（默认）
 *   off     移除本工具链的块（保留用户其它块）
 *   status  只打印状态，不写文件
 * 环境变量: DSH_IOS_PHONE_CONTROL=0 等价于 off
 *
 * 纯 Node 内置模块，零 npm 依赖，可在 --jitless 档运行。
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const HOME = process.argv[2] || process.env.DSH_HOME || '/var/jb/var/mobile/.dsh';
let MODE = (process.argv[3] || 'on').toLowerCase();
if (process.env.DSH_IOS_PHONE_CONTROL === '0') MODE = 'off';
if (!['on', 'off', 'status'].includes(MODE)) {
    process.stderr.write('用法: ensure-config.cjs <DSH_HOME> [on|off|status]\n');
    process.exit(2);
}

const ID = 'dsh-ios-phone-bridge-mcp';

/* +ios24.8：旧的 plugins/dsh-ios-phone-control（用户手动装过的生态插件）
 * 也用 serverName: ios，但 url 直连 8090（原生 ios-mcp）。两个同名的
 * MCP 客户端共存时，DSH 可能连到 8090 —— 那样所有 tools/call 都绕过
 * 8091 bridge，进度事件一个都不会产生，HUD 与 Web 面板永远「待命」。
 * 这是真机「看不到任何实时进度」的隐性根因之一。注册时把这类冲突块
 * 整块移除（只认 url 指向 8090 的 dsh-mcp-client，不动用户其它块；
 * dsh-home-heal.cjs 只删 im-qqbot / xmanrui-dsh-im，两者互不干扰）。
 */
function isConflictingIosBlock(text) {
    if (!/@deepseek-ai\/dsh-mcp-client/.test(text) && !/dsh-ios-phone-control-mcp/.test(text)) return false;
    if (!/serverName:\s*ios\b/.test(text) && !/dsh-ios-phone-control-mcp/.test(text)) return false;
    // 旧块：直连 8090，或干脆就是手动装的 phone-control 插件块。
    return /dsh-ios-phone-control-mcp/.test(text) || /127\.0\.0\.1:8090/.test(text);
}

const BLOCK = [
    '- insert:',
    '    - id: ' + ID,
    "      name: '@deepseek-ai/dsh-mcp-client'",
    '      config:',
    '        serverName: ios',
    '        transport: streamable-http',
    '        url: http://127.0.0.1:8091/mcp',
    '        headers: {}',
    '        toolCallTimeoutMs: 120000',
    '        failOnStartupError: false',
    '        maxInstructionBytes: 32768',
    '        reconnect:',
    '          enabled: true',
    '          initialDelayMs: 500',
    '          maxDelayMs: 30000',
    '          maxAttempts: 30'
].join('\n');

/* 与 dsh-home-heal.cjs 的 patchLooksValid 同构：顶层必须是 YAML 数组。 */
function looksValid(text) {
    if (!text) return false;
    let sawItem = false;
    for (const raw of text.split('\n')) {
        const line = raw.replace(/\s+$/, '');
        if (!line.trim() || /^\s*#/.test(line)) continue;
        if (/^\s*(?:---|\.\.\.)\s*(?:#.*)?$/.test(line)) continue;
        if (/^\s/.test(line)) continue;              // 缩进行属于当前数组项
        if (/^\[\s*\]\s*(?:#.*)?$/.test(line.trim())) return true;
        if (/^-\s/.test(line) || /^-$/.test(line)) { sawItem = true; continue; }
        return false;
    }
    return sawItem;
}

function hasOurBlock(text) {
    return new RegExp('(^|\\n)\\s*-?\\s*id:\\s*[\'"]?' + ID + '[\'"]?\\s*(?:#.*)?$', 'm').test(text);
}

function splitTopBlocks(lines) {
    const head = [];
    const blocks = [];
    let i = 0;
    while (i < lines.length && !/^-\s/.test(lines[i]) && !/^-$/.test(lines[i])) {
        head.push(lines[i]); i++;
    }
    while (i < lines.length) {
        const block = [lines[i]];
        let j = i + 1;
        while (j < lines.length && !/^-\s/.test(lines[j]) && !/^-$/.test(lines[j])) {
            block.push(lines[j]); j++;
        }
        blocks.push(block);
        i = j;
    }
    return { head, blocks };
}

/* 原子写：先写同目录临时文件再 rename，避免半写；mode 0600 与 heal 一致。 */
function atomicWrite(p, content) {
    try { fs.mkdirSync(path.dirname(p), { recursive: true, mode: 0o700 }); }
    catch (e) { return 'mkdir: ' + e.code; }
    const tmp = p + '.dsh-phone-bridge.' + process.pid;
    try {
        fs.writeFileSync(tmp, content, { mode: 0o600 });
        fs.renameSync(tmp, p);
        try { fs.chmodSync(p, 0o600); } catch (_) {}
        return true;
    } catch (e) {
        try { fs.unlinkSync(tmp); } catch (_) {}
        return String(e.code || e.message || e);
    }
}

function targets() {
    const out = [path.join(HOME, 'cordis.patch.yml')];
    const pdir = path.join(HOME, 'profiles');
    let ents = [];
    try { ents = fs.readdirSync(pdir, { withFileTypes: true }); } catch (_) {}
    for (const e of ents) {
        if (e.isDirectory() || e.isSymbolicLink()) out.push(path.join(pdir, e.name, 'cordis.patch.yml'));
    }
    return out;
}

function processFile(p) {
    let text = '';
    let existed = false;
    try { text = fs.readFileSync(p, 'utf8'); existed = true; }
    catch (_) { text = '# dsh-ios phone-bridge patch layer\n[]\n'; }

    const valid = looksValid(text);
    if (!valid) text = '# dsh-ios phone-bridge: 顶层非数组，已重置\n[]\n';

    const has = hasOurBlock(text);
    if (MODE === 'status') {
        let conflicts = 0;
        let ls = text.split('\n');
        const sp = splitTopBlocks(ls);
        for (const b of sp.blocks) if (isConflictingIosBlock(b.join('\n'))) conflicts++;
        return { file: p, existed, valid: !!valid, registered: has, conflicting_8090_blocks: conflicts, action: 'none' };
    }

    let lines = text.split('\n');
    // 单独的 [] 与后面的 "- insert:" 不能共存（YAML 会出现两个顶层值）。
    if (!lines.some((l) => /^-\s/.test(l) || /^-$/.test(l))) {
        lines = lines.filter((l) => !/^\[\s*\]\s*(?:#.*)?$/.test(l.trim()));
    }
    let { head, blocks } = splitTopBlocks(lines);
    let conflicts = 0;
    const ourBlocks = [];
    const others = [];
    // +ios24.8：只精准移除「8090 直连冲突块」；我方已有块原样保留
    // （用户可能改过 toolCallTimeoutMs 等），其余用户块一律不动。
    for (const b of blocks) {
        const t = b.join('\n');
        if (isConflictingIosBlock(t)) { conflicts += 1; continue; }
        if (hasOurBlock(t)) { ourBlocks.push(b); continue; }
        others.push(b);
    }
    // 冲突块被删后，head 里可能残留描述它的孤立注释（含 8090 /
    // phone-control 字样），语义错位且会干扰诊断脚本。只清这类注释行。
    if (conflicts > 0) {
        head = head.filter((l) => {
            if (!/^\s*#/.test(l)) return true;
            return !/8090|phone-control|ios-mcp/i.test(l);
        });
    }

    let next;
    let changed;
    if (MODE === 'on') {
        // 保留用户原有我方块；没有才追加标准块。
        const finalBlocks = others.slice();
        if (ourBlocks.length) finalBlocks.push(...ourBlocks);
        else finalBlocks.push(BLOCK.split('\n'));
        next = (head.length ? head.join('\n') + '\n' : '') +
               finalBlocks.map((b) => b.join('\n')).join('\n') +
               '\n';
        next = next.replace(/\n{3,}/g, '\n\n').replace(/\s+$/, '') + '\n';
        if (!looksValid(next)) return { file: p, action: 'error', error: 'would produce invalid top-level' };
        changed = !has || conflicts > 0;
    } else {
        const rest = (head.length ? head.join('\n') + '\n' : '') +
                     others.map((b) => b.join('\n')).join('\n');
        next = (rest.trim() || '[]').replace(/\n{3,}/g, '\n\n') + '\n';
        if (!looksValid(next)) next = '[]\n';
        changed = has || conflicts > 0;
    }
    // 幂等：内容完全一致时直接 unchanged，不触碰文件 mtime
    try { if (fs.readFileSync(p, 'utf8') === next) changed = false; } catch (_) {}

    const baseAction = MODE === 'on' ? (has ? 'unchanged' : 'registered')
                                     : (has ? 'removed' : 'unchanged');
    const action = conflicts > 0 ? baseAction + '+removed-8090-conflict' : baseAction;
    if (!changed) {
        return { file: p, existed, valid: !!valid, registered: MODE === 'on',
            conflicting_8090_removed: 0, action: MODE === 'on' ? 'unchanged' : 'unchanged' };
    }
    const w = atomicWrite(p, next);
    if (w !== true) return { file: p, action: 'error', error: String(w) };
    return { file: p, existed, valid: !!valid, registered: MODE === 'on',
        conflicting_8090_removed: conflicts, action };
}

const results = targets().map(processFile);
const errors = results.filter((r) => r.action === 'error');
process.stdout.write(JSON.stringify({ mode: MODE, home: HOME, results }, null, 2) + '\n');
process.exit(errors.length ? 1 : 0);
