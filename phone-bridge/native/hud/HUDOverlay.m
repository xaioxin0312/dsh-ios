/*
 * dsh-ios-hud —— SpringBoard 常驻的「灵动岛」实时进度胶囊。
 *
 * bridge（8091）每次工具调用把状态原子写入
 *   /var/mobile/Library/DSH/hud.json
 * 本 dylib 以 150ms 轮询该文件，在屏幕顶部画一条胶囊：
 *   运行中：脉冲绿点 + 当前动作 + 第 n/N 步 + 实时耗时 + 进度线
 *   完成/失败：短暂停留后淡出
 *
 * 设计约束：
 *   - 不注册 MCP、不开端口，只读一个文件，HUD 挂掉不影响操控链路。
 *   - window 的 hitTest 恒返回 nil，绝不拦截触摸。
 *   - 窗口位于状态栏之上、系统弹窗之下；有灵动岛/刘海时自动贴在其下方。
 */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kDSHHUDPath = @"/var/mobile/Library/DSH/hud.json";

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
    _titleLabel.text = @"DSH 操控中";
    [self addSubview:_titleLabel];

    _detailLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _detailLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightRegular];
    _detailLabel.textColor = [UIColor colorWithWhite:1.0 alpha:0.70];
    _detailLabel.text = @"准备中…";
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

- (void)applyState:(NSString *)state {
    self.running = [state isEqualToString:@"running"];
    if (self.running) {
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
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) DSHHUDView *hud;
@property (nonatomic, strong) NSTimer *pollTimer;
@property (nonatomic, strong) NSTimer *tickTimer;
@property (nonatomic, assign) NSTimeInterval lastMTime;
@property (nonatomic, strong) NSDictionary *lastState;
@property (nonatomic, assign) NSTimeInterval shownAt;
@end

@implementation DSHHUD

+ (instancetype)shared {
    static DSHHUD *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [DSHHUD new]; });
    return s;
}

- (UIWindowScene *)activeScene {
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]] &&
            s.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)s;
        }
    }
    for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
        if ([s isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)s;
    }
    return nil;
}

- (CGFloat)topInset {
    CGFloat inset = 0;
    if (@available(iOS 11.0, *)) inset = self.window.safeAreaInsets.top;
    if (inset <= 0) inset = [UIApplication sharedApplication].statusBarFrame.size.height;
    if (inset <= 0) inset = 44;
    return inset;
}

- (void)start {
    if (self.window) return;
    UIWindowScene *scene = [self activeScene];
    if (!scene) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self start];
        });
        return;
    }
    self.window = [[UIWindow alloc] initWithWindowScene:scene];
    self.window.frame = scene.coordinateSpace.bounds;
    self.window.windowLevel = 2000;
    self.window.backgroundColor = [UIColor clearColor];
    self.window.userInteractionEnabled = NO;
    self.window.rootViewController = [UIViewController new];
    self.window.rootViewController.view.backgroundColor = [UIColor clearColor];
    self.window.rootViewController.view.userInteractionEnabled = NO;
    self.window.hidden = NO;

    self.hud = [[DSHHUDView alloc] initWithFrame:CGRectMake(0, 0, 230, 40)];
    self.hud.alpha = 0.0;
    [self.window addSubview:self.hud];

    __weak typeof(self) weakSelf = self;
    self.pollTimer = [NSTimer scheduledTimerWithTimeInterval:0.15 repeats:YES block:^(NSTimer *t) {
        [weakSelf poll];
    }];
    self.tickTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *t) {
        [weakSelf tick];
    }];
    NSLog(@"[dsh-hud] started (level=%.0f top=%.1f)", self.window.windowLevel, [self topInset]);
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

    self.lastState = json;
    self.shownAt = [NSDate date].timeIntervalSince1970;

    self.hud.titleLabel.text = title;
    self.hud.detailLabel.text = detail.length ? detail : @"…";
    [self.hud applyState:state];
    [self layoutHUD];

    if (total > 0) {
        [self.hud setProgress:(CGFloat)step / (CGFloat)total];
    } else if (!self.hud.running) {
        [self.hud setProgress:1.0];
    } else {
        [self.hud setProgress:0.15];
    }
    [self updateMeta];

    if (self.hud.alpha < 0.99) {
        [UIView animateWithDuration:0.18 animations:^{ self.hud.alpha = 1.0; }];
    }
}

- (void)layoutHUD {
    if (!self.hud) return;
    CGFloat top = [self topInset] + 6;
    NSString *detail = self.hud.detailLabel.text ?: @"";
    UIFont *f = self.hud.detailLabel.font;
    CGFloat textW = [detail sizeWithAttributes:@{NSFontAttributeName: f}].width;
    CGFloat titleW = [self.hud.titleLabel.text sizeWithAttributes:@{NSFontAttributeName: self.hud.titleLabel.font}].width;
    CGFloat width = MAX(196, MIN(310, MAX(textW, titleW) + 32 + 74 + 14));
    CGFloat screenW = self.window.bounds.size.width;
    CGFloat x = (screenW - width) * 0.5;
    self.hud.frame = CGRectMake(x, top, width, 40);
    [self.hud setNeedsLayout];
}

- (void)tick {
    if (!self.lastState) return;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSInteger ttl = [self.lastState[@"ttl_ms"] respondsToSelector:@selector(integerValue)]
        ? [self.lastState[@"ttl_ms"] integerValue] : 3000;
    BOOL running = [self.lastState[@"state"] isEqualToString:@"running"];
    if (!running && (now - self.shownAt) * 1000 > ttl) {
        [UIView animateWithDuration:0.25 animations:^{ self.hud.alpha = 0.0; } completion:^(BOOL finished) {
            self.lastState = nil;
        }];
        return;
    }
    [self updateMeta];
}

- (void)updateMeta {
    if (!self.lastState) return;
    NSInteger step = [self.lastState[@"step"] respondsToSelector:@selector(integerValue)] ? [self.lastState[@"step"] integerValue] : 0;
    NSInteger total = [self.lastState[@"total"] respondsToSelector:@selector(integerValue)] ? [self.lastState[@"total"] integerValue] : 0;
    NSInteger elapsed = [self.lastState[@"elapsed_ms"] respondsToSelector:@selector(integerValue)] ? [self.lastState[@"elapsed_ms"] integerValue] : 0;
    NSTimeInterval ts = [self.lastState[@"ts"] respondsToSelector:@selector(doubleValue)] ? [self.lastState[@"ts"] doubleValue] / 1000.0 : self.shownAt;
    NSInteger live = elapsed + (NSInteger)MAX(0, ([NSDate date].timeIntervalSince1970 - ts) * 1000);
    NSString *stepText = total > 0 ? [NSString stringWithFormat:@"%ld/%ld", (long)step, (long)total] : @"";
    NSString *secs = [NSString stringWithFormat:@"%.1fs", live / 1000.0];
    self.hud.metaLabel.text = stepText.length ? [NSString stringWithFormat:@"%@ · %@", stepText, secs] : secs;
}

@end

#pragma mark - 入口

__attribute__((constructor)) static void dsh_hud_ctor(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DSHHUD shared] start];
    });
}
