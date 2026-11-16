/*
 * DSHSettingsVC — 设置页。网页工作台从这里进入，不再占主界面。
 * 用 SFSafariViewController（系统 Safari 进程内渲染）而非 WKWebView：
 * rootless 手签 App 的 WKWebView 无法启动 WebContent XPC，SafariServices 可靠。
 */
#import "DSHSettingsVC.h"
#import <SafariServices/SafariServices.h>

static NSString *const kWebURL = @"http://127.0.0.1:3080/?token=dshios-fixed-token-8f3a2c";
static NSString *const kBridge = @"http://127.0.0.1:8091";

@interface DSHSettingsVC () <SFSafariViewControllerDelegate>
@property (nonatomic, strong) NSArray<NSDictionary *> *sections;
@end

@implementation DSHSettingsVC

- (instancetype)init {
    self = [super initWithStyle:UITableViewStyleInsetGrouped];
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.view.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0];
    self.tableView.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0];
    self.sections = @[
        @{ @"title": @"工作台", @"rows": @[
            @{ @"t": @"打开 DSH 网页工作台", @"s": @"对话 · 工作区 · 插件市场", @"a": @"web" },
            @{ @"t": @"桥状态", @"s": @"实时进度与控制链路", @"a": @"status" },
        ]},
        @{ @"title": @"关于", @"rows": @[
            @{ @"t": @"DeepSeek Harness", @"s": @"0.2.2-rc.3 · iPhoneOS arm64", @"a": @"about" },
        ]},
    ];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return self.sections.count; }
- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)sec {
    return [self.sections[sec][@"rows"] count];
}
- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)sec {
    return self.sections[sec][@"title"];
}
- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)ip {
    static NSString *cid = @"dshset";
    UITableViewCell *c = [tv dequeueReusableCellWithIdentifier:cid];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:cid];
    NSDictionary *row = self.sections[ip.section][@"rows"][ip.row];
    c.textLabel.text = row[@"t"];
    c.detailTextLabel.text = row[@"s"];
    c.textLabel.textColor = [UIColor whiteColor];
    c.detailTextLabel.textColor = [UIColor colorWithWhite:0.55 alpha:1.0];
    c.backgroundColor = [UIColor colorWithRed:0.14 green:0.15 blue:0.18 alpha:1.0];
    c.accessoryType = [row[@"a"] isEqualToString:@"web"] ? UITableViewCellAccessoryDisclosureIndicator
                                                         : UITableViewCellAccessoryNone;
    return c;
}
- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [tv deselectRowAtIndexPath:ip animated:YES];
    NSString *a = self.sections[ip.section][@"rows"][ip.row][@"a"];
    if ([a isEqualToString:@"web"]) {
        SFSafariViewController *sf = [[SFSafariViewController alloc]
            initWithURL:[NSURL URLWithString:kWebURL]];
        sf.delegate = self;
        sf.preferredBarTintColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.12 alpha:1.0];
        sf.preferredControlTintColor = [UIColor colorWithRed:0.20 green:0.78 blue:0.62 alpha:1.0];
        [self presentViewController:sf animated:YES completion:nil];
    } else if ([a isEqualToString:@"status"]) {
        [self showStatus];
    }
}

- (void)showStatus {
    NSString *u = [kBridge stringByAppendingString:@"/health"];
    __weak typeof(self) weakSelf = self;
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:u]
      completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSString *msg;
        if (e || !d) msg = @"桥未连接。请确认 dsh-phone-bridge 守护进程已启动。";
        else {
            NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
            msg = [NSString stringWithFormat:@"桥在线\n%@", j[@"progress"] ?: @"实时进度端点就绪"];
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            UIAlertController *ac = [UIAlertController alertControllerWithTitle:@"桥状态"
                message:msg preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
            [weakSelf presentViewController:ac animated:YES completion:nil];
        });
    }] resume];
}

- (void)safariViewControllerDidFinish:(SFSafariViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
}

@end
