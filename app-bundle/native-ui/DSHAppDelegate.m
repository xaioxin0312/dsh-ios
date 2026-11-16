/*
 * DSHAppDelegate — DeepSeek Harness 原生 App 入口。
 *
 * 与旧的 SFSafariViewController 壳不同：本 App 的主界面是原生 UIKit 写的
 * 「实时操控进度」面板（DSHRootVC），直接读本机 bridge 127.0.0.1:8091 的
 * /progress 与 /control。DSH 网页工作台不再是主界面，而是「设置」页里的
 * 一个入口（DSHSettingsVC）。
 *
 * 自己写的界面语言：深色石墨底 + 青绿强调 + 大圆角卡片 + 状态灯，
 * 不复制 DSHGo / fish-pocket 的布局与配色。
 */
#import "DSHAppDelegate.h"
#import "DSHRootVC.h"

@implementation DSHAppDelegate

- (BOOL)application:(UIApplication *)application
didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.tintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];

    DSHRootVC *root = [[DSHRootVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBar.prefersLargeTitles = YES;
    nav.navigationBar.barStyle = UIBarStyleBlack;

    window.rootViewController = nav;
    [window makeKeyAndVisible];
    self.window = window;
    return YES;
}

@end
