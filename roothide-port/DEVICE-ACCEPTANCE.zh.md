# iOS 16.6.1 / Dopamine-roothide 真机验收

本说明用于验证通过云端编译和静态审计的候选 deb。云端没有连接手机，不把主机测试当作真机运行结果。

## 安装与首启

1. 在手机「设置 → 通用 → 关于本机」确认系统为 iOS 16.6.1，并确认当前已激活 Dopamine-roothide。
2. 用该隐根环境的包管理器安装候选 `dev.airdevs.dsh` deb。它不是普通 rootless 包，也不是需要 Apple 证书签名的 IPA。
3. 安装完做一次用户空间的 respring，让 SpringBoard 操控层/HUD 加载；不要用重启整台手机替代这一步。
4. 点击「DeepSeek Harness」App。验收内容是：后台引擎被拉起、网页工作台加载、能打开工作区和会话列表，而不是只看到一个桌面图标。

## 核心功能

- 在 App 内配置你自己的模型服务商，创建一条新会话并获得正常回复。
- 让智能体运行一个简单命令，例如 `printf '42\n'`，检查工具调用结果和流式回复。
- 安装你需要的一个纯 JavaScript DSH 插件，分别测试安装、启用、停用，退出 App 后再打开确认状态保留。
- 切到后台再回来，确认会话和工作区仍能打开。

本候选保留了手机操控 bridge，但不会自动迁移或改写已有用户 YAML。首次需要这项功能时，在手机的 bootstrap 终端显式运行：

```sh
dsh-phone-bridge-ctl config-on
```

再从 App 中测试读屏和一个可撤销的点按操作。已有注册保持有效。

## 出现问题时

先保留安装错误原文或首启界面。不要为了排错清空原有会话/插件/工作区。

若已能打开隐根终端，可只读取服务状态：

```sh
dpkg-query -W -f='${Package} ${Version} ${Architecture}\n' dev.airdevs.dsh
launchctl print user/foreground/dev.airdevs.dsh
launchctl print user/foreground/dev.airdevs.dsh.phone-bridge
```

反馈时优先说明：手机型号、系统版本、安装是否完成、App 能否打开、哪个步骤失败，以及服务状态里的 `state` / `pid` / `last exit code`。模型服务商的 Key 留在手机上自行配置。

## 完成条件

只有上述核心首启、会话和插件流程在这台 iOS 16.6.1 手机上实际通过后，才记录为该设备上的可用结果。重新越狱后还需检查路径变化情况下的再次启动。
