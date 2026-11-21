# 第 9 版：iOS 16.6.1 首启闪退修复

## 从日志确认的事实

用户的崩溃报告与第 8 版 App 的二进制 UUID 一致。异常是 `SIGABRT` / Objective-C 异常；堆栈经过 WebKit 内容进程终止回调，随后进入 `SFSafariViewController initWithURL:` 初始化。

第 8 版源码存在对应的竞态：先创建 WebView，再异步启动后台并给 `targetURL` 赋值；如果 WebContent 先失败，Safari 兜底路径可能拿到尚未准备好的 URL。报告本身没有直接保存 URL 参数，也没有单独证明 WebContent XPC 启动失败的底层原因。

## 第 9 版的改动

- 创建 WebView 前就生成有效的本机 HTTP URL；异常端口回退为 3080，token 采用正确的查询编码。
- 早期 WebContent 失败先记入启动状态，后台启动完成、窗口就绪后再进入 Safari 兜底。
- Safari 入口再次验证 URL，捕获同步初始化异常，并提供重新连接或在浏览器打开的恢复入口。
- launchctl 实际参数改为 roothide 提示的 `user/foreground`，同时调整 job 的域身份字段。旧提示属于兼容转发警告，不据此断言旧服务没有运行。
- 仅 App 改用官方 roothide 四项基础 entitlement；Node/helper 各自所需权限保持不变。这是减少签名变量的调整，不是已证实的 WebContent 底层原因。
- App 元数据更新为 `0.2.2` / `1.9`，便于识别后续日志。

## 已通过的验证

- 10 项 Python 回归、4 项 Node 路径回归，以及完整原包 stage 检查。
- Apple 主机上实际执行的 URL 构造测试和早期 WebContent 失败/窗口/模态/重试状态测试。
- iOS 16.5 SDK 下原生编译；成品中受检原生组件最低系统版本仍全部为 iOS 15.0。
- 云端及下载后的本机成品审计、SHA-256、root 属主、helper 权限位和 Node 原始指令/权限保留检查。

构建运行编号：`44875240621`。包版本：`0.2.2-rc.3+ios24.12+roothide1.9`。

## 手机复测

用隐根包管理器覆盖安装第 9 版，按提示 respring，打开「DeepSeek Harness」。现有配置和数据保留。

先确认 App 能否进入工作台，再验证新会话和插件安装/启停。如果仍有问题，请提供第 9 版的新截图或 `.ips`；新报告应显示 App build `1.9`。这份包尚未在用户手机上完成复测。
