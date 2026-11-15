/*
 * dsh-ios-hud —— SpringBoard 常驻实时进度胶囊（+ios24.8 可见性修复）。
 *
 * bridge（8091）把每个工具调用的状态原子写入
 *   /var/mobile/Library/DSH/hud.json
 * 本 dylib 以 150ms 轮询该文件，把状态画到屏幕顶部。
 *
 * +ios24.8 修复真机「HUD 完全不可见，一个像素都没有」的三个确定性根因：
 *   1) 旧版初始 alpha=0 且只有 poll 到事件才 apply —— 没有事件/文件读不到时
 *      窗口恒透明，用户连「HUD 到底注入没有」都判断不了。现在启动时就画一个
 *      低亮度「DSH 待命」常驻胶囊，加载成功即肉眼可见。
 *   2) 旧版 windowLevel=2000，被灵动岛/Dynamic Island 类插件的高层窗口盖住。
 *      现在默认 1e6 级别，并支持 hud.json 里 `level` 字段动态覆盖。
 *   3) 旧版只取 activeScene，全屏 Web Clip 在前台时 SpringBoard 自己的 scene
 *      未必 foregroundActive，拿不到 scene 就永远不建窗口。现在遍历所有
 *      connectedScenes 各建一个窗口，并保留「无 scene 时用 mainScreen 兜底」。
 *
 * 另外写回一个 ack 文件（/var/mobile/Library/DSH/hud.ack.json），记录
 * 本 dylib 已加载、建了几个窗口、windowLevel、最后一次成功读到状态的时间，
 * 供 `dsh-phone-bridge-ctl hud` 直接判断「没注入 / 注入了但被遮挡 / 读不到文件」。
 *
 * 设计约束：
 *   - 不注册 MCP、不开端口，只读一个文件，HUD 挂掉不影响操控链路。
 *   - window 的 hitTest 恒返回 nil，绝不拦截触摸。
 *   - 进度主通道是 DSH Web UI 内的面板；本胶囊只是跨 App 兜底。
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/stat.h>

static NSString *const kDSHHUDPath    = @"/var/mobile/Library/DSH/hud.json";
static NSString *const kDSHHUDAckPath = @"/var/mobile/Library/DSH/hud.ack.json";
static CGFloat   const kDSHDefaultLevel = 1000000.0;  // 盖过灵动岛插件

#pragma mark - 视图

@interface DSHHUDView : UIView
@property (nonatomic, strong) UIView *dot;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UILabel *metaLabel;
@property (nonatomic, strong) UIView *progressTrack;
@property (nonatomic, strong) UIView *progressBar;
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) BOOL running;
@property (nonatomic, strong) NSTimer *pulseTimer;
@property (nonatomic, assign) CGFloat pulsePhase;
@end

@implementation DSHHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.90];
    self.layer.cornerRadius = 20;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.12].CGColor;
    self.userInteractionEnabled = NO;

    _dot = [[UIView alloc] initWithFrame:CGRectMake(14, 16, 8, 8)];
    _dot.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
    _dot.layer.cornerRadius = 4;
    [self addSubview:_dot];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.font = [UIFont systemFontOfSize:11.5 weight:UIFontWeightSemibold];
    _titleLabel.textColor = [UIColor whiteColor];
    _titleLabel.text = @"DSH 就绪";
    [self addSubview:_titleLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _detailLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.70];
    _detailLabel.text = @"等待任务 · 桥已连接";
    [self addSubview:_detailLabel];

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightMedium];
    _metaLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.62];
    _metaLabel.textAlignment = NSTextAlignmentRight;
    [self addSubview:_metaLabel];

    _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.14];
    _progressTrack.layer.cornerRadius = 1;
    [self addSubview:_progressTrack];

    _progressBar = [[UIView alloc] initWithFrame:CGRectZero];
    _progressBar.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
    _progressBar.layer.cornerRadius = 1;
    [_progressTrack addSubview:_progressBar];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat w = CGRectGetWidth(self.bounds);
    self.dot.center = CGPointMake(19, h * 0.5 - 4);
    CGFloat textLeft = 32;
    CGFloat metaW = 74;
    CGFloat textW = MAX(60, w - textLeft - metaW - 12);
    self.titleLabel.frame = CGRectMake(textLeft, 6, textW, 14);
    self.detailLabel.frame = CGRectMake(textLeft, 20, textW, 14);
    self.metaLabel.frame = CGRectMake(w - metaW - 12, 15, metaW, 14);
    self.progressTrack.frame = CGRectMake(12, h - 4, w - 24, 2);
    [self setProgress:self.progress];
}

- (void)setProgress:(CGFloat)p {
    _progress = MAX(0, MIN(1, p));
    CGFloat w = CGRectGetWidth(self.progressTrack.bounds);
    self.progressBar.frame = CGRectMake(0, 0, MAX(0, w * _progress), 2);
}

- (void)startPulse {
    if (self.pulseTimer) return;
    __weak typeof(self) weakSelf = self;
    self.pulseTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2) return;
        self2.pulsePhase = 1.0 - self2.pulsePhase;
        [UIView animateWithDuration:0.45 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            self2.dot.alpha = 0.35 + 0.65 * self2.pulsePhase;
            self2.dot.transform = CGAffineTransformMakeScale(0.85 + 0.15 * self2.pulsePhase,
                                                             0.85 + 0.15 * self2.pulsePhase);
        } completion:nil];
    }];
}

- (void)stopPulse {
    [self.pulseTimer invalidate];
    self.pulseTimer = nil;
    self.dot.alpha = 1.0;
    self.dot.transform = CGAffineTransformIdentity;
}

- (void)applyState:(NSString *)state idle:(BOOL)idle {
    self.running = [state isEqualToString:@"running"];
    if (idle) {
        [self stopPulse];
        self.dot.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    } else if (self.running) {
        self.dot.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        [self startPulse];
    } else if ([state isEqualToString:@"error"]) {
        [self stopPulse];
        self.dot.backgroundColor = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
    } else {
        [self stopPulse];
        self.dot.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.35 alpha:1.0];
    }
}

// 永不拦截触摸
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event { return nil; }

@end

#pragma mark - 控制器

@interface DSHHUD : NSObject
@property (nonatomic, strong) NSMutableArray<UIWindow *> *windows;
@property (nonatomic, strong) NSMutableArray<DSHHUDView *> *huds;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, assign) NSTimeInterval lastMTime;
@property (nonatomic, strong) NSDictionary *lastState;
@property (nonatomic, assign) NSTimeInterval shownAt;
@property (nonatomic, assign) NSTimeInterval lastApplyAt;
@property (nonatomic, assign) BOOL idleMode;
@property (nonatomic, assign) CGFloat level;
@end

@implementation DSHHUD

+ (instancetype)shared {
    static DSHHUD *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DSHHUD new]; });
    return s;
}

- (void)writeAck:(NSString *)phase {
    NSMutableDictionary *a = [NSMutableDictionary dictionary];
    a[@"loaded"] = @YES;
    a[@"phase"] = phase ?: @"unknown";
    a[@"windows"] = @(self.windows.count);
    a[@"level"] = @(self.level);
    a[@"bundle"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    a[@"last_apply_at"] = @(self.lastApplyAt);
    a[@"last_state"] = self.lastState[@"state"] ?: @"";
    a[@"ts"] = @([NSDate date].timeIntervalSince1970 * 1000.0);
    NSData *d = [NSJSONSerialization dataWithJSONObject:a options:0 error:nil];
    if (d) [d writeToFile:kDSHHUDAckPath atomically:YES];
}

/* 不再依赖 activeScene：遍历所有 connectedScenes 各建一个窗口；
 * 一个都没有时用 mainScreen.bounds 建无 scene 窗口（iOS 仍会显示）。 */
- (NSArray<UIWindowScene *> *)allScenes {
    NSMutableArray *out = [NSMutableArray array];
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) [out addObject:(UIWindowScene *)s];
        }
    }
    return out;
}

- (CGFloat)topInsetForWidth:(CGFloat)screenW {
    CGFloat inset = 0;
    if (@available(iOS 11.0, *)) {
        UIWindow *w = self.windows.firstObject;
        if (w) inset = w.safeAreaInsets.top;
    }
    if (inset <= 0) inset = [UIApplication sharedApplication].statusBarFrame.size.height;
    if (inset <= 0) inset = 44;
    // 灵动岛插件常把假岛画在状态栏里，往下多让一点，避免被其遮住。
    return inset + 8;
}

- (UIWindow *)makeWindowForScene:(UIWindowScene *)scene {
    UIWindow *w;
    if (scene) {
        if (@available(iOS 13.0, *)) w = [[UIWindow alloc] initWithWindowScene:scene];
        else return nil;
    } else {
        w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    }
    w.frame = scene ? scene.coordinateSpace.bounds : [UIScreen mainScreen].bounds;
    w.windowLevel = self.level;
    w.backgroundColor = [UIColor clearColor];
    w.userInteractionEnabled = NO;
    w.hidden = NO;
    w.rootViewController = [UIViewController new];
    w.rootViewController.view.backgroundColor = [UIColor clearColor];
    w.rootViewController.view.userInteractionEnabled = NO;

    DSHHUDView *hud = [[DSHHUDView alloc] initWithFrame:CGRectMake(0, 0, 230, 40)];
    // 关键修复：初始化即常驻可见（低亮度待命），不再等事件才 alpha→1。
    hud.alpha = 0.62;
    [w addSubview:hud];
    [self.huds addObject:hud];
    [self.windows addObject:w];
    return w;
}

- (void)start {
    if (self.windows.count) return;
    self.windows = [NSMutableArray array];
    self.huds = [NSMutableArray array];
    self.level = kDSHDefaultLevel;
    self.idleMode = YES;

    NSArray *scenes = [self allScenes];
    if (scenes.count == 0) {
        // SpringBoard 尚未建立任何 scene：先建一个无 scene 的兜底窗口，
        // 1s 后再试一次，把后续 scene 也补上（不阻塞主线程）。
        [self makeWindowForScene:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachLateScenes];
        });
    } else {
        for (UIWindowScene *s in scenes) [self makeWindowForScene:s];
    }

    // 启动即显示待命态，让「HUD 是否加载」肉眼可判。
    for (DSHHUDView *h in self.huds) [h applyState:@"idle" idle:YES];
    [self layoutHUD];
    [self writeAck:@"started"];

    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        [weakSelf poll];
    }];
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        [weakSelf tick];
    }];
    NSLog(@"[dsh-hud] started windows=%lu level=%.0f", (unsigned long)self.windows.count, self.level);
}

- (void)attachLateScenes {
    NSArray *scenes = [self allScenes];
    if (scenes.count == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachLateScenes];
        });
        return;
    }
    // 已有无 scene 兜底窗口时，再为每个真实 scene 补一个（避免前台切换后不显示）。
    for (UIWindowScene *s in scenes) [self makeWindowForScene:s];
    for (DSHHUDView *h in self.huds) {
        [h applyState:self.lastState[@"state"] ?: @"idle" idle:self.idleMode];
        h.alpha = self.idleMode ? 0.62 : 1.0;
    }
    [self layoutHUD];
    [self writeAck:@"scenes-attached"];
}

- (void)poll {
    NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:kDSHHUDPath error:nil];
    if (!attrs) return;
    NSTimeInterval mtime = [attrs[NSFileModificationDate] timeIntervalSince1970];
    if (mtime == self.lastMTime) return;
    self.lastMTime = mtime;

    NSData *data = [NSData dataWithContentsOfFile:kDSHHUDPath];
    if (!data) return;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![json isKindOfClass:[NSDictionary class]]) return;
    [self apply:json];
}

- (void)apply:(NSDictionary *)json {
    NSString *state = [json[@"state"] isKindOfClass:[NSString class]] ? json[@"state"] : @"running";
    NSString *detail = [json[@"detail"] isKindOfClass:[NSString class]] ? json[@"detail"] : @"";
    NSString *title = [json[@"title"] isKindOfClass:[NSString class]] ? json[@"title"] : @"DSH 操控中";
    NSInteger step = [json[@"step"] respondsToSelector:@selector(integerValue)] ? [json[@"step"] integerValue] : 0;
    NSInteger total = [json[@"total"] respondsToSelector:@selector(integerValue)] ? [json[@"total"] integerValue] : 0;
    BOOL idle = [state isEqualToString:@"idle"] || [state isEqualToString:@"ready"];

    // 允许 bridge 动态覆盖 windowLevel（应对更强的灵动岛插件）。
    id lv = json[@"level"];
    if ([lv respondsToSelector:@selector(doubleValue)] && [lv doubleValue] > 0) {
        CGFloat newLevel = (CGFloat)[lv doubleValue];
        if (newLevel != self.level) {
            self.level = newLevel;
            for (UIWindow *w in self.windows) w.windowLevel = newLevel;
        }
    }

    self.lastState = json;
    self.idleMode = idle;
    self.shownAt = [NSDate date].timeIntervalSince1970;
    self.lastApplyAt = self.shownAt;

    for (DSHHUDView *hud in self.huds) {
        hud.titleLabel.text = title;
        hud.detailLabel.text = detail.length ? detail : @"…";
        [hud applyState:state idle:idle];
        if (total > 0) [hud setProgress:(CGFloat)step / (CGFloat)total];
        else if (!idle && ![state isEqualToString:@"running"]) [hud setProgress:1.0];
        else [hud setProgress:idle ? 0.0 : 0.15];
        hud.alpha = idle ? 0.62 : 1.0;   // 待命低亮度，执行时全亮
    }
    [self layoutHUD];
    [self updateMeta];
    [self writeAck:@"applied"];
}

- (void)layoutHUD {
    for (NSUInteger i = 0; i < self.huds.count; i++) {
        DSHHUDView *hud = self.huds[i];
        UIWindow *w = i < self.windows.count ? self.windows[i] : nil;
        CGFloat screenW = w ? w.bounds.size.width : [UIScreen mainScreen].bounds.size.width;
        CGFloat top = [self topInsetForWidth:screenW];
        NSString *detail = hud.detailLabel.text ?: @"";
        UIFont *f = hud.detailLabel.font;
        CGFloat textW = [detail sizeWithAttributes:@{NSFontAttributeName: f}].width;
        CGFloat titleW = [hud.titleLabel.text sizeWithAttributes:@{NSFontAttributeName: hud.titleLabel.font}].width;
        CGFloat width = MAX(196, MIN(310, MAX(textW, titleW) + 32 + 74 + 14));
        CGFloat x = (screenW - width) * 0.5;
        hud.frame = CGRectMake(x, top, width, 40);
        [hud setNeedsLayout];
    }
}

- (void)tick {
    if (!self.lastState) {
        // 还没有任何事件：保持待命胶囊常驻，绝不淡出（旧版在这里什么都不画）。
        [self updateMeta];
        return;
    }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSInteger ttl = [self.lastState[@"ttl_ms"] respondsToSelector:@selector(integerValue)]
        ? [self.lastState[@"ttl_ms"] integerValue] : 3000;
    if (self.idleMode) { [self updateMeta]; return; }   // 待命/就绪常驻
    BOOL running = [self.lastState[@"state"] isEqualToString:@"running"];
    if (!running && (now - self.shownAt) * 1000 > ttl) {
        // 完成/失败：淡出回到「待命」而不是彻底消失，保证始终可判 HUD 存在。
        for (DSHHUDView *h in self.huds) {
            [UIView animateWithDuration:0.25 animations:^{ h.alpha = 0.62; }];
            h.titleLabel.text = @"DSH 就绪";
            h.detailLabel.text = @"等待任务 · 桥已连接";
            [h applyState:@"idle" idle:YES];
            [h setProgress:0.0];
        }
        self.idleMode = YES;
        self.lastState = nil;
        [self writeAck:@"idle"];
        return;
    }
    [self updateMeta];
}

- (void)updateMeta {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (self.idleMode || !self.lastState) {
        for (DSHHUDView *h in self.huds) h.metaLabel.text = @"待命";
        return;
    }
    NSInteger step = [self.lastState[@"step"] respondsToSelector:@selector(integerValue)] ? [self.lastState[@"step"] integerValue] : 0;
    NSInteger total = [self.lastState[@"total"] respondsToSelector:@selector(integerValue)] ? [self.lastState[@"total"] integerValue] : 0;
    NSInteger elapsed = [self.lastState[@"elapsed_ms"] respondsToSelector:@selector(integerValue)] ? [self.lastState[@"elapsed_ms"] integerValue] : 0;
    NSTimeInterval ts = [self.lastState[@"ts"] respondsToSelector:@selector(doubleValue)] ? [self.lastState[@"ts"] doubleValue] / 1000.0 : self.shownAt;
    NSInteger live = elapsed + (NSInteger)MAX(0, (now - ts) * 1000);
    NSString *stepText = total > 0 ? [NSString stringWithFormat:@"%ld/%ld", (long)step, (long)total] : @"";
    NSString *secs = [NSString stringWithFormat:@"%.1fs", live / 1000.0];
    NSString *m = stepText.length ? [NSString stringWithFormat:@"%@ · %@", stepText, secs] : secs;
    for (DSHHUDView *h in self.huds) h.metaLabel.text = m;
}

@end

#pragma mark - 入口

__attribute__((constructor)) static void dsh_hud_ctor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DSHHUD shared] start];
    });
}
