#!/bin/sh
# 单包构建：rc.3 引擎树 + native APP + **真全屏 Web Clip** + extras -> 一个 deb
#
# 用法: sh build-one-package.sh <引擎树目录 | rc3 bundle .tar.gz> <APP payload 目录> [输出.deb]
#   引擎树目录需含 node_modules/（可选 bin/node）；bundle 顶层为 node_modules/。
#   内置 node 二进制优先取引擎树的 bin/node，其次 bundles/node-v22.12.0-iphoneos-arm64
#   （由 bootstrap.sh 下载），也可 NODE_IOS_BIN=/path 指定。缺则直接中止，绝不
#   产出「装得上但起不来」的残包。
#
# 旧版断裂点（本脚本逐一补齐）：
#   * 没复制 dsh-extras-postinst.sh / prerm.sh -> postinst 的 `[ -x "$EX" ]`
#     恒为假，全屏 Web Clip 从来没装进设备；
#   * 没复制 prebuilt/DSHLauncher / dsh-app-helper / 图标 -> .app 空壳；
#   * 没复制根 payload 的 usr/bin/dsh 等 wrapper -> daemon 要 exec 的文件
#     根本不在包里；
#   * 没调用固定 token 补丁 / rc.3 transform 补丁；
#   * 没有 chown 0:0 / SOURCE_DATE_EPOCH / -z9，不可复现。
set -eu

ENGINE_IN="${1:?engine tree dir or rc3 bundle .tar.gz}"
APPDIR="${2:?app payload dir (app-bundle/payload)}"
HERE=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=$(CDPATH= cd -- "$HERE/.." && pwd)
OUT="${3:-$ROOT/dist/dev.airdevs.dsh_0.2.2-rc.3+ios18_iphoneos-arm64.deb}"
TOKEN=$(tr -d '\r\n' < "$HERE/dsh-web-token")
SDE="${SOURCE_DATE_EPOCH:-1700000000}"
# 版本标签：默认 ios18（Node 22.12.0 稳定档，逐字节保持已发布产物）。
# 用 CI 编出的 Node 24 时显式传 DSH_IOS_TAG=ios24，产出并列实验档，
# 绝不覆盖 +ios18 交付物，也不改仓库里的 control 原文件。
TAG="${DSH_IOS_TAG:-ios18}"

for c in python3 node dpkg-deb sha256sum tar; do
    command -v "$c" >/dev/null 2>&1 || { echo "缺少 $c" >&2; exit 1; }
done
[ -n "$TOKEN" ] || { echo "one-package/dsh-web-token 为空" >&2; exit 1; }
[ -f "$APPDIR/var/jb/Applications/DSH.app/Info.plist" ] || { echo "APP payload 不对: $APPDIR" >&2; exit 1; }

WORK="$ROOT/.build/one-package"
STAGE="$WORK/stage"
ENGINE="$WORK/engine"
rm -rf "$WORK"; mkdir -p "$STAGE" "$ENGINE"
trap 'rm -rf "$WORK"' EXIT INT TERM

# ---------------------------------------------------------------- 0) 令牌一致性
# 四处必须逐字相同：dsh-web-token / Web Clip URL / launchd plist /
# apply_fixed_token_patch.cjs 缺省值。任一漂移都会让静态 URL 401。
echo "==> 校验固定 token 一致性 ($TOKEN)"
python3 - "$HERE/webclip/Info.plist" \
          "$APPDIR/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist" \
          "$ROOT/shims/apply_fixed_token_patch.cjs" "$TOKEN" <<'PY'
import plistlib, sys
wc, ld, patch, tok = sys.argv[1:5]
d = plistlib.load(open(wc, 'rb'))
assert d.get('FullScreen') is True, 'Web Clip 不是 FullScreen'
assert d.get('URL', '').endswith('?token=' + tok), 'Web Clip URL 的 token 与 dsh-web-token 不一致'
l = plistlib.load(open(ld, 'rb'))
assert l.get('EnvironmentVariables', {}).get('DSH_WEB_TOKEN') == tok, 'launchd plist 未注入同一个 token'
assert '/var/jb/var/log/dsh-app/' in l.get('StandardOutPath', ''), 'daemon 日志仍写在 $DSH_HOME'
pa = l.get('ProgramArguments', [])
assert pa == ['/var/jb/usr/bin/dsh-daemon'], 'launchd 必须直接执行 dsh-daemon（/var/jb/bin/sh 在 rootless 上不存在，无法 spawn）'
s = open(patch, encoding='utf-8').read()
assert ('"'+tok+'"') in s, '固定 token 补丁的缺省值与 dsh-web-token 不一致'
print('    Web Clip / plist / 补丁 / 常量文件 四处一致')
PY

# ---------------------------------------------------------------- 1) 引擎树
if [ -f "$ENGINE_IN" ]; then
    echo "==> 解包 rc.3 依赖树: $(basename "$ENGINE_IN")"
    tar xzf "$ENGINE_IN" -C "$ENGINE"
elif [ -d "$ENGINE_IN" ]; then
    echo "==> 复制引擎树: $ENGINE_IN"
    cp -a "$ENGINE_IN/." "$ENGINE/"
else
    echo "引擎树不存在: $ENGINE_IN" >&2; exit 1
fi
[ -d "$ENGINE/node_modules/@deepseek-ai/dsh" ] || { echo "引擎树缺 node_modules/@deepseek-ai/dsh" >&2; exit 1; }

# 内置 node 二进制（daemon/cli 的真实执行者）
# 显式 NODE_IOS_BIN 必须优先于 bundles 里的默认 22.12.0：rc.3 的
# engines.node >= 24.9.0 且 bin.js 用 import.meta.main（Node 24 才支持），
# 用 CI 编出的 24.x 时若被旧版覆盖，包会「装得上但起不来」。
if [ ! -f "$ENGINE/bin/node" ]; then
    NODE_SRC=""
    for p in "${NODE_IOS_BIN:-}" "$ROOT/bundles/node-v22.12.0-iphoneos-arm64"; do
        [ -n "$p" ] && [ -f "$p" ] && { NODE_SRC="$p"; break; }
    done
    [ -n "$NODE_SRC" ] || {
        echo "缺少内置 node 二进制。请先跑 sh bootstrap.sh，或 NODE_IOS_BIN=/path 指定。" >&2
        echo "（绝不能省：daemon 要 exec /var/jb/usr/bin/dsh -> 包内 node）" >&2
        exit 1; }
    mkdir -p "$ENGINE/bin"; cp "$NODE_SRC" "$ENGINE/bin/node"
    echo "    内置 node: $NODE_SRC"
fi
# 无论来源都做 Mach-O + 大小校验，防止 x86 / 截断 / 占位文件混进包
NB="$ENGINE/bin/node"
NMAGIC=$(od -An -tx1 -N4 "$NB" 2>/dev/null | tr -d ' \n')
[ "$NMAGIC" = "cffaedfe" ] || { echo "内置 node 不是 arm64 Mach-O (magic=$NMAGIC)" >&2; exit 1; }
[ "$(wc -c < "$NB" | tr -d '[:space:]')" -gt 20000000 ] || {
    echo "内置 node 疑似占位/截断文件" >&2; exit 1; }
echo "    内置 node OK（arm64 Mach-O, $(wc -c < "$NB" | tr -d '[:space:]') 字节）"

# ---------------------------------------------------------------- 2) iOS 补丁
# 单包必须打与稳定底座 build.sh 完全相同的全套兼容补丁。历史缺陷：
# 本脚本只把 shims/*.cjs 复制进包（3c），却一个都没执行，于是 rc.3 的
# 引擎树是「裸」的 —— 真机上表现为：
#   * 插件市场索引 fetch(url,{redirect:"error"}) 遇到 CDN 跳转直接失败，
#     且 parseIndexInWorker() 起子 Worker 在 A11 上 SIGBUS -> 全部 fetch failed；
#   * dsh plugin 子进程找不到 pnpm / 裸 execa("git") 预检 -> 安装失败；
#   * 前端 index.html 没注入 safari16-polyfill.js，iOS 16.7(Safari 16.6)
#     缺 AbortSignal.any -> 工作区目录弹窗直接抛 "is not a function"。
# 补丁全部幂等，且带「锚点未精确命中即中止」断言，绝不打出未验证的包。
NM="$ENGINE/node_modules"
FRONT="$NM/@deepseek-ai/dsh-web-frontend/dist"
[ -f "$FRONT/index.html" ] || { echo "引擎树缺前端 dist/index.html: $FRONT" >&2; exit 1; }

# [1/6] 是 Node 22.12 专用兼容补丁（补 import.meta.main / zstd /
# stripTypeScriptTypes，并把新会话默认压缩 zstd 改成 none）。Node 24 原生
# 支持这些 API，>=24 跳过整包，避免无谓改动已验证的组合。
# 注意：那 4 条里「DEFAULT_COMPRESSION zstd→none」并非 Node API 兼容，
# 而是「兼容用户从 +ios15/+ios18 升级带来的明文 .jsonl 会话数据」——
# 与 Node 主版本无关，>=24 档必须在下面 [7/6] 单独补回，否则 host 装配
# 期 checkRootEncoding() 会因 zstd 撞上 .jsonl 全局 fatal，工作区/对话/
# 目录选择器全部 unavailable（+ios24.1 真机截图实证）。
# 按包内 node 的真实主版本分流：>=24 跳过本整包补丁，22.x 必打。
# 注意：「跳过兼容补丁」不等于「运行时脚本不用改」——+ios24 真机实测
# Node 24 原生 JIT 在 A11 上四档全 SIGBUS(138)，唯一能活的 nowasm 档又被
# tier.sh 里 Node 24 已删除的 --no-expose-wasm 挡成 rc=9。因此 >=24 时
# 下面 3d-1 还会对 stage 副本打一套专用的零 JIT 运行时补丁。
NVER=$(strings "$NB" 2>/dev/null | grep -m1 -oE '^v2[0-9]+\.[0-9]+\.[0-9]+$' || true)
NMAJOR=$(printf '%s' "$NVER" | sed -E 's/^v([0-9]+)\..*/\1/')
case "$NMAJOR" in ''|*[!0-9]*) NMAJOR=0 ;; esac
if [ "$NMAJOR" -ge 24 ]; then
    echo "==> [1/6] 跳过 Node 22 兼容补丁（内置 node ${NVER:-v24.x} 原生支持，保持已验证组合）"
else
    echo "==> [1/6] 应用 Node 22 兼容补丁（内置 node ${NVER:-v22.12.0}）"
    python3 "$ROOT/shims/apply_compat_patches.py" "$NM" || exit 1
fi

echo "==> [2/6] pnpm 绝对路径直连（修真机 dsh plugin 127 / SIGBUS）"
PM="$NM/@deepseek-ai/dsh-plugin-manager/lib"
# +ios24：共享 shim 注入的 __dshPnpmFlags 含 Node 24 已删除的
# --no-expose-wasm，会让插件安装子进程 `bad option` 退出 9。共享 shim
# 被 make_fix_ios15.py 内嵌进 fix-ios15.sh（改它会动稳定底座 SHA），
# 所以单包用专用副本；MARK 保持 +ios14，设备端自愈会幂等跳过。
if [ "$NMAJOR" -ge 24 ]; then
    PNPM_PATCH="$HERE/apply_pnpm_abs_patch_node24.cjs"
else
    PNPM_PATCH="$ROOT/shims/apply_pnpm_abs_patch.cjs"
fi
node "$PNPM_PATCH" "$PM" || exit 1
node --check "$PM/index.js" || { echo "补丁后 index.js 语法错误" >&2; exit 1; }
node --check "$PM/types/operations.js" || { echo "补丁后 operations.js 语法错误" >&2; exit 1; }

echo "==> [3/6] 插件安装 / 插件市场全链路（git 预检短路 + 主线程解析 + redirect follow + 手动转化钩子）"
# 必须用单包专用副本：共享 shims/apply_plugin_install_patch.cjs 会被
# make_fix_ios15.py 内嵌进 fix-ios15.sh、进而打进稳定底座 deb。为 rc.3
# 改它会连锁改变稳定底座 SHA（违反「稳定包逐字节不动」）。这份副本额外
# 支持 rc.3 client.js 的 minify bundle 锚点，A/B 段与共享 shim 完全一致。
node "$HERE/apply_plugin_install_patch_rc3.cjs" "$NM" || exit 1
for f in "@deepseek-ai/dsh-plugin-manager/lib/index.js" \
         "@deepseek-ai/dsh-plugin-market/lib/index.js" \
         "@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" \
         "@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js"; do
    node --check "$NM/$f" || { echo "补丁后 $f 语法错误" >&2; exit 1; }
done

echo "==> [4/6] 注入 Safari 16.7 前端垫片 + 手动安装转化逻辑"
node "$ROOT/shims/apply_frontend_inject.cjs" \
    "$FRONT" \
    "$ROOT/shims/safari16-polyfill.js" \
    "$ROOT/shims/dsh-ios-manual-install-transform.js" || exit 1
for m in 'safari16-polyfill.js' 'dsh-ios-manual-install-transform.js'; do
    grep -q "$m" "$FRONT/index.html" || { echo "构建中止：index.html 缺 $m 引用" >&2; exit 1; }
    [ -f "$FRONT/assets/$m" ] || { echo "构建中止：缺 assets/$m" >&2; exit 1; }
    node --check "$FRONT/assets/$m" || { echo "构建中止：assets/$m 语法错误" >&2; exit 1; }
done

# [4b/6] +ios24.8 实时进度面板 —— 注入 DSH Web UI 内部（用户 100% 看得见的位置）。
# 单包专用注入脚本，绝不动共享 shims/apply_frontend_inject.cjs（保护 +ios15 SHA）。
echo "==> [4b/6] 注入 DSH Web UI 内嵌实时进度面板"
node "$HERE/apply_live_progress_inject.cjs" \
    "$FRONT" \
    "$HERE/dsh-ios-live-progress.js" || exit 1
LP="$FRONT/assets/dsh-ios-live-progress.js"
grep -q 'dsh-ios-live-progress.js' "$FRONT/index.html" || { echo "构建中止：index.html 缺进度面板引用" >&2; exit 1; }
[ -f "$LP" ] || { echo "构建中止：缺 assets/dsh-ios-live-progress.js" >&2; exit 1; }
node --check "$LP" || { echo "构建中止：进度面板脚本语法错误" >&2; exit 1; }
for needle in '127.0.0.1:8091' '/events' '/progress'; do
    grep -qF "$needle" "$LP" || { echo "构建中止：进度面板缺 $needle（疑似空壳）" >&2; exit 1; }
done
echo "    进度面板已注入（SSE 主通道 + 轮询兜底 + DOM 观察终极兜底）"

echo "==> [5/6] 内置纯 JS pnpm（让「安装插件前需配置 pnpm 环境」不再出现）"
PNPMSRC="$ROOT/bundles/pnpm"
if [ ! -f "$PNPMSRC/bin/pnpm.cjs" ] || [ ! -f "$PNPMSRC/dist/pnpm.cjs" ]; then
    echo "缺少内置 pnpm: $PNPMSRC（插件安装必须有它）" >&2; exit 1
fi
mkdir -p "$ENGINE/libexec"
cp -a "$PNPMSRC" "$ENGINE/libexec/pnpm"
[ "$(find "$ENGINE/libexec/pnpm" -name '*.node' | wc -l)" -eq 0 ] || {
    echo "构建中止：内置 pnpm 含原生 .node（iOS 无法加载）" >&2; exit 1; }

echo "==> [6/6] 应用固定 loopback token 补丁（rc.3 静态 URL 鉴权）"
node "$ROOT/shims/apply_fixed_token_patch.cjs" "$NM" || exit 1
python3 - "$ENGINE/node_modules" "$TOKEN" <<'PY'
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
assert hits >= 1, '没有任何 dsh-client-connection/lib/index.js 被打补丁'
print('    已打补丁文件: %d' % hits)
PY
for f in $(find "$ENGINE/node_modules" -path '*dsh-client-connection/lib/index.js'); do
    node --check "$f" || { echo "补丁后 $f 语法错误" >&2; exit 1; }
done

# rc.3 前端「生态插件转化」钩子已由 [3/6] 的 apply_plugin_install_patch.cjs
# 通过「源码 / minify bundle 双锚点」通用注入，不再依赖外部成品替换。
# 构建期强校验：四处补丁真正落到引擎树，绝不打出「脚本在包里但没执行」的裸树。
for spec in \
  "@deepseek-ai/dsh-web-frontend/dist/assets/safari16-polyfill.js|AbortSignal.any" \
  "@deepseek-ai/dsh-web-frontend/dist/assets/dsh-ios-manual-install-transform.js|__dshIosTransformSpec" \
  "@deepseek-ai/dsh-web-frontend/dist/assets/dsh-ios-live-progress.js|127.0.0.1:8091" \
  "@deepseek-ai/dsh-plugin-manager/lib/index.js|git-probe-shortcircuit" \
  "@deepseek-ai/dsh-plugin-market/lib/index.js|redirect: \"follow\"" \
  "@deepseek-ai/dsh-client-ui-plugin-manager/lib/client.js|__dshIosTransformSpec"; do
    rel=${spec%%|*}; needle=${spec#*|}
    [ -f "$NM/$rel" ] || { echo "构建中止：补丁产物缺失 $rel" >&2; exit 1; }
    grep -qF "$needle" "$NM/$rel" || { echo "构建中止：$rel 缺 $needle（补丁未生效）" >&2; exit 1; }
done
[ -f "$NM/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" ] || {
    echo "构建中止：worker-parse.cjs 未派生" >&2; exit 1; }
grep -q 'safari16-polyfill.js' "$FRONT/index.html" || { echo "构建中止：index.html 未注入垫片" >&2; exit 1; }
echo "    补丁链校验通过：垫片注入 / 插件市场 / git 预检 / pnpm / 转化钩子 / 固定 token"

echo "==> [7/6] iOS 数据兼容：会话默认明文 .jsonl + 目录选择器强制 browse"
# 修 +ios24.x 真机「工作区/对话加载不出」。两处都是依赖树的数据/平台适配，
# 与 Node 版本、鉴权、零 JIT 无关；只改 ENGINE 的临时展开副本，随后整体
# 拷进 stage，共享 shims/ 与 payload/ 一个字节不动（+ios15 SHA 不变）。
# 对 Node22 档（+ios18）本脚本幂等跳过：apply_compat_patches.py 已把
# DEFAULT_COMPRESSION 改成 none。详见 make_ios_data_compat.py 顶部说明。
python3 "$HERE/make_ios_data_compat.py" "$NM" || exit 1
SP="$NM/@deepseek-ai/dsh-session-persistence-jsonl/lib/index.js"
DP="$NM/@deepseek-ai/dsh-host-directory-picker-auto/lib/index.js"
grep -q 'const DEFAULT_COMPRESSION = "none";' "$SP" || {
    echo "构建中止：会话默认压缩仍为 zstd（会撞上用户明文 .jsonl 会话）" >&2; exit 1; }
! grep -q 'const DEFAULT_COMPRESSION = "zstd";' "$SP" || {
    echo "构建中止：会话默认压缩仍残留 zstd" >&2; exit 1; }
grep -q 'facts.platform === "darwin" || facts.platform === "win32") return "browse";' "$DP" || {
    echo "构建中止：iOS/darwin 目录选择器仍走 native（Web Clip 用不了）" >&2; exit 1; }
node --check "$SP" || { echo "构建中止：session-persistence-jsonl 语法错误" >&2; exit 1; }
node --check "$DP" || { echo "构建中止：directory-picker-auto 语法错误" >&2; exit 1; }
echo "    会话默认压缩=none（兼容明文 .jsonl）、iOS 目录选择器=browse（纯 JS）"

# ---------------------------------------------------------------- 3) 组装 stage
echo "==> 组装 stage"
mkdir -p "$STAGE/DEBIAN" "$STAGE/var/jb/usr/lib/dsh" "$STAGE/var/jb/usr/bin" \
         "$STAGE/var/jb/etc/dsh" "$STAGE/var/jb/Applications/DSH.app" \
         "$STAGE/var/jb/Library/LaunchDaemons"

# 3a 引擎树（node_modules + bin/node + 可选 libexec）
cp -a "$ENGINE/." "$STAGE/var/jb/usr/lib/dsh/"

# 3b 根 payload：wrapper / doctor / pnpm / 档位链 / 环境文件
cp -a "$ROOT/payload/var/jb/usr/bin/." "$STAGE/var/jb/usr/bin/"
cp -a "$ROOT/payload/var/jb/etc/dsh/." "$STAGE/var/jb/etc/dsh/"
cp -a "$ROOT/payload/var/jb/usr/lib/dsh/." "$STAGE/var/jb/usr/lib/dsh/"
cp "$ROOT/ent.plist" "$STAGE/var/jb/usr/lib/dsh/ent.plist"

# 3c 设备端运行时/热修脚本（dsh wrapper 与 doctor 会用到）
for f in fetch-shim.cjs dsh-home-heal.cjs dsh-plugin-compat.cjs \
         apply_frontend_inject.cjs apply_fixed_token_patch.cjs \
         safari16-polyfill.js dsh-ios-manual-install-transform.js; do
    [ -f "$ROOT/shims/$f" ] || { echo "缺少 shims/$f" >&2; exit 1; }
    cp "$ROOT/shims/$f" "$STAGE/var/jb/usr/lib/dsh/$f"
done
# apply_pnpm_abs_patch.cjs 同样按 node 主版本分流：+ios24 用无废 flag 的副本，
# 名字保持不变，设备端 doctor 的自愈调用路径不用改。
cp "$PNPM_PATCH" "$STAGE/var/jb/usr/lib/dsh/apply_pnpm_abs_patch.cjs"
node --check "$STAGE/var/jb/usr/lib/dsh/apply_pnpm_abs_patch.cjs" || {
    echo "构建中止：设备端 pnpm 补丁语法错误" >&2; exit 1; }
# apply_plugin_install_patch.cjs 用单包专用副本：设备端 dsh-doctor 热修在
# rc.3 树上重跑时也需要支持 minify bundle 锚点，否则会命中 0 次失败。
# 文件名保持不变，doctor 的调用路径不用改。
cp "$HERE/apply_plugin_install_patch_rc3.cjs" \
   "$STAGE/var/jb/usr/lib/dsh/apply_plugin_install_patch.cjs"
node --check "$STAGE/var/jb/usr/lib/dsh/apply_plugin_install_patch.cjs" || {
    echo "构建中止：单包专用插件补丁语法错误" >&2; exit 1; }

# 3d APP payload（Info.plist / entitlements / LaunchDaemon / dsh-app-* 脚本）
cp -a "$APPDIR/." "$STAGE/"

# 3d-1 Node 24 专用运行时改造（只改 stage 副本，源文件一律不动）
# 触发条件：包内真实 node 主版本 >=24。Node 22 档不打补丁；+ios18 是
# 已冻结的历史对照档（发布 SHA 927b5308…），当前源码面向 +ios24.2。
# 改动见 make_node24_runtime.py 顶部说明。
if [ "$NMAJOR" -ge 24 ]; then
    echo "==> [3d-1] Node 24 运行时适配（零 JIT 全链路 + 版本感知 doctor）"
    python3 "$HERE/make_node24_runtime.py" "$STAGE" || exit 1
else
    echo "==> [3d-1] Node 22 档：保留稳定底座原运行时（不打 Node24 补丁）"
fi

# 3d-2 单包只保留「一个全屏入口」。native DSH.app 用的是
# SFSafariViewController，永远带 Safari 顶栏/底栏/关闭按钮（真机截图
# "127.0.0.1 / 关闭 / 大小"），与用户要求的「和官方 App 一样全屏」冲突。
# 真全屏的是 FullScreen=true 的 Web Clip（3f）。这里给 native APP 注入
# SBAppTags=hidden 让 SpringBoard 不再显示它，并改个不混淆的名字；APP 文件
# 本身保留（终端 dsh-app-ctl ensure / 兜底仍可用），但不再是点开的入口。
# 只改 stage 内的副本，app-bundle 独立包的源 Info.plist 一个字节不动。
python3 - "$STAGE/var/jb/Applications/DSH.app/Info.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
d = plistlib.load(open(p, 'rb'))
d['SBAppTags'] = ['hidden']
d['CFBundleDisplayName'] = 'DSH (Safari fallback)'
with open(p, 'wb') as f:
    plistlib.dump(d, f, sort_keys=False)
print('    native APP 已标记隐藏，桌面主入口 = 全屏 Web Clip')
PY

# 3e prebuilt 可执行 + setuid helper + 图标
APPB="$ROOT/app-bundle"
cp "$APPB/prebuilt/DSHLauncher"     "$STAGE/var/jb/Applications/DSH.app/DSHLauncher"
cp "$APPB/prebuilt/dsh-app-helper"  "$STAGE/var/jb/usr/bin/dsh-app-helper"
python3 "$APPB/make_app_icon.py" "$STAGE/var/jb/Applications/DSH.app" | sed 's/^/    /'

# 3e-2 手机操控（DSH GO 的 iOS 等价实现：SpringBoard 常驻 AX + HID 注入）
#   原生层：ios-mcp 1.2.8（MIT，见 LICENSE-ios-mcp / NOTICE），随包下发
#   prebuilt dylib，respring 后由 ElleKit/Substrate 注入 SpringBoard，暴露
#   127.0.0.1:8090/mcp（AX 树 / 点按 / 滑动 / 输入 / 截图 / OCR）；
#   bridge：8091/mcp，合并本机 A 层工具（设备信息、文件、命令、App、URL、
#   进程、syslog）与原生 B 层工具，DSH 通过 @deepseek-ai/dsh-mcp-client 接入。
PB="$ROOT/phone-bridge"
NATIVE="$PB/native"
DL="$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries"
mkdir -p "$DL" "$STAGE/var/jb/usr/lib/dsh-phone-bridge" \
         "$STAGE/var/jb/usr/share/doc/dev.airdevs.dsh"
cp "$NATIVE/prebuilt/dsh-ios-control.dylib" "$DL/dsh-ios-control.dylib"
cp "$NATIVE/dsh-ios-control.plist"          "$DL/dsh-ios-control.plist"
# +ios24.7 实时进度胶囊（SpringBoard 注入，只读 hud.json，不开端口）
if [ -f "$NATIVE/hud/dsh-ios-hud.dylib" ]; then
    cp "$NATIVE/hud/dsh-ios-hud.dylib" "$DL/dsh-ios-hud.dylib"
    cp "$NATIVE/hud/dsh-ios-hud.plist" "$DL/dsh-ios-hud.plist"
else
    echo "缺 Native HUD 产物：$NATIVE/hud/dsh-ios-hud.dylib（先跑 build-native-hud workflow）" >&2
    exit 1
fi
cp "$NATIVE/prebuilt/mcp-logreader"         "$STAGE/var/jb/usr/bin/mcp-logreader"
cp "$PB/server.cjs" "$PB/ensure-config.cjs" "$STAGE/var/jb/usr/lib/dsh-phone-bridge/"
cp "$PB/dsh-phone-bridge-daemon" "$PB/dsh-phone-bridge-ctl" "$STAGE/var/jb/usr/bin/"
cp "$PB/dev.airdevs.dsh.phone-bridge.plist" "$STAGE/var/jb/Library/LaunchDaemons/"
cp "$NATIVE/LICENSE-ios-mcp" "$NATIVE/NOTICE" "$STAGE/var/jb/usr/share/doc/dev.airdevs.dsh/"
cp "$PB/README.md" "$STAGE/var/jb/usr/share/doc/dev.airdevs.dsh/phone-bridge-README.md"
chmod 755 "$STAGE/var/jb/usr/bin/mcp-logreader" \
          "$STAGE/var/jb/usr/bin/dsh-phone-bridge-daemon" \
          "$STAGE/var/jb/usr/bin/dsh-phone-bridge-ctl" \
          "$STAGE/var/jb/usr/bin/dsh-autostart" \
          "$STAGE/var/jb/usr/bin/dsh-autostart-agent"
chmod 644 "$DL/dsh-ios-control.dylib" "$DL/dsh-ios-control.plist" \
          "$DL/dsh-ios-hud.dylib" "$DL/dsh-ios-hud.plist" \
          "$STAGE/var/jb/usr/lib/dsh-phone-bridge/"*.cjs \
          "$STAGE/var/jb/Library/LaunchAgents/dev.airdevs.dsh.agent.plist" \
          "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist"
echo "    手机操控：原生 8090 + bridge 8091 + 开机自启 + 自动注册 MCP"

# 3f 全屏 Web Clip（真正装进设备的那一份）
mkdir -p "$STAGE/var/jb/usr/lib/dsh/webclip"
cp "$HERE/webclip/Info.plist" "$STAGE/var/jb/usr/lib/dsh/webclip/Info.plist"
cp "$HERE/webclip/icon.png"   "$STAGE/var/jb/usr/lib/dsh/webclip/icon.png"
# token 单一真相源也随包下发：extras-postinst 清理旧 Web Clip / 自检时读它，
# 不再把 token 硬编码进安装脚本（避免与 Web Clip URL、plist、补丁漂移）。
cp "$HERE/dsh-web-token" "$STAGE/var/jb/usr/lib/dsh/webclip/token"

# 3g extras 必须进包 —— 旧版漏在这里，导致全屏入口从未安装
cp "$HERE/dsh-extras-postinst.sh" "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh"
cp "$HERE/dsh-extras-prerm.sh"   "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh"
chmod 755 "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" \
          "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh"

# 3h DEBIAN
cp -a "$HERE/DEBIAN/." "$STAGE/DEBIAN/"
# 并列实验档（如 Node 24）只改 stage 内 control 的 Version，仓库原文件
# 不动；默认 ios18 时一字不改，保证已发布产物逐字节可复现。
if [ "$TAG" != "ios18" ]; then
    sed "s/^Version: .*/Version: 0.2.2-rc.3+${TAG}/" \
        "$HERE/DEBIAN/control" > "$STAGE/DEBIAN/control"
    echo "    版本标签: +$TAG（并列实验档，不覆盖 +ios18）"
fi
# +ios24.x 的 changelog 只写在 stage 副本里：共享 control 原文件一个字节不动。
# +ios18 是已冻结的对照档（927b5308…），当前源码面向 +ios24.6，不再承诺
# 从当前 HEAD 重新构建 +ios18 能 1:1 复现当时的历史产物。
case "$TAG" in ios24.1|ios24.2|ios24.3|ios24.4|ios24.5|ios24.6|ios24.7|ios24.8|ios24.9) ;; *) skip_changelog=1 ;; esac
if [ "${skip_changelog:-0}" != "1" ]; then
    python3 - "$STAGE/DEBIAN/control" "$TAG" <<'PY'
import sys
p, tag = sys.argv[1:3]
s = open(p, encoding='utf-8').read()
extra = ""
if tag == "ios24.9":
    extra = """ * 深度对标 DSH Go 的手机 Agent 效率模型：工具集恒定，绝不随 8090 原生层
   在线状态变化 —— 工具名 / 描述 / schema 每轮都进模型上下文，任何变化
   都会让 DeepSeek 的 KV cache 从第一个改动的 token 起整段作废；原生层
   离线也不改清单，只由 phone_native 逃生口给出明确说明；
 * 按行增量读屏（ScreenDigest）：屏幕编号 sN，元素编号按阅读顺序发放，
   未变化的行不重复发、变化超过三分之一才整屏重发；读不到可比对内容时
   明确说「无法验证」，绝不谎称界面没变（ScreenVerdict）；
 * 省链路新工具：phone_intent 用系统意图直达闹钟 / 日程 / 电话 / 导航 /
   设置（能办就别点界面）、phone_collect 自动滚长列表一次收集去重、
   phone_skill_save / phone_skill_run 把成功轨迹存成技能一次重放、
   phone_handoff 把登录 / 验证码 / 支付交还用户、phone_batch 批量组合；
 * 串行动作队列 + 每步时间预算 + epoch 围栏：暂停 / 停止 / 插话后旧队列
   动作一律不重放，卡死步骤超时即中断（对标 SerialWorker 的停止语义）；
 * 进度面板可交互：暂停 / 继续 / 停止按钮、插话输入框、handoff 确认卡，
   统一走 /control 端点，SSE 快照实时带 control 状态；
 * 保留 +ios24.8 的实时进度双通道与 HUD 可见性修复、+ios24.7 组合动作、
   +ios24.6 图片支持、+ios24.2 会话兼容等全部历史修复，升级不丢
   插件 / 工作区 / 对话 / 配置。
"""
elif tag == "ios24.8":
    extra = """ * 实时进度「看得见」：进度主通道搬进 DSH Web UI 内（右下角常驻面板），
   对标 DSH Go 的状态机与工具调用折叠——状态灯 / 当前动作 / 第 n/N 步 /
   实时耗时 / 进度线 / 可折叠事件流，全程不依赖 SpringBoard 注入与灵动岛；
   SSE 主通道 + 轮询兜底 + 页面 DOM 观察终极兜底，断线按 seq 增量续传；
 * 修 HUD 完全不可见：旧版只有 tools/call 才写 hud.json、窗口初始全透明，
   没有事件就一个像素都不画；现在桥启动即发「就绪」并 2s 心跳常驻，
   HUD 改为启动即显示待命胶囊、windowLevel 提升到灵动岛插件之上、
   遍历所有 UIWindowScene 兜底（全屏 Web Clip 前台时 SpringBoard 未必有
   active scene），并写回 hud.ack.json 供 dsh-phone-bridge-ctl hud 自检；
 * 修进度根本不产生的隐性根因：ensure-config 注册 8091 时自动清掉
   serverName 同为 ios 的旧 8090 直连块（否则 DSH 绕过 bridge，
   事件流零产生，HUD 与面板都永远「待命」）；
 * 操控效率：新增 find_element（按文本直接给可点坐标）、wait_for_text
   （设备端等文本出现/消失）、progress_status；phone_act 支持整批预校验、
   find / wait_text / assert / screenshot 步骤，返回紧凑纯文本 UI 与
   增量 diff，避免「截图 -> 模型认坐标 -> 再点 -> 再截图」的往返；
 * 保留 +ios24.7 的组合动作 / 看屏 / 灵动岛胶囊 / 自启兜底，以及
   +ios24.6 图片支持、+ios24.2 会话兼容等全部历史修复，升级不丢
   插件 / 工作区 / 对话 / 配置。
"""
elif tag == "ios24.7":
    extra = """ * 手机操控提速：phone_act 一次调用执行整串动作（点按/输入/滑动/
   按键/回主屏/打开 App/等待），随后等待界面稳定并返回精简 UI，把原来
   5~10 次模型往返压成 1 次；bridge 不再在每次 tools/call 前强制
   initialize + tools/list（旧实现每次多 3 个回环请求）；
 * watch_screen / wait_for_change：原生连续采集 1~6fps，帧差检测 + 关键帧
   + Vision OCR，一次调用返回「第几秒画面变了」的事件时间线，用于看视频/
   动画/加载进度，而不是让模型轮询截图；
 * 灵动岛实时进度：新增 dsh-ios-hud.dylib 注入 SpringBoard，顶部胶囊
   实时显示当前动作、第 n/N 步、耗时与进度线；bridge 以原子文件写入
   进度，HUD 未加载时不影响任何操控链路；
 * 自启兜底：新增 LaunchAgent（用户会话）与 dsh-autostart status/repair，
   系统域 launchd 未扫描 /var/jb/Library/LaunchDaemons 时由 SpringBoard
   启动时自动拉起，装完不再需要终端敲 dsh；
 * 保留 +ios24.6 的图片支持与内置手机操控、+ios24.5 的 launchd 免终端、
   +ios24.4 的 corrupt 会话恢复、+ios24.3 的 profile 核心包隔离、
   +ios24.2 的 zstd→none 与 browse。
"""
elif tag == "ios24.6":
    extra = """ * 图片支持（读取 + 上传，全程不依赖 sharp 原生库）：rc.3 的
   prepareImages() 会遍历历史里每一张图片并调用 readImageRequest()，
   而该链路依赖 sharp；iOS 包只有 JS 壳，任一历史图片都会在请求发出前
   抛错，被 adapter 统一包成 TRANSPORT —— 这就是「新对话正常、老对话
   一发消息就 5/5 重试 DeepSeek Messages transport failed」的真因；
 * Node --import 预加载纯 JS 图片层：读取 attachments/v1 对象并校验
   sha256，PNG/JPEG/GIF/WebP 头部解析宽高/alpha/动图/EXIF 方向，
   上传直存原图；对象缺失时退化为 1x1 PNG 占位，老会话不再整轮失败；
 * 内置手机操控（DSH GO 的 iOS 等价实现）：SpringBoard 常驻 ios-mcp
   原生层（AX 树 / 点按 / 滑动 / 输入 / 截图 / OCR，127.0.0.1:8090）
   + 本机 bridge（8091）合并文件/App/进程/syslog 等 A 层工具，launchd
   开机自启；dsh wrapper 每次启动前以 mobile 身份幂等注册 MCP，装完
   respring 一次即可让模型直接点按/输入/截图；
 * 修 phone-bridge 在 Node 24 上的启动失败（--no-expose-wasm 已删除，
   改用 node-safe 零 JIT 档），ctl 新增 native/status 诊断与 config-off
   标记，撤销自动注册后不再写用户配置；
 * 保留 +ios24.5 的 launchd 免终端自启、+ios24.4 的 corrupt 会话恢复、
   +ios24.3 的 profile 核心包隔离、+ios24.2 的 zstd→none 与 browse。
"""
elif tag == "ios24.5":
    extra = """ * 修「只有终端敲 dsh 才能启动」：launchd plist 的 ProgramArguments[0]
   原为 /var/jb/bin/sh，但包内与 rootless 底座都没有这个路径，launchd
   posix_spawn 直接失败，RunAtLoad + KeepAlive 形同虚设；
 * 改为直接执行 /var/jb/usr/bin/dsh-daemon（脚本 shebang #!/bin/sh），
   安装后 launchd 正常自启并保活，桌面「DeepSeek Harness」图标即点即用，
   不需要再开终端；
 * 保留 +ios24.4 的 `.corrupt-<ts>` 会话备份目录恢复/隔离、+ios24.3 的
   profile 核心包隔离、+ios24.2 的 zstd→none 与 darwin→browse；
 * control / dsh-doctor / README / GitHub Release 统一到 +ios24.5。
"""
elif tag == "ios24.3":
    extra = """ * 继续修「工作区/对话加载不出」的第二个根因（装过插件、从 rc.5 升级的
   设备必现）：dsh plugin add 后 pnpm 的 hoisted 布局会把 @deepseek-ai
   核心包也装进 profiles/<name>/node_modules；boot 按 profile 优先进
   行模块解析，于是 rc.3 的 directory-picker 行拿到 rc.5 旧副本，版本
   守卫判定不兼容后把整行 disabled，directoryPickerController 永远
   unavailable（typert gateway: active Service ... is unavailable）；
 * 启动前的 heal 现在会隔离「运行时同名、版本不同」的核心包副本到
   $DSH_HOME/.dsh-compat-quarantine（带版本号备份，不删除），用户自己
   装的第三方插件一律不动；隔离后目录选择器与会话持久化都走运行时
   版本，rc.5 创建的明文会话/工作区原样加载；
 * 保留 +ios24.2 的 zstd→none 明文会话兼容与 darwin→browse 目录选择器
   两项修复。
"""
elif tag == "ios24.4":
    extra = """ * 修会话目录里的历史备份 `<id>.corrupt-<ts>/` 被当成活动会话读取：
   其 session.v4.jsonl 头仍是 `<id>`，stored-identity 校验判定路径不一致，
   抛错后 workspaceRegistry 不注册，工作区/对话全空（真机日志:
   dsh: warning: 5 entries did not activate / session-controller pending）；
 * 启动前 heal 会扫描 sessions/<project>/ 下的 `.corrupt-<ts>` 目录：
   同名正常会话不存在时改名回正常会话（恢复数据），已存在时移到
   $DSH_HOME/.dsh-compat-quarantine/sessions/ 保留，不再影响 boot；
 * 保留 +ios24.3 的 profile 核心包隔离、+ios24.2 的 zstd→none 与
   darwin→browse 修复。
"""
elif tag == "ios24.2":
    extra = """ * 修「工作区/对话加载不出」：会话默认压缩 zstd 改回 none，兼容用户从
   +ios15/+ios18 升级带来的明文 .jsonl 会话（不再触发 checkRootEncoding
   全局 fatal，workspace/session/directoryPicker 控制器全部正常装配）；
 * iOS(darwin) 目录选择器强制走 browse 后端（Web Clip 无原生选择器），
   「选择工作区目录」可列目录/新建文件夹；装/卸零写入 $DSH_HOME。
"""
block = """ 本版（+%s）真机回归修复（iPhone X / A11 / iOS 16.7.x）：
 * 去掉 Node 24 已删除的 --no-expose-wasm（tier.sh / pnpm / 插件子进程）；
   A11 上四档原生 JIT 全 SIGBUS 时，唯一可用的零 JIT 档不再被 bad option(9) 挡死；
 * 全部短命 node 调用统一走 node-safe（--jitless + fetch-shim），
   dsh-doctor 改为 rc.3 / Node 24 版本感知，不再误报 +ios15 的 12 项 FAIL；
 * 升级时强制 bootout + kickstart -k 换掉旧 daemon、清理旧 Web Clip，
   修掉「dsh web authentication required」401 黑屏；
%s""" % (tag, extra)
# Description 的续行必须以单个空格开头，且必须紧跟在该字段之后、
# 其它字段（Homepage:）之前，否则 dpkg 会把续行算进 Homepage。
i = s.index('\nHomepage:')
# block 自带结尾换行，s[i:] 也以 \nHomepage: 开头；去掉 block 的尾换行，
# 否则中间会多出一个空行，dpkg-deb 会报「several package info entries」。
s = s[:i] + '\n' + block.rstrip('\n') + s[i:]
open(p, 'w', encoding='utf-8').write(s)
PY
fi
chmod 755 "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"

# ---------------------------------------------------------------- 4) 完整性断言
echo "==> 构建期完整性断言"
for f in \
  "$STAGE/var/jb/usr/bin/dsh" \
  "$STAGE/var/jb/usr/bin/dsh-doctor" \
  "$STAGE/var/jb/usr/bin/dsh-daemon" \
  "$STAGE/var/jb/usr/bin/dsh-app-ctl" \
  "$STAGE/var/jb/usr/bin/dsh-app-ui" \
  "$STAGE/var/jb/usr/bin/dsh-app-helper" \
  "$STAGE/var/jb/usr/lib/dsh/bin/node" \
  "$STAGE/var/jb/usr/lib/dsh/libexec/pnpm/bin/pnpm.cjs" \
  "$STAGE/var/jb/usr/lib/dsh/libexec/pnpm/dist/pnpm.cjs" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh/lib/bin.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/assets/safari16-polyfill.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/assets/dsh-ios-manual-install-transform.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist/assets/dsh-ios-live-progress.js" \
  "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-plugin-market/lib/worker-parse.cjs" \
  "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" \
  "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh" \
  "$STAGE/var/jb/usr/lib/dsh/webclip/Info.plist" \
  "$STAGE/var/jb/usr/lib/dsh/webclip/icon.png" \
  "$STAGE/var/jb/usr/lib/dsh/webclip/token" \
  "$STAGE/var/jb/Applications/DSH.app/DSHLauncher" \
  "$STAGE/var/jb/Applications/DSH.app/Info.plist" \
  "$STAGE/var/jb/Applications/DSH.app/entitlements.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.plist" \
  "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm" "$STAGE/DEBIAN/control"; do
    [ -e "$f" ] || { echo "构建中止：缺 $f" >&2; exit 1; }
done
if [ "$NMAJOR" -ge 24 ]; then
    [ -x "$STAGE/var/jb/usr/lib/dsh/node-safe" ] || {
        echo "构建中止：缺 node-safe（Node 24 零 JIT 启动器）" >&2; exit 1; }
    grep -q 'nowasm|--jitless --require ' "$STAGE/var/jb/usr/lib/dsh/tier.sh" || {
        echo "构建中止：tier.sh nowasm 档未去掉 --no-expose-wasm" >&2; exit 1; }
    grep -q 'NODE_SAFE' "$STAGE/var/jb/usr/bin/dsh-doctor" || {
        echo "构建中止：dsh-doctor 未接上 node-safe" >&2; exit 1; }
    grep -q 'PFLAGS="--jitless"' "$STAGE/var/jb/usr/bin/pnpm" || {
        echo "构建中止：pnpm 仍带已删除的 --no-expose-wasm" >&2; exit 1; }
    for _f in "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-plugin-manager/lib/index.js" \
              "$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-plugin-manager/lib/types/operations.js" \
              "$STAGE/var/jb/usr/lib/dsh/apply_pnpm_abs_patch.cjs"; do
        if grep -v '^[[:space:]]*[/\*#]' "$_f" | grep -q -- '--no-expose-wasm'; then
            echo "构建中止：$_f 生效行仍含 Node 24 已删除的 --no-expose-wasm" >&2; exit 1
        fi
    done
    echo "    Node 24 运行时断言通过（nowasm 可用 / 短命调用与插件子进程全零 JIT）"
fi

# +ios24.6：图片支持 + 手机操控（缺任何一件都不允许出包）
for f in \
  "$STAGE/var/jb/usr/lib/dsh/ios-image-shim.mjs" \
  "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.dylib" \
  "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/dsh-ios-control.plist" \
  "$STAGE/var/jb/Library/LaunchDaemons/dev.airdevs.dsh.phone-bridge.plist" \
  "$STAGE/var/jb/usr/bin/dsh-phone-bridge-daemon" \
  "$STAGE/var/jb/usr/bin/dsh-phone-bridge-ctl" \
  "$STAGE/var/jb/usr/bin/mcp-logreader" \
  "$STAGE/var/jb/usr/lib/dsh-phone-bridge/server.cjs" \
  "$STAGE/var/jb/usr/lib/dsh-phone-bridge/ensure-config.cjs" \
  "$STAGE/var/jb/usr/share/doc/dev.airdevs.dsh/NOTICE"; do
    [ -e "$f" ] || { echo "构建中止：缺 $f" >&2; exit 1; }
done
[ "$(grep -c -- '--import "\$D/ios-image-shim.mjs"' "$STAGE/var/jb/usr/bin/dsh")" -eq 2 ] || {
    echo "构建中止：dsh wrapper 的两条 node 启动行未同时注入图片 preload" >&2; exit 1; }
grep -q 'ensure-config.cjs" "\$DSH_HOME" on' "$STAGE/var/jb/usr/bin/dsh" || {
    echo "构建中止：dsh wrapper 未接手机操控 MCP 自动注册" >&2; exit 1; }
if grep -v '^[[:space:]]*#' "$STAGE/var/jb/usr/bin/dsh-phone-bridge-daemon" | grep -q -- '--no-expose-wasm'; then
    echo "构建中止：phone-bridge daemon 仍带 Node 24 已删除的 --no-expose-wasm" >&2; exit 1
fi
sh -n "$STAGE/var/jb/usr/bin/dsh-phone-bridge-daemon" || exit 1
sh -n "$STAGE/var/jb/usr/bin/dsh-phone-bridge-ctl" || exit 1
node --check "$STAGE/var/jb/usr/lib/dsh-phone-bridge/server.cjs" || exit 1
node --check "$STAGE/var/jb/usr/lib/dsh-phone-bridge/ensure-config.cjs" || exit 1
node --check "$STAGE/var/jb/usr/lib/dsh/ios-image-shim.mjs" || exit 1
echo "    图片支持 / 手机操控断言通过（preload + 原生层 + bridge + 自动注册）"

# +ios24.7：实时进度 HUD + 组合动作 + 自启兜底（缺任何一件都不允许出包）
for f in \
  "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.dylib" \
  "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.plist" \
  "$STAGE/var/jb/usr/bin/dsh-autostart" \
  "$STAGE/var/jb/usr/bin/dsh-autostart-agent" \
  "$STAGE/var/jb/Library/LaunchAgents/dev.airdevs.dsh.agent.plist"; do
    [ -e "$f" ] || { echo "构建中止：缺 $f" >&2; exit 1; }
done
HM=$(od -An -tx1 -N4 "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.dylib" 2>/dev/null | tr -d ' \n')
[ "$HM" = "cffaedfe" ] || { echo "构建中止：dsh-ios-hud.dylib 不是 arm64 Mach-O (magic=$HM)" >&2; exit 1; }
python3 - "$STAGE/var/jb/Library/MobileSubstrate/DynamicLibraries/dsh-ios-hud.plist" <<'PY'
import plistlib, sys
d = plistlib.load(open(sys.argv[1], 'rb'))
assert 'com.apple.springboard' in d['Filter']['Bundles'], 'HUD 未过滤 SpringBoard'
print('    HUD 注入目标 = SpringBoard')
PY
grep -q 'dsh-ios-hud.dylib' "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" || {
    echo "构建中止：extras-postinst 未给 HUD 授权/sign" >&2; exit 1; }
grep -q "phone_act" "$STAGE/var/jb/usr/lib/dsh-phone-bridge/server.cjs" || {
    echo "构建中止：bridge 缺 phone_act 组合动作" >&2; exit 1; }
grep -q "watch_screen" "$STAGE/var/jb/usr/lib/dsh-phone-bridge/server.cjs" || {
    echo "构建中止：bridge 缺 watch_screen 看屏工具" >&2; exit 1; }
grep -q "hudPublish" "$STAGE/var/jb/usr/lib/dsh-phone-bridge/server.cjs" || {
    echo "构建中止：bridge 缺实时进度上报" >&2; exit 1; }
grep -q "upstreamTools(false)" "$STAGE/var/jb/usr/lib/dsh-phone-bridge/server.cjs" || {
    echo "构建中止：bridge 仍在每次 tools/call 强制刷新工具列表" >&2; exit 1; }
sh -n "$STAGE/var/jb/usr/bin/dsh-autostart" || exit 1
sh -n "$STAGE/var/jb/usr/bin/dsh-autostart-agent" || exit 1
echo "    实时进度 / 组合动作 / 自启兜底断言通过"

# +ios24.8：实时进度主通道搬进 DSH Web UI + 事件流 + 效率工具 + 8090 去重
# + HUD 可见性修复。任何一件缺失都不允许出包。
echo "==> 构建期 +ios24.8 断言（实时进度可见性 / 事件流 / 省往返工具）"
FR="$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist"
BR="$STAGE/var/jb/usr/lib/dsh-phone-bridge"
# 1) 前端进度面板真的注入了 index.html 且连的是本机事件端点
grep -q 'dsh-ios-live-progress.js' "$FR/index.html" || {
    echo "构建中止：index.html 未注入实时进度面板" >&2; exit 1; }
[ -f "$FR/assets/dsh-ios-live-progress.js" ] || {
    echo "构建中止：缺进度面板脚本" >&2; exit 1; }
node --check "$FR/assets/dsh-ios-live-progress.js" || exit 1
for needle in '127.0.0.1:8091' '/events' '/progress' 'DOMContentLoaded'; do
    grep -qF "$needle" "$FR/assets/dsh-ios-live-progress.js" || {
        echo "构建中止：进度面板缺 $needle" >&2; exit 1; }
done
# 2) bridge 事件流：SSE / 轮询 / 启动即写 / 心跳常驻 / 序号续传
for needle in 'emitEvent' 'text/event-stream' 'Last-Event-ID' '/progress' 'sseClients' \
              'writeIdleHud' "emitEvent('idle'" 'level: HUD_LEVEL'; do
    grep -qF "$needle" "$BR/server.cjs" || {
        echo "构建中止：bridge 缺事件流要素 $needle" >&2; exit 1; }
done
# 3) 效率工具（省模型往返）
for needle in 'find_element' 'wait_for_text' 'progress_status' 'validateSteps' \
              'compactUI' 'uiDelta' 'stop_on_error'; do
    grep -qF "$needle" "$BR/server.cjs" || {
        echo "构建中止：bridge 缺效率工具 $needle" >&2; exit 1; }
done
# 4) 8090 冲突去重（否则 DSH 直连 8090 绕过 bridge，进度彻底没有）
grep -qF 'isConflictingIosBlock' "$BR/ensure-config.cjs" || {
    echo "构建中止：ensure-config 缺 8090 冲突去重（进度不会产生）" >&2; exit 1; }
grep -qF '127.0.0.1:8091/mcp' "$BR/ensure-config.cjs" || {
    echo "构建中止：ensure-config 未注册 8091 bridge" >&2; exit 1; }
node --check "$BR/ensure-config.cjs" || exit 1
# 5) ctl 的 HUD 诊断命令
grep -qF 'hud_diag' "$STAGE/var/jb/usr/bin/dsh-phone-bridge-ctl" || {
    echo "构建中止：ctl 缺 hud 诊断命令" >&2; exit 1; }
echo "    +ios24.8 断言通过（进度面板 / SSE / 效率工具 / 8090 去重 / HUD 诊断）"

# +ios24.9：深度对标 DSH Go 的手机 Agent 效率模型。固定工具集（KV cache）、
# 按行增量读屏（ScreenDigest/ScreenVerdict）、串行队列与 epoch 围栏、
# intent/collect/skill/handoff 省链路工具、可交互进度控制，缺一不出包。
echo "==> 构建期 +ios24.9 断言（固定工具集 / 增量读屏 / 串行围栏 / 交互控制）"
FR="$STAGE/var/jb/usr/lib/dsh/node_modules/@deepseek-ai/dsh-web-frontend/dist"
BR="$STAGE/var/jb/usr/lib/dsh-phone-bridge"
# 1) 固定工具集：tools/list 恒返回 FIXED_TOOLS，绝不读上游在线状态
for needle in 'const FIXED_TOOLS' 'FIXED_TOOL_NAMES' 'tools: FIXED_TOOLS' \
              'fixed_toolset_note' 'upstreamTools(false)'; do
    grep -qF "$needle" "$BR/server.cjs" || {
        echo "构建中止：bridge 缺固定工具集要素 $needle" >&2; exit 1; }
done
# 2) 按行增量读屏 + 诚实判定（缺少观测依据不等于界面没变）
for needle in 'function screenDigest' "screenDigest('act'" '无法验证' \
              '与 s' 'ui_verdict' 'compactUI' 'uiDelta'; do
    grep -qF "$needle" "$BR/server.cjs" || {
        echo "构建中止：bridge 缺增量读屏要素 $needle" >&2; exit 1; }
done
# 3) 串行动作队列 + 每步预算 + epoch 围栏 + /control 端点
for needle in 'function runSerialized' 'function controlApply' 'publicControlState' \
              "admitted !== controlState.epoch" 'controlState.epoch' '/control' \
              'function handoffWait' 'function skillRun'; do
    grep -qF "$needle" "$BR/server.cjs" || {
        echo "构建中止：bridge 缺串行围栏/控制端点 $needle" >&2; exit 1; }
done
# 4) 省链路新工具真的接进 callLocal 分发
for needle in "case 'phone_screen':" "case 'phone_intent':" "case 'phone_collect':" \
              "case 'phone_skill_save':" "case 'phone_skill_run':" \
              "case 'phone_skill_list':" "case 'phone_handoff':" \
              "case 'phone_control':" "case 'phone_native':" "case 'phone_batch':"; do
    grep -qF "$needle" "$BR/server.cjs" || {
        echo "构建中止：bridge 缺工具分发 $needle" >&2; exit 1; }
done
# 5) 进度面板可交互：暂停/继续/停止/插话/handoff 确认卡走 /control
for needle in 'sendControl' "BRIDGE + '/control'" 'handoffBox' 'interjectInput' \
              "case 'paused'" 'snap.control' 'EventSource'; do
    grep -qF "$needle" "$FR/assets/dsh-ios-live-progress.js" || {
        echo "构建中止：进度面板缺交互要素 $needle" >&2; exit 1; }
done
node --check "$BR/server.cjs" || exit 1
node --check "$FR/assets/dsh-ios-live-progress.js" || exit 1
echo "    +ios24.9 断言通过（固定工具集 / 增量读屏 / 串行围栏 / 10 个新工具 / 面板交互）"

for f in "$STAGE/var/jb/usr/bin/dsh" "$STAGE/var/jb/usr/bin/dsh-daemon" \
         "$STAGE/var/jb/usr/bin/dsh-app-ctl" "$STAGE/var/jb/usr/bin/dsh-app-ui" \
         "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" \
         "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh" \
         "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"; do
    sh -n "$f" || { echo "$f 语法错误" >&2; exit 1; }
done
# daemon 必须真的 exec dsh web，且不得写 $DSH_HOME
grep -q 'web --no-open --port' "$STAGE/var/jb/usr/bin/dsh-daemon" || { echo "daemon 未 exec web" >&2; exit 1; }

# ---------------------------------------------------------------- 5) 可复现归一化
echo "==> 固定 mode / mtime / 属主（SOURCE_DATE_EPOCH=$SDE）"
python3 - "$STAGE" <<'PY'
import os, sys
root = sys.argv[1]
for dp, dns, fns in os.walk(root):
    os.chmod(dp, 0o755)
    for n in fns:
        p = os.path.join(dp, n)
        if os.path.islink(p):
            continue
        m = os.stat(p).st_mode
        os.chmod(p, 0o755 if (m & 0o100) else 0o644)
PY
# 顺序很重要：chown(2) 会清掉 setuid/setgid 位，所以 4755 必须在
# chown -R 0:0 之后再设。旧版两个构建脚本都在 chown 之前设 4755，
# 结果 helper 实际是 755 —— App 以 mobile 身份执行它时无法 bootstrap
# launchd daemon，点图标根本起不来服务。
chown -R 0:0 "$STAGE" 2>/dev/null || true
chmod 755 "$STAGE/var/jb/Applications/DSH.app/DSHLauncher" \
          "$STAGE/var/jb/usr/bin/dsh" "$STAGE/var/jb/usr/bin/dsh-doctor" \
          "$STAGE/var/jb/usr/bin/dsh-daemon" "$STAGE/var/jb/usr/bin/dsh-app-ctl" \
          "$STAGE/var/jb/usr/bin/dsh-app-ui" "$STAGE/var/jb/usr/bin/pnpm" \
          "$STAGE/var/jb/usr/bin/dsh-compat" \
          "$STAGE/var/jb/usr/lib/dsh/node-safe" \
          "$STAGE/var/jb/usr/lib/dsh/dsh-extras-postinst.sh" \
          "$STAGE/var/jb/usr/lib/dsh/dsh-extras-prerm.sh" \
          "$STAGE/DEBIAN/postinst" "$STAGE/DEBIAN/prerm"
chmod 4755 "$STAGE/var/jb/usr/bin/dsh-app-helper"
find "$STAGE" -depth -exec touch -h -d "@$SDE" {} + 2>/dev/null || \
    find "$STAGE" -depth -exec touch -h -t 202311142013.20 {} + 2>/dev/null || true

# ---------------------------------------------------------------- 6) 打包
mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
echo "==> dpkg-deb 组装（-Zgzip -z9，可复现）"
SOURCE_DATE_EPOCH="$SDE" dpkg-deb -b -Zgzip -z9 "$STAGE" "$OUT" >/dev/null
echo "==> 产物"
echo "    $(du -h "$OUT" | cut -f1)  $OUT"
sha256sum "$OUT" | sed 's/^/    /'
