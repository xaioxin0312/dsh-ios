# phone-bridge — 内置手机操控工具链

让「启动 DSH，DSH 就能直接调用工具操作手机」成立。**+ios24.6 起随主
deb（`dev.airdevs.dsh`）一起安装**：原生层、bridge、launchd 自启、MCP
注册全部开箱即用；不再依赖单独的 app 包或手动装 ios-mcp。

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
| `native/prebuilt/mcp-logreader` | `/var/jb/usr/bin/` | 原生层读取 unified log 的小工具 |
| `server.cjs` | `/var/jb/usr/lib/dsh-phone-bridge/` | 纯 Node MCP Streamable HTTP 服务，`127.0.0.1:8091/mcp` |
| `ensure-config.cjs` | 同目录 | 幂等把 `@deepseek-ai/dsh-mcp-client` 注册进 `$DSH_HOME` 的 patch 层 |
| `dsh-phone-bridge-daemon` | `/var/jb/usr/bin/` | launchd 前台入口：exec 进 server（node-safe 零 JIT） |
| `dsh-phone-bridge-ctl` | `/var/jb/usr/bin/` | `status\|health\|native\|native-on\|native-off\|tools\|enable\|disable\|config-on\|config-off\|config-status\|log` |
| `dev.airdevs.dsh.phone-bridge.plist` | `/var/jb/Library/LaunchDaemons/` | `RunAtLoad + KeepAlive`，`UserName=mobile` |
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
