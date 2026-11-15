#!/usr/bin/env node
/*
 * dsh-ios phone-bridge —— 设备本机 MCP 工具链（Streamable HTTP）
 *
 * 目的：用户要求「启动 DSH 让 DSH 操作手机，能够直接调用相关工具链」。
 * 早期方案要求用户额外安装第三方 witchan/ios-mcp 并手动装配置插件；现在原生能力随包提供，
 * 不满足「启动即可用」。本服务把能力分成两层，用一个固定回环端点统一暴露：
 *
 *   A 层（本文件原生实现，纯 Node，无需任何第三方原生组件）：
 *     设备信息 / 目录 / 读写文件 / 执行命令 / App 列表 / 启动 App /
 *     打开 URL / 进程 / 系统日志 / DSH 自身状态 / bridge 状态
 *   B 层（真·看屏幕、点屏幕、UI 树、OCR、剪贴板、亮度音量…）：
 *     转发到随包安装的原生 SpringBoard 插件 dsh-ios-control
 *     （默认 http://127.0.0.1:8090/mcp）。插件由 dev.airdevs.dsh-app 一起装，
 *     安装后 respring 一次即加载；在线时工具合并进 tools/list，tools/call 原样转发。
 *     离线时这些工具不出现，并给出明确的 respring / 状态检查指引。
 *
 * 为什么固定 8091：8090 是第三方 ios-mcp 的默认端口，不能抢占。
 * DSH 侧 cordis.patch.yml 由 ensure-config.cjs 自动注册到 127.0.0.1:8091/mcp。
 *
 * 协议：MCP 2025-11-25，POST /mcp 走 JSON-RPC；响应 application/json，
 * 带 MCP-Protocol-Version 与 Mcp-Session-Id。notification（无 id）返回 202。
 * 只用 Node 内置模块，零 npm 依赖，可在 --jitless / fetch-shim 零 JIT 档运行。
 *
 * 安全：无任何认证，仅绑定 127.0.0.1。run_command 可执行任意 shell，
 * 必须在可信设备上使用；不要改成 0.0.0.0。
 */
'use strict';

const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const cp = require('node:child_process');

const HOST = process.env.DSH_BRIDGE_HOST || '127.0.0.1';
const PORT = Number(process.env.DSH_BRIDGE_PORT || 8091);
const UPSTREAM = process.env.DSH_IOS_MCP_URL || 'http://127.0.0.1:8090/mcp';
const DSH_HOME = process.env.DSH_HOME || '/var/jb/var/mobile/.dsh';
const JB = '/var/jb';
const PROTOCOL = '2025-11-25';
const SESSION = 'dsh-ios-phone-bridge';
const MAX_OUTPUT = 64 * 1024;
const MAX_FILE = 2 * 1024 * 1024;
const CMD_TIMEOUT = Number(process.env.DSH_BRIDGE_CMD_TIMEOUT || 60000);

/* ------------------------------------------------------- 实时进度事件总线
 * +ios24.8：把「实时进度」从「只有一个 SpringBoard 悬浮胶囊」升级为
 * 一条带序号、可续传、多订阅者的事件流。对标 DSH Go 的流式事件状态机：
 *   - 引擎侧每个动作都产生结构化事件（state/tool/action/step/total/耗时）；
 *   - 有界环形缓冲 + 单调递增 seq，断线后用 Last-Event-ID / ?since= 续传；
 *   - SSE 为主通道（DSH Web UI 内嵌进度面板订阅），轮询为兜底；
 *   - 同时保留 hud.json 原子写，供原生 SpringBoard 胶囊读取（向后兼容），
 *     并**在空闲时也持续发心跳**，让 HUD 一装上就常驻可见，而不是收不到
 *     事件就永远 alpha=0（这正是真机「HUD 完全不可见」的表象）。
 *
 * 设计要点：HUD 没装/没注入/被灵动岛插件盖住时，操控链路完全不受影响；
 * Web UI 面板是主通道，原生 HUD 只是跨 App 兜底。
 */
const HUD_PATH = process.env.DSH_HUD_PATH || '/var/mobile/Library/DSH/hud.json';
const EVENT_CAP = 240;
const SSE_PING_MS = 15000;
const HUD_HEARTBEAT_MS = 2000;
let eventSeq = 0;
let hudStart = 0;
let runSeq = 0;
const eventRing = [];
const sseClients = new Set();
let snapshot = {
    seq: 0, ts: Date.now(), state: 'idle', title: 'DSH 就绪',
    detail: '等待任务', tool: '', action: '', step: 0, total: 0,
    elapsed_ms: 0, ok: null, run_id: '', ttl_ms: 0
};
let idleSince = Date.now();

function hudCompatibleState(state) {
    // 原生 HUD 只认 running / error / 其它；把细分状态折叠过去。
    if (state === 'error' || state === 'failed') return 'error';
    if (state === 'done' || state === 'idle' || state === 'ready') return state;
    return 'running';
}

function writeHud(obj) {
    try {
        fs.mkdirSync(path.dirname(HUD_PATH), { recursive: true });
        const tmp = HUD_PATH + '.tmp';
        fs.writeFileSync(tmp, JSON.stringify(obj));
        fs.renameSync(tmp, HUD_PATH);
    } catch (_) { /* HUD 不可用时静默，不影响操控链路 */ }
}

function emitEvent(state, detail, extra) {
    const e = extra || {};
    const now = Date.now();
    const st = String(state || 'running');
    if (st === 'running' && !hudStart) { hudStart = now; runSeq += 1; }
    if (st === 'done' || st === 'error' || st === 'failed' || st === 'idle') hudStart = 0;
    if (st === 'idle') idleSince = now;

    snapshot = {
        seq: ++eventSeq,
        ts: now,
        state: st,
        title: e.title || (st === 'idle' ? 'DSH 就绪' : 'DSH 操控中'),
        detail: String(detail === undefined ? '' : detail).slice(0, 160),
        tool: String(e.tool || ''),
        action: String(e.action || ''),
        step: Number(e.step || 0),
        total: Number(e.total || 0),
        elapsed_ms: hudStart ? now - hudStart : 0,
        ok: e.ok === undefined ? null : !!e.ok,
        run_id: e.run_id || ('r' + (runSeq || 1)),
        ttl_ms: Number(e.ttl || (st === 'running' ? 30000 : 1600))
    };
    eventRing.push(snapshot);
    if (eventRing.length > EVENT_CAP) eventRing.shift();

    // 原生 HUD：保持旧字段结构 + 常驻态（idle 也写，且 ttl 极长）
    writeHud({
        v: 2,
        state: hudCompatibleState(st),
        title: snapshot.title,
        detail: snapshot.detail.slice(0, 90),
        step: snapshot.step,
        total: snapshot.total,
        elapsed_ms: snapshot.elapsed_ms,
        ts: snapshot.ts,
        ttl_ms: st === 'idle' ? 86400000 : snapshot.ttl_ms
    });

    // SSE 广播
    const frame = 'id: ' + snapshot.seq + '\nevent: ' + st + '\ndata: ' + JSON.stringify(snapshot) + '\n\n';
    for (const c of sseClients) {
        try { c.write(frame); } catch (_) { sseClients.delete(c); }
    }
    return snapshot;
}

/* 兼容旧调用点：所有 hudPublish(state, detail, extra) 原样保留。 */
function hudPublish(state, detail, extra) {
    return emitEvent(state, detail, extra);
}

/* 空闲心跳：让 hud.json 的 mtime 持续变化，原生 HUD 保持常驻可见；
 * 同时给 SSE 客户端发 ping，防止 iOS Safari 把长连接判死。
 * 心跳不写入事件环（避免刷屏），只刷新文件与当前快照时间。
 */
setInterval(() => {
    if (snapshot.state === 'idle' || snapshot.state === 'ready') {
        writeHud({
            v: 2, state: 'running', title: 'DSH 就绪', detail: '等待任务 · 桥已连接',
            step: 0, total: 0, elapsed_ms: Date.now() - idleSince,
            ts: Date.now(), ttl_ms: 86400000
        });
    }
    for (const c of sseClients) {
        try { c.write(': ping\n\n'); } catch (_) { sseClients.delete(c); }
    }
}, HUD_HEARTBEAT_MS).unref();

function tool(name, description, properties, required) {
    return {
        name,
        description,
        inputSchema: { type: 'object', properties: properties || {}, required: required || [] }
    };
}
const S = (d) => ({ type: 'string', description: d });
const N = (d) => ({ type: 'number', description: d });
const B = (d) => ({ type: 'boolean', description: d });

/* ------------------------------------------------------------------ A 层工具 */
const LOCAL_TOOLS = [
    tool('get_device_info', 'Read device/JB/DSH runtime info (model, OS, arch, memory, uptime, jailbreak root).', {}),
    tool('list_dir', 'List a directory with type/size/mtime.', { path: S('absolute directory path') }, ['path']),
    tool('read_file', 'Read a text file (max 2 MiB).', { path: S('absolute file path'), max_bytes: N('optional cap') }, ['path']),
    tool('write_file', 'Write a text file (max 2 MiB), creating parent directories.', { path: S('absolute file path'), content: S('text content'), append: B('append instead of overwrite') }, ['path', 'content']),
    tool('run_command', 'Run a shell command on the device with a timeout. Use for install/build/test loops.', { command: S('shell command'), cwd: S('optional working directory'), timeout_ms: N('optional timeout in ms') }, ['command']),
    tool('list_apps', 'List installed .app bundles under /var/jb/Applications and /Applications with bundle id / name.', { root: S('optional extra directory to scan') }),
    tool('launch_app', 'Launch an app by bundle id or open a URL scheme (uiopen / open / launchctl).', { bundle_id: S('CFBundleIdentifier'), url: S('URL or scheme, used when bundle_id is empty') }),
    tool('open_url', 'Open a URL / URL scheme on the device.', { url: S('e.g. bilibili:// or https://...') }, ['url']),
    tool('list_processes', 'List running processes (ps), optionally filtered.', { filter: S('optional grep filter') }),
    tool('get_syslog', 'Best-effort read of system log; returns a clear hint when no log tool is available.', { lines: N('max lines, default 200') }),
    tool('dsh_status', 'Report whether the DSH web service / daemon / this bridge are reachable.', { port: N('DSH web port, default 3080') }),
    tool('phone_bridge_status', 'Report this bridge: local tool count, upstream ios-mcp reachability and merged tool count.', {}),
    tool('phone_act',
        'Run a batch of UI actions in ONE call (fewest model round trips), with live streamed progress, ' +
        'then wait for the screen to settle and return COMPACT, incremental UI text. ' +
        'Whole step list is pre-validated before any tap is sent. ' +
        'Actions: tap, type, swipe, key, home, open, wait, ocr, find, wait_text, assert, screenshot. ' +
        'Prefer find + tap(x,y) / wait_text / assert to avoid extra screenshot round trips.',
        {
            steps: {
                type: 'array',
                description: 'ordered actions, e.g. [{"action":"find","text":"发送"},{"action":"tap","text":"发送"},{"action":"wait_text","text":"已发送"}]',
                items: {
                    type: 'object',
                    properties: {
                        action: S('tap | type | swipe | key | home | open | wait | ocr | find | wait_text | assert | screenshot'),
                        text: S('tap/find/wait_text/assert: element or screen text; type: text to type'),
                        x: N('tap: x point'), y: N('tap: y point'),
                        from_x: N('swipe start x'), from_y: N('swipe start y'),
                        to_x: N('swipe end x'), to_y: N('swipe end y'),
                        duration_ms: N('swipe duration'),
                        key: S('key name for key action, e.g. return/backspace'),
                        bundle_id: S('open: bundle id or URL'),
                        ms: N('wait: milliseconds / wait_text: timeout ms'),
                        disappear: B('wait_text/assert: wait for text to disappear'),
                        limit: N('find: max matches')
                    },
                    required: ['action']
                }
            },
            observe: B('return compact UI after the screen settles (default true)'),
            compact: B('return only changed UI lines (incremental), default true'),
            full_ui: B('also return the full raw UI tree for debugging, default false'),
            screenshot: B('also return a final screenshot (default false)'),
            settle_ms: N('screen settle timeout in ms, default 2500'),
            clickable_only: B('only clickable elements in the returned UI, default true'),
            stop_on_error: B('stop the whole batch on first failed step, default true')
        }, ['steps']),
    tool('watch_screen',
        'Watch the screen for a short window without model round trips: capture frames at 1-6 fps, detect scene changes, ' +
        'and return a change timeline plus keyframe images (and OCR text when ocr=true). ' +
        'Best for "watching" video/animation progress: the model gets events, not 30fps frames.',
        {
            fps: N('capture rate 1-6, default 3'),
            duration_ms: N('window length 500-8000, default 3000'),
            max_keyframes: N('max keyframe images returned, default 3'),
            ocr: B('OCR changed frames (vision engine), default true'),
            region: S('optional region "x,y,w,h" (reserved)')
        }, []),
    tool('wait_for_change',
        'Wait until the screen changes (pixel-level) or timeout. Much faster than a fixed sleep after tapping.',
        {
            timeout_ms: N('max wait, default 5000'),
            poll_ms: N('poll interval, default 120'),
            min_bytes: N('minimum JPEG byte delta to count as change, default 200')
        }, []),
    /* +ios24.8 效率工具：对标 DSH Go / dsh-ios-connect 的 phone_find / phone_wait。
     * 一次模型往返里把「找元素 / 等文本 / 断言」都在设备端闭环，避免
     * 「截图 -> 模型认坐标 -> 再点 -> 再截图复核」这种最贵的循环。 */
    tool('find_element',
        'Find UI elements by text/label in ONE call and return compact, directly-tappable points. ' +
        'Avoids a full screenshot + model-side coordinate guessing round trip. ' +
        'Returns plain-text lines "[i] text @ (x,y)" so even a text-only model can use it.',
        {
            text: S('text/label to match (substring, case-insensitive)'),
            exact: B('exact match instead of substring'),
            limit: N('max matches, default 12'),
            clickable_only: B('only clickable elements, default false (match all)')
        }, ['text']),
    tool('wait_for_text',
        'Wait on-device until a text appears (or disappears) on screen, then return compact UI. ' +
        'Replaces the "act -> screenshot -> model checks -> act again" loop with one tool call.',
        {
            text: S('text to wait for'),
            disappear: B('wait until text disappears instead of appears'),
            timeout_ms: N('max wait, default 6000'),
            poll_ms: N('poll interval, default 200'),
            ocr: B('also use OCR text when AX tree misses, default false')
        }, ['text']),
    tool('progress_status',
        'Report the live progress channel: current event snapshot, seq, SSE subscriber count, ' +
        'event buffer size and the exact endpoints the DSH Web UI progress panel uses.',
        {})
];

/* B 层工具名（上游在线时动态合并，离线时作为「需要 ios-mcp」的提示清单） */
const UPSTREAM_HINT_TOOLS = [
    'screenshot', 'get_screen_info', 'get_ui_elements', 'get_element_at_point',
    'tap_screen', 'swipe_screen', 'long_press', 'double_tap', 'drag_and_drop',
    'input_text', 'type_text', 'press_key', 'press_home', 'press_power',
    'press_volume_up', 'press_volume_down', 'toggle_mute', 'wake_and_home',
    'tap_element', 'wait_for_element', 'wait_for_disappear', 'ocr_screen',
    'describe_screen', 'get_frontmost_app', 'kill_app', 'install_app',
    'uninstall_app', 'get_app_info', 'get_crash_logs', 'read_crash_log',
    'get_brightness', 'set_brightness', 'get_volume', 'set_volume',
    'get_clipboard', 'set_clipboard', 'list_running_apps'
];

function textResult(value, isError) {
    const s = typeof value === 'string' ? value : JSON.stringify(value, null, 2);
    return { content: [{ type: 'text', text: s.slice(0, MAX_OUTPUT) }], isError: !!isError };
}
function err(msg) { return textResult({ error: msg }, true); }

function sh(cmd, opts) {
    return new Promise((resolve) => {
        const o = opts || {};
        cp.execFile('/bin/sh', ['-c', cmd], {
            timeout: o.timeout || CMD_TIMEOUT,
            maxBuffer: MAX_OUTPUT * 2,
            cwd: o.cwd || undefined,
            env: Object.assign({}, process.env, {
                PATH: [JB + '/usr/bin', JB + '/bin', '/usr/bin', '/bin', '/usr/sbin', '/sbin', process.env.PATH || ''].join(':')
            })
        }, (error, stdout, stderr) => {
            resolve({
                code: error ? (error.code === null ? 124 : (error.code || 1)) : 0,
                stdout: String(stdout || '').slice(-MAX_OUTPUT),
                stderr: String(stderr || '').slice(-MAX_OUTPUT),
                killed: !!(error && error.killed)
            });
        });
    });
}

function parsePlistStrings(p) {
    try {
        const s = fs.readFileSync(p, 'utf8');
        const pick = (key) => {
            const re = new RegExp('<key>' + key + '</key>\\s*<string>([\\s\\S]*?)</string>', 'i');
            const m = s.match(re);
            return m ? m[1].trim() : '';
        };
        return {
            bundle_id: pick('CFBundleIdentifier'),
            name: pick('CFBundleName') || pick('CFBundleDisplayName'),
            executable: pick('CFBundleExecutable'),
            version: pick('CFBundleShortVersionString')
        };
    } catch (_) {
        return { bundle_id: '', name: '', executable: '', version: '' };
    }
}

async function listApps(extra) {
    const roots = [JB + '/Applications', '/Applications'];
    if (extra) roots.push(extra);
    const out = [];
    for (const root of roots) {
        let entries = [];
        try { entries = fs.readdirSync(root, { withFileTypes: true }); } catch (_) { continue; }
        for (const e of entries) {
            if (!e.name.endsWith('.app')) continue;
            const dir = path.join(root, e.name);
            const plist = path.join(dir, 'Info.plist');
            if (!fs.existsSync(plist)) continue;
            out.push(Object.assign({ app: e.name, path: dir, root }, parsePlistStrings(plist)));
        }
    }
    return out;
}

const crypto = require('node:crypto');

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const STEP_LABEL = { tap: '点按', type: '输入', swipe: '滑动', key: '按键', home: '回主屏', open: '打开', wait: '等待', ocr: '识别' };

function shotOf(result) {
    const list = result && Array.isArray(result.content) ? result.content : [];
    const img = list.find((c) => c && c.type === 'image' && c.data);
    if (!img) return null;
    return { data: img.data, mimeType: img.mimeType || 'image/jpeg' };
}

function uiOf(result) {
    if (!result) return null;
    if (result.structuredContent) return result.structuredContent;
    const list = Array.isArray(result.content) ? result.content : [];
    const t = list.find((c) => c && c.type === 'text');
    if (!t) return null;
    try { return JSON.parse(t.text); } catch (_) { return { raw: t.text }; }
}

async function shotHash() {
    const r = await upstreamCall('screenshot', {});
    const s = shotOf(r);
    if (!s) return null;
    return { hash: crypto.createHash('sha1').update(s.data).digest('hex'), bytes: s.data.length, shot: s };
}

async function nativeOk(name, args) {
    const r = await upstreamCall(name, args);
    return { ok: !(r && r.isError), result: r };
}

function stepText(s) {
    const a = s.action;
    if (a === 'tap') return s.text ? s.text : (s.x + ',' + s.y);
    if (a === 'type') return String(s.text || '').slice(0, 20);
    if (a === 'open') return String(s.bundle_id || '');
    if (a === 'wait') return (Number(s.ms) || 0) + 'ms';
    if (a === 'key') return String(s.key || '');
    return '';
}

async function runStep(s) {
    const a = String(s.action || '').toLowerCase();
    const t0 = Date.now();
    let r;
    switch (a) {
        case 'tap':
            if (s.text) r = await nativeOk('tap_element', { text: String(s.text) });
            else if (s.x !== undefined && s.y !== undefined) r = await nativeOk('tap_screen', { x: Number(s.x), y: Number(s.y) });
            else return { action: a, ok: false, error: 'tap needs text or x/y', ms: 0 };
            break;
        case 'type': {
            const text = String(s.text === undefined ? '' : s.text);
            r = await nativeOk('input_text', { text });
            if (!r.ok) r = await nativeOk('type_text', { text });
            break;
        }
        case 'swipe':
            r = await nativeOk('swipe_screen', {
                fromX: Number(s.from_x), fromY: Number(s.from_y),
                toX: Number(s.to_x), toY: Number(s.to_y),
                duration: Number(s.duration_ms) || 0.3
            });
            break;
        case 'key':
            r = await nativeOk('press_key', { key: String(s.key || 'return') });
            break;
        case 'home':
            r = await nativeOk('press_home', {});
            break;
        case 'open':
            r = await nativeOk('launch_app', { bundle_id: String(s.bundle_id || '') });
            break;
        case 'wait':
            await sleep(Math.min(Number(s.ms) || 300, 10000));
            return { action: a, ok: true, ms: Date.now() - t0 };
        case 'ocr':
            r = await nativeOk('ocr_screen', { engine: 'vision' });
            break;
        default:
            return { action: a, ok: false, error: 'unknown action: ' + a, ms: 0 };
    }
    return { action: a, ok: r.ok, ms: Date.now() - t0 };
}

async function settle(ms, clickableOnly) {
    const deadline = Date.now() + Math.min(Math.max(Number(ms) || 2500, 300), 8000);
    let prev = '';
    let stable = 0;
    while (Date.now() < deadline) {
        const r = await upstreamCall('get_ui_elements', { clickable_only: !!clickableOnly, limit: 80 });
        const ui = uiOf(r);
        const key = ui ? crypto.createHash('sha1').update(JSON.stringify(ui)).digest('hex') : '';
        if (key && key === prev) {
            stable += 1;
            if (stable >= 2) return ui;
        } else {
            stable = 0;
            prev = key;
        }
        await sleep(140);
    }
    const r = await upstreamCall('get_ui_elements', { clickable_only: !!clickableOnly, limit: 80 });
    return uiOf(r);
}

const VALID_ACTIONS = new Set(['tap', 'type', 'swipe', 'key', 'home', 'open', 'wait', 'ocr', 'find', 'wait_text', 'assert', 'screenshot']);

/* 批量执行前先整张清单校验（dsh-ios-connect phone_batch 的做法）：任一步
 * 动作名写错 / 参数缺失，整批不执行，避免已发出的点击无法撤回。 */
function validateSteps(steps) {
    const problems = [];
    for (let i = 0; i < steps.length; i++) {
        const s = steps[i] || {};
        const a = String(s.action || '').toLowerCase();
        const where = 'steps[' + i + ']';
        if (!VALID_ACTIONS.has(a)) { problems.push(where + ': unknown action "' + a + '"'); continue; }
        if (a === 'tap' && !s.text && (s.x === undefined || s.y === undefined)) problems.push(where + ': tap needs text or x/y');
        if (a === 'type' && s.text === undefined) problems.push(where + ': type needs text');
        if (a === 'swipe' && [s.from_x, s.from_y, s.to_x, s.to_y].some((v) => v === undefined)) problems.push(where + ': swipe needs from_x/from_y/to_x/to_y');
        if (a === 'open' && !s.bundle_id) problems.push(where + ': open needs bundle_id');
        if (a === 'find' && !s.text) problems.push(where + ': find needs text');
        if (a === 'wait_text' && !s.text) problems.push(where + ': wait_text needs text');
        if (a === 'assert' && !s.text) problems.push(where + ': assert needs text');
    }
    return problems;
}

async function phoneAct(a) {
    const steps = Array.isArray(a.steps) ? a.steps.slice(0, 40) : [];
    if (!steps.length) return err('steps must be a non-empty array');
    const problems = validateSteps(steps);
    if (problems.length) {
        hudPublish('error', '批量步骤校验失败：' + problems.length + ' 处', { tool: 'phone_act', ok: false });
        return textResult({ ok: false, rejected: true, reason: 'pre-validation failed, no step executed', problems,
            valid_actions: Array.from(VALID_ACTIONS) }, true);
    }
    const total = steps.length;
    const out = [];
    const t0 = Date.now();
    const runId = 'act-' + t0;
    hudPublish('running', `准备执行 ${total} 步`, { tool: 'phone_act', action: 'validate', step: 0, total, run_id: runId });
    for (let i = 0; i < total; i++) {
        const s = steps[i] || {};
        const act = String(s.action || '').toLowerCase();
        hudPublish('running', `第 ${i + 1}/${total} 步：${STEP_LABEL[act] || act} ${stepText(s)}`.trim(),
            { tool: 'phone_act', action: act, step: i + 1, total, run_id: runId });
        let r;
        if (act === 'find') {
            const f = await findElement({ text: s.text, limit: s.limit || 8, clickable_only: s.clickable_only !== false });
            const j = JSON.parse(f.content[0].text);
            r = { action: act, ok: j.found > 0, ms: j.elapsed_ms, found: j.found, matches: j.matches };
        } else if (act === 'wait_text') {
            const w = await waitForText({ text: s.text, disappear: !!s.disappear, timeout_ms: s.timeout_ms || s.ms || 6000 });
            const j = JSON.parse(w.content[0].text);
            r = { action: act, ok: !!j.matched, ms: j.elapsed_ms, matched: j.matched };
        } else if (act === 'assert') {
            const f = await findElement({ text: s.text, limit: 1 });
            const j = JSON.parse(f.content[0].text);
            r = { action: act, ok: s.disappear ? j.found === 0 : j.found > 0, ms: j.elapsed_ms, found: j.found };
        } else if (act === 'screenshot') {
            const sh = await shotHash();
            r = { action: act, ok: !!sh, ms: 0, bytes: sh ? sh.bytes : 0 };
        } else {
            r = await runStep(s);
        }
        out.push(r);
        if (!r.ok && a.stop_on_error !== false) {
            hudPublish('error', `第 ${i + 1} 步失败：${stepText(s) || act}`, { tool: 'phone_act', action: act, step: i + 1, total, ok: false, run_id: runId });
            return textResult({ ok: false, failed_at: i + 1, steps: out }, true);
        }
    }
    hudPublish('running', '等待界面稳定…', { tool: 'phone_act', action: 'settle', step: total, total, run_id: runId });
    const observe = a.observe !== false;
    const ui = observe ? await settle(a.settle_ms, a.clickable_only !== false) : null;
    // +ios24.8：默认返回紧凑纯文本 + 增量 diff，不再把整棵 JSON 树塞给模型。
    // a.full_ui=true 才回退到完整结构（兼容旧会话/调试）。
    const compact = observe ? (a.compact === false ? compactUI(ui, { limit: 60 }) : uiDelta(ui, { limit: 60 })) : null;
    const payload = { ok: true, steps: out, elapsed_ms: Date.now() - t0, ui: compact,
        ui_lines: compact ? compact.lines : [], ui_unchanged: compact ? compact.changed === false : null };
    if (a.full_ui) payload.settled_ui = ui;
    if (a.screenshot) {
        const sh = await shotHash();
        if (sh) {
            hudPublish('done', `${total} 步完成 · ${sh.bytes}B 画面`, { tool: 'phone_act', action: 'done', step: total, total, ok: true, run_id: runId });
            return {
                content: [{ type: 'text', text: JSON.stringify(payload).slice(0, MAX_OUTPUT) },
                          { type: 'image', data: sh.shot.data, mimeType: sh.shot.mimeType }]
            };
        }
    }
    hudPublish('done', `${total} 步完成 · ${Date.now() - t0}ms`, { tool: 'phone_act', action: 'done', step: total, total, ok: true, run_id: runId });
    return textResult(payload);
}

async function watchScreen(a) {
    const fps = Math.min(Math.max(Number(a.fps) || 3, 1), 6);
    const windowMs = Math.min(Math.max(Number(a.duration_ms) || 3000, 500), 8000);
    const maxKf = Math.min(Math.max(Number(a.max_keyframes) || 3, 0), 5);
    const wantOcr = a.ocr !== false;
    const interval = Math.round(1000 / fps);
    const t0 = Date.now();
    const timeline = [];
    const keyframes = [];
    const ocr = [];
    let lastHash = '';
    let frames = 0;
    let prevBytes = 0;
    hudPublish('running', `看屏 ${fps}fps · ${windowMs}ms`, {});
    while (Date.now() - t0 < windowMs) {
        const tick = Date.now();
        const sh = await shotHash();
        if (sh) {
            frames += 1;
            if (sh.hash !== lastHash) {
                const delta = lastHash ? Math.abs(sh.bytes - prevBytes) : sh.bytes;
                lastHash = sh.hash;
                prevBytes = sh.bytes;
                const rec = { t_ms: tick - t0, delta_bytes: delta };
                timeline.push(rec);
                if (keyframes.length < maxKf) {
                    keyframes.push({ t_ms: rec.t_ms, data: sh.shot.data, mimeType: sh.shot.mimeType });
                    if (wantOcr && ocr.length < maxKf) {
                        const o = await nativeOk('ocr_screen', { engine: 'vision' });
                        if (o.ok) {
                            const ui = uiOf(o.result);
                            const text = ui ? JSON.stringify(ui) : (o.result.content && o.result.content[0] && o.result.content[0].text) || '';
                            ocr.push({ t_ms: rec.t_ms, text: String(text).slice(0, 2000) });
                        }
                    }
                }
            }
        }
        const wait = interval - (Date.now() - tick);
        if (wait > 0) await sleep(wait);
    }
    const summary = {
        window_ms: windowMs, fps, frames_captured: frames,
        changes: timeline.length,
        timeline: timeline.slice(0, 40),
        ocr,
        keyframes_returned: keyframes.length,
        note: 'Pixel-level changes only; keyframes are the first changed frames.'
    };
    hudPublish('done', `${frames} 帧 · ${timeline.length} 次变化`, {});
    const content = [{ type: 'text', text: JSON.stringify(summary).slice(0, MAX_OUTPUT) }];
    for (const k of keyframes) content.push({ type: 'image', data: k.data, mimeType: k.mimeType });
    return { content };
}

async function waitForChange(a) {
    const timeout = Math.min(Math.max(Number(a.timeout_ms) || 5000, 200), 30000);
    const poll = Math.min(Math.max(Number(a.poll_ms) || 120, 60), 1000);
    const minDelta = Number(a.min_bytes) || 200;
    const t0 = Date.now();
    const base = await shotHash();
    if (!base) return err('screenshot unavailable (native provider offline?)');
    hudPublish('running', '等待画面变化…', {});
    let polls = 0;
    while (Date.now() - t0 < timeout) {
        await sleep(poll);
        polls += 1;
        const cur = await shotHash();
        if (cur && cur.hash !== base.hash && Math.abs(cur.bytes - base.bytes) >= minDelta) {
            hudPublish('done', `画面已变化 · ${Date.now() - t0}ms`, {});
            return textResult({ changed: true, elapsed_ms: Date.now() - t0, polls, bytes_delta: cur.bytes - base.bytes });
        }
    }
    hudPublish('done', '未检测到变化', {});
    return textResult({ changed: false, elapsed_ms: Date.now() - t0, polls });
}

/* ------------------------------------------------- +ios24.8 效率：紧凑 UI 树
 * 原生 get_ui_elements 返回的是一整棵嵌套 JSON（几十 KB），模型每读一次都
 * 要吞掉整棵树。DSH Go 的做法是「控件树转纯文本，纯文本模型也能用」；
 * dsh-ios-connect 则把「按文本找控件直接给坐标」「等文本出现」做成工具，
 * 让这两步不再需要截图与模型往返。这里两者都实现，并且只回传变化量。
 */
function extractElements(ui) {
    if (!ui) return [];
    let list = [];
    if (Array.isArray(ui)) list = ui;
    else if (Array.isArray(ui.elements)) list = ui.elements;
    else if (Array.isArray(ui.nodes)) list = ui.nodes;
    else if (Array.isArray(ui.children)) list = ui.children;
    else if (ui.structuredContent) return extractElements(ui.structuredContent);
    const out = [];
    const walk = (arr, depth) => {
        if (!Array.isArray(arr) || depth > 8) return;
        for (const e of arr) {
            if (!e || typeof e !== 'object') continue;
            out.push(e);
            if (Array.isArray(e.children)) walk(e.children, depth + 1);
            else if (Array.isArray(e.elements)) walk(e.elements, depth + 1);
        }
    };
    walk(list, 0);
    return out;
}

function elemText(e) {
    for (const k of ['text', 'label', 'name', 'title', 'value', 'contentDescription', 'accessibilityLabel']) {
        if (e[k] !== undefined && e[k] !== null && String(e[k]).trim()) return String(e[k]).trim();
    }
    return '';
}

function elemPoint(e) {
    // 兼容 ios-mcp / WDA / AX 各家字段：center / x,y / frame / rect / bounds
    let cx = null, cy = null;
    for (const k of ['centerX', 'cx', 'center_x']) if (e[k] !== undefined) cx = Number(e[k]);
    for (const k of ['centerY', 'cy', 'center_y']) if (e[k] !== undefined) cy = Number(e[k]);
    if (cx === null && e.x !== undefined) cx = Number(e.x);
    if (cy === null && e.y !== undefined) cy = Number(e.y);
    const f = e.frame || e.rect || e.bounds;
    if ((cx === null || cy === null) && f) {
        let m;
        if (typeof f === 'string') {
            m = f.match(/\{\{?\s*([\d.]+)\s*,\s*([\d.]+)\s*\}\s*,\s*\{\{?\s*([\d.]+)\s*,\s*([\d.]+)/);
            if (m) { cx = Number(m[1]) + Number(m[3]) / 2; cy = Number(m[2]) + Number(m[4]) / 2; }
        } else if (typeof f === 'object') {
            const fx = Number(f.x !== undefined ? f.x : f.origin && f.origin.x);
            const fy = Number(f.y !== undefined ? f.y : f.origin && f.origin.y);
            const fw = Number(f.width !== undefined ? f.width : f.size && f.size.width);
            const fh = Number(f.height !== undefined ? f.height : f.size && f.size.height);
            if (!Number.isNaN(fx) && !Number.isNaN(fy)) {
                cx = fx + (Number.isNaN(fw) ? 0 : fw / 2);
                cy = fy + (Number.isNaN(fh) ? 0 : fh / 2);
            }
        }
    }
    if (e.center && typeof e.center === 'object') {
        if (cx === null && e.center.x !== undefined) cx = Number(e.center.x);
        if (cy === null && e.center.y !== undefined) cy = Number(e.center.y);
    }
    return { x: cx, y: cy, ok: Number.isFinite(cx) && Number.isFinite(cy) };
}

function compactUI(ui, opts) {
    const o = opts || {};
    const limit = Math.min(Math.max(Number(o.limit) || 40, 1), 120);
    const els = extractElements(ui);
    const lines = [];
    let i = 0;
    for (const e of els) {
        const t = elemText(e);
        if (!t && !o.includeEmpty) continue;
        if (o.clickable_only && e.clickable === false) continue;
        const p = elemPoint(e);
        const tag = e.type || e.role || e.className || '';
        const pos = p.ok ? '@(' + Math.round(p.x) + ',' + Math.round(p.y) + ')' : '@(?)';
        const click = e.clickable === true ? '*' : ' ';
        lines.push('[' + i + ']' + click + ' ' + (t || tag || '·').slice(0, 48) + ' ' + pos);
        i += 1;
        if (lines.length >= limit) break;
    }
    return { count: els.length, shown: lines.length, lines };
}

let lastUIKey = '';
function uiDelta(ui, opts) {
    // 只回传相对上一次观察发生变化的行，减少 token 与传输（DSH Go 增量思路）。
    const c = compactUI(ui, opts);
    const key = crypto.createHash('sha1').update(c.lines.join('\n')).digest('hex');
    const changed = key !== lastUIKey;
    lastUIKey = key;
    return { changed, total: c.count, lines: changed ? c.lines : [], note: changed ? undefined : 'UI unchanged since last observation' };
}

async function readUI(args) {
    const r = await upstreamCall('get_ui_elements', {
        clickable_only: !!(args && args.clickable_only),
        limit: Math.min(Number(args && args.limit) || 80, 200)
    });
    return uiOf(r);
}

async function findElement(a) {
    const needle = String(a.text || '').trim().toLowerCase();
    if (!needle) return err('text is required');
    const t0 = Date.now();
    hudPublish('running', '查找「' + String(a.text).slice(0, 20) + '」', { tool: 'find_element' });
    const ui = await readUI({ clickable_only: false, limit: 200 });
    const els = extractElements(ui);
    const limit = Math.min(Math.max(Number(a.limit) || 12, 1), 40);
    const hits = [];
    for (let i = 0; i < els.length && hits.length < limit; i++) {
        const e = els[i];
        if (a.clickable_only && e.clickable === false) continue;
        const t = elemText(e);
        if (!t) continue;
        const hay = t.toLowerCase();
        const match = a.exact ? hay === needle : hay.includes(needle);
        if (!match) continue;
        const p = elemPoint(e);
        hits.push({ i, text: t.slice(0, 60), x: p.ok ? Math.round(p.x) : null, y: p.ok ? Math.round(p.y) : null, clickable: e.clickable !== false });
    }
    hudPublish('done', '找到 ' + hits.length + ' 个 · ' + (Date.now() - t0) + 'ms', { tool: 'find_element', ok: true, ttl: 1400 });
    const lines = hits.map((h) => '[' + h.i + '] ' + h.text + ' @(' + h.x + ',' + h.y + ')');
    return textResult({ found: hits.length, query: a.text, elapsed_ms: Date.now() - t0, matches: hits, lines,
        hint: hits.length ? 'Pass {"action":"tap","x":..,"y":..} in phone_act, or use {"action":"tap","text":".."}.' : 'No match; try ocr_screen or broader text.' });
}

async function waitForText(a) {
    const needle = String(a.text || '').trim().toLowerCase();
    if (!needle) return err('text is required');
    const timeout = Math.min(Math.max(Number(a.timeout_ms) || 6000, 300), 30000);
    const poll = Math.min(Math.max(Number(a.poll_ms) || 200, 100), 1000);
    const t0 = Date.now();
    let polls = 0;
    hudPublish('running', (a.disappear ? '等待「' : '等待出现「') + String(a.text).slice(0, 20) + (a.disappear ? '」消失' : '」'), { tool: 'wait_for_text' });
    while (Date.now() - t0 < timeout) {
        polls += 1;
        let hay = '';
        const ui = await readUI({ clickable_only: false, limit: 200 });
        hay = extractElements(ui).map(elemText).join('\n').toLowerCase();
        if (a.ocr && !hay.includes(needle)) {
            const o = await nativeOk('ocr_screen', { engine: 'vision' });
            if (o.ok) hay += '\n' + JSON.stringify(uiOf(o.result) || '').toLowerCase();
        }
        const present = hay.includes(needle);
        if (a.disappear ? !present : present) {
            const d = uiDelta(ui, { limit: 40 });
            hudPublish('done', (a.disappear ? '已消失' : '已出现') + ' · ' + (Date.now() - t0) + 'ms', { tool: 'wait_for_text', ok: true, ttl: 1400 });
            return textResult({ matched: true, mode: a.disappear ? 'disappear' : 'appear', text: a.text,
                elapsed_ms: Date.now() - t0, polls, ui_delta: d });
        }
        await sleep(poll);
    }
    hudPublish('done', '等待超时（' + timeout + 'ms）', { tool: 'wait_for_text', ok: false, ttl: 1400 });
    return textResult({ matched: false, text: a.text, elapsed_ms: Date.now() - t0, polls });
}

async function callLocal(name, args) {
    const a = args || {};
    switch (name) {
        case 'get_device_info': {
            let uname = '';
            const r = await sh('uname -a');
            uname = r.stdout.trim();
            let jb = { present: fs.existsSync(JB), symlink: false };
            try { jb.symlink = fs.lstatSync(JB).isSymbolicLink(); } catch (_) {}
            return textResult({
                hostname: os.hostname(), platform: os.platform(), arch: os.arch(),
                release: os.release(), type: os.type(), uname,
                cpus: os.cpus().length, cpu_model: (os.cpus()[0] || {}).model || '',
                total_memory_bytes: os.totalmem(), free_memory_bytes: os.freemem(),
                uptime_seconds: os.uptime(), node: process.version,
                jailbreak_root: jb, dsh_home: DSH_HOME,
                bridge: { host: HOST, port: PORT, upstream: UPSTREAM }
            });
        }
        case 'list_dir': {
            const p = String(a.path || '');
            if (!p.startsWith('/')) return err('path must be absolute');
            let items;
            try { items = fs.readdirSync(p, { withFileTypes: true }); } catch (e) { return err(String(e.message)); }
            return textResult(items.map((d) => {
                let st = null;
                try { st = fs.statSync(path.join(p, d.name)); } catch (_) {}
                return { name: d.name, type: d.isDirectory() ? 'dir' : (d.isSymbolicLink() ? 'link' : 'file'), size: st ? st.size : null, mtime: st ? st.mtime.toISOString() : null };
            }));
        }
        case 'read_file': {
            const p = String(a.path || '');
            if (!p.startsWith('/')) return err('path must be absolute');
            let st;
            try { st = fs.statSync(p); } catch (e) { return err(String(e.message)); }
            const cap = Math.min(Number(a.max_bytes) || MAX_FILE, MAX_FILE);
            if (st.size > cap) return err('file too large: ' + st.size + ' > ' + cap);
            try { return textResult(fs.readFileSync(p, 'utf8')); } catch (e) { return err(String(e.message)); }
        }
        case 'write_file': {
            const p = String(a.path || '');
            const content = String(a.content === undefined ? '' : a.content);
            if (!p.startsWith('/')) return err('path must be absolute');
            if (Buffer.byteLength(content) > MAX_FILE) return err('content exceeds ' + MAX_FILE + ' bytes');
            try {
                fs.mkdirSync(path.dirname(p), { recursive: true });
                if (a.append) fs.appendFileSync(p, content, 'utf8');
                else fs.writeFileSync(p, content, 'utf8');
                return textResult({ written: p, bytes: Buffer.byteLength(content), append: !!a.append });
            } catch (e) { return err(String(e.message)); }
        }
        case 'run_command': {
            const cmd = String(a.command || '');
            if (!cmd.trim()) return err('command is empty');
            const r = await sh(cmd, { cwd: a.cwd, timeout: Math.min(Number(a.timeout_ms) || CMD_TIMEOUT, 300000) });
            return textResult({ exit_code: r.code, killed: r.killed, stdout: r.stdout, stderr: r.stderr });
        }
        case 'list_apps':
            return textResult({ count: (await listApps(a.root)).length, apps: await listApps(a.root) });
        case 'launch_app':
        case 'open_url': {
            const target = name === 'open_url' ? String(a.url || '') : (String(a.bundle_id || '') || String(a.url || ''));
            if (!target) return err('provide bundle_id or url');
            const q = "'" + target.replace(/'/g, "'\\''") + "'";
            const attempts = [
                'uiopen ' + q,
                'open ' + q,
                'launchctl open ' + q,
                JB + '/usr/bin/uiopen ' + q,
                JB + '/usr/bin/open ' + q
            ];
            const tried = [];
            for (const c of attempts) {
                const r = await sh(c, { timeout: 15000 });
                tried.push({ cmd: c, exit_code: r.code, stderr: r.stderr.slice(0, 200) });
                if (r.code === 0) return textResult({ launched: target, via: c, tried });
            }
            return err('could not launch/open; uiopen/open/launchctl unavailable. tried=' + JSON.stringify(tried));
        }
        case 'list_processes': {
            const f = String(a.filter || '').replace(/[^a-zA-Z0-9_. -]/g, '');
            const r = await sh('ps aux' + (f ? ' | grep -F ' + "'" + f + "'" + ' | grep -v grep' : ''), { timeout: 20000 });
            return textResult({ exit_code: r.code, output: r.stdout });
        }
        case 'get_syslog': {
            const n = Math.min(Number(a.lines) || 200, 2000);
            const r = await sh('log show --last 5m --style syslog 2>/dev/null | tail -n ' + n, { timeout: 30000 });
            if (r.code === 0 && r.stdout.trim()) return textResult({ source: 'log show', lines: r.stdout });
            return textResult({
                available: false,
                hint: 'No usable system log tool on this device. The bundled provider ships /var/jb/usr/bin/mcp-logreader; check dsh-phone-bridge-ctl status.',
                fallback_output: r.stderr.slice(0, 500)
            });
        }
        case 'dsh_status': {
            const port = Number(a.port) || 3080;
            const r = await sh('ps aux | grep -F "dsh" | grep -v grep', { timeout: 15000 });
            const http = await new Promise((resolve) => {
                const req = http.request({ host: '127.0.0.1', port, path: '/', method: 'GET', timeout: 3000 }, (res) => {
                    res.resume(); resolve(res.statusCode);
                });
                req.on('error', () => resolve(0));
                req.on('timeout', () => { req.destroy(); resolve(0); });
                req.end();
            });
            return textResult({ web_port: port, web_http_status: http, web_reachable: http > 0, processes: r.stdout.trim().split('\n').filter(Boolean).slice(0, 20), bridge_alive: true });
        }
        case 'phone_bridge_status': {
            const up = await upstreamTools(true);
            return textResult({
                version: '1.0.0', protocol: PROTOCOL, endpoint: 'http://' + HOST + ':' + PORT + '/mcp',
                local_tools: LOCAL_TOOLS.length,
                upstream: { url: UPSTREAM, online: up.length > 0, tools: up.length, names: up.map((t) => t.name) },
                merged_tools: LOCAL_TOOLS.length + up.length,
                b_class_offline_hint: up.length === 0 ? UPSTREAM_HINT_TOOLS : []
            });
        }
        case 'phone_act':
            return phoneAct(a);
        case 'watch_screen':
            return watchScreen(a);
        case 'wait_for_change':
            return waitForChange(a);
        case 'find_element':
            return findElement(a);
        case 'wait_for_text':
            return waitForText(a);
        case 'progress_status': {
            const up = await upstreamTools(false);
            return textResult({
                version: '2.0.0', channel: 'sse+polling', seq: eventSeq,
                snapshot, events_buffered: eventRing.length, event_cap: EVENT_CAP,
                sse_subscribers: sseClients.size,
                endpoints: {
                    sse: 'http://' + HOST + ':' + PORT + '/events',
                    poll: 'http://' + HOST + ':' + PORT + '/progress?since=<seq>',
                    hud_file: HUD_PATH
                },
                upstream_online: up.length > 0,
                note: 'The DSH Web UI progress panel subscribes to /events; HUD reads hud.json.'
            });
        }
        default:
            return err('unknown local tool: ' + name);
    }
}

/* ------------------------------------------------------- 上游 ios-mcp 转发 */
let upstreamCache = { at: 0, tools: [], session: '' };

function postJson(url, payload, timeoutMs) {
    return new Promise((resolve, reject) => {
        let u;
        try { u = new URL(url); } catch (e) { reject(e); return; }
        const body = JSON.stringify(payload);
        const headers = {
            'Content-Type': 'application/json',
            'Accept': 'application/json, text/event-stream',
            'MCP-Protocol-Version': PROTOCOL,
            'Content-Length': Buffer.byteLength(body)
        };
        if (payload.method !== 'initialize' && upstreamCache.session) {
            headers['Mcp-Session-Id'] = upstreamCache.session;
        }
        const req = http.request({
            hostname: u.hostname, port: u.port, path: u.pathname + (u.search || ''),
            method: 'POST', headers, timeout: timeoutMs || 2500
        }, (res) => {
            const sid = res.headers['mcp-session-id'];
            if (sid) upstreamCache.session = Array.isArray(sid) ? sid[0] : sid;
            let raw = '';
            res.on('data', (c) => { raw += c; });
            res.on('end', () => {
                // Streamable HTTP 可能返回 application/json 或 text/event-stream
                let text = raw.trim();
                if (res.headers['content-type'] && String(res.headers['content-type']).includes('text/event-stream')) {
                    const lines = text.split('\n').filter((l) => l.startsWith('data:'));
                    text = lines.length ? lines[lines.length - 1].slice(5).trim() : '';
                }
                if (!text) { resolve(null); return; }
                try { resolve(JSON.parse(text)); } catch (_) { resolve(null); }
            });
        });
        req.on('error', reject);
        req.on('timeout', () => { req.destroy(); reject(new Error('upstream timeout')); });
        req.write(body);
        req.end();
    });
}

async function upstreamTools(force) {
    const now = Date.now();
    if (!force && upstreamCache.tools.length && now - upstreamCache.at < 30000) return upstreamCache.tools;
    upstreamCache.at = now;
    try {
        const init = await postJson(UPSTREAM, {
            jsonrpc: '2.0', id: 1, method: 'initialize',
            params: { protocolVersion: PROTOCOL, capabilities: {}, clientInfo: { name: 'dsh-ios-phone-bridge', version: '1.0.0' } }
        }, 2000);
        if (!init || !init.result) { upstreamCache.tools = []; return []; }
        // notification: notifications/initialized（上游没收到也不影响列工具）
        postJson(UPSTREAM, { jsonrpc: '2.0', method: 'notifications/initialized' }, 1500).catch(() => {});
        const listed = await postJson(UPSTREAM, { jsonrpc: '2.0', id: 2, method: 'tools/list', params: {} }, 2500);
        const tools = listed && listed.result && Array.isArray(listed.result.tools) ? listed.result.tools : [];
        upstreamCache.tools = tools;
        return tools;
    } catch (_) {
        upstreamCache.tools = [];
        return [];
    }
}

async function upstreamCall(name, args) {
    try {
        await upstreamTools(false);
        const r = await postJson(UPSTREAM, {
            jsonrpc: '2.0', id: 3, method: 'tools/call',
            params: { name, arguments: args || {} }
        }, 120000);
        if (!r) return err('upstream ios-mcp returned no response');
        if (r.error) return textResult({ upstream_error: r.error }, true);
        return r.result || textResult({});
    } catch (e) {
        return err('upstream ios-mcp unreachable: ' + String(e.message || e));
    }
}

/* ------------------------------------------------------------- JSON-RPC 分发 */
function commonHeaders() {
    return {
        'Content-Type': 'application/json',
        'MCP-Protocol-Version': PROTOCOL,
        'Mcp-Session-Id': SESSION,
        'Access-Control-Allow-Origin': '*',
        'Access-Control-Allow-Headers': 'Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id'
    };
}
function reply(res, id, result) {
    res.writeHead(200, commonHeaders());
    res.end(JSON.stringify({ jsonrpc: '2.0', id, result }));
}
function replyError(res, id, code, message) {
    res.writeHead(200, commonHeaders());
    res.end(JSON.stringify({ jsonrpc: '2.0', id, error: { code, message } }));
}

async function dispatch(msg, res) {
    const method = msg.method;
    if (msg.id === undefined) { // notification
        res.writeHead(202, commonHeaders());
        res.end();
        return;
    }
    switch (method) {
        case 'initialize':
            return reply(res, msg.id, {
                protocolVersion: PROTOCOL,
                capabilities: { tools: { listChanged: false } },
                serverInfo: { name: 'dsh-ios-phone-bridge', version: '1.0.0' },
                instructions: 'On-device iOS toolchain for DSH. A-class tools work out of the box; B-class (screen/touch/OCR) come from the bundled SpringBoard provider dsh-ios-control on 127.0.0.1:8090 (shipped with dev.airdevs.dsh-app; respring once after install).'
            });
        case 'ping':
            return reply(res, msg.id, {});
        case 'tools/list': {
            const up = await upstreamTools(false);
            const localNames = new Set(LOCAL_TOOLS.map((t) => t.name));
            const merged = LOCAL_TOOLS.concat(up.filter((t) => !localNames.has(t.name)));
            return reply(res, msg.id, { tools: merged });
        }
        case 'tools/call': {
            const name = msg.params && msg.params.name;
            const args = (msg.params && msg.params.arguments) || {};
            if (!name) return replyError(res, msg.id, -32602, 'missing tool name');
            const localNames = new Set(LOCAL_TOOLS.map((t) => t.name));
            const t0 = Date.now();
            if (localNames.has(name)) {
                // +ios24.8：每个工具调用都有「开始」事件，批量/看屏类工具内部
                // 还会自己逐步推事件；这里只在结束时补一条汇总。
                hudPublish('running', `调用 ${name}`, { tool: name, action: 'tool_start' });
                const out = await callLocal(name, args);
                if (name !== 'phone_act' && name !== 'watch_screen' && name !== 'wait_for_change') {
                    hudPublish(out && out.isError ? 'error' : 'done',
                        `${name} · ${Date.now() - t0}ms`, { tool: name, action: 'tool_done',
                        ok: !(out && out.isError), ttl: 1400 });
                }
                return reply(res, msg.id, out);
            }
            // 工具清单 30s 缓存；未命中才强制刷新一次。旧实现每次都 initialize+list，
            // 白白多出 3 个回环请求，是操控慢的主要来源之一。
            let up = await upstreamTools(false);
            if (!up.some((t) => t.name === name)) up = await upstreamTools(true);
            if (up.some((t) => t.name === name)) {
                hudPublish('running', `调用 ${name}`, { tool: name, action: 'tool_start' });
                const out = await upstreamCall(name, args);
                hudPublish(out && out.isError ? 'error' : 'done', `${name} · ${Date.now() - t0}ms`,
                    { tool: name, action: 'tool_done', ok: !(out && out.isError), ttl: 1400 });
                return reply(res, msg.id, out);
            }
            if (UPSTREAM_HINT_TOOLS.includes(name)) {
                return reply(res, msg.id, textResult({
                    error: 'B-class tool "' + name + '" requires the bundled native provider dsh-ios-control on 127.0.0.1:8090.',
                    how_to_enable: [
                        'The provider ships in dev.airdevs.dsh-app (dsh-ios-control.dylib + plist)',
                        'After installing/upgrading, respring once so ElleKit loads it into SpringBoard',
                        'Check dsh-phone-bridge-ctl status; it reports upstream online + tool count',
                        'Keep the device unlocked; the bridge auto-merges tools on the next tools/list'
                    ],
                    local_alternatives: ['run_command', 'list_apps', 'launch_app', 'open_url', 'get_device_info', 'dsh_status']
                }, true));
            }
            return replyError(res, msg.id, -32601, 'unknown tool: ' + name);
        }
        case 'resources/list':
            return reply(res, msg.id, { resources: [] });
        case 'prompts/list':
            return reply(res, msg.id, { prompts: [] });
        default:
            return replyError(res, msg.id, -32601, 'method not found: ' + method);
    }
}

function corsHeaders(extra) {
    return Object.assign(commonHeaders(), {
        'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
        'Cache-Control': 'no-cache, no-transform',
        'Connection': 'keep-alive',
        'X-Accel-Buffering': 'no'
    }, extra || {});
}

const server = http.createServer((req, res) => {
    const url = String(req.url || '');
    // ---- /health ----
    if (req.method === 'GET' && (url === '/health' || url === '/' || url.startsWith('/health?'))) {
        res.writeHead(200, corsHeaders({ 'Content-Type': 'application/json' }));
        res.end(JSON.stringify({
            status: 'ok', server: 'dsh-ios-phone-bridge', version: '2.0.0',
            protocolVersion: PROTOCOL, local_tools: LOCAL_TOOLS.length,
            upstream: UPSTREAM, endpoint: 'http://' + HOST + ':' + PORT + '/mcp',
            progress: { channel: 'sse', seq: eventSeq, sse_subscribers: sseClients.size,
                sse: 'http://' + HOST + ':' + PORT + '/events',
                poll: 'http://' + HOST + ':' + PORT + '/progress' },
            hud_file: HUD_PATH
        }));
        return;
    }
    // ---- /events : Server-Sent Events（DSH Web UI 进度面板主通道）----
    // 断线续传：优先 Last-Event-ID 头，其次 ?since=；重连后先补发历史事件。
    if (req.method === 'GET' && (url === '/events' || url.startsWith('/events?'))) {
        let since = 0;
        const m = url.match(/[?&]since=(\d+)/);
        if (m) since = Number(m[1]);
        const laid = req.headers['last-event-id'];
        if (laid && Number(laid) > since) since = Number(laid);
        res.writeHead(200, corsHeaders({
            'Content-Type': 'text/event-stream; charset=utf-8',
            'Access-Control-Allow-Headers': 'Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id, Last-Event-ID'
        }));
        res.write('retry: 1200\n\n');
        // 先补发断线期间的历史事件（有界环形缓冲）
        for (const e of eventRing) {
            if (e.seq > since) res.write('id: ' + e.seq + '\nevent: ' + e.state + '\ndata: ' + JSON.stringify(e) + '\n\n');
        }
        // 没有历史时也要给一条当前快照，让面板立刻有内容、HUD 立刻可见
        res.write('event: snapshot\ndata: ' + JSON.stringify(snapshot) + '\n\n');
        sseClients.add(res);
        const keepAlive = setInterval(() => {
            try { res.write(': ping\n\n'); } catch (_) { /* 由 close 清理 */ }
        }, SSE_PING_MS);
        keepAlive.unref();
        req.on('close', () => { clearInterval(keepAlive); sseClients.delete(res); });
        return;
    }
    // ---- /progress : 轮询兜底（SSE 被 Web Clip / Safari 拦截时）----
    if (req.method === 'GET' && (url === '/progress' || url.startsWith('/progress?'))) {
        const m = url.match(/[?&]since=(\d+)/);
        const since = m ? Number(m[1]) : 0;
        const events = eventRing.filter((e) => e.seq > since).slice(-120);
        res.writeHead(200, corsHeaders({ 'Content-Type': 'application/json' }));
        res.end(JSON.stringify({ seq: eventSeq, now: Date.now(), snapshot, events,
            sse_subscribers: sseClients.size, cap: EVENT_CAP }));
        return;
    }
    if (req.method === 'OPTIONS') { res.writeHead(204, corsHeaders()); res.end(); return; }
    if (req.method !== 'POST' || !url.startsWith('/mcp')) {
        res.writeHead(404, corsHeaders()); res.end(); return;
    }
    let body = '';
    req.on('data', (c) => {
        body += c;
        if (body.length > 2 * 1024 * 1024) { req.destroy(); }
    });
    req.on('end', () => {
        let msg;
        try { msg = JSON.parse(body); } catch (_) {
            res.writeHead(400, commonHeaders());
            res.end(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } }));
            return;
        }
        Promise.resolve(dispatch(msg, res)).catch((e) => {
            if (!res.headersSent) replyError(res, msg.id, -32603, String(e && e.message || e));
            else res.end();
        });
    });
});

server.on('error', (e) => {
    if (e && e.code === 'EADDRINUSE') {
        // 已有实例在跑：直接退出，让 ensure 逻辑认为「端口已占用 = 已启动」。
        process.stderr.write('dsh-phone-bridge: port ' + PORT + ' already in use (another instance running), exit\n');
        process.exit(0);
    }
    process.stderr.write('dsh-phone-bridge: ' + String(e && e.message || e) + '\n');
    process.exit(1);
});

server.listen(PORT, HOST, () => {
    // +ios24.8：启动即发「就绪」事件并写 hud.json。旧实现要等第一次
    // tools/call 才写文件，真机上 HUD 因此永远 alpha=0（完全不可见）。
    // 现在桥一起来，原生 HUD 与 Web UI 面板都能立刻看到常驻状态。
    emitEvent('idle', '桥已连接 · 等待任务', { title: 'DSH 就绪', tool: '', action: 'ready', ok: true });
    process.stdout.write('dsh-phone-bridge: listening on http://' + HOST + ':' + PORT + '/mcp (upstream ' + UPSTREAM + ')\n');
    process.stdout.write('dsh-phone-bridge: progress SSE /events + poll /progress + hud ' + HUD_PATH + '\n');
});
