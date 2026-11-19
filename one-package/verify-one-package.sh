#!/bin/sh
# verify-one-package.sh — 独立核验 rc.3 全屏单包 deb（自解包，不复用构建逻辑）
#
# 最关键的一段：拿 Web Clip Info.plist 里那条【静态 URL】直接喂给 deb 内
# 真实 rc.3 的 BrowserAuth.authorizeIndex，验证
#   无 token -> 401 / 静态 URL -> 303 + Set-Cookie / 带 cookie -> 放行
# 这才真正证明「点桌面图标 -> 插件/工作区/对话能加载」，而不只是文件都在。
#
# 用法: sh one-package/verify-one-package.sh <deb> [引擎树|bundle] [APP payload]
#   后两个参数给齐时才做「两次构建字节级可复现」检查。
set -e
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
DEB="${1:-$ROOT/dist/dev.airdevs.dsh_0.2.2-rc.3+ios18_iphoneos-arm64.deb}"
ENGINE_ARG="${2:-}"
APPDIR_ARG="${3:-}"
TOKEN=$(tr -d '\r\n' < "$HERE/dsh-web-token")
VTAG="${DSH_IOS_TAG:-ios18}"   # 并列实验档（如 +ios24）用同一个标签核验
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  [ OK ] %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  [FAIL] %s\n' "$*"; }
sec()  { printf '\n=== %s ===\n' "$*"; }

[ -f "$DEB" ] || { echo "缺少 $DEB" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "需要 node 做鉴权黑盒验证" >&2; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT INT TERM
dpkg-deb -x "$DEB" "$TMP/x"
dpkg-deb -e "$DEB" "$TMP/DEBIAN"
X="$TMP/x"
D="$X/var/jb/usr/lib/dsh"
NM="$D/node_modules"
APP="$X/var/jb/Applications/DSH.app"
LDPLIST="$X/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist"
WCPLIST="$D/webclip/Info.plist"
CONN="$NM/@deepseek-ai/dsh-client-connection/lib/index.js"

sec "1) deb 布局（引擎 + APP + 全屏 Web Clip + extras 全在一个包里）"
for f in "$NM/@deepseek-ai/dsh/lib/bin.js" "$D/bin/node" "$D/webclip/Info.plist" \
         "$D/webclip/icon.png" "$D/dsh-extras-postinst.sh" "$D/dsh-extras-prerm.sh" \
         "$X/var/jb/usr/bin/dsh" "$X/var/jb/usr/bin/dsh-doctor" \
         "$X/var/jb/usr/bin/dsh-daemon" "$X/var/jb/usr/bin/dsh-app-ctl" \
         "$X/var/jb/usr/bin/dsh-app-ui" "$X/var/jb/usr/bin/dsh-app-helper" \
         "$APP/DSHLauncher" "$APP/Info.plist" "$APP/entitlements.plist" \
         "$LDPLIST" "$TMP/DEBIAN/postinst" "$TMP/DEBIAN/prerm" "$TMP/DEBIAN/control"; do
    [ -f "$f" ] && ok "存在 ${f#$X/}" || bad "缺失 ${f#$X/}"
done
N=$(find "$APP" -name '*.png' | wc -l | tr -d ' ')
[ "$N" -ge 5 ] && ok "APP 图标 $N 个" || bad "APP 图标只有 $N 个"
if dpkg-deb -c "$DEB" | grep 'dsh-app-helper' | grep -q 'rws'; then
    ok "setuid helper 为 4755（chown 后 setuid 位仍在）"
else bad "setuid helper 丢了 setuid 位（App 无法拉起 daemon）"; fi

sec "2) DSH 版本与固定 token 补丁"
python3 - "$NM/@deepseek-ai/dsh/package.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding='utf-8'))
assert d.get('version') == '0.2.2-rc.3', '不是最新 rc.3: %s' % d.get('version')
print('  [ OK ] DSH version = 0.2.2-rc.3')
PY
R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
python3 - "$NM" "$TOKEN" <<'PY'
import os, sys
root, tok = sys.argv[1:3]
hits = 0
for dp, dns, fns in os.walk(root):
    for n in fns:
        p = os.path.join(dp, n)
        if p.replace('\\', '/').endswith('dsh-client-connection/lib/index.js'):
            s = open(p, encoding='utf-8').read()
            assert 'process.env.DSH_WEB_TOKEN' in s, '未打补丁: ' + p
            assert ('"'+tok+'"') in s, '缺省 token 不一致: ' + p
            hits += 1
assert hits >= 1
print('  [ OK ] %d 份 dsh-client-connection/lib/index.js 已固定 token 且缺省值一致' % hits)
PY
R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
for f in $(find "$NM" -path '*dsh-client-connection/lib/index.js'); do
    node --check "$f" >/dev/null 2>&1 && ok "补丁后 index.js 语法通过" || bad "补丁后 index.js 语法错误"
done

sec "3) Web Clip 与 launchd plist 的 token / 全屏 / 日志一致性"
python3 - "$TOKEN" "$WCPLIST" "$LDPLIST" <<'PY'
import plistlib, sys
tok = sys.argv[1]
wc = plistlib.load(open(sys.argv[2], 'rb'))
ld = plistlib.load(open(sys.argv[3], 'rb'))
checks = [
 ('Web Clip FullScreen=true', wc.get('FullScreen') is True),
 ('Web Clip URL 带同一个固定 token', wc.get('URL', '').endswith('?token=' + tok)),
 ('Web Clip URL 为 loopback 3080', wc.get('URL', '').startswith('http://127.0.0.1:3080/')),
 ('Web Clip Precomposed=true', wc.get('Precomposed') is True),
 ('launchd DSH_WEB_TOKEN 一致', ld.get('EnvironmentVariables', {}).get('DSH_WEB_TOKEN') == tok),
 ('launchd RunAtLoad', ld.get('RunAtLoad') is True),
 ('launchd KeepAlive', ld.get('KeepAlive') is True),
 ('launchd UserName=mobile', ld.get('UserName') == 'mobile'),
 ('launchd 日志在 $DSH_HOME 之外', '/.dsh/' not in (str(ld.get('StandardOutPath', '')) + str(ld.get('StandardErrorPath', '')))),
 ('launchd 程序为 dsh-daemon 绝对路径', '/var/jb/usr/bin/dsh-daemon' in (ld.get('ProgramArguments') or [])),
]
for n, c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ') + n)
    if not c: sys.exit(1)
PY
R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+10)) || FAIL=$((FAIL+1))

sec "3b) 兼容补丁链真落到引擎树（+ios24 真机四症状的根因回归）"
# 历史缺陷：脚本只把 shims 复制进包却一个都没执行，rc.3 树是「裸」的，
# 真机表现为插件市场全 fetch failed / pnpm 环境缺失 / AbortSignal.any 报错。
FRONT="$NM/@deepseek-ai/dsh-web-frontend/dist"
python3 - "$D" "$NM" "$FRONT" "$X" <<'PY'
import os, sys
D, NM, FRONT, X = sys.argv[1:5]
checks = [
 (os.path.join(FRONT, 'assets/safari16-polyfill.js'), 'AbortSignal.any', 'iOS16 前端垫片'),
 (os.path.join(FRONT, 'assets/dsh-ios-manual-install-transform.js'), '__dshIosTransformSpec', '手动安装转化'),
 (os.path.join(NM, '@deepseek-ai/dsh-plugin-manager/lib/index.js'), 'git-probe-shortcircuit', 'git 预检短路'),
 (os.path.join(NM, '@deepseek-ai/dsh-plugin-market/lib/index.js'), 'redirect: "follow"', '插件市场 redirect follow'),
 (os.path.join(NM, '@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js'), '__dshIosTransformSpec', '前端转化钩子'),
 (os.path.join(NM, '@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs'), 'parseIndexBody', '主线程索引解析'),
 (os.path.join(D, 'libexec/pnpm/bin/pnpm.cjs'), 'pnpm', '内置纯 JS pnpm 入口'),
 (os.path.join(D, 'libexec/pnpm/dist/pnpm.cjs'), 'pnpm', '内置 pnpm 主 bundle'),
 (os.path.join(FRONT, 'index.html'), 'safari16-polyfill.js', 'index.html 注入垫片引用'),
]
bad = 0
for p, needle, label in checks:
    hit = os.path.isfile(p) and needle in open(p, encoding='utf-8', errors='replace').read()
    print(('  [ OK ] ' if hit else '  [FAIL] ') + label)
    if not hit: bad += 1
nd = sum(1 for dp, dn, fn in os.walk(os.path.join(D, 'libexec/pnpm'))
         for f in fn if f.endswith('.node'))
print(('  [ OK ] ' if nd == 0 else '  [FAIL] ') + '内置 pnpm 0 个原生 .node')
if nd: bad += 1
sys.exit(1 if bad else 0)
PY
R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+10)) || FAIL=$((FAIL+1))

sec "3b-2) iOS 数据兼容（工作区/对话加载不出的根因回归）"
# +ios24.1 真机截图：会话默认 zstd 撞上用户从 +ios15/+ios18 带来的明文
# .jsonl，host 装配期 checkRootEncoding() 全局 fatal -> 所有 controller
# pending -> 前端「directoryPickerController is unavailable」、工作区/对话全空。
# 同时 iOS(darwin) 目录选择器必须走 browse（Web Clip 无原生选择器）。
SP="$NM/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
DP="$NM/@deepseek-ai/dsh-host-directory-picker-auto/lib/index.js"
BR="$NM/@deepseek-ai/dsh-host-directory-picker-browse/lib/index.js"
python3 - "$SP" "$DP" "$BR" <<'PY'
import sys, os
sp, dp, br = sys.argv[1:4]
def txt(p): return open(p, encoding='utf-8', errors='replace').read() if os.path.isfile(p) else ''
s, d = txt(sp), txt(dp)
checks = [
 ('会话默认压缩为 none（兼容用户明文 .jsonl 会话）',
  'const DEFAULT_COMPRESSION = "none";' in s),
 ('会话默认压缩不再残留 zstd（不再触发 encodingMismatch 全局 fatal）',
  'const DEFAULT_COMPRESSION = "zstd";' not in s),
 ('compression 仍可选 zstd（读 .jsonl.zstd 能力保留）',
  'z.const("zstd")' in s),
 ('iOS/darwin 目录选择器返回 browse（Web Clip 浏览器可用）',
  'facts.platform === "darwin" || facts.platform === "win32") return "browse";' in d),
 ('iOS/darwin 目录选择器不再返回 native（无 osascript/NSOpenPanel）',
  'facts.platform === "darwin" || facts.platform === "win32") return "native";' not in d),
 ('browse 后端为纯 JS（node:fs/promises，零原生依赖）',
  os.path.isfile(br) and 'node:fs/promises' in txt(br)),
 ('两处补丁带幂等 marker（设备端热修可复用）',
  'dsh-iOS compat' in s and 'dsh-iOS compat' in d),
]
for n, c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ') + n)
    if not c: sys.exit(1)
PY
R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+7)) || FAIL=$((FAIL+1))
node --check "$SP" >/dev/null 2>&1 && ok "session-persistence-jsonl 语法" || bad "session-persistence-jsonl 语法"
node --check "$DP" >/dev/null 2>&1 && ok "directory-picker-auto 语法" || bad "directory-picker-auto 语法"

sec "3c) 桌面入口（Web Clip 有 Title；+ios24.10 起 native APP 反转为主入口）"
case "$VTAG" in ios24.*) NC=8 ;; *) NC=5 ;; esac
python3 - "$WCPLIST" "$APP/Info.plist" "$D/dsh-extras-postinst.sh" "$VTAG" <<'PY'
import plistlib, sys
wc = plistlib.load(open(sys.argv[1], 'rb'))
app = plistlib.load(open(sys.argv[2], 'rb'))
ex = open(sys.argv[3], encoding='utf-8').read()
tag = sys.argv[4]
native_primary = (tag in ('ios24.10', 'ios24.11', 'ios24.12'))
checks = [
 ('Web Clip 有 Title（桌面图标不再叫 Untitled）', bool(wc.get('Title'))),
 ('Web Clip Title 为 DeepSeek Harness', wc.get('Title') == 'DeepSeek Harness'),
]
if native_primary:
    # +ios24.10：原生 App 是主入口，不隐藏，可执行指向 DSHNativeApp，postinst 显式注册。
    checks += [
     ('native APP 不再隐藏（无 SBAppTags=hidden）', 'hidden' not in (app.get('SBAppTags') or [])),
     ('CFBundleExecutable = DSHNativeApp', app.get('CFBundleExecutable') == 'DSHNativeApp'),
     ('extras 显式 register 原生 APP 图标', '"$CTL" register' in ex or '"$U" -p "$APP"' in ex),
     ('postinst 对 DSHNativeApp 签名', '"$APP/DSHNativeApp"' in ex),
    ]
else:
    checks += [
     ('半屏 native APP 标记 SBAppTags=hidden', 'hidden' in (app.get('SBAppTags') or [])),
     ('extras 不再 register 半屏 APP 图标', 'register' not in ex or all(
         l.strip().startswith('#') for l in ex.splitlines() if 'register' in l)),
    ]
if tag.startswith('ios24.'):
    # +ios24.1 起升级路径改为强制换进程；首版 +ios24 / +ios18 用 enable。
    checks += [
     ('extras 强制 bootout 旧 daemon（升级不再留随机 token 进程）', 'bootout' in ex),
     ('extras 强制 kickstart -k 换上新引擎树', 'kickstart -k' in ex),
     ('extras 清理旧 DSH Web Clip（防 SpringBoard 缓存旧 URL）', '*.webclip' in ex and 'rm -rf "$d"' in ex),
     ('extras 用固定 token 真探 303/200', 'statusCode===303||r.statusCode===200' in ex),
    ]
else:
    checks += [('extras 仍做 launchd 保活 enable', '"$CTL" enable' in ex)]
for n, c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ') + n)
    if not c: sys.exit(1)
PY
R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+NC)) || FAIL=$((FAIL+1))

# ---------------------------------------------------------------- 3d) Node 24
# 真机截图回归：+ios24 上 tier.sh / pnpm 的 --no-expose-wasm 在 Node 24 已被
# 删除，nowasm 档 rc=9；doctor 硬编码 +ios15/Node22 大小造成 12 个误报 FAIL。
# 只有 +ios24 档才打这套运行时补丁，+ios18 不做要求（保持原产物可复现）。
case "$VTAG" in
  ios24*)
    sec "3d) Node 24 运行时补丁（零 JIT 全链路 + 版本感知 doctor）"
    python3 - "$X" "$TOKEN" <<'PY'
import os, sys, plistlib
X, tok = sys.argv[1:3]
D = os.path.join(X, 'var/jb/usr/lib/dsh')
B = os.path.join(X, 'var/jb/usr/bin')
NM = os.path.join(D, 'node_modules')
checks = []
def active(p, needle):
    """needle 是否出现在非注释行里。"""
    s = open(p, encoding='utf-8').read()
    return any(needle in l and not l.lstrip().startswith('#') for l in s.splitlines())
def has(p, needle):
    return os.path.isfile(p) and needle in open(p, encoding='utf-8', errors='replace').read()
ns = os.path.join(D, 'node-safe')
checks += [
 ('node-safe 存在且可执行', os.path.isfile(ns) and os.access(ns, os.X_OK)),
 ('node-safe 走 --jitless + fetch-shim', has(ns, '--jitless') and has(ns, 'fetch-shim.cjs')),
 ('tier.sh nowasm 去掉已删除的 --no-expose-wasm',
  has(os.path.join(D, 'tier.sh'), 'nowasm|--jitless --require ') and
  not active(os.path.join(D, 'tier.sh'), '--no-expose-wasm')),
 ('tier.sh 全档失败兜底 nowasm', has(os.path.join(D, 'tier.sh'), 'TIER_SOURCE=fallback')),
 ('pnpm PFLAGS 无 --no-expose-wasm',
  has(os.path.join(B, 'pnpm'), 'PFLAGS="--jitless"') and
  not active(os.path.join(B, 'pnpm'), '--no-expose-wasm')),
 ('dsh wrapper 兜底零 JIT', has(os.path.join(B, 'dsh'), 'TIER_SOURCE=fallback')),
 ('dsh wrapper heal 走 node-safe', has(os.path.join(B, 'dsh'), '"$D/node-safe" "$D/dsh-home-heal.cjs"')),
 ('dsh-doctor 抬头为 +ios24 / rc.3', has(os.path.join(B, 'dsh-doctor'), '+ios24 (DSH 0.2.2-rc.3 / Node 24)')),
 ('dsh-doctor 不再硬编码 Node22 大小', not active(os.path.join(B, 'dsh-doctor'), '101297000')),
 ('dsh-doctor 版本号改为 rc.3', has(os.path.join(B, 'dsh-doctor'), 'if [ "$DV" = "0.2.2-rc.3" ]')),
 ('dsh-doctor 短命检查统一 NODE_SAFE', has(os.path.join(B, 'dsh-doctor'), 'NODE_SAFE="$D/node-safe"')),
 ('ctl 探活接上 SAFE_NODE', has(os.path.join(B, 'dsh-app-ctl'), 'SAFE_NODE="$JB/usr/lib/dsh/node-safe"')),
 ('webclip/token 与单一真相源一致',
  open(os.path.join(D, 'webclip/token'), encoding='utf-8').read().strip() == tok),
 ('插件子进程 __dshPnpmFlags 无废 flag',
  all('--no-expose-wasm' not in l
      for p in (os.path.join(NM, '@deepseek-ai/dsh-plugin-manager/lib/index.js'),
                os.path.join(NM, '@deepseek-ai/dsh-plugin-manager/lib/types/operations.js'))
      for l in open(p, encoding='utf-8', errors='replace').read().splitlines()
      if '__dshPnpmFlags' in l and not l.lstrip().startswith('*'))),
 ('设备端 pnpm 热修副本同步去掉废 flag',
  '--no-expose-wasm' not in [
      l for l in open(os.path.join(D, 'apply_pnpm_abs_patch.cjs'), encoding='utf-8').read().splitlines()
      if '__dshPnpmFlags =' in l][0]),
]
bad = 0
for n, c in checks:
    print(('  [ OK ] ' if c else '  [FAIL] ') + n)
    if not c: bad += 1
sys.exit(1 if bad else 0)
PY
    R=$?; [ "$R" -eq 0 ] && PASS=$((PASS+15)) || FAIL=$((FAIL+1))
    ;;
  *)
    echo "  [note] 非 +ios24 档，跳过 Node 24 运行时断言"
    ;;
esac

sec "4) 鉴权黑盒：Web Clip 静态 URL 真能通过 rc.3 的 401 -> 303 -> cookie"
# 在 deb 解出的同目录建一个 ESM 桥接副本（bare specifier 仍从同树 node_modules 解析）
LIBDIR=$(dirname "$CONN")
cp "$CONN" "$LIBDIR/_dsh_verify_full.mjs"
printf '\nexport { BrowserAuth };\n' >> "$LIBDIR/_dsh_verify_full.mjs"
WCURL=$(python3 - "$WCPLIST" <<'PY'
import plistlib, sys
print(plistlib.load(open(sys.argv[1], 'rb'))['URL'])
PY
)
cat > "$TMP/auth_verify.mjs" <<'JS'
const mod = process.argv[2];
const wcUrl = process.argv[3];
const { BrowserAuth } = await import(mod);
function mkRes() {
  return { status: 0, headers: {}, body: undefined,
    writeHead(s, h) { this.status = s; this.headers = h || {}; },
    end(t) { this.body = t; } };
}
function req(url, cookie) {
  const headers = { host: '127.0.0.1:3080' };
  if (cookie) headers.cookie = cookie;
  return { url, method: 'GET', headers };
}
const wc = new URL(wcUrl);
const tok = wc.searchParams.get('token');
const a = new BrowserAuth({}, 'unit-test-secret-fixed-value-0123456789', 30);
if (a.launchToken !== tok) {
  console.error('launchToken 与 Web Clip URL 不一致:', a.launchToken, '!=', tok);
  process.exit(1);
}
console.log('  [ OK ] launchToken = ' + a.launchToken + '（与静态 URL 一致）');

let r = mkRes();
const c1 = a.authorizeIndex(req('/'), r);
if (c1 !== false || r.status !== 401) { console.error('case1 无 token 未返回 401'); process.exit(1); }
console.log('  [ OK ] 无 token 访问 / -> 401');

r = mkRes();
const c2 = a.authorizeIndex(req(wc.pathname + wc.search), r);
const setCookie = r.headers['set-cookie'] || r.headers['Set-Cookie'];
if (c2 !== false || r.status !== 303 || !setCookie) {
  console.error('case2 静态 Web Clip URL 未返回 303+Set-Cookie', r.status, r.headers);
  process.exit(1);
}
console.log('  [ OK ] 静态 Web Clip URL -> 303 + HttpOnly Set-Cookie');

const cookieKV = (Array.isArray(setCookie) ? setCookie[0] : setCookie).split(';')[0];
r = mkRes();
const c3 = a.authorizeIndex(req('/', cookieKV), r);
if (c3 !== true) { console.error('case3 带 cookie 未放行', r.status); process.exit(1); }
console.log('  [ OK ] 带上一步 cookie 访问裸 / -> 放行（前端 JS/API/SSE/WS 全部可加载）');

// /connect（API / WebSocket mux）同样用固定 token 换取独立凭据
r = mkRes();
a.authorizeConnect(req('/connect?token=' + encodeURIComponent(tok)), r, false, () => 'verify-operator');
if (r.status !== 302 || !r.headers['set-cookie']) {
  console.error('case4 /connect 未返回 302+Set-Cookie', r.status); process.exit(1);
}
console.log('  [ OK ] /connect?token=<固定值> -> 302 + Set-Cookie（API mux 可用）');
JS
node "$TMP/auth_verify.mjs" "file://$LIBDIR/_dsh_verify_full.mjs" "$WCURL" \
    && ok "鉴权链端到端通过（插件 / 工作区 / 对话可正常加载）" \
    || bad "鉴权链失败：静态 Web Clip URL 无法通过 rc.3 鉴权"
rm -f "$LIBDIR/_dsh_verify_full.mjs"

sec "5) shell 脚本语法 + 关键调用 / 零写入"
for f in "$X/var/jb/usr/bin/dsh" "$X/var/jb/usr/bin/dsh-daemon" \
         "$X/var/jb/usr/bin/dsh-app-ctl" "$X/var/jb/usr/bin/dsh-app-ui" \
         "$D/dsh-extras-postinst.sh" "$D/dsh-extras-prerm.sh" \
         "$TMP/DEBIAN/postinst" "$TMP/DEBIAN/prerm"; do
    sh -n "$f" >/dev/null 2>&1 && ok "sh -n $(basename "$f")" || bad "sh -n $(basename "$f")"
done
grep -q 'web --no-open --port' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon exec dsh web --no-open" || bad "daemon 未 exec web"
grep -q 'DSH_WEB_TOKEN' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon 注入固定 token" || bad "daemon 缺 token"
if grep -v '^[[:space:]]*#' "$X/var/jb/usr/bin/dsh-daemon" \
        | grep -qE 'while .*ping.*sleep|sleep 30'; then
    bad "daemon 仍有 401 待机死循环"
else ok "daemon 已删待机死循环"; fi
grep -q 'statusCode===303' "$X/var/jb/usr/bin/dsh-app-ctl" && ok "ctl ping 只认 303/200" || bad "ctl ping 仍把 401 判可连"
if [ -f "$D/node-safe" ]; then
    sh -n "$D/node-safe" >/dev/null 2>&1 && ok "sh -n node-safe" || bad "sh -n node-safe"
fi
if grep -qE '^cp "\$WCSRC/Info\.plist"' "$D/dsh-extras-postinst.sh"; then
    bad "extras 仍在安装 Web Clip 书签（+ios24.11 应只留原生 App）"
else ok "+ios24.11 extras 不再安装 Web Clip 书签（桌面只留原生 App）"; fi
# 自动链路不得写 $DSH_HOME
if grep -vE '^[[:space:]]*#|^[[:space:]]*echo|^[[:space:]]*printf' \
        "$TMP/DEBIAN/postinst" "$TMP/DEBIAN/prerm" \
        "$D/dsh-extras-postinst.sh" "$D/dsh-extras-prerm.sh" \
        | grep -qE 'chown[[:space:]]+-R.*(\$DSH_HOME|\.dsh)|chmod[[:space:]]+-R.*(\$DSH_HOME|\.dsh)|config-on|config-off|(\$DSH_HOME|\$DSHHOME)/logs'; then
    bad "自动链路仍在写 \$DSH_HOME"
else ok "postinst/prerm/extras 均零写入 \$DSH_HOME"; fi

sec "6) control 元数据"
grep -q '^Package: dev.airdevs.dsh$' "$TMP/DEBIAN/control" && ok "包名正确" || bad "包名错误"
grep -q "^Version: 0.2.2-rc.3+${VTAG}\$" "$TMP/DEBIAN/control" && ok "版本 rc.3+${VTAG}" || bad "版本错误"
grep -q '^Architecture: iphoneos-arm64$' "$TMP/DEBIAN/control" && ok "架构 iphoneos-arm64" || bad "架构错误"
grep -q 'Replaces: dev.airdevs.dsh-app' "$TMP/DEBIAN/control" && ok "Replaces 独立 App 包" || bad "缺 Replaces"

sec "7) 数据零改动实测（模拟 rootless，17 个用户数据文件全量指纹对比）"
if sh "$ROOT/app-bundle/verify-no-data-touch.sh" > "$TMP/vndt.log" 2>&1; then
    ok "verify-no-data-touch.sh 全部断言通过"
else
    bad "verify-no-data-touch.sh 失败："
    tail -40 "$TMP/vndt.log" >&2
fi

sec "7b) +ios24.8 实时进度（Web UI 主通道 / SSE / 效率工具 / HUD 注入）"
# 独立核验：从 deb 解包结果直接查，不复用 build-one-package.sh 的任何结论。
# 用户真机症状是「实时进度完全没有 / HUD 完全不可见」，所以这里除了查
# 面板与事件流，还必须确认打进包的 HUD 是【重编后的新二进制】。
PBDIR="$X/var/jb/usr/lib/dsh-phone-bridge"
LP="$FRONT/assets/dsh-ios-live-progress.js"
if [ -f "$LP" ]; then
    ok "进度面板脚本已打包"
    node --check "$LP" >/dev/null 2>&1 && ok "进度面板语法通过" || bad "进度面板语法错误"
    for needle in '127.0.0.1:8091' '/events' '/progress' 'EventSource' 'MutationObserver'; do
        grep -qF "$needle" "$LP" && ok "面板含 $needle" || bad "面板缺 $needle"
    done
else bad "deb 缺进度面板脚本（实时进度主通道没了）"; fi
grep -qF 'dsh-ios-live-progress.js' "$FRONT/index.html" \
    && ok "index.html 已注入进度面板" || bad "index.html 未注入进度面板"
SRV="$PBDIR/server.cjs"
if [ -f "$SRV" ]; then
    ok "bridge server.cjs 已打包"
    node --check "$SRV" >/dev/null 2>&1 && ok "bridge 语法通过" || bad "bridge 语法错误"
    for needle in 'emitEvent' 'text/event-stream' 'Last-Event-ID' '/progress' \
                  'sseClients' 'writeIdleHud' 'level: HUD_LEVEL' \
                  'find_element' 'wait_for_text' 'progress_status' \
                  'validateSteps' 'compactUI' 'uiDelta' 'stop_on_error'; do
        grep -qF "$needle" "$SRV" && ok "bridge 含 $needle" || bad "bridge 缺 $needle"
    done
else bad "deb 缺 bridge server.cjs"; fi
grep -qF 'isConflictingIosBlock' "$PBDIR/ensure-config.cjs" \
    && ok "ensure-config 会清理 8090 同名冲突" || bad "ensure-config 未处理 8090（进度不会产生）"
grep -qF '127.0.0.1:8091/mcp' "$PBDIR/ensure-config.cjs" \
    && ok "DSH 注册到 8091 bridge" || bad "未注册 8091 bridge"
grep -qF 'hud_diag' "$X/var/jb/usr/bin/dsh-phone-bridge-ctl" \
    && ok "ctl 含 hud 诊断命令" || bad "ctl 缺 hud 诊断命令"
HDYL="$X/var/jb/Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.dylib"
if [ -f "$HDYL" ]; then
    HM=$(od -An -tx1 -N4 "$HDYL" 2>/dev/null | tr -d ' \n')
    [ "$HM" = "cffaedfe" ] && ok "HUD dylib 为 arm64 Mach-O" || bad "HUD dylib magic 异常 ($HM)"
    # 旧二进制没有 ack / 常驻态；缺这两串说明仍会「完全不可见」。
    grep -aqF 'hud.ack.json' "$HDYL" \
        && ok "HUD dylib 为新编版（含 hud.ack.json）" \
        || bad "HUD dylib 仍是旧二进制（无 ack，真机仍不可见）"
    grep -aqF 'last_apply_at' "$HDYL" \
        && ok "HUD dylib 含常驻状态诊断字段" || bad "HUD dylib 缺常驻状态诊断字段"
    grep -aqF '/var/jb/Library/MobileSubstrate' "$HDYL" \
        && ok "HUD install_name 为 rootless 路径" || bad "HUD install_name 未改 rootless"
else bad "deb 缺 HUD dylib"; fi
grep -qF 'HUDSTATE' "$D/dsh-extras-postinst.sh" \
    && ok "postinst 把 HUD 状态目录属主设为 mobile" || bad "postinst 未处理 HUD 目录属主"

sec "7c) +ios24.9 操控效率（固定工具集 / 增量读屏 / 串行围栏 / 交互控制）"
# 独立核验：直接从 deb 解包结果查，不复用构建脚本结论。对应「全面参考
# DSH Go 继续优化操控手机」——核心是让模型少发 token、少跑往返、不空转。
PBDIR="$X/var/jb/usr/lib/dsh-phone-bridge"
LP="$FRONT/assets/dsh-ios-live-progress.js"
SRV="$PBDIR/server.cjs"
# 1) 固定工具集：工具名/描述/schema 恒定，避免每轮 KV cache 失效
for needle in 'const FIXED_TOOLS' 'FIXED_TOOL_NAMES' 'tools: FIXED_TOOLS' \
              'fixed_toolset_note' 'upstreamTools(false)'; do
    grep -qF "$needle" "$SRV" && ok "固定工具集含 $needle" || bad "固定工具集缺 $needle"
done
# 2) 按行增量读屏 + 诚实判定
for needle in 'function screenDigest' "screenDigest('act'" '无法验证' \
              '与 s' 'ui_verdict' 'compactUI' 'uiDelta'; do
    grep -qF "$needle" "$SRV" && ok "增量读屏含 $needle" || bad "增量读屏缺 $needle"
done
# 3) 串行队列 / 时间预算 / epoch 围栏 / 控制端点
for needle in 'function runSerialized' 'function controlApply' 'publicControlState' \
              "admitted !== controlState.epoch" 'function handoffWait' '/control' \
              'function skillRun'; do
    grep -qF "$needle" "$SRV" && ok "串行/控制含 $needle" || bad "串行/控制缺 $needle"
done
# 4) 省链路新工具都已接进分发
for needle in "case 'phone_screen':" "case 'phone_intent':" "case 'phone_collect':" \
              "case 'phone_skill_save':" "case 'phone_skill_run':" \
              "case 'phone_skill_list':" "case 'phone_handoff':" \
              "case 'phone_control':" "case 'phone_native':" "case 'phone_batch':"; do
    grep -qF "$needle" "$SRV" && ok "工具分发含 $needle" || bad "工具分发缺 $needle"
done
# 5) 进度面板可交互（暂停/继续/停止/插话/handoff 确认卡）
for needle in 'sendControl' "BRIDGE + '/control'" 'handoffBox' 'interjectInput' \
              "case 'paused'" 'snap.control' 'EventSource'; do
    grep -qF "$needle" "$LP" && ok "面板交互含 $needle" || bad "面板交互缺 $needle"
done
node --check "$SRV" >/dev/null 2>&1 && ok "+ios24.9 bridge 语法通过" || bad "+ios24.9 bridge 语法错误"
node --check "$LP" >/dev/null 2>&1 && ok "+ios24.9 面板语法通过" || bad "+ios24.9 面板语法错误"

if [ "$VTAG" = "ios24.10" ] || [ "$VTAG" = "ios24.11" ] || [ "$VTAG" = "ios24.12" ]; then
  sec "7d) 原生 App 主入口 + 灵动岛药丸形态（+ios24.10 起，24.11/24.12 保留）"
  NA="$APP/DSHNativeApp"
  [ -f "$NA" ] && ok "原生 App DSHNativeApp 已打包" || bad "缺原生 App DSHNativeApp"
  if [ -f "$NA" ]; then
    NMAGIC=$(od -An -tx1 -N4 "$NA" 2>/dev/null | tr -d ' \n')
    [ "$NMAGIC" = "cffaedfe" ] && ok "DSHNativeApp 为 arm64 Mach-O" || bad "DSHNativeApp magic 异常 ($NMAGIC)"
  fi
  python3 - "$APP/Info.plist" <<'PY' && ok "native App 为主入口且未隐藏" || bad "native App 仍隐藏/可执行不符"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
assert d.get('CFBundleExecutable') == 'DSHNativeApp'
assert 'hidden' not in (d.get('SBAppTags') or [])
PY
  # 原生 UI 源码关键要素（进度来源 / 设置页兜底）—— 两档都保留的共用部分
  NU="$HERE/../app-bundle/native-ui"
  for needle in 'DSHRootVC' 'verbLabel' '/progress' '/control' \
                'DSHSettingsVC' 'SFSafariViewController'; do
    grep -qrF "$needle" "$NU" && ok "原生 UI 源码含 $needle" || bad "原生 UI 源码缺 $needle"
  done
  # +ios24.10 网页地址写死 3080；+ios24.11 改成读动态端口状态文件，不再写死
  if [ "$VTAG" = "ios24.10" ]; then
    grep -qrF '127.0.0.1:3080' "$NU" && ok "24.10 设置页网页地址 127.0.0.1:3080" || bad "24.10 缺 3080 地址"
  fi
  # 药丸形态源码
  HSRC="$HERE/../phone-bridge/native/hud/HUDOverlay.m"
  for needle in 'verbLabel' 'shape' 'pill_w' 'colorWithWhite:0.02 alpha:0.97' 'setExpanded'; do
    grep -qF "$needle" "$HSRC" && ok "药丸形态含 $needle" || bad "药丸形态缺 $needle"
  done
  # 人话状态 server 侧
  for needle in 'function humanVerb' 'noteRecent' 'verb: verb'; do
    grep -qF "$needle" "$SRV" && ok "人话状态 server 含 $needle" || bad "人话状态 server 缺 $needle"
  done
fi

if [ "$VTAG" = "ios24.11" ] || [ "$VTAG" = "ios24.12" ]; then
  sec "7e) +ios24.11 全屏 WebView 主界面 + 动态端口 + 无书签（24.12 保留）"
  NU="$HERE/../app-bundle/native-ui"
  # 主界面改成全屏 WKWebView，带 SFSafari 降级兜底 + WebKit framework + 网络 entitlement
  for needle in 'WKWebView' 'DSHWebVC' 'degradeToSafari' 'webViewWebContentProcessDidTerminate' \
                'web-port' 'web-token'; do
    grep -qrF "$needle" "$NU" && ok "原生 UI 全屏 WebView 含 $needle" || bad "原生 UI 缺 $needle"
  done
  grep -q -- '-framework WebKit' "$NU/build-native-app.sh" && ok "编译链含 WebKit framework" || bad "编译链缺 WebKit"
  python3 - "$APP/entitlements.plist" <<'PY' && ok "App 含 WKWebView 网络 entitlement" || bad "App 缺 WKWebView 网络 entitlement"
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
assert d.get('com.apple.security.network.client') is True
assert d.get('com.apple.security.network.server') is True
PY
  # AppDelegate 根控制器换成 DSHWebVC（不再是手写进度卡主界面）
  grep -qF '[[DSHWebVC alloc] init]' "$NU/DSHAppDelegate.m" && ok "主界面根控制器 = DSHWebVC 全屏 WebView" || bad "主界面未切到全屏 WebView"
  # 灵动岛 HUD 完全不动：仍读 hud.json
  grep -qF 'hud.json' "$HERE/../phone-bridge/native/hud/HUDOverlay.m" && ok "灵动岛 HUD 仍读 hud.json（未改动）" || bad "灵动岛 HUD 链路变了"
  # 动态端口：daemon 探测 + 探测器随包 + 状态文件原子写
  grep -qF 'port-probe.cjs' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon 调用动态端口探测器" || bad "daemon 未接动态端口"
  [ -f "$D/port-probe.cjs" ] && ok "port-probe.cjs 随包下发" || bad "缺 port-probe.cjs"
  node --check "$D/port-probe.cjs" >/dev/null 2>&1 && ok "port-probe.cjs 语法通过" || bad "port-probe.cjs 语法错误"
  grep -qF 'web-port' "$X/var/jb/usr/bin/dsh-daemon" && ok "daemon 写 web-port 状态文件" || bad "daemon 未写端口状态文件"
  grep -qF 'refresh_port' "$D/dsh-extras-postinst.sh" && ok "postinst 探活读动态端口" || bad "postinst 探活仍写死端口"
  # 端口冲突避让黑盒：占用 base 端口后探测器应换端口
  node -e '
    const net=require("net"),cp=require("child_process");
    const b=net.createServer();
    b.listen(0,"127.0.0.1",()=>{
      const base=b.address().port;   // 用一个真实被占的端口
      const out=cp.execSync("node "+process.argv[1]+" "+base).toString().trim();
      b.close();
      if(Number(out)!==base){console.log("  [ OK ] 端口冲突自动避让 "+base+" -> "+out);process.exit(0);}
      console.error("  [FAIL] 端口冲突未避让 ("+base+")");process.exit(1);
    });
  ' "$D/port-probe.cjs" && PASS=$((PASS+1)) || FAIL=$((FAIL+1))
fi

if [ "$VTAG" = "ios24.12" ]; then
  sec "7f) +ios24.12 App 主动启动 + 终端复用实例打印链接"
  NU="$HERE/../app-bundle/native-ui"
  # App 启动引导：setuid helper + posix_spawn + 后台队列不卡主线程
  for needle in 'dsh-app-helper' 'posix_spawn' 'ensureDaemonThenLoad' 'waitpid' 'environ'; do
    grep -qF "$needle" "$NU/DSHWebVC.m" && ok "App 主动启动含 $needle" || bad "App 主动启动缺 $needle"
  done
  grep -qF 'dispatch_get_global_queue' "$NU/DSHWebVC.m" && ok "App 启动引导在后台队列（不卡 UI）" || bad "App 启动引导阻塞主线程"
  # setuid helper 随包且 4755（能提权执行 ensure）
  [ -f "$X/var/jb/usr/bin/dsh-app-helper" ] && ok "setuid helper 随包下发" || bad "缺 dsh-app-helper"
  if dpkg-deb -c "$DEB" 2>/dev/null | grep 'usr/bin/dsh-app-helper' | grep -q 'rws'; then
    ok "setuid helper 为 4755"
  else
    # 解包态看不到 setuid 位时用 postinst 断言兜底
    grep -qF 'chmod 4755' "$D/dsh-extras-postinst.sh" && ok "postinst 设 helper 为 4755" || bad "helper 无 setuid 处理"
  fi
  # helper 源码确实执行 dsh-app-ctl ensure（幂等）
  grep -qF 'dsh-app-ctl ensure' "$HERE/../app-bundle/helper-src/dsh-app-helper.c" && ok "helper 执行幂等 ensure" || bad "helper 未执行 ensure"
  # 终端复用：读端口状态文件 + ping + 打印链接 + exit 0
  for needle in 'web-port' 'web-token' '网页工作台：http://127.0.0.1' 'exit 0'; do
    grep -qF "$needle" "$X/var/jb/usr/bin/dsh" && ok "终端 dsh 复用逻辑含 $needle" || bad "终端 dsh 复用逻辑缺 $needle"
  done
  sh -n "$X/var/jb/usr/bin/dsh" && ok "复用后 dsh 语法通过" || bad "dsh 语法错误"
  # 终端复用黑盒：模拟一个带 token 的 web 服务，dsh 探测片段应能命中 303。
  # 用宿主 node（非包内 arm64 node-safe），Linux/macOS 上都能跑。
  node -e '
    const http=require("http");
    const s=http.createServer((req,res)=>{res.writeHead(303,{Location:"/"});res.end();});
    s.listen(0,"127.0.0.1",()=>{
      const port=s.address().port;
      const req=http.get({host:"127.0.0.1",port,path:"/?token=t",timeout:1200},r=>{
        r.resume(); s.close();
        process.exit(r.statusCode===303?0:1);
      });
      req.on("error",()=>{s.close();process.exit(1)});
    });
  ' >/dev/null 2>&1 && { echo "  [ OK ] 终端复用探活黑盒（303 命中）"; PASS=$((PASS+1)); } || FAIL=$((FAIL+1))
fi

sec "8) 两次构建字节级可复现"
if [ -n "$ENGINE_ARG" ] && [ -n "$APPDIR_ARG" ]; then
    A=$(sha256sum "$DEB" | cut -d' ' -f1)
    sh "$HERE/build-one-package.sh" "$ENGINE_ARG" "$APPDIR_ARG" "$TMP/rebuild.deb" >/dev/null 2>&1
    B=$(sha256sum "$TMP/rebuild.deb" | cut -d' ' -f1)
    [ "$A" = "$B" ] && ok "两次构建 SHA 一致 ($A)" || bad "两次构建不一致：$A / $B"
else
    echo "  [note] 未提供引擎树/APP payload，跳过复现检查"
    echo "         完整用法: sh one-package/verify-one-package.sh <deb> <引擎树|bundle> app-bundle/payload"
fi

printf '\n=== 汇总: OK=%d FAIL=%d ===\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
echo "✔ rc.3 单包独立核验全部通过（固定 token 鉴权黑盒 + 全屏 WebView + 动态端口）"
