/*!
 * dsh-ios-live-progress.js —— DSH Web UI 内嵌「实时进度」面板（+ios24.8）
 *
 * 为什么需要它：真机上进度只靠一个 SpringBoard 悬浮胶囊（灵动岛 HUD），
 * 而用户全程在全屏 Web Clip 的 DSH 界面里；那个胶囊既可能被灵动岛插件
 * 的高层窗口盖住，也可能因为 SpringBoard 没有 active scene 而根本不显示。
 * DSH Go 的做法是「进度在 App 自己的界面里」：工具调用折叠成一行、
 * 状态机常驻、流式事件增量推送、断线续传。本面板把它搬进 DSH Web UI。
 *
 * 数据来源：本机 bridge 127.0.0.1:8091
 *   GET /events     SSE 主通道（支持 Last-Event-ID / ?since= 断线续传）
 *   GET /progress   轮询兜底（SSE 被 Web Clip / Safari 拦截时）
 *
 * 约束：
 *   - 纯原生 JS，零依赖，零构建，可在 iOS 16.7 / Safari 16.6 的 Web Clip 里跑；
 *   - 只连 127.0.0.1 回环，不访问外网、不读写用户数据、不改 DSH 任何逻辑；
 *   - 独立容器 + 高 z-index + 精细 pointer-events，绝不拦截 DSH 的交互；
 *   - bridge 未启动时显示明确的「未连接」，降级轮询，不刷屏报错。
 */
(function () {
    'use strict';

    var BRIDGE = 'http://127.0.0.1:8091';
    var SSE_URL = BRIDGE + '/events';
    var POLL_URL = BRIDGE + '/progress';
    var POLL_MS = 1200;
    var SSE_GRACE_MS = 3500;
    var MAX_TIMELINE = 60;

    var ID = 'dsh-live-progress-root';
    var MARK = '__dshLiveProgressV2';
    if (window[MARK]) return;
    window[MARK] = true;

    // ---------- 状态 ----------
    var seq = 0;
    var snap = null;
    var timeline = [];
    var sse = null;
    var pollTimer = null;
    var tickTimer = null;
    var sseTimer = null;
    var lastEventAt = 0;
    var connected = false;
    var expanded = false;
    var hiddenByUser = false;
    var runStart = 0;
    var runBaseMs = 0;

    // ---------- 工具 ----------
    function el(tag, cls, txt) {
        var e = document.createElement(tag);
        if (cls) e.className = cls;
        if (txt !== undefined) e.textContent = txt;
        return e;
    }
    function fmtMs(ms) {
        if (!ms || ms < 0) ms = 0;
        if (ms < 1000) return ms + 'ms';
        if (ms < 60000) return (ms / 1000).toFixed(1) + 's';
        var m = Math.floor(ms / 60000);
        return m + 'm' + ((ms % 60000) / 1000).toFixed(0) + 's';
    }
    function stateInfo(s) {
        switch (s) {
            case 'idle': case 'ready': return { label: '待命', color: '#8b93a1', pulse: false };
            case 'thinking': return { label: '思考中', color: '#5b8def', pulse: true };
            case 'waiting': return { label: '等待界面', color: '#e0a53a', pulse: true };
            case 'paused': return { label: '已暂停', color: '#e0a53a', pulse: false };
            case 'running': return { label: '执行中', color: '#33c759', pulse: true };
            case 'done': return { label: '已完成', color: '#33c759', pulse: false };
            case 'error': case 'failed': return { label: '失败', color: '#ff453a', pulse: false };
            default: return { label: s || '运行中', color: '#33c759', pulse: true };
        }
    }
    function phaseOf(e) {
        if (!e) return 'running';
        if (e.state === 'running' && e.action === 'tool_start') return 'thinking';
        if (e.state === 'running' && (e.action === 'settle' || e.action === 'waiting')) return 'waiting';
        return e.state;
    }

    // ---------- 样式（全部 dshlp- 前缀，避免污染宿主） ----------
    var CSS = [
        '#', ID, '{position:fixed;right:10px;bottom:calc(env(safe-area-inset-bottom, 0px) + 12px);',
        'z-index:2147483000;width:min(320px, calc(100vw - 20px));font:12px/1.45 -apple-system,BlinkMacSystemFont,"PingFang SC",system-ui,sans-serif;',
        'color:#f2f4f8;pointer-events:none;-webkit-user-select:none;user-select:none;}',
        '#', ID, ' *{box-sizing:border-box;}',
        '.dshlp-card{pointer-events:auto;background:rgba(18,20,26,.92);border:1px solid rgba(255,255,255,.12);',
        'border-radius:16px;box-shadow:0 8px 28px rgba(0,0,0,.45);backdrop-filter:blur(12px);-webkit-backdrop-filter:blur(12px);overflow:hidden;}',
        '.dshlp-head{display:flex;align-items:center;gap:8px;padding:9px 11px;cursor:pointer;}',
        '.dshlp-dot{width:9px;height:9px;border-radius:50%;flex:0 0 auto;background:#8b93a1;}',
        '.dshlp-dot.on{animation:dshlp-pulse 1s ease-in-out infinite;}',
        '@keyframes dshlp-pulse{0%,100%{opacity:1;transform:scale(1)}50%{opacity:.4;transform:scale(.8)}}',
        '.dshlp-title{font-weight:600;font-size:12px;white-space:nowrap;}',
        '.dshlp-state{font-size:11px;opacity:.72;white-space:nowrap;}',
        '.dshlp-meta{margin-left:auto;font:11px/1 ui-monospace,Menlo,monospace;opacity:.7;white-space:nowrap;}',
        '.dshlp-caret{font-size:10px;opacity:.5;transition:transform .2s;}',
        '.dshlp-caret.open{transform:rotate(180deg);}',
        '.dshlp-detail{padding:0 11px 8px;font-size:11.5px;opacity:.85;word-break:break-all;line-height:1.4;}',
        '.dshlp-track{height:3px;background:rgba(255,255,255,.1);border-radius:2px;margin:0 11px 9px;overflow:hidden;}',
        '.dshlp-bar{height:100%;background:#33c759;border-radius:2px;transition:width .25s ease;width:0;}',
        '.dshlp-body{max-height:0;overflow:hidden;transition:max-height .25s ease;border-top:0 solid rgba(255,255,255,.08);}',
        '.dshlp-body.open{max-height:230px;overflow-y:auto;border-top-width:1px;-webkit-overflow-scrolling:touch;}',
        '.dshlp-summary{padding:8px 11px;font-size:11px;opacity:.7;display:flex;justify-content:space-between;}',
        '.dshlp-list{padding:0 11px 9px;list-style:none;margin:0;}',
        '.dshlp-list li{display:flex;gap:7px;padding:3px 0;font-size:11px;border-bottom:1px solid rgba(255,255,255,.05);}',
        '.dshlp-list li:last-child{border-bottom:0;}',
        '.dshlp-seq{font:10px/1.5 ui-monospace,Menlo,monospace;opacity:.45;min-width:22px;}',
        '.dshlp-txt{flex:1;word-break:break-all;}',
        '.dshlp-t{opacity:.5;margin-left:auto;font:10px/1.5 ui-monospace,Menlo,monospace;white-space:nowrap;}',
        '.dshlp-err{color:#ff8a80;} .dshlp-done{color:#7ee08a;}',
        '.dshlp-foot{padding:6px 11px 9px;display:flex;gap:8px;align-items:center;}',
        '.dshlp-btn{pointer-events:auto;font-size:10.5px;padding:3px 8px;border-radius:8px;border:1px solid rgba(255,255,255,.16);',
        'background:rgba(255,255,255,.06);color:#f2f4f8;cursor:pointer;}',
        '.dshlp-link{font-size:10px;opacity:.55;margin-left:auto;}',
        // +ios24.9：暂停/停止/插话 + 交还确认卡（对齐 DSH Go 悬浮条）
        '.dshlp-ctl{padding:0 11px 8px;display:flex;gap:6px;align-items:center;flex-wrap:wrap;}',
        '.dshlp-ctl .dshlp-btn.act{background:rgba(51,199,89,.18);border-color:rgba(51,199,89,.5);}',
        '.dshlp-ctl .dshlp-btn.stop{background:rgba(255,69,58,.13);border-color:rgba(255,69,58,.45);}',
        '.dshlp-input{flex:1;min-width:96px;font:11px/1.4 inherit;color:#f2f4f8;',
        'background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.16);border-radius:8px;',
        'padding:4px 7px;-webkit-user-select:text;user-select:text;}',
        '.dshlp-input::placeholder{color:rgba(242,244,248,.4);}',
        '.dshlp-handoff{margin:0 11px 8px;padding:8px 9px;border-radius:10px;',
        'background:rgba(224,165,58,.14);border:1px solid rgba(224,165,58,.42);font-size:11.5px;line-height:1.45;}',
        '.dshlp-handoff .why{color:#ffd88a;margin-bottom:7px;}',
        '.dshlp-handoff .row{display:flex;gap:6px;}',
        '.dshlp-hidden{display:none!important;}',
        '.dshlp-off{display:none!important;}'
    ].join('');

    // ---------- 构建 DOM ----------
    var root, card, dot, titleEl, stateEl, metaEl, caret, detailEl, bar, body, summaryEl, listEl, linkEl;
    var ctlRow, pauseBtn, stopBtn, interjectInput, handoffBox, handoffWhy;

    function build() {
        root = document.getElementById(ID);
        if (root) return;
        var style = el('style');
        style.textContent = CSS;
        (document.head || document.documentElement).appendChild(style);

        root = el('div'); root.id = ID;
        card = el('div', 'dshlp-card');

        var head = el('div', 'dshlp-head');
        dot = el('span', 'dshlp-dot');
        titleEl = el('span', 'dshlp-title', 'DSH 操控');
        stateEl = el('span', 'dshlp-state', '待命');
        metaEl = el('span', 'dshlp-meta', '');
        caret = el('span', 'dshlp-caret', '▾');
        head.appendChild(dot); head.appendChild(titleEl); head.appendChild(stateEl);
        head.appendChild(metaEl); head.appendChild(caret);
        head.addEventListener('click', function () {
            expanded = !expanded;
            body.className = 'dshlp-body' + (expanded ? ' open' : '');
            caret.className = 'dshlp-caret' + (expanded ? ' open' : '');
            if (expanded) renderTimeline();
        });

        detailEl = el('div', 'dshlp-detail', '正在连接进度通道…');
        var track = el('div', 'dshlp-track'); bar = el('div', 'dshlp-bar'); track.appendChild(bar);

        // +ios24.9：暂停/继续、停止、插话（对齐 DSH Go 悬浮条胶囊与卡片）
        ctlRow = el('div', 'dshlp-ctl');
        pauseBtn = el('button', 'dshlp-btn', '暂停');
        pauseBtn.addEventListener('click', function (ev) {
            ev.stopPropagation();
            var paused = !!(snap && snap.control && snap.control.paused);
            sendControl(paused ? 'resume' : 'pause');
        });
        stopBtn = el('button', 'dshlp-btn stop', '停止');
        stopBtn.addEventListener('click', function (ev) { ev.stopPropagation(); sendControl('stop'); });
        interjectInput = el('input', 'dshlp-input');
        interjectInput.type = 'text';
        interjectInput.placeholder = '插话：换个做法…';
        interjectInput.addEventListener('click', function (ev) { ev.stopPropagation(); });
        interjectInput.addEventListener('keydown', function (ev) {
            ev.stopPropagation();
            if (ev.key === 'Enter' || ev.keyCode === 13) {
                var t = interjectInput.value.trim();
                if (t) { sendControl('interject', t); interjectInput.value = ''; }
            }
        });
        var sendBtn = el('button', 'dshlp-btn', '发送');
        sendBtn.addEventListener('click', function (ev) {
            ev.stopPropagation();
            var t = interjectInput.value.trim();
            if (t) { sendControl('interject', t); interjectInput.value = ''; }
        });
        ctlRow.appendChild(pauseBtn); ctlRow.appendChild(stopBtn);
        ctlRow.appendChild(interjectInput); ctlRow.appendChild(sendBtn);

        // 交还用户确认卡：登录/验证码/支付等步骤由人来完成
        handoffBox = el('div', 'dshlp-handoff dshlp-hidden');
        handoffWhy = el('div', 'why', '');
        var hoRow = el('div', 'row');
        var hoCont = el('button', 'dshlp-btn act', '继续');
        hoCont.addEventListener('click', function (ev) { ev.stopPropagation(); sendControl('continue'); });
        var hoStop = el('button', 'dshlp-btn stop', '停止');
        hoStop.addEventListener('click', function (ev) { ev.stopPropagation(); sendControl('stop'); });
        hoRow.appendChild(hoCont); hoRow.appendChild(hoStop);
        handoffBox.appendChild(handoffWhy); handoffBox.appendChild(hoRow);

        body = el('div', 'dshlp-body');
        summaryEl = el('div', 'dshlp-summary');
        listEl = el('ul', 'dshlp-list');
        body.appendChild(summaryEl); body.appendChild(listEl);

        var foot = el('div', 'dshlp-foot');
        var toggle = el('button', 'dshlp-btn', '隐藏');
        toggle.addEventListener('click', function (ev) {
            ev.stopPropagation();
            hiddenByUser = !hiddenByUser;
            card.className = 'dshlp-card' + (hiddenByUser ? ' dshlp-off' : '');
            toggle.textContent = hiddenByUser ? '显示' : '隐藏';
        });
        var clear = el('button', 'dshlp-btn', '清空');
        clear.addEventListener('click', function (ev) { ev.stopPropagation(); timeline = []; renderTimeline(); });
        linkEl = el('span', 'dshlp-link', '连接中…');
        foot.appendChild(toggle); foot.appendChild(clear); foot.appendChild(linkEl);

        card.appendChild(head); card.appendChild(detailEl); card.appendChild(track);
        card.appendChild(ctlRow); card.appendChild(handoffBox);
        card.appendChild(body); card.appendChild(foot);
        root.appendChild(card);
        (document.body || document.documentElement).appendChild(root);

        // SPA 路由切换 / 宿主重渲染把容器摘掉时自动挂回
        try {
            var mo = new MutationObserver(function () {
                if (!document.body.contains(root)) {
                    (document.body || document.documentElement).appendChild(root);
                }
            });
            mo.observe(document.body || document.documentElement, { childList: true });
        } catch (_) { /* 老 Safari 无 MO 也无妨 */ }
    }

    // ---------- 渲染 ----------
    function renderTimeline() {
        if (!listEl) return;
        var n = timeline.length;
        var tools = 0;
        for (var i = 0; i < n; i++) if (timeline[i].tool) tools++;
        summaryEl.textContent = n ? ('本次 ' + n + ' 个事件 · ' + tools + ' 次工具调用（点开看逐步）')
                                  : '暂无事件';
        listEl.innerHTML = '';
        var start = Math.max(0, n - MAX_TIMELINE);
        for (var j = start; j < n; j++) {
            var e = timeline[j];
            var li = el('li');
            var cls = e.state === 'error' || e.state === 'failed' ? 'dshlp-err'
                    : (e.state === 'done' ? 'dshlp-done' : '');
            var tx = el('span', 'dshlp-txt' + (cls ? ' ' + cls : ''), e.detail || e.state);
            li.appendChild(el('span', 'dshlp-seq', '#' + e.seq));
            li.appendChild(tx);
            li.appendChild(el('span', 'dshlp-t', e.ts ? new Date(e.ts).toLocaleTimeString('zh-CN', { hour12: false }) : ''));
            listEl.appendChild(li);
        }
        if (expanded) body.scrollTop = body.scrollHeight;
    }

    function render() {
        if (!dot) return;
        var e = snap;
        var ctl = (e && e.control) || null;
        var ph = (ctl && ctl.paused) ? 'paused' : phaseOf(e);
        var info = stateInfo(ph);
        dot.style.background = info.color;
        dot.className = 'dshlp-dot' + (info.pulse ? ' on' : '');
        stateEl.textContent = info.label;
        titleEl.textContent = (e && e.title) || 'DSH 操控';
        var domMirror = e && e.run_id === 'dom';
        detailEl.textContent = (!connected && !domMirror)
            ? '进度通道未连接 · 正在重试（不影响 DSH 使用）'
            : ((e && e.detail) || (domMirror ? '正在调用工具…' : '等待任务 · 桥已连接'));
        linkEl.textContent = connected ? (sse ? 'SSE 已连接' : '轮询')
                                        : (domMirror ? '页面观察' : '未连接');

        if (e && e.total > 0) {
            bar.style.width = Math.round((e.step / e.total) * 100) + '%';
            metaEl.textContent = e.step + '/' + e.total + ' · ' + fmtMs(liveElapsed());
        } else {
            bar.style.width = (ph === 'running' || ph === 'thinking' || ph === 'waiting') ? '15%' : '0%';
            metaEl.textContent = (ph === 'running' || ph === 'thinking' || ph === 'waiting')
                ? fmtMs(liveElapsed()) : '';
        }

        // +ios24.9：控制态渲染。SSE / 轮询的每个事件快照都带 control 字段。
        if (pauseBtn) {
            var paused = !!(ctl && ctl.paused);
            pauseBtn.textContent = paused ? '继续' : '暂停';
            pauseBtn.className = 'dshlp-btn' + (paused ? ' act' : '');
        }
        if (handoffBox) {
            var ho = ctl && ctl.handoff;
            if (ho) {
                handoffBox.className = 'dshlp-handoff';
                handoffWhy.textContent = '需要你来操作：' + (ho.reason || '完成这一步，然后点继续');
            } else {
                handoffBox.className = 'dshlp-handoff dshlp-hidden';
            }
        }
    }

    // 把暂停/继续/停止/插话送回 bridge 的 /control。XHR 优先，fetch 兜底，
    // 全部静默失败（控制不可用时不影响 DSH 本身使用），并做乐观渲染。
    function sendControl(action, text) {
        var payload = { action: action };
        if (text) payload.text = text;
        var body = JSON.stringify(payload);
        var apply = function (j) {
            if (!j || !j.control) return;
            if (!snap) snap = { state: 'running' };
            snap.control = j.control;
            render();
        };
        try {
            var xhr = new XMLHttpRequest();
            xhr.open('POST', BRIDGE + '/control', true);
            xhr.setRequestHeader('Content-Type', 'application/json');
            xhr.timeout = 3000;
            xhr.onreadystatechange = function () {
                if (xhr.readyState === 4 && xhr.status === 200) {
                    try { apply(JSON.parse(xhr.responseText)); } catch (_) {}
                }
            };
            xhr.send(body);
        } catch (_) {
            try {
                if (typeof fetch === 'function') {
                    fetch(BRIDGE + '/control', {
                        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: body
                    }).then(function (r) { return r.json(); }).then(apply).catch(function () {});
                }
            } catch (_) {}
        }
        // 乐观更新：按钮与确认卡不等网络回包
        if (!snap) snap = { state: 'running' };
        if (!snap.control) snap.control = {};
        if (action === 'pause') snap.control.paused = true;
        if (action === 'resume' || action === 'continue') {
            snap.control.paused = false; snap.control.handoff = null;
        }
        if (action === 'stop') {
            snap.control.paused = false; snap.control.handoff = null;
        }
        render();
    }

    function liveElapsed() {
        if (!snap) return 0;
        if (snap.state === 'idle' || snap.state === 'ready') return 0;
        return (runBaseMs || 0) + (runStart ? (Date.now() - runStart) : 0);
    }

    // ---------- 事件处理 ----------
    function accept(e, fromSse) {
        if (!e || typeof e !== 'object') return;
        if (!e.state) return;
        if (e.seq && e.seq <= seq) return;          // 去重（续传/双通道）
        if (e.seq) seq = e.seq;
        snap = e;
        lastEventAt = Date.now();
        connected = true;
        runBaseMs = Number(e.elapsed_ms) || 0;
        runStart = (e.state === 'idle' || e.state === 'ready') ? 0 : Date.now();
        timeline.push(e);
        if (timeline.length > MAX_TIMELINE * 2) timeline = timeline.slice(-MAX_TIMELINE);
        render();
        renderTimeline();
        if (fromSse && pollTimer) stopPoll();       // SSE 正常就停掉轮询
    }

    function sseFrame(txt) {
        // SSE 一帧可能含多行；只取 data: 行拼起来
        var lines = txt.split('\n');
        var data = '';
        for (var i = 0; i < lines.length; i++) {
            var l = lines[i];
            if (l.indexOf('data:') === 0) data += l.slice(5).trim();
        }
        if (!data) return;
        try { accept(JSON.parse(data), true); } catch (_) { /* 忽略坏帧 */ }
    }

    function startSse() {
        if (typeof EventSource === 'undefined') { startPoll(); return; }
        try { if (sse) sse.close(); } catch (_) {}
        try {
            sse = new EventSource(SSE_URL + '?since=' + seq);
        } catch (_) { startPoll(); return; }
        sse.onopen = function () { connected = true; render(); };
        sse.onmessage = function (ev) { if (ev && ev.data) sseFrame('data:' + ev.data); };
        sse.onerror = function () {
            // EventSource 会自己重连；我们只需在长时间无事件时开轮询兜底
            startPoll();
        };
        // 自定义 event（idle/running/done/error/snapshot）用 addEventListener 兜住
        ['idle', 'ready', 'thinking', 'running', 'waiting', 'done', 'error', 'failed', 'snapshot'].forEach(function (n) {
            try { sse.addEventListener(n, function (ev) { if (ev && ev.data) sseFrame('data:' + ev.data); }); } catch (_) {}
        });
    }

    function startPoll() {
        if (pollTimer) return;
        pollTimer = setInterval(pollOnce, POLL_MS);
        pollOnce();
    }
    function stopPoll() {
        if (pollTimer) { clearInterval(pollTimer); pollTimer = null; }
    }

    function pollOnce() {
        var url = POLL_URL + '?since=' + seq + '&_=' + Date.now();
        var done = false;
        var timer = setTimeout(function () { if (!done) { done = true; } }, 2500);
        try {
            var xhr = new XMLHttpRequest();
            xhr.open('GET', url, true);
            xhr.timeout = 2500;
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== 4 || done) return;
                done = true; clearTimeout(timer);
                if (xhr.status === 200) {
                    try {
                        var j = JSON.parse(xhr.responseText);
                        connected = true;
                        if (j.snapshot && !j.events.length) snap = j.snapshot;
                        if (j.events && j.events.length) {
                            for (var i = 0; i < j.events.length; i++) accept(j.events[i], false);
                        } else render();
                    } catch (_) {}
                } else { connected = false; render(); }
            };
            xhr.onerror = function () { if (done) return; done = true; clearTimeout(timer); connected = false; render(); };
            xhr.ontimeout = function () { if (done) return; done = true; connected = false; render(); };
            xhr.send();
        } catch (_) { clearTimeout(timer); startPollFallbackFetch(); }
    }

    // fetch 兜底（XHR 被 CSP 拦时）
    function startPollFallbackFetch() {
        if (typeof fetch !== 'function') return;
        stopPoll();
        pollTimer = setInterval(function () {
            fetch(POLL_URL + '?since=' + seq, { mode: 'cors', credentials: 'omit' })
                .then(function (r) { return r.json(); })
                .then(function (j) {
                    connected = true;
                    if (j.events) for (var i = 0; i < j.events.length; i++) accept(j.events[i], false);
                    else render();
                })
                .catch(function () { connected = false; render(); });
        }, POLL_MS);
    }

    /* ---------- 终极兜底：观察 DSH 页面自己的工具调用 DOM ----------
     * 完全零网络、零注入、零原生依赖。即使 bridge 没起来、SSE 被 CSP/WKWebView
     * 拦截、HUD dylib 没注入，只要 DSH 页面在渲染工具调用，本面板就一定能
     * 显示「正在调用 mcp__ios__xxx」。对标 DSH Go「工具调用折叠成一行」。
     * 只在桥不可达（!connected）时生成事件，避免与 SSE 事件重复。
     */
    var domSeen = Object.create(null);
    var domScanTimer = null;
    var RE_TOOL = /\b(?:mcp__ios__[a-z0-9_]+|phone_act|watch_screen|wait_for_change|find_element|wait_for_text|tap_screen|get_ui_elements|screenshot|ocr_screen|launch_app|input_text)\b/gi;

    function domMirrorScan() {
        if (connected) return;                  // 桥通了就以 SSE 为准
        var nodes, i, n;
        try { nodes = document.querySelectorAll('[class*="tool"],[class*="Tool"],[data-tool],[class*="message"],[class*="Message"]'); }
        catch (_) { return; }
        var found = null;
        for (i = 0; i < nodes.length && i < 400; i++) {
            var t = (nodes[i].textContent || '').trim();
            if (!t || t.length > 400) continue;
            var m = t.match(RE_TOOL);
            if (!m) continue;
            for (n = 0; n < m.length; n++) {
                var key = m[n].toLowerCase();
                if (domSeen[key]) continue;
                domSeen[key] = 1;
                found = m[n];
            }
        }
        if (!found) return;
        seq += 1;
        var e = { seq: seq, ts: Date.now(), state: 'running', title: 'DSH 操控（页面观察）',
                  detail: '正在调用 ' + found, tool: found, action: 'tool_start',
                  step: 0, total: 0, elapsed_ms: 0, ok: null, run_id: 'dom' };
        snap = e;
        connected = false;                      // 保持「未连接」标识，但内容可见
        runBaseMs = 0; runStart = Date.now();
        timeline.push(e);
        if (timeline.length > MAX_TIMELINE * 2) timeline = timeline.slice(-MAX_TIMELINE);
        render(); renderTimeline();
    }
    function startDomMirror() {
        if (domScanTimer) return;
        domScanTimer = setInterval(domMirrorScan, 900);
    }

    // ---------- 启动 ----------
    function boot() {
        build();
        render();
        renderTimeline();
        startSse();
        // SSE 静默（某些 Web Clip 会吞长连接）→ 轮询兜底
        sseTimer = setInterval(function () {
            if (Date.now() - lastEventAt > SSE_GRACE_MS && Date.now() - lastEventAt > 1500) startPoll();
        }, 1500);
        tickTimer = setInterval(render, 500);   // 实时耗时
        startDomMirror();                       // 零网络终极兜底
        document.addEventListener('visibilitychange', function () {
            if (document.hidden) { /* 后台不强连，交给浏览器节流 */ }
            else { lastEventAt = Date.now(); }
        });
    }

    if (document.readyState === 'loading') {
        document.addEventListener('DOMContentLoaded', boot);
    } else {
        boot();
    }
})();
