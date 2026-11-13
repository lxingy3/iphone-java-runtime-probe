// Small host controls for a self-contained local runtime. No account credentials or external services.
#import <WebKit/WebKit.h>

@interface RPSLocalArtwork : NSObject <WKURLSchemeHandler>
@property(nonatomic,copy) NSString *documents;
@property(nonatomic,strong) NSMutableDictionary *diagnostics;
@end
@implementation RPSLocalArtwork
- (void)webView:(WKWebView *)webView startURLSchemeTask:(id<WKURLSchemeTask>)task {
    NSURL *url=task.request.URL;
    BOOL font=[url.path isEqual:@"/training-assets/game-font.ttf"];
    if(![url.host isEqual:@"local"]||(!font && ![@[@"/training-assets/courtyard.png",@"/training-assets/portraits.png"] containsObject:url.path])){
        [task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];return;
    }
    // The font stays in the user's existing game bundle; it is not redistributed by the probe.
    NSString *path=font?[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"miHoYoSDKAssets.bundle/font/zh-cn.ttf"]:[self.documents stringByAppendingPathComponent:[url.path substringFromIndex:1]];
    NSData *data=[NSData dataWithContentsOfFile:path];
    if(!data){[task didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorFileDoesNotExist userInfo:nil]];return;}
    [task didReceiveResponse:[[NSURLResponse alloc] initWithURL:url MIMEType:font?@"font/ttf":@"image/png" expectedContentLength:data.length textEncodingName:nil]];
    [task didReceiveData:data];[task didFinish];self.diagnostics[font?@"gameFontLoaded":@"artworkLoaded"]=@YES;
}
- (void)webView:(WKWebView *)webView stopURLSchemeTask:(id<WKURLSchemeTask>)task {}
@end

@interface RPSBattlePanel : UIViewController <WKScriptMessageHandler,WKNavigationDelegate>
@property(nonatomic,strong) WKWebView *web;
@property(nonatomic,copy) NSString *storage;
@property(nonatomic,weak) UIWindow *previousKey;
@property(nonatomic,strong) NSMutableDictionary *diagnostics;
@property(nonatomic,strong) UIImageView *backdrop;
@property(nonatomic,strong) NSMutableArray<UIVisualEffectView *> *glassViews;
@property(nonatomic,copy) NSArray *lastGlassLayout;
@property(nonatomic,strong) UIButton *exitButton;
@end
@implementation RPSBattlePanel
- (void)loadView {
    self.diagnostics=[NSMutableDictionary new];
    WKWebViewConfiguration *config=[WKWebViewConfiguration new];
    RPSLocalArtwork *artwork=[RPSLocalArtwork new];artwork.documents=self.storage.stringByDeletingLastPathComponent;artwork.diagnostics=self.diagnostics;
    [config setURLSchemeHandler:artwork forURLScheme:@"training"];
    [config.userContentController addScriptMessageHandler:self name:@"training"];
    self.view=[UIView new];self.view.backgroundColor=[UIColor colorWithRed:.48 green:.71 blue:.87 alpha:1];
    NSString *documents=self.storage.stringByDeletingLastPathComponent;
    self.backdrop=[[UIImageView alloc] initWithImage:[UIImage imageWithContentsOfFile:[documents stringByAppendingPathComponent:@"training-assets/courtyard.png"]]];
    self.backdrop.contentMode=UIViewContentModeScaleAspectFill;self.backdrop.clipsToBounds=YES;
    self.backdrop.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.backdrop];self.glassViews=[NSMutableArray new];
    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:@"document.documentElement.classList.add('native-glass')" injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
    self.web=[[WKWebView alloc] initWithFrame:CGRectZero configuration:config];self.web.navigationDelegate=self;
    self.web.opaque=NO;self.web.backgroundColor=UIColor.clearColor;self.web.scrollView.backgroundColor=UIColor.clearColor;
    self.web.scrollView.contentInsetAdjustmentBehavior=UIScrollViewContentInsetAdjustmentNever;
    self.web.scrollView.bounces=NO;self.web.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.web];self.title=@"木桩训练场";
    // A native close control remains usable even if the web process fails.
    self.exitButton=[UIButton buttonWithType:UIButtonTypeSystem];self.exitButton.accessibilityLabel=@"返回游戏";
    [self.exitButton setImage:[UIImage systemImageNamed:@"xmark"] forState:UIControlStateNormal];
    self.exitButton.tintColor=[UIColor colorWithWhite:1 alpha:.95];self.exitButton.backgroundColor=[UIColor colorWithWhite:1 alpha:.22];
    self.exitButton.layer.cornerRadius=22;self.exitButton.layer.borderWidth=1;self.exitButton.layer.borderColor=[UIColor colorWithWhite:1 alpha:.6].CGColor;
    [self.exitButton addTarget:self action:@selector(closePanel) forControlEvents:UIControlEventTouchUpInside];[self.view addSubview:self.exitButton];
    NSURL *file=[NSURL fileURLWithPath:[documents stringByAppendingPathComponent:@"battle-training.html"]];
    self.diagnostics[@"fileExists"]=@([NSFileManager.defaultManager fileExistsAtPath:file.path]);
    self.diagnostics[@"expectedPath"]=file.path;
    NSError *error=nil;NSString *html=[NSString stringWithContentsOfURL:file encoding:NSUTF8StringEncoding error:&error];
    if(html.length)[self.web loadHTMLString:html baseURL:[NSURL URLWithString:@"training://local/"]];
    else {self.diagnostics[@"loadError"]=@(error.code);UILabel *label=[UILabel new];label.text=@"训练场未就绪";label.textAlignment=NSTextAlignmentCenter;label.frame=CGRectMake(20,100,300,60);[self.view addSubview:label];}
}
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated];[self.navigationController setNavigationBarHidden:YES animated:NO]; }
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];self.backdrop.frame=self.view.bounds;self.web.frame=self.view.bounds;
    UIEdgeInsets safe=self.view.safeAreaInsets;self.exitButton.frame=CGRectMake(self.view.bounds.size.width-MAX(16,safe.right)-44,MAX(10,safe.top),44,44);
    [self.web evaluateJavaScript:@"typeof glassLayout==='function'&&glassLayout()" completionHandler:nil];
}
- (void)placeGlass:(NSArray *)rects {
    if(![rects isKindOfClass:NSArray.class]||rects.count>8)return;
    if([self.lastGlassLayout isEqualToArray:rects])return;self.lastGlassLayout=[rects copy];
    for(UIVisualEffectView *glass in self.glassViews)[glass removeFromSuperview];[self.glassViews removeAllObjects];
    for(id value in rects){
        if(![value isKindOfClass:NSDictionary.class])continue;
        NSDictionary *r=value;BOOL valid=YES;for(NSString *key in @[@"x",@"y",@"width",@"height",@"radius"])valid &= [r[key] isKindOfClass:NSNumber.class] && isfinite([r[key] doubleValue]);
        if(!valid)continue;
        CGRect frame=CGRectIntersection(self.view.bounds,CGRectMake([r[@"x"] doubleValue],[r[@"y"] doubleValue],[r[@"width"] doubleValue],[r[@"height"] doubleValue]));
        if(CGRectIsNull(frame)||CGRectIsEmpty(frame))continue;
        UIVisualEffect *effect;
        if(@available(iOS 26.0,*)){UIGlassEffect *glass=[UIGlassEffect effectWithStyle:UIGlassEffectStyleRegular];glass.tintColor=[UIColor colorWithWhite:.97 alpha:.30];effect=glass;}
        else effect=[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialLight];
        UIVisualEffectView *glass=[[UIVisualEffectView alloc] initWithEffect:effect];glass.frame=frame;glass.layer.cornerRadius=MAX(0,MIN(60,[r[@"radius"] doubleValue]));glass.clipsToBounds=YES;glass.userInteractionEnabled=NO;
        [self.view insertSubview:glass belowSubview:self.web];[self.glassViews addObject:glass];
    }
    self.diagnostics[@"glassCount"]=@(self.glassViews.count);
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
    BOOL allowed=[actual.absoluteString isEqual:@"about:blank"] || [actual.absoluteString isEqual:@"training://local/"] || (actual.isFileURL && [actual.URLByResolvingSymlinksInPath.path isEqual:expected.URLByResolvingSymlinksInPath.path]);
    self.diagnostics[@"navigationAllowed"]=@(allowed);
    self.diagnostics[@"navigationPath"]=actual.isFileURL?(actual.path?:@""):@"non-file";
    decision(allowed?WKNavigationActionPolicyAllow:WKNavigationActionPolicyCancel);
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation { self.diagnostics[@"finished"]=@YES;[webView evaluateJavaScript:@"glassLayout()" completionHandler:nil]; }
- (void)webViewWebContentProcessDidTerminate:(WKWebView *)webView { self.diagnostics[@"webProcessTerminated"]=@YES;[self closePanel]; }
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
    if([action isEqual:@"layout"]){if([body[@"args"] isKindOfClass:NSDictionary.class])[self placeGlass:body[@"args"][@"rects"]];return;}
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
