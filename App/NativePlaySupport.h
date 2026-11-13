// Small host controls for a self-contained local runtime. No account credentials or external services.
#import <WebKit/WebKit.h>

@interface RPSBattlePanel : UIViewController <WKScriptMessageHandler,WKNavigationDelegate>
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,copy) NSString *storage;
@property(nonatomic,weak) UIWindow *previousKey;
@property(nonatomic,strong) NSMutableDictionary *diagnostics;
@end
@implementation RPSBattlePanel
- (void)loadView {
    self.diagnostics=[NSMutableDictionary new];
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    [config.userContentController addScriptMessageHandler:self name:@"training"];
    self.web=[[WKWebView alloc] initWithFrame:CGRectZero configuration:config];self.web.navigationDelegate=self;
    self.web.opaque=NO;self.web.backgroundColor=[UIColor colorWithRed:0.063 green:0.098 blue:0.137 alpha:1];
    self.view=self.web;self.title=@"木桩训练场";
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"返回游戏" style:UIBarButtonItemStyleDone target:self action:@selector(closePanel)];
    NSURL *file=[NSURL fileURLWithPath:[self.storage.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"battle-training.html"]];
    self.diagnostics[@"fileExists"]=@([NSFileManager.defaultManager fileExistsAtPath:file.path]);
    self.diagnostics[@"expectedPath"]=file.path;
    [self.web loadFileURL:file allowingReadAccessToURL:file];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    for(UIWindow *window in self.view.window.windowScene.windows)if(window.isKeyWindow && window!=self.view.window)self.previousKey=window;
    [self.view.window makeKeyWindow];
}
- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];[self.previousKey makeKeyWindow];
    [self.web.configuration.userContentController removeScriptMessageHandlerForName:@"training"];
}
- (void)closePanel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)action decisionHandler:(void (^)(WKNavigationActionPolicy))decision {
    NSURL *expected=[NSURL fileURLWithPath:[self.storage.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"battle-training.html"]];
    NSURL *actual=action.request.URL;
    BOOL allowed=actual.isFileURL && [actual.URLByResolvingSymlinksInPath.path isEqual:expected.URLByResolvingSymlinksInPath.path];
    self.diagnostics[@"navigationAllowed"]=@(allowed);
    self.diagnostics[@"navigationPath"]=actual.isFileURL?(actual.path?:@""):@"non-file";
    decision(allowed?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { self.diagnostics[@"finished"]=@YES; }
- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    self.diagnostics[@"loadError"]=@(error.code);
}
- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error {
    self.diagnostics[@"loadError"]=@(error.code);
}
- (void)respond:(NSNumber *)identifier result:(NSDictionary *)result {
    NSData *json=[NSJSONSerialization dataWithJSONObject:@{@"id":identifier,@"payload":result} options:0 error:nil];
    if(!json)return;
    NSString *script=[@"window.trainingReply(" stringByAppendingString:[[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
    [self.web evaluateJavaScript:[script stringByAppendingString:@");"] completionHandler:nil];
}
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    if(!message.frameInfo.isMainFrame || ![message.body isKindOfClass:NSDictionary.class])return;
    NSDictionary *body=message.body;NSNumber *identifier=body[@"id"];NSString *action=body[@"action"];
    if(![identifier isKindOfClass:NSNumber.class] || ![action isKindOfClass:NSString.class])return;
    if([action isEqual:@"close"]){[self respond:identifier result:@{@"retcode":@0}];[self closePanel];return;}
    NSSet *allowed=[NSSet setWithArray:@[@"status",@"dpsStart",@"dpsStop",@"dpsAgain",@"bossSpawn",@"bossClear",@"bossAgain",@"restoreHp",@"fillEnergy",@"arenaEnter",@"arenaExit",@"hudToggle"]];
    if(![allowed containsObject:action])return;
    NSString *token=[NSString stringWithContentsOfFile:[self.storage stringByAppendingPathComponent:@"server/local-maintenance.token"] encoding:NSUTF8StringEncoding error:nil];
    if(!token.length){[self respond:identifier result:@{@"retcode":@-1,@"message":@"本机服务还在准备，请稍候。"}];return;}
    BOOL status=[action isEqual:@"status"];
    NSURL *url=[NSURL URLWithString:status?@"http://127.0.0.1:8088/local/manage/training":@"http://127.0.0.1:8088/local/manage/training-action"];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];request.HTTPMethod=status?@"GET":@"POST";request.timeoutInterval=6;
    [request setValue:token forHTTPHeaderField:@"X-Local-Maintenance"];
    if(!status){
        NSDictionary *args=[body[@"args"] isKindOfClass:NSDictionary.class]?body[@"args"]:@{};
        request.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"action":action,@"args":args} options:0 error:nil];
        if(!request.HTTPBody || request.HTTPBody.length>4096)return;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    }
    __weak RPSBattlePanel *weakSelf=self;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        id value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        NSDictionary *result=(!error && [value isKindOfClass:NSDictionary.class])?value:@{@"retcode":@-1,@"message":@"本机服务暂未响应，请等待世界恢复。"};
        dispatch_async(dispatch_get_main_queue(), ^{[weakSelf respond:identifier result:result];});
    }] resume];
}
@end

@interface RPSOverlayWindow : UIWindow
@end
@implementation RPSOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self.rootViewController.view ? nil : hit;
}
@end

@interface RPSPlaySupport : UIViewController
@property(nonatomic,strong) RPSOverlayWindow *overlay;
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) UILabel *message;
@property(nonatomic,strong) NSDictionary *service;
@property(nonatomic,strong) NSDate *began;
@property(nonatomic,strong) NSDate *readyAt;
@property(nonatomic,strong) NSDate *lastResponse;
@property(nonatomic,copy) NSString *storage;
@property(nonatomic) BOOL fetching;
@property(nonatomic) BOOL saving;
@property(nonatomic) NSInteger ticks;
+ (instancetype)shared;
- (void)start:(NSString *)storage;
@end

@implementation RPSPlaySupport
+ (instancetype)shared { static id value; static dispatch_once_t once; dispatch_once(&once, ^{ value=[self new]; }); return value; }
- (void)loadView {
    self.view=[UIView new]; self.view.backgroundColor=UIColor.clearColor;
    self.button=[UIButton buttonWithType:UIButtonTypeSystem];
    self.button.translatesAutoresizingMaskIntoConstraints=NO;
    self.button.backgroundColor=[UIColor colorWithWhite:0.08 alpha:0.85];
    self.button.layer.cornerRadius=15; self.button.tintColor=UIColor.whiteColor;
    self.button.titleLabel.font=[UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    self.button.accessibilityIdentifier=@"local-play-status";
    [self.button addTarget:self action:@selector(showStatus) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.button];
    self.message=[UILabel new]; self.message.translatesAutoresizingMaskIntoConstraints=NO;
    self.message.numberOfLines=0; self.message.textAlignment=NSTextAlignmentCenter;
    self.message.font=[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    self.message.adjustsFontForContentSizeCategory=YES;
    self.message.textColor=UIColor.whiteColor; self.message.backgroundColor=[UIColor colorWithWhite:0.08 alpha:0.85];
    self.message.layer.cornerRadius=10; self.message.clipsToBounds=YES;
    [self.view addSubview:self.message];
    UILayoutGuide *safe=self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.button.topAnchor constraintEqualToAnchor:safe.topAnchor constant:6],
        [self.button.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.button.widthAnchor constraintEqualToConstant:94], [self.button.heightAnchor constraintEqualToConstant:32],
        [self.message.topAnchor constraintEqualToAnchor:self.button.bottomAnchor constant:5],
        [self.message.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [self.message.leadingAnchor constraintGreaterThanOrEqualToAnchor:safe.leadingAnchor constant:12],
        [self.message.trailingAnchor constraintLessThanOrEqualToAnchor:safe.trailingAnchor constant:-12],
        [self.message.widthAnchor constraintLessThanOrEqualToConstant:390]
    ]];
}
- (void)start:(NSString *)storage {
    if(self.storage) return;
    self.storage=storage; self.began=NSDate.date;
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer){ [self update]; }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification){
            if(!self.readyAt || self.saving) return;
            __block UIBackgroundTaskIdentifier task=UIBackgroundTaskInvalid;
            task=[UIApplication.sharedApplication beginBackgroundTaskWithName:@"保存本机进度" expirationHandler:^{
                if(task!=UIBackgroundTaskInvalid){ [UIApplication.sharedApplication endBackgroundTask:task];task=UIBackgroundTaskInvalid; }
            }];
            [self request:@"save" completion:^(NSDictionary *result){
                if(task!=UIBackgroundTaskInvalid){ [UIApplication.sharedApplication endBackgroundTask:task];task=UIBackgroundTaskInvalid; }
            }];
        }];
    [self update];
}
- (void)attach {
    if(UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if(![scene isKindOfClass:UIWindowScene.class] || scene.activationState!=UISceneActivationStateForegroundActive) continue;
        if(self.overlay.windowScene==(UIWindowScene *)scene) return;
        self.overlay.hidden=YES;
        self.overlay=[[RPSOverlayWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
        self.overlay.windowLevel=UIWindowLevelAlert-1;
        self.overlay.backgroundColor=UIColor.clearColor; self.overlay.rootViewController=self;
        self.overlay.hidden=NO; return;
    }
}
- (void)update {
    [self attach]; if(!self.overlay || UIApplication.sharedApplication.applicationState!=UIApplicationStateActive) return;
    NSDictionary *host=RPHostSnapshot();
    BOOL failed=[host[@"phase"] isEqual:@"failed"];
    BOOL healthy=self.lastResponse && -self.lastResponse.timeIntervalSinceNow<20 && [self.service[@"ready"] boolValue];
    NSDictionary *dps=[self.service[@"dps"] isKindOfClass:NSDictionary.class]?self.service[@"dps"]:nil;
    BOOL testing=healthy && [dps[@"active"] boolValue];
    NSInteger elapsed=(NSInteger)-self.began.timeIntervalSinceNow;
    NSString *title=healthy ? @"本机 · 就绪" : failed ? @"本机 · 异常" : @"本机 · 准备中";
    [self.button setTitle:title forState:UIControlStateNormal];
    if(healthy && !self.readyAt) self.readyAt=NSDate.date;
    if(healthy) self.message.text=@"  服务已就绪，可以登录或点击进入。  \n  若仍有旧的网络提示，请点一次重试。  ";
    else if(failed) self.message.text=@"  本机服务启动失败。点上方按钮查看状态。  ";
    else if(self.readyAt) self.message.text=@"  正在检查本机服务，请稍候。  ";
    else self.message.text=[NSString stringWithFormat:@"  正在准备世界 · 已用 %ld:%02ld  \n  请保持游戏在前台，等显示就绪再登录。  ",(long)elapsed/60,(long)elapsed%60];
    self.message.hidden=healthy && -self.readyAt.timeIntervalSinceNow>10;
    if(testing && ![self.service[@"hideDpsHud"] boolValue]){
        self.message.hidden=NO;
        self.message.text=[NSString stringWithFormat:@"  木桩 · 剩余 %@ 秒 · %@ 次命中  \n  总伤害 %.0f · 平均 DPS %.0f  ",
                dps[@"remainingSeconds"]?:@0,dps[@"hitCount"]?:@0,[dps[@"totalDamage"] doubleValue],[dps[@"averageDps"] doubleValue]];
        if(-self.lastResponse.timeIntervalSinceNow>3) self.message.text=@"  木桩统计正在同步…  ";
    }
    if((++self.ticks%5==0 || testing) && !self.fetching) [self request:@"status" completion:^(NSDictionary *result){}];
}
- (void)request:(NSString *)operation completion:(void (^)(NSDictionary *))completion {
    BOOL status=[operation isEqualToString:@"status"];
    if(status) self.fetching=YES; else self.saving=YES;
    NSString *token=[NSString stringWithContentsOfFile:[self.storage stringByAppendingPathComponent:@"server/local-maintenance.token"] encoding:NSUTF8StringEncoding error:nil];
    if(!token.length){ self.fetching=NO; self.saving=NO; completion(nil);return; }
    NSURL *url=[NSURL URLWithString:[@"http://127.0.0.1:8088/local/manage/" stringByAppendingString:operation]];
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod=status?@"GET":@"POST"; request.timeoutInterval=status?3:48;
    [request setValue:token forHTTPHeaderField:@"X-Local-Maintenance"];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){
        id object=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
        NSDictionary *result=(!error && [(NSHTTPURLResponse *)response statusCode]==200 && [object isKindOfClass:NSDictionary.class] && [object[@"retcode"] isEqual:@0])?object:nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if(status) self.fetching=NO; else self.saving=NO;
            if(result){ self.service=result;self.lastResponse=NSDate.date; }
            completion(result);
        });
    }] resume];
}
- (NSString *)localDate:(NSString *)value {
    if(!value.length) return @"尚未记录";
    NSISO8601DateFormatter *parser=[NSISO8601DateFormatter new];
    parser.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
    NSDate *date=[parser dateFromString:value];
    if(!date){parser.formatOptions=NSISO8601DateFormatWithInternetDateTime;date=[parser dateFromString:value];}
    if(!date) return value;
    NSDateFormatter *format=[NSDateFormatter new];format.dateStyle=NSDateFormatterShortStyle;format.timeStyle=NSDateFormatterMediumStyle;
    return [format stringFromDate:date];
}
- (NSString *)expiry {
    NSData *data=[NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"embedded.mobileprovision"]];
    if(!data) return @"以 SideStore 的剩余天数为准";
    NSString *raw=[[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    NSRange start=[raw rangeOfString:@"<?xml"],end=[raw rangeOfString:@"</plist>"];
    if(start.location==NSNotFound||end.location==NSNotFound||end.location<start.location) return @"以 SideStore 为准";
    NSData *xml=[[raw substringWithRange:NSMakeRange(start.location,NSMaxRange(end)-start.location)] dataUsingEncoding:NSISOLatin1StringEncoding];
    NSDictionary *profile=[NSPropertyListSerialization propertyListWithData:xml options:0 format:nil error:nil];
    NSDate *date=profile[@"ExpirationDate"];if(![date isKindOfClass:NSDate.class])return @"以 SideStore 为准";
    NSDateFormatter *format=[NSDateFormatter new];format.dateStyle=NSDateFormatterMediumStyle;format.timeStyle=NSDateFormatterShortStyle;
    return [format stringFromDate:date];
}
- (void)message:(NSString *)text {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"本机游玩" message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)save:(BOOL)backup {
    if(self.saving){[self message:@"上一次保存尚未完成，请稍候。"];return;}
    [self request:backup?@"backup":@"save" completion:^(NSDictionary *result){
        if(!result){[self message:@"尚未确认保存完成。请保持前台，稍后重试；不要删除 App。"];return;}
        if(!backup){[self message:@"进度已保存到手机。正常退出时，建议先返回游戏登录页。"];return;}
        NSString *name=result[@"lastBackup"];
        if(![name isKindOfClass:NSString.class] || ![name isEqualToString:name.lastPathComponent] || ![name hasSuffix:@".zip"]){[self message:@"备份文件名无效。"];return;}
        NSURL *url=[NSURL fileURLWithPath:[[self.storage stringByAppendingPathComponent:@"Backups"] stringByAppendingPathComponent:name]];
        if(![NSFileManager.defaultManager fileExistsAtPath:url.path]){[self message:@"备份文件尚未完成。"];return;}
        UIActivityViewController *share=[[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView=self.button;share.popoverPresentationController.sourceRect=self.button.bounds;
        [self presentViewController:share animated:YES completion:nil];
    }];
}
- (void)guide {
    NSURL *file=[NSURL fileURLWithPath:[self.storage.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"手机游玩手册.html"]];
    if(![NSFileManager.defaultManager fileExistsAtPath:file.path]){[self message:@"手册位于“文件 → 我的 iPhone → 原神本机实验”。"];return;}
    UIViewController *page=[UIViewController new];page.title=@"手机游玩手册";
    WKWebView *web=[[WKWebView alloc] initWithFrame:CGRectZero];page.view=web;
    [web loadFileURL:file allowingReadAccessToURL:file];
    page.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:@"完成" style:UIBarButtonItemStyleDone target:self action:@selector(closeGuide)];
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:page];
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)closeGuide { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)showTraining {
    if(self.presentedViewController)return;
    NSString *path=[self.storage.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"battle-training.html"];
    if(![NSFileManager.defaultManager fileExistsAtPath:path]){[self message:@"训练台正在准备，请等本机服务就绪后再打开。"];return;}
    RPSBattlePanel *panel=[RPSBattlePanel new];panel.storage=self.storage;
    UINavigationController *navigation=[[UINavigationController alloc] initWithRootViewController:panel];
    navigation.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    navigation.modalPresentationStyle=UIModalPresentationFullScreen;
    [self presentViewController:navigation animated:YES completion:nil];
}
- (void)performMenuAction:(NSInteger)choice {
    void (^run)(void)=^{
        switch(choice){
            case 0: [self showTraining];break;
            case 1: [self save:NO];break;
            case 2: [self save:YES];break;
            case 3: [self guide];break;
        }
    };
    // Present only after the alert is gone, so UIKit never drops the next panel.
    if([self.presentedViewController isKindOfClass:UIAlertController.class])
        [self dismissViewControllerAnimated:YES completion:run];
    else if(!self.presentedViewController)run();
}
- (void)showStatus {
    if(self.presentedViewController) return;
    NSString *state=self.lastResponse && -self.lastResponse.timeIntervalSinceNow<20?@"本机服务已响应":@"尚未就绪，请保持前台等待";
    NSString *text=[NSString stringWithFormat:@"%@\n最近保存：%@\n签名到期：%@",state,[self localDate:self.service[@"fullSaveAt"]],[self expiry]];
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"本机游玩" message:text preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:@"木桩训练场" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self performMenuAction:0];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"保存进度" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self performMenuAction:1];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"备份并导出" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self performMenuAction:2];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"使用手册与命令" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self performMenuAction:3];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"继续游戏" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
@end
