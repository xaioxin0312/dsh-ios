# phone-bridge — 内置手机操控工具链

让「启动 DSH，DSH 就能直接调用工具操作手机」成立。**+ios24.6 起随主
deb（`dev.airdevs.dsh`）一起安装**：原生层、bridge、launchd 自启、MCP
注册全部开箱即用；不再依赖单独的 app 包或手动装 ios-mcp。**+ios24.7**
起再加组合动作 / 看屏 / 实时进度 HUD 与用户会话自启兜底。

## +ios24.7：操控提速、实时进度与自启兜底

### 三个减少模型往返的工具

| 工具 | 作用 |
| --- | --- |
| `phone_act` | 一次调用执行整串 UI 动作（`tap` 文本/坐标、`type`、`swipe`、`key`、`home`、`open`、`wait`、`ocr`），全部跑完后等 UI 树连续两次一致（`settle_ms`，默认 2500ms），返回精简后的可点元素；`screenshot:true` 可附带最终截图。原来 5~10 次模型往返压成 1 次 |
| `watch_screen` | `fps` 1~6、`duration_ms` 500~8000 连续截图，按 JPEG 字节哈希做帧差，保留关键帧（`max_keyframes`，默认 3），`ocr`（默认开）对变化帧跑 Vision OCR，返回事件时间线；用于看视频/动画/加载进度，模型拿到的是「第几秒发生了变化」而不是 30fps 帧 |
| `wait_for_change` | 点按后轮询到画面真的变化（`min_bytes` 阈值）或超时，取代固定 `sleep` |

```text
phone_act(steps=[{action:"tap",text:"搜索"},{action:"type",text:"天气"},{action:"tap",text:"搜索"}],
          observe=true, screenshot=false)
watch_screen(fps=3, duration_ms=3000, max_keyframes=3, ocr=true)
wait_for_change(timeout_ms=5000, poll_ms=120)
```

同时修掉一个真实延迟源：旧实现每次 `tools/call` 前都强制
`initialize + tools/list`（每次多 3 个本地回环）。现在工具清单 30s 缓存，
未命中才刷新；mock 端到端测试里整个流程 `initialize` / `tools/list` 各只 1 次。

### 灵动岛实时进度（`dsh-ios-hud.dylib`）

SpringBoard 注入的悬浮胶囊，读 `/var/mobile/Library/DSH/hud.json`
（bridge 用「写临时文件 + rename」原子更新，不依赖 IPC）：

- 显示当前工具名/动作、第 `n/N` 步、实时耗时与底部进度线；
  完成/失败短暂停留（`ttl_ms` 1.6s）后淡出，运行中超时 30s 自动隐藏；
- 胶囊贴在屏幕顶部安全区下方（刘海/灵动岛下缘 `+6pt`），宽度 196~310pt；
- `windowLevel=2000`、`userInteractionEnabled=NO`、`hitTest` 返回 `nil`，
  不拦截触摸，也不注册 MCP、不开端口；
- HUD 未加载 / `hud.json` 不可写时，`hudPublish()` 静默失败，
  操控链路完全不受影响。

HUD 由 GitHub Actions `macos-15` 编译（`.github/workflows/build-native-hud.yml`），
`native/hud/build-hud.sh` 是等价的本地命令。

### 自启兜底（`dsh-autostart`）

部分 rootless 环境开机不扫描 `/var/jb/Library/LaunchDaemons`，旧版表现就是
「必须开终端敲 `dsh`」。现在两级兜底：

1. 系统域 `dev.airdevs.dsh`（LaunchDaemon，已有）；
2. 用户域 `dev.airdevs.dsh.agent`（LaunchAgent，`LimitLoadToSessionType=Aqua`）：
   SpringBoard 启动时执行 `dsh-autostart-agent`，3080 已就绪直接 `exit 0`，
   未就绪才拉起 daemon；`KeepAlive{SuccessfulExit=false}` + `ThrottleInterval=15`。

```sh
dsh-autostart status   # 两级 launchd 状态、3080 探活、三份日志尾部
dsh-autostart repair   # bootout + bootstrap 系统域，再 bootstrap gui/501，最多等 20s
dsh-autostart logs     # 直接看 autostart / agent 日志
```

安装时 `dsh-extras-postinst.sh` 会自动跑一次 `dsh-autostart repair`（失败不阻塞安装）。

## 对标 Android DSH GO 的「手机 Agent」

DSH GO（DSHarness Go）在 Android 上的手机操控建立在 **AccessibilityService**
之上：读取无障碍节点树、按文本定位控件、dispatchGesture 点按/滑动、
ACTION_SET_TEXT 输入、无障碍截图；敏感页面（密码/验证码/支付）跳过，
并有三档确认强度。iOS 没有公开的 AccessibilityService，等价物只能是：

| 能力 | Android DSH GO | 本包 iOS 实现 |
|---|---|---|
| 读界面 | AccessibilityNodeInfo 树 | SpringBoard 内私有 AX（AXUIElement）树 |
| 点按/滑动 | dispatchGesture | IOHIDEvent 注入（SpringBoard 进程内） |
| 输入文本 | ACTION_SET_TEXT | HID 键盘事件 + 剪贴板兜底 |
| 截图 | AccessibilityService.takeScreenshot | IOMobileFramebuffer / 私有截屏 |
| 打开 App | Intent | `open_url` + `launch_app`（FrontBoard） |
| 文字识别 | 节点文本即可 | Vision OCR（可选 PaddleOCR） |
| 确认/边界 | 三档确认 + 敏感页拦截 | 工具审批在 DSH 侧；本包不自动执行敏感操作 |

原生层用 [witchan/ios-mcp]（MIT，见 `native/LICENSE-ios-mcp`、`NOTICE`）
的 prebuilt dylib，随包安装到
`/var/jb/Library/MobileSubstrate/DynamicLibraries/`，respring 后由
ElleKit/Substrate 注入 SpringBoard，在 `0.0.0.0:8090/mcp` 暴露 46 个工具。
bridge 再把它们与本机 A 层工具合并到 `127.0.0.1:8091/mcp`。

## 组件

| 文件 | 落到设备上 | 作用 |
|---|---|---|
| `native/prebuilt/dsh-ios-control.dylib` | `/var/jb/Library/MobileSubstrate/DynamicLibraries/` | SpringBoard 原生层：AX 树 / 点按 / 滑动 / 输入 / 截图 / OCR |
| `native/dsh-ios-control.plist` | 同目录 | MobileSubstrate filter（`com.apple.springboard`） |
| `native/hud/dsh-ios-hud.dylib` | 同目录 | +ios24.7 实时进度胶囊：读 `hud.json`，在屏幕顶部显示动作/步骤/耗时 |
| `native/hud/dsh-ios-hud.plist` | 同目录 | HUD 的 MobileSubstrate filter |
| `native/prebuilt/mcp-logreader` | `/var/jb/usr/bin/` | 原生层读取 unified log 的小工具 |
| `server.cjs` | `/var/jb/usr/lib/dsh-phone-bridge/` | 纯 Node MCP Streamable HTTP 服务，`127.0.0.1:8091/mcp` |
| `ensure-config.cjs` | 同目录 | 幂等把 `@deepseek-ai/dsh-mcp-client` 注册进 `$DSH_HOME` 的 patch 层 |
| `dsh-phone-bridge-daemon` | `/var/jb/usr/bin/` | launchd 前台入口：exec 进 server（node-safe 零 JIT） |
| `dsh-phone-bridge-ctl` | `/var/jb/usr/bin/` | `status\|health\|native\|native-on\|native-off\|tools\|enable\|disable\|config-on\|config-off\|config-status\|log` |
| `dev.airdevs.dsh.phone-bridge.plist` | `/var/jb/Library/LaunchDaemons/` | `RunAtLoad + KeepAlive`，`UserName=mobile` |
| `dsh-autostart` | `/var/jb/usr/bin/` | +ios24.7 `status\|repair\|logs`：两级 launchd / 端口 / 日志诊断 |
| `dsh-autostart-agent` + `dev.airdevs.dsh.agent.plist` | `/var/jb/usr/bin/` + `/var/jb/Library/LaunchAgents/` | 用户会话兜底：SpringBoard 启动时 3080 未就绪才拉起 daemon |
| `verify-phone-bridge.sh` | 仅仓库 | 本地 28 项验证（真 MCP 握手 / 工具调用 / 上游转发 / 配置 schema / 零 JIT） |

MCP 注册不在 daemon 里做（避免改写用户配置的嫌疑），而由
`/var/jb/usr/bin/dsh` wrapper 在每次启动 DSH **之前**以当前用户
（launchd = mobile）幂等追加一条 `id: dsh-ios-phone-bridge-mcp`；
其它插件行原样保留。`config-off` 会留下
`$DSH_HOME/.phone-bridge-no-auto-config`，之后不再自动写。

## 能力分层

**A 层（开箱即用，纯 Node 实现）**

`get_device_info`、`list_dir`、`read_file`、`write_file`、`run_command`、
`list_apps`、`launch_app`、`open_url`、`list_processes`、`get_syslog`、
`dsh_status`、`phone_bridge_status`。

**B 层（转发到原生层 8090）**

`screenshot`、`tap_screen`、`swipe_screen`、`type_text`、`press_key`、
`get_ui_elements`、`ocr_screen`、`launch_app` 等 46 个工具，在
`tools/list` 里自动合并，`tools/call` 原样转发。原生层未加载时返回明确
的指引（respring 一次），不影响 A 层。

> 纯 JS 拿不到 IOHIDEvent / SpringBoard XPC，真·触控注入与截图必须靠原生
> 实现。

## 为什么是 8091

`8090` 是 ios-mcp 原生层的默认端口，不能抢占。DSH 侧配置固定连
`http://127.0.0.1:8091/mcp`；旧的 `plugins/dsh-ios-phone-control`（直连
8090）仍可独立使用，但不要与内置注册同时启用（两者 `serverName` 都是
`ios`，工具前缀都会是 `mcp__ios__*`）。

## 安全

- bridge 只绑定 `127.0.0.1`；但上游原生层监听 `0.0.0.0:8090` 且**无任何
  认证**（上游设计）。不在可信局域网时执行 `dsh-phone-bridge-ctl
  native-off` 并 respring，停用原生层、只保留 A 层。
- `run_command` 可执行任意 shell，`read_file` / `write_file` 能读写服务
  进程权限内的路径。工具调用审批在 DSH 侧完成；本包不会自动执行
  支付/密码/验证码类操作。
- 关闭：`dsh-phone-bridge-ctl config-off && dsh-phone-bridge-ctl disable`。
  卸载 `dev.airdevs.dsh` 时 `prerm` 会自动做这两件事。
- 配置写在用户 patch 层，保持顶层为 YAML 数组（真机曾因顶层非数组直接
  fatal）；`dsh-home-heal.cjs` 只删两个旧 IM 插件块，不会误删本工具链。

## 验证

```sh
sh phone-bridge/verify-phone-bridge.sh   # 28 项
sh app-bundle/verify-app.sh              # 73 项（含 16 项工具链断言）
```

端到端验证用包内 `@modelcontextprotocol/client` 真跑 `initialize` +
`tools/list` + `tools/call`，并用假上游 ios-mcp 验证 B 层合并与转发。
真机侧的 ldid 伪签 / respring 注入 / HID 注入仍需在设备上确认。

[witchan/ios-mcp]: https://github.com/witchan/ios-mcp
