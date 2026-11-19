/*
 * DSHWebVC — 主界面：全屏 WKWebView 加载 DSH 官方 Web UI（与桌面端同构）。
 *
 * 来源优先级（与 daemon 动态端口状态文件一致）：
 *   /var/jb/var/log/dsh-app/web-port  -> 端口（daemon 启动时选定并原子写）
 *   /var/jb/var/log/dsh-app/web-token -> loopback token（与引擎固定 token 同源）
 * 读不到则回退到编译期常量 3080 / kDefaultToken，绝不白屏。
 *
 * 关键设计（+ios24.11）：
 *  1) 观感 = 官方桌面端：全屏 WebView，隐藏一切浏览器 chrome，就是普通 APP。
 *  2) rootless 手签 App 的 WKWebView 可能无法启动 WebContent XPC（见历史实测）。
 *     因此内置「看门狗」：WebView 若在 6s 内没有 didFinish / 进程崩溃 / 加载失败，
 *     自动降级到 SFSafariViewController 打开同一 URL，保证「不断」。
 *  3) 灵动岛进度继续由独立 SpringBoard HUD 读 hud.json 驱动，与本界面解耦，
 *     不依赖 WebView，也不依赖 APNs。
 *  4) 保留悬浮进度胶囊（可选显示）与控制，数据直读本机 bridge 8091，
 *     与 HUD 共用同一份 verb/recent 人话状态。
 */
#import "DSHWebVC.h"
#import "DSHSettingsVC.h"
#import <WebKit/WebKit.h>
#import <SafariServices/SafariServices.h>
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <dispatch/dispatch.h>

extern char **environ;

static NSString *const kPortFile  = @"/var/jb/var/log/dsh-app/web-port";
static NSString *const kTokenFile = @"/var/jb/var/log/dsh-app/web-token";
static NSString *const kDefaultPort  = @"3080";
static NSString *const kDefaultToken = @"dshios-fixed-token-8f3a2c";
static NSString *const kBridge = @"http://127.0.0.1:8091";

@interface DSHWebVC () <WKNavigationDelegate, WKUIDelegate, SFSafariViewControllerDelegate>
@property (nonatomic, strong) WKWebView *web;
@property (nonatomic, strong) UIView *capsule;
@property (nonatomic, strong) UILabel *capsuleLabel;
@property (nonatomic, strong) NSTimer *watchdog;
@property (nonatomic, assign) BOOL didFinish;
@property (nonatomic, assign) BOOL degraded;
@property (nonatomic, strong) NSURL *targetURL;
@end

@implementation DSHWebVC

- (NSString *)readFile:(NSString *)path fallback:(NSString *)fb {
    NSString *s = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    s = [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return (s.length > 0) ? s : fb;
}
- (NSString *)port  { return [self readFile:kPortFile  fallback:kDefaultPort]; }
- (NSString *)token { return [self readFile:kTokenFile fallback:kDefaultToken]; }

- (NSURL *)buildURL {
    NSString *u = [NSString stringWithFormat:@"http://127.0.0.1:%@/?token=%@", [self port], [self token]];
    return [NSURL URLWithString:u];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0];
    self.title = @"DeepSeek Harness";
    [self buildWebView];
    [self buildCapsule];
    [self buildSettingsButton];
    // +ios24.12：像官方桌面端那样，App 打开就主动拉起 DSH 引擎。
    // 用包内 setuid helper 执行幂等的 `dsh-app-ctl ensure`——daemon 已在跑
    // 就秒回，没跑才 bootstrap+kickstart。放到后台队列，不阻塞主线程；
    // 完成后回主线程按状态文件里的真实端口加载 WebView（绝不用写死 3080）。
    [self ensureDaemonThenLoad];
}

// 主动拉起 daemon 后加载 Web UI。helper 缺失/失败都降级为直接加载，绝不白屏。
- (void)ensureDaemonThenLoad {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        const char *helper = "/var/jb/usr/bin/dsh-app-helper";
        if (access(helper, X_OK) == 0) {
            pid_t pid = -1;
            char *const argv[] = { (char *)helper, NULL };
            // helper 自身执行 setuid(0) + dsh-app-ctl ensure（幂等，已跑即返回）。
            if (posix_spawn(&pid, helper, NULL, NULL, argv, environ) == 0 && pid > 0) {
                int st = 0;
                waitpid(pid, &st, 0);  // ensure 内部探活最多 ~8s，子线程等待不卡 UI
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self.targetURL = [self buildURL];
            [self loadTarget];
        });
    });
}

#pragma mark - WebView
- (void)buildWebView {
    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    WKPreferences *pref = [[WKPreferences alloc] init];
    pref.javaScriptEnabled = YES;
    cfg.preferences = pref;
    if (@available(iOS 10.0, *)) {
        cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
    }
    WKWebView *w = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
    w.translatesAutoresizingMaskIntoConstraints = NO;
    w.navigationDelegate = self;
    w.UIDelegate = self;
    w.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0];
    w.opaque = NO;
    [self.view addSubview:w];
    [NSLayoutConstraint activateConstraints:@[
        [w.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [w.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [w.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [w.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    ]];
    if (@available(iOS 11.0, *)) {
        w.scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    self.web = w;
}

- (void)loadTarget {
    NSURLRequest *req = [NSURLRequest requestWithURL:self.targetURL
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8.0];
    [self.web loadRequest:req];
    // 看门狗：6s 内没 didFinish 或 WebContent 崩溃 -> 降级 SFSafari。
    self.didFinish = NO;
    __weak typeof(self) weakSelf = self;
    self.watchdog = [NSTimer scheduledTimerWithTimeInterval:6.0 repeats:NO block:^(NSTimer *t) {
        if (!weakSelf.didFinish && !weakSelf.degraded) [weakSelf degradeToSafari];
    }];
}

#pragma mark - 降级通道（保证「不断」）
- (void)degradeToSafari {
    if (self.degraded) return;
    self.degraded = YES;
    [self.watchdog invalidate];
    self.watchdog = nil;
    SFSafariViewController *sf = [[SFSafariViewController alloc] initWithURL:self.targetURL];
    sf.delegate = self;
    if (@available(iOS 10.0, *)) {
        sf.preferredBarTintColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0];
        sf.preferredControlTintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
    }
    [self presentViewController:sf animated:NO completion:nil];
}
- (void)safariViewControllerDidFinish:(SFSafariViewController *)c {
    [c dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - WKNavigationDelegate
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.didFinish = YES;
    [self.watchdog invalidate];
    self.watchdog = nil;
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (!self.didFinish) [self degradeToSafari];
}
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    if (!self.didFinish) [self degradeToSafari];
}
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView {
    if (!self.didFinish) [self degradeToSafari];
}

// 外部链接交系统浏览器，绝不跳出 loopback。
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action
    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
    NSURL *u = action.request.URL;
    NSString *host = u.host ?: @"";
    if ([host isEqualToString:@"127.0.0.1"] || [host isEqualToString:@"localhost"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    NSString *scheme = u.scheme ?: @"";
    if ([scheme isEqualToString:@"about"] || [scheme isEqualToString:@"data"]) {
        decisionHandler(WKNavigationActionPolicyAllow);
        return;
    }
    if (action.navigationType == WKNavigationTypeLinkActivated && u) {
        if ([[UIApplication sharedApplication] canOpenURL:u]) {
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
        }
    }
    decisionHandler(WKNavigationActionPolicyCancel);
}

// JS 弹窗转原生，避免静默丢弃。
- (void)webView:(WKWebView *)webView runJavaScriptAlertPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(void))completionHandler {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"DeepSeek Harness"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { completionHandler(); }]];
    [self presentViewController:ac animated:YES completion:nil];
}
- (void)webView:(WKWebView *)webView runJavaScriptConfirmPanelWithMessage:(NSString *)message
    initiatedByFrame:(WKFrameInfo *)frame completionHandler:(void (^)(BOOL))completionHandler {
    UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"DeepSeek Harness"
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [ac addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel
        handler:^(UIAlertAction *a) { completionHandler(NO); }]];
    [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault
        handler:^(UIAlertAction *a) { completionHandler(YES); }]];
    [self presentViewController:ac animated:YES completion:nil];
}

#pragma mark - 悬浮进度胶囊（灵动岛之外的前台补充；数据与 HUD 同源）
- (void)buildCapsule {
    UIView *c = [[UIView alloc] initWithFrame:CGRectMake(16, 8, self.view.bounds.size.width - 74, 40)];
    c.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    c.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.55];
    c.layer.cornerRadius = 20;
    c.hidden = YES;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(14, 0, c.bounds.size.width - 28, 40)];
    l.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    l.textColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
    l.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    l.textAlignment = NSTextAlignmentCenter;
    l.lineBreakMode = NSLineBreakByTruncatingTail;
    [c addSubview:l];
    [self.view addSubview:c];
    self.capsule = c;
    self.capsuleLabel = l;
    [NSTimer scheduledTimerWithTimeInterval:1.0 target:self selector:@selector(pollBridge:)
                                   userInfo:nil repeats:YES];
    [self pollBridge:nil];
}

- (void)pollBridge:(NSTimer *)t {
    NSString *u = [kBridge stringByAppendingString:@"/progress"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:2.0];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) return;
        NSDictionary *top = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSDictionary *s = top[@"snapshot"];
        if (![s isKindOfClass:[NSDictionary class]]) s = top;
        NSString *state = s[@"state"] ?: @"idle";
        NSString *verb = s[@"verb"];
        if (![verb isKindOfClass:[NSString class]] || !verb.length) verb = @"待命";
        NSInteger step = [s[@"step"] respondsToSelector:@selector(integerValue)] ? [s[@"step"] integerValue] : 0;
        NSInteger total = [s[@"total"] respondsToSelector:@selector(integerValue)] ? [s[@"total"] integerValue] : 0;
        BOOL running = [state isEqualToString:@"running"] || [state isEqualToString:@"thinking"] || [state isEqualToString:@"paused"];
        NSString *text = running
            ? (total > 0 ? [NSString stringWithFormat:@"%@  ·  %ld/%ld", verb, (long)step, (long)total] : verb)
            : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.capsule.hidden = (text.length == 0);
            weakSelf.capsuleLabel.text = text;
        });
    }] resume];
}

#pragma mark - 设置入口（设置页里仍保留网页兜底与桥状态）
- (void)buildSettingsButton {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *gear = [UIImage systemImageNamed:@"gearshape.fill"];
    if (gear) [b setImage:gear forState:UIControlStateNormal];
    else [b setTitle:@"设置" forState:UIControlStateNormal];
    b.tintColor = [UIColor whiteColor];
    b.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    b.layer.cornerRadius = 17;
    b.frame = CGRectMake(self.view.bounds.size.width - 50, 8, 34, 34);
    b.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [b addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:b];
}
- (void)openSettings {
    DSHSettingsVC *s = [[DSHSettingsVC alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)dealloc {
    [self.watchdog invalidate];
}

@end
