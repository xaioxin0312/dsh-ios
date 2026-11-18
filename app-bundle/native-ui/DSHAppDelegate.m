/*
 * DSHAppDelegate — DeepSeek Harness 原生 App 入口。
 *
 * 主界面 = 全屏 WKWebView 加载 DSH 官方 Web UI（DSHWebVC），观感与官方
 * 桌面端一致：没有浏览器 chrome，就是普通 APP。端口/token 运行时从 daemon
 * 写的状态文件读取（动态端口，避开 3080 冲突）；WKWebView 若因 rootless
 * 手签起不来，自动降级 SFSafariViewController，绝不白屏。
 *
 * 灵动岛进度由独立 SpringBoard HUD 读 hud.json 驱动，与本 App 解耦。
 * 设置页（DSHSettingsVC）里保留网页工作台兜底入口与桥状态诊断。
 */
#import "DSHAppDelegate.h"
#import "DSHWebVC.h"

@implementation DSHAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.tintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
    window.rootViewController = [[DSHWebVC alloc] init];
    [window makeKeyAndVisible];
    self.window = window;
    return YES;
}

@end
