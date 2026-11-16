/*
 * DSHRootVC — 原生主界面：手机操控的实时进度就是首页本身。
 *
 * 数据来自本机 bridge 127.0.0.1:8091：
 *   GET  /progress  -> { snapshot:{verb,state,step,total,recent,control,...}, events:[] }
 *   POST /control   -> {action: pause|resume|stop|interject|continue, text?}
 * 纯 UIKit 代码布局，无 storyboard、无第三方依赖、无 WKWebView。
 * 界面语言（深色石墨 + 青绿强调 + 大圆角 + 状态灯）为本项目自创。
 */
#import "DSHRootVC.h"
#import "DSHSettingsVC.h"
#import <Foundation/Foundation.h>

static NSString *const kBridge = @"http://127.0.0.1:8091";

@interface DSHRootVC () <UITextFieldDelegate>
@property (nonatomic, strong) NSTimer *poll;
@property (nonatomic, strong) UIView *hero;
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UILabel *verbLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *countLabel;
@property (nonatomic, strong) UIView *track;
@property (nonatomic, strong) UIView *bar;
@property (nonatomic, strong) UIButton *pauseBtn;
@property (nonatomic, strong) UIButton *stopBtn;
@property (nonatomic, strong) UITextField *interject;
@property (nonatomic, strong) UIView *recentBox;
@property (nonatomic, strong) UILabel *recentTitle;
@property (nonatomic, strong) NSArray<UILabel *> *recentRows;
@property (nonatomic, strong) UIView *handoffBox;
@property (nonatomic, strong) UILabel *handoffLabel;
@property (nonatomic, strong) NSDictionary *snap;
@property (nonatomic, assign) NSInteger lastSeq;
@end

@implementation DSHRootVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0];
    self.title = @"实时进度";
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeAlways;
    self.navigationController.navigationBar.largeTitleTextAttributes =
        @{ NSForegroundColorAttributeName: [UIColor whiteColor] };
    self.navigationController.navigationBar.titleTextAttributes =
        @{ NSForegroundColorAttributeName: [UIColor whiteColor] };
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:@"设置"
                                        style:UIBarButtonItemStylePlain
                                       target:self action:@selector(openSettings)];
    [self buildUI];
    [self poll:nil];
    self.poll = [NSTimer scheduledTimerWithTimeInterval:1.0 target:self
                                               selector:@selector(poll:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.poll forMode:NSRunLoopCommonModes];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self poll:nil];
}

- (UIColor *)accent { return [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0]; }
- (UIColor *)card    { return [UIColor colorWithRed:0.14 green:0.15 blue:0.18 alpha:1.0]; }

- (void)buildUI {
    CGFloat w = self.view.bounds.size.width;

    // ---- Hero 卡 ----
    self.hero = [[UIView alloc] initWithFrame:CGRectMake(16, 24, w - 32, 190)];
    self.hero.backgroundColor = [self card];
    self.hero.layer.cornerRadius = 22;
    self.hero.layer.cornerCurve = kCACornerCurveContinuous;
    [self.view addSubview:self.hero];

    self.dot = [[UIView alloc] initWithFrame:CGRectMake(22, 24, 12, 12)];
    self.dot.layer.cornerRadius = 6;
    self.dot.backgroundColor = [UIColor colorWithWhite:0.5 alpha:1.0];
    [self.hero addSubview:self.dot];

    self.verbLabel = [self label:@"待命" size:26 bold:YES
                           frame:CGRectMake(44, 16, w - 32 - 60, 34)];
    self.verbLabel.textColor = [UIColor whiteColor];
    [self.hero addSubview:self.verbLabel];

    self.detailLabel = [self label:@"桥已连接 · 等待任务" size:14 bold:NO
                             frame:CGRectMake(44, 52, w - 32 - 60, 20)];
    self.detailLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    self.detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self.hero addSubview:self.detailLabel];

    self.countLabel = [self label:@"" size:13 bold:YES
                            frame:CGRectMake(22, 88, 140, 18)];
    self.countLabel.textColor = [self accent];
    self.countLabel.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.hero addSubview:self.countLabel];

    self.track = [[UIView alloc] initWithFrame:CGRectMake(22, 148, w - 32 - 44, 5)];
    self.track.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.10];
    self.track.layer.cornerRadius = 2.5;
    [self.hero addSubview:self.track];
    self.bar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 0, 5)];
    self.bar.backgroundColor = [self accent];
    self.bar.layer.cornerRadius = 2.5;
    [self.track addSubview:self.bar];

    // ---- 控制条 ----
    CGFloat cy = 232;
    self.pauseBtn = [self button:@"暂停" frame:CGRectMake(16, cy, (w - 48) / 2, 46)];
    [self.pauseBtn addTarget:self action:@selector(togglePause)
            forControlEvents:UIControlEventTouchUpInside];
    self.stopBtn = [self button:@"停止" frame:CGRectMake(32 + (w - 48) / 2, cy, (w - 48) / 2, 46)];
    self.stopBtn.backgroundColor = [UIColor colorWithRed:0.62 green:0.20 blue:0.18 alpha:1.0];
    [self.stopBtn addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.pauseBtn];
    [self.view addSubview:self.stopBtn];

    self.interject = [[UITextField alloc] initWithFrame:CGRectMake(16, cy + 60, w - 96, 44)];
    self.interject.placeholder = @"插话：给 AI 补充一句…";
    self.interject.backgroundColor = [self card];
    self.interject.textColor = [UIColor whiteColor];
    self.interject.layer.cornerRadius = 14;
    self.interject.layer.cornerCurve = kCACornerCurveContinuous;
    self.interject.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 1)];
    self.interject.leftViewMode = UITextFieldViewModeAlways;
    self.interject.delegate = self;
    self.interject.returnKeyType = UIReturnKeySend;
    [self.view addSubview:self.interject];
    UIButton *send = [self button:@"发送" frame:CGRectMake(w - 72, cy + 60, 56, 44)];
    send.backgroundColor = [self accent];
    [send setTitleColor:[UIColor colorWithRed:0.08 green:0.10 blue:0.10 alpha:1.0]
               forState:UIControlStateNormal];
    [send addTarget:self action:@selector(sendInterject) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:send];

    // ---- 交还确认卡（handoff）----
    self.handoffBox = [[UIView alloc] initWithFrame:CGRectMake(16, cy + 118, w - 32, 64)];
    self.handoffBox.backgroundColor = [UIColor colorWithRed:0.30 green:0.24 blue:0.10 alpha:1.0];
    self.handoffBox.layer.cornerRadius = 16;
    self.handoffBox.hidden = YES;
    [self.view addSubview:self.handoffBox];
    self.handoffLabel = [self label:@"" size:14 bold:NO
                             frame:CGRectMake(14, 8, w - 60, 30)];
    self.handoffLabel.textColor = [UIColor colorWithRed:1.0 green:0.86 blue:0.55 alpha:1.0];
    self.handoffLabel.numberOfLines = 2;
    [self.handoffBox addSubview:self.handoffLabel];
    UIButton *go = [self button:@"我操作好了" frame:CGRectMake(14, 36, w - 60, 22)];
    go.backgroundColor = [UIColor colorWithRed:0.85 green:0.65 blue:0.20 alpha:1.0];
    [go setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    go.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    [go addTarget:self action:@selector(continueHandoff) forControlEvents:UIControlEventTouchUpInside];
    [self.handoffBox addSubview:go];

    // ---- 最近操作 ----
    self.recentBox = [[UIView alloc] initWithFrame:CGRectMake(16, cy + 196, w - 32, 168)];
    self.recentBox.backgroundColor = [self card];
    self.recentBox.layer.cornerRadius = 20;
    [self.view addSubview:self.recentBox];
    self.recentTitle = [self label:@"最近操作" size:15 bold:YES
                             frame:CGRectMake(16, 12, w - 64, 22)];
    self.recentTitle.textColor = [UIColor colorWithWhite:0.75 alpha:1.0];
    [self.recentBox addSubview:self.recentTitle];
    NSMutableArray *rows = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        UILabel *r = [self label:@"—" size:14 bold:NO
                           frame:CGRectMake(16, 44 + i * 34, w - 64, 28)];
        r.textColor = [UIColor colorWithWhite:0.88 alpha:1.0];
        [self.recentBox addSubview:r];
        [rows addObject:r];
    }
    self.recentRows = rows;
}

- (UILabel *)label:(NSString *)text size:(CGFloat)size bold:(BOOL)bold frame:(CGRect)frame {
    UILabel *l = [[UILabel alloc] initWithFrame:frame];
    l.text = text;
    l.font = bold ? [UIFont systemFontOfSize:size weight:UIFontWeightSemibold]
                  : [UIFont systemFontOfSize:size weight:UIFontWeightRegular];
    return l;
}

- (UIButton *)button:(NSString *)title frame:(CGRect)frame {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.frame = frame;
    [b setTitle:title forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:0.18 alpha:1.0];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    b.layer.cornerRadius = 14;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    return b;
}

#pragma mark - 数据

- (void)poll:(NSTimer *)t {
    NSString *u = [kBridge stringByAppendingFormat:@"/progress?since=%ld", (long)self.lastSeq];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:u]
                                                     cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                 timeoutInterval:2.0];
    __weak typeof(self) weakSelf = self;
    NSURLSessionTask *task = [[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        if (err || !data) return;
        NSDictionary *top = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![top isKindOfClass:[NSDictionary class]]) return;
        NSDictionary *s = top[@"snapshot"];
        if (![s isKindOfClass:[NSDictionary class]]) s = top;
        NSInteger seq = [top[@"seq"] respondsToSelector:@selector(integerValue)] ? [top[@"seq"] integerValue] : 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.lastSeq = seq;
            [weakSelf render:s];
        });
    }];
    [task resume];
}

- (void)render:(NSDictionary *)s {
    self.snap = s;
    NSString *state = s[@"state"] ?: @"idle";
    NSString *verb = s[@"verb"];
    if (![verb isKindOfClass:[NSString class]] || ![verb length]) verb = @"执行中";
    NSString *detail = s[@"detail"];
    if (![detail isKindOfClass:[NSString class]]) detail = @"";
    NSInteger step = [s[@"step"] respondsToSelector:@selector(integerValue)] ? [s[@"step"] integerValue] : 0;
    NSInteger total = [s[@"total"] respondsToSelector:@selector(integerValue)] ? [s[@"total"] integerValue] : 0;

    self.verbLabel.text = verb;
    self.detailLabel.text = detail.length ? detail : @"桥已连接 · 等待任务";

    BOOL running = [state isEqualToString:@"running"] || [state isEqualToString:@"thinking"];
    BOOL paused = [state isEqualToString:@"paused"];
    BOOL err = [state isEqualToString:@"error"] || [state isEqualToString:@"failed"];
    if (paused)      self.dot.backgroundColor = [UIColor colorWithRed:0.88 green:0.65 blue:0.23 alpha:1.0];
    else if (err)    self.dot.backgroundColor = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
    else if (running)self.dot.backgroundColor = [self accent];
    else             self.dot.backgroundColor = [UIColor colorWithWhite:0.5 alpha:1.0];

    self.countLabel.text = total > 0 ? [NSString stringWithFormat:@"第 %ld / %ld 步", (long)step, (long)total]
                                     : (running ? @"执行中…" : @"");
    CGFloat p = total > 0 ? (CGFloat)step / (CGFloat)total : (running ? 0.15 : ([state isEqualToString:@"done"] ? 1.0 : 0.0));
    p = MAX(0, MIN(1, p));
    CGRect b = self.track.bounds;
    self.bar.frame = CGRectMake(0, 0, b.size.width * p, b.size.height);

    [self.pauseBtn setTitle:paused ? @"继续" : @"暂停" forState:UIControlStateNormal];

    // 交还卡：control.handoff 是 {reason,since} 字典；老版本可能是纯字符串。
    NSDictionary *ctl = [s[@"control"] isKindOfClass:[NSDictionary class]] ? s[@"control"] : nil;
    id ho = ctl[@"handoff"];
    NSString *handoff = @"";
    if ([ho isKindOfClass:[NSDictionary class]]) handoff = ho[@"reason"] ?: @"";
    else if ([ho isKindOfClass:[NSString class]]) handoff = ho;
    BOOL needHandoff = handoff.length > 0;
    self.handoffBox.hidden = !needHandoff;
    if (needHandoff) self.handoffLabel.text = [NSString stringWithFormat:@"需要你来：%@", handoff];

    // 最近操作
    NSArray *recent = s[@"recent"];
    if ([recent isKindOfClass:[NSArray class]]) {
        for (NSInteger i = 0; i < self.recentRows.count; i++) {
            UILabel *row = self.recentRows[i];
            if (i < recent.count) {
                NSDictionary *op = recent[i];
                NSString *v = op[@"v"] ?: @"—";
                id ok = op[@"ok"];
                NSString *mark = [ok isKindOfClass:[NSNumber class]] ? ([ok boolValue] ? @"✓ " : @"✕ ") : @"· ";
                row.text = [mark stringByAppendingString:v];
            } else {
                row.text = @"—";
            }
        }
    }
}

#pragma mark - 控制

- (void)post:(NSString *)action text:(NSString *)text {
    NSMutableDictionary *body = [NSMutableDictionary dictionary];
    body[@"action"] = action;
    if (text.length) body[@"text"] = text;
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:
        [NSURL URLWithString:[kBridge stringByAppendingString:@"/control"]]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = data;
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf poll:nil]; });
    }] resume];
}

- (void)togglePause {
    BOOL paused = [self.snap[@"state"] isEqualToString:@"paused"];
    [self post:paused ? @"resume" : @"pause" text:nil];
}
- (void)stop { [self post:@"stop" text:nil]; }
- (void)continueHandoff { [self post:@"continue" text:nil]; }
- (void)sendInterject {
    NSString *t = self.interject.text;
    if (![t length]) return;
    self.interject.text = @"";
    [self.view endEditing:YES];
    [self post:@"interject" text:t];
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [self sendInterject]; return YES; }

- (void)openSettings {
    [self.navigationController pushViewController:[[DSHSettingsVC alloc] init] animated:YES];
}

@end
