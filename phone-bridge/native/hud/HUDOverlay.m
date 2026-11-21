/*
 * dsh-ios-hud —— SpringBoard 常驻「灵动岛药丸」实时进度（+ios24.10）。
 *
 * bridge（8091）把每个工具调用的状态原子写入
 *   /var/mobile/Library/DSH/hud.json
 * 本 dylib 以 150ms 轮询该文件，把状态画成一颗落在灵动岛位置的纯黑药丸。
 *
 * 为什么要自绘药丸而不是只靠系统 Live Activity：
 *   - iOS 上「内容进灵动岛」只有 ActivityKit Live Activity 一条正路，但它
 *     后台更新必须走 APNs push，而我们是没有推送证书的本地 bridge；App 一
 *     退后台，岛就冻结在最后状态。
 *   - 本 dylib 注入在 SpringBoard 进程，150ms 直接读文件刷新，不依赖 App
 *     前后台、不依赖推送、不依赖签名 entitlement —— 是「操控手机时始终能
 *     在岛上看到实时进度」唯一可控的通道。
 *   - 与用户已开启的灵动岛插件并存：默认把药丸画在岛位置（可用 hud.json
 *     的 pill_y / pill_w / pill_h 覆盖微调）。
 *
 * +ios24.8 修的「完全不可见」三根因继续保留：
 *   1) 启动即画低亮度待命药丸，不再等事件才显示；
 *   2) windowLevel 默认 1e6（hud.json.level 可覆盖），盖过普通窗口；
 *   3) 遍历所有 connectedScenes 建窗，无 scene 时用 mainScreen 兜底。
 *
 * 形态（+ios24.10）：
 *   - 紧凑态：纯黑胶囊（约 168×36，圆角=高/2），落在顶部中央岛位置，
 *     显示状态点 + verb 人话动作（看屏幕 / 点按 / 输入中 / 等待你操作…）
 *     + 第 n/N 步，底部一条细进度线。
 *   - 展开态：state=paused / handoff 非空时展开为宽卡（约 300×72），
 *     多显示一行 detail / 交还原因，配合原生 App 的确认卡。
 *   - 待命态：灰色小胶囊「DSH 待命」，常驻不淡出。
 *
 * 设计约束：不注册 MCP、不开端口、只读一个文件；hitTest 恒 nil 不拦触摸；
 * 写回 hud.ack.json 供 `dsh-phone-bridge-ctl hud` 自检（含药丸几何与阶段）。
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
@property (nonatomic, strong) UILabel *verbLabel;   // 人话动作（主文案）
@property (nonatomic, strong) UILabel *metaLabel;   // 第 n/N 步 · 耗时
@property (nonatomic, strong) UILabel *detailLabel; // 展开态明细
@property (nonatomic, strong) UIView *progressTrack;
@property (nonatomic, strong) UIView *progressBar;
@property (nonatomic, assign) CGFloat progress;
@property (nonatomic, assign) BOOL expanded;
@property (nonatomic, strong) NSTimer *pulseTimer;
@property (nonatomic, assign) CGFloat pulsePhase;
@end

@implementation DSHHUDView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    // 纯黑药丸，贴合灵动岛质感。
    self.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.97];
    self.layer.cornerRadius = frame.size.height / 2.0;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 0.5;
    self.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.08].CGColor;
    self.userInteractionEnabled = NO;

    _dot = [[UIView alloc] initWithFrame:CGRectMake(15, 0, 8, 8)];
    _dot.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    _dot.layer.cornerRadius = 4;
    [self addSubview:_dot];

    _verbLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _verbLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    _verbLabel.textColor = [UIColor whiteColor];
    _verbLabel.text = @"DSH 待命";
    _verbLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    [self addSubview:_verbLabel];

    _metaLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _metaLabel.font = [UIFont monospacedDigitSystemFontOfSize:10.5 weight:UIFontWeightMedium];
    _metaLabel.textColor = [UIColor colorWithWhite:0.62 alpha:1.0];
    _metaLabel.textAlignment = NSTextAlignmentRight;
    [self addSubview:_metaLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.font = [UIFont systemFontOfSize:10.5 weight:UIFontWeightRegular];
    _detailLabel.textColor = [UIColor colorWithWhite:0.72 alpha:1.0];
    _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _detailLabel.hidden = YES;
    [self addSubview:_detailLabel];

    _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    _progressTrack.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.12];
    _progressTrack.layer.cornerRadius = 1;
    [self addSubview:_progressTrack];
    _progressBar = [[UIView alloc] initWithFrame:CGRectZero];
    _progressBar.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
    _progressBar.layer.cornerRadius = 1;
    [_progressTrack addSubview:_progressBar];

    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = CGRectGetHeight(self.bounds);
    CGFloat w = CGRectGetWidth(self.bounds);
    self.layer.cornerRadius = h / 2.0;

    CGFloat dotX = 15;
    CGFloat left = dotX + 8 + 8;             // 点右侧
    CGFloat metaW = 66;
    if (self.expanded) {
        // 展开态：verb 独占第一行，detail 第二行，meta 右上，进度条底部。
        self.dot.center = CGPointMake(dotX + 4, 20);
        self.verbLabel.frame = CGRectMake(left, 10, w - left - 12, 18);
        self.metaLabel.frame = CGRectMake(w - metaW - 14, 12, metaW, 16);
        self.detailLabel.hidden = NO;
        self.detailLabel.frame = CGRectMake(left, 36, w - left - 14, 16);
        self.progressTrack.frame = CGRectMake(16, h - 6, w - 32, 2);
    } else {
        // 紧凑态：单行 verb + 右侧 meta，进度条贴底。
        self.dot.center = CGPointMake(dotX + 4, h / 2.0);
        self.verbLabel.frame = CGRectMake(left, (h - 18) / 2.0 - 1, w - left - metaW - 8, 18);
        self.metaLabel.frame = CGRectMake(w - metaW - 14, (h - 16) / 2.0, metaW, 16);
        self.detailLabel.hidden = YES;
        self.progressTrack.frame = CGRectMake(28, h - 4, w - 56, 2);
    }
    [self setProgress:self.progress];
}

- (void)setExpanded:(BOOL)e {
    if (_expanded == e) return;
    _expanded = e;
    [self setNeedsLayout];
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
    if (idle) {
        [self stopPulse];
        self.dot.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    } else if ([state isEqualToString:@"running"] || [state isEqualToString:@"thinking"]) {
        self.dot.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
        [self startPulse];
    } else if ([state isEqualToString:@"paused"]) {
        [self stopPulse];
        self.dot.backgroundColor = [UIColor colorWithRed:0.88 green:0.65 blue:0.23 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithRed:0.88 green:0.65 blue:0.23 alpha:1.0];
    } else if ([state isEqualToString:@"error"] || [state isEqualToString:@"failed"]) {
        [self stopPulse];
        self.dot.backgroundColor = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithRed:1.0 green:0.27 blue:0.23 alpha:1.0];
    } else {
        [self stopPulse];
        self.dot.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
        self.progressBar.backgroundColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
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
// 药丸几何（hud.json 可覆盖）
@property (nonatomic, assign) CGFloat pillY;      // 顶部 Y（默认贴 status bar）
@property (nonatomic, assign) CGFloat pillW;      // 紧凑宽度
@property (nonatomic, assign) CGFloat pillH;      // 紧凑高度
@property (nonatomic, assign) CGFloat pillExpandW;
@property (nonatomic, assign) CGFloat pillExpandH;
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
    a[@"shape"] = @"pill";
    a[@"pill"] = @{ @"y": @(self.pillY), @"w": @(self.pillW), @"h": @(self.pillH),
                    @"expand_w": @(self.pillExpandW), @"expand_h": @(self.pillExpandH) };
    a[@"ts"] = @([NSDate date].timeIntervalSince1970 * 1000.0);
    NSData *d = [NSJSONSerialization dataWithJSONObject:a options:0 error:nil];
    if (d) [d writeToFile:kDSHHUDAckPath atomically:YES];
}

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
    // 灵动岛药丸落在状态栏内（刘海中央），不是刘海下方。
    CGFloat inset = 0;
    if (@available(iOS 11.0, *)) {
        UIWindow *w = self.windows.firstObject;
        if (w) inset = w.safeAreaInsets.top;
    }
    if (inset <= 0) inset = [UIApplication sharedApplication].statusBarFrame.size.height;
    if (inset <= 0) inset = 44;
    // 药丸中心大致落在状态栏中线：y = (inset - 高度)/2，最小 6。
    CGFloat y = (inset - self.pillH) / 2.0;
    return MAX(6, y);
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

    DSHHUDView *hud = [[DSHHUDView alloc] initWithFrame:CGRectMake(0, 0, self.pillW, self.pillH)];
    hud.alpha = 0.72;   // 待命低亮度，启动即肉眼可见
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
    self.pillY = 0;      // 0 = 用 topInset 自动计算
    self.pillW = 168;
    self.pillH = 36;
    self.pillExpandW = 300;
    self.pillExpandH = 72;
    self.idleMode = YES;

    NSArray *scenes = [self allScenes];
    if (scenes.count == 0) {
        [self makeWindowForScene:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachLateScenes];
        });
    } else {
        for (UIWindowScene *s in scenes) [self makeWindowForScene:s];
    }

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
    NSLog(@"[dsh-hud] started windows=%lu level=%.0f pill", (unsigned long)self.windows.count, self.level);
}

- (void)attachLateScenes {
    NSArray *scenes = [self allScenes];
    if (scenes.count == 0) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self attachLateScenes];
        });
        return;
    }
    for (UIWindowScene *s in scenes) [self makeWindowForScene:s];
    for (DSHHUDView *h in self.huds) {
        [h applyState:self.lastState[@"state"] ?: @"idle" idle:self.idleMode];
        h.alpha = self.idleMode ? 0.72 : 1.0;
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
    NSString *verb = [json[@"verb"] isKindOfClass:[NSString class]] ? json[@"verb"] : @"";
    NSString *handoff = [json[@"handoff"] isKindOfClass:[NSString class]] ? json[@"handoff"] : @"";
    BOOL paused = [json[@"paused"] isKindOfClass:[NSNumber class]] ? [json[@"paused"] boolValue] : NO;
    NSInteger step = [json[@"step"] respondsToSelector:@selector(integerValue)] ? [json[@"step"] integerValue] : 0;
    NSInteger total = [json[@"total"] respondsToSelector:@selector(integerValue)] ? [json[@"total"] integerValue] : 0;
    BOOL idle = [state isEqualToString:@"idle"] || [state isEqualToString:@"ready"];

    // windowLevel 与药丸几何可由 bridge 动态覆盖。
    id lv = json[@"level"];
    if ([lv respondsToSelector:@selector(doubleValue)] && [lv doubleValue] > 0) {
        CGFloat newLevel = (CGFloat)[lv doubleValue];
        if (newLevel != self.level) {
            self.level = newLevel;
            for (UIWindow *w in self.windows) w.windowLevel = newLevel;
        }
    }
    id py = json[@"pill_y"];
    if ([py respondsToSelector:@selector(doubleValue)] && [py doubleValue] > 0) self.pillY = (CGFloat)[py doubleValue];
    id pw = json[@"pill_w"];
    if ([pw respondsToSelector:@selector(doubleValue)] && [pw doubleValue] >= 120) self.pillW = (CGFloat)[pw doubleValue];
    id ph = json[@"pill_h"];
    if ([ph respondsToSelector:@selector(doubleValue)] && [ph doubleValue] >= 28) self.pillH = (CGFloat)[ph doubleValue];

    self.lastState = json;
    self.idleMode = idle;
    self.shownAt = [NSDate date].timeIntervalSince1970;
    self.lastApplyAt = self.shownAt;

    BOOL expand = paused || handoff.length > 0;
    for (DSHHUDView *hud in self.huds) {
        hud.verbLabel.text = idle ? @"DSH 待命" : (verb.length ? verb : @"执行中");
        hud.detailLabel.text = handoff.length ? [@"需要你：" stringByAppendingString:handoff] : detail;
        [hud setExpanded:expand];
        [hud applyState:state idle:idle];
        if (total > 0) [hud setProgress:(CGFloat)step / (CGFloat)total];
        else if (!idle && ![state isEqualToString:@"running"]) [hud setProgress:1.0];
        else [hud setProgress:idle ? 0.0 : 0.15];
        hud.alpha = idle ? 0.72 : 1.0;
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
        CGFloat top = self.pillY > 0 ? self.pillY : [self topInsetForWidth:screenW];
        CGFloat width = hud.expanded ? self.pillExpandW : self.pillW;
        CGFloat height = hud.expanded ? self.pillExpandH : self.pillH;
        width = MIN(width, screenW - 24);
        CGFloat x = (screenW - width) * 0.5;
        hud.frame = CGRectMake(x, top, width, height);
        [hud setNeedsLayout];
    }
}

- (void)tick {
    if (!self.lastState) { [self updateMeta]; return; }
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSInteger ttl = [self.lastState[@"ttl_ms"] respondsToSelector:@selector(integerValue)]
        ? [self.lastState[@"ttl_ms"] integerValue] : 3000;
    if (self.idleMode) { [self updateMeta]; return; }
    BOOL running = [self.lastState[@"state"] isEqualToString:@"running"];
    BOOL paused = [self.lastState[@"paused"] isKindOfClass:[NSNumber class]] ? [self.lastState[@"paused"] boolValue] : NO;
    if (running || paused) { [self updateMeta]; return; }  // 执行/暂停中常驻
    if ((now - self.shownAt) * 1000 > ttl) {
        for (DSHHUDView *h in self.huds) {
            [UIView animateWithDuration:0.25 animations:^{ h.alpha = 0.72; }];
            h.verbLabel.text = @"DSH 待命";
            h.detailLabel.text = @"";
            [h setExpanded:NO];
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
    if (self.idleMode || !self.lastState) {
        for (DSHHUDView *h in self.huds) h.metaLabel.text = @"待命";
        return;
    }
    NSInteger step = [self.lastState[@"step"] respondsToSelector:@selector(integerValue)] ? [self.lastState[@"step"] integerValue] : 0;
    NSInteger total = [self.lastState[@"total"] respondsToSelector:@selector(integerValue)] ? [self.lastState[@"total"] integerValue] : 0;
    NSString *stepText = total > 0 ? [NSString stringWithFormat:@"%ld/%ld", (long)step, (long)total] : @"";
    for (DSHHUDView *h in self.huds) h.metaLabel.text = stepText.length ? stepText : @"··";
}
@end

#pragma mark - 入口

__attribute__((constructor)) static void dsh_hud_ctor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DSHHUD shared] start];
    });
}
