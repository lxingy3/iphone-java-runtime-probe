// Small host controls for a self-contained local runtime. No account credentials or external services.
#import <WebKit/WebKit.h>
#import <CoreText/CoreText.h>

static UIFont *RPSTrainingFont(CGFloat size) {
    static NSString *name;static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *url=[NSURL fileURLWithPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"miHoYoSDKAssets.bundle/font/zh-cn.ttf"]];
        if([NSFileManager.defaultManager fileExistsAtPath:url.path]){
            CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url,kCTFontManagerScopeProcess,NULL);
            NSArray *descriptors=CFBridgingRelease(CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url));
            if(descriptors.count)name=CFBridgingRelease(CTFontDescriptorCopyAttribute((__bridge CTFontDescriptorRef)descriptors.firstObject,kCTFontNameAttribute));
        }
    });
    return name?[UIFont fontWithName:name size:size]:[UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
}

@interface RPSTrainingChart : UIView
@property(nonatomic,copy) NSArray *points;
@end
@implementation RPSTrainingChart
- (void)drawRect:(CGRect)rect {
    [[UIColor colorWithWhite:0 alpha:.35] setFill];UIRectFill(rect);
    double max=1,end=1;for(NSDictionary *p in self.points){max=MAX(max,[p[@"dps"] doubleValue]);end=MAX(end,[p[@"seconds"] doubleValue]);}
    CGFloat left=36,top=13,w=MAX(1,rect.size.width-left-8),h=MAX(1,rect.size.height-32);
    NSDictionary *attrs=@{NSFontAttributeName:RPSTrainingFont(9),NSForegroundColorAttributeName:UIColor.whiteColor};
    for(int i=0;i<3;i++){CGFloat y=top+h*i/2;UIBezierPath *grid=[UIBezierPath bezierPath];[grid moveToPoint:CGPointMake(left,y)];[grid addLineToPoint:CGPointMake(left+w,y)];[[UIColor colorWithWhite:1 alpha:.25] setStroke];[grid stroke];[[NSString stringWithFormat:@"%.0fk",max*(1-i/2.)/1000] drawAtPoint:CGPointMake(3,y-5) withAttributes:attrs];}
    UIBezierPath *line=[UIBezierPath bezierPath];BOOL first=YES;for(NSDictionary *p in self.points){CGPoint pt=CGPointMake(left+w*[p[@"seconds"] doubleValue]/end,top+h*(1-[p[@"dps"] doubleValue]/max));if(first)[line moveToPoint:pt];else[line addLineToPoint:pt];first=NO;}
    [[UIColor colorWithRed:1 green:.85 blue:.46 alpha:1] setStroke];line.lineWidth=1.5;[line stroke];
    [@"0" drawAtPoint:CGPointMake(left,top+h+3) withAttributes:attrs];[[NSString stringWithFormat:@"%.0fs",end] drawAtPoint:CGPointMake(left+w-28,top+h+3) withAttributes:attrs];
}
@end

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
@property(nonatomic,strong) UIButton *exitButton;
@property(nonatomic,copy) NSString *initialSection;
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
    [self.view addSubview:self.backdrop];
    [config.userContentController addUserScript:[[WKUserScript alloc] initWithSource:@"document.documentElement.classList.add('native-host')" injectionTime:WKUserScriptInjectionTimeAtDocumentEnd forMainFrameOnly:YES]];
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
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.diagnostics[@"finished"]=@YES;[webView evaluateJavaScript:@"glassLayout()" completionHandler:nil];
    if([self.initialSection isEqual:@"results"])[webView evaluateJavaScript:@"openModal('resultsModal')" completionHandler:nil];
    else if([@[@"target",@"party",@"display",@"supplies",@"timing"] containsObject:self.initialSection]){
        NSString *code=[NSString stringWithFormat:@"openTrainingSection('%@')",self.initialSection];[webView evaluateJavaScript:code completionHandler:nil];
    }
}
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
    if([action isEqual:@"layout"]){return;}
    if([action isEqual:@"close"]){[self respond:identifier result:@{@"retcode":@0}];[self closePanel];return;}
    NSSet *allowed=[NSSet setWithArray:@[@"status",@"dpsStart",@"dpsStop",@"dpsAgain",@"bossSpawn",@"bossClear",@"bossAgain",@"restoreHp",@"fillEnergy",@"arenaEnter",@"arenaExit",@"hudToggle",@"labPrepare",@"labDisplay",@"labStart",@"labStop",@"labAgain",@"labAvatar",@"labResetAvatars",@"partyHeal",@"partyRevive",@"partyEnergy"]];
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
@property(nonatomic,strong) UILabel *trainingDetails;
@property(nonatomic,strong) UILabel *trainingPanel;
@property(nonatomic,strong) RPSTrainingChart *trainingChart;
@property(nonatomic,strong) UIButton *trainingInteraction;
@property(nonatomic,strong) UIButton *trainingReport;
@property(nonatomic) BOOL trainingRequest;
@property(nonatomic,strong) NSDictionary *service;
@property(nonatomic,strong) NSDate *began;
@property(nonatomic,strong) NSDate *readyAt;
@property(nonatomic,strong) NSDate *lastResponse;
@property(nonatomic,copy) NSString *lastResultId;
@property(nonatomic,strong) NSDate *resultReceivedAt;
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
    self.trainingDetails=[UILabel new];self.trainingPanel=[UILabel new];
    for(UILabel *label in @[self.trainingDetails,self.trainingPanel]){label.font=RPSTrainingFont(11);label.numberOfLines=0;label.textColor=UIColor.whiteColor;label.backgroundColor=[UIColor colorWithWhite:0 alpha:.28];label.layer.cornerRadius=8;label.clipsToBounds=YES;label.hidden=YES;[self.view addSubview:label];}
    self.trainingChart=[RPSTrainingChart new];self.trainingChart.userInteractionEnabled=NO;self.trainingChart.hidden=YES;self.trainingChart.layer.cornerRadius=8;self.trainingChart.clipsToBounds=YES;[self.view addSubview:self.trainingChart];
    self.trainingInteraction=[UIButton buttonWithType:UIButtonTypeSystem];self.trainingReport=[UIButton buttonWithType:UIButtonTypeSystem];
    for(UIButton *b in @[self.trainingInteraction,self.trainingReport]){b.backgroundColor=[UIColor colorWithWhite:.08 alpha:.7];b.tintColor=UIColor.whiteColor;b.titleLabel.font=RPSTrainingFont(14);b.layer.cornerRadius=21;b.layer.borderWidth=1;b.layer.borderColor=[UIColor colorWithWhite:1 alpha:.5].CGColor;b.hidden=YES;[self.view addSubview:b];}
    self.trainingInteraction.accessibilityIdentifier=@"training-interaction";self.trainingReport.accessibilityIdentifier=@"training-report";
    [self.trainingInteraction addTarget:self action:@selector(trainingInteract) forControlEvents:UIControlEventTouchUpInside];
    [self.trainingReport setTitle:@"战斗报告" forState:UIControlStateNormal];[self.trainingReport addTarget:self action:@selector(showTrainingReport) forControlEvents:UIControlEventTouchUpInside];
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
    [NSTimer scheduledTimerWithTimeInterval:.5 repeats:YES block:^(NSTimer *timer){ [self update]; }];
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
        if(self.overlay.windowScene==(UIWindowScene *)scene) {
            CGRect bounds=((UIWindowScene *)scene).coordinateSpace.bounds;
            if(!CGRectEqualToRect(self.overlay.frame,bounds)){self.overlay.frame=bounds;[self.view setNeedsLayout];}
            return;
        }
        self.overlay.hidden=YES;
        self.overlay=[[RPSOverlayWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
        self.overlay.frame=((UIWindowScene *)scene).coordinateSpace.bounds;
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
    BOOL lab=healthy && [dps[@"mode"] isEqual:@"lab"];
    NSInteger elapsed=(NSInteger)-self.began.timeIntervalSinceNow;
    NSString *title=healthy ? @"本机 · 就绪" : failed ? @"本机 · 异常" : @"本机 · 准备中";
    if(healthy && [self.service[@"lastError"] length])title=@"本机 · 保存待确认";
    [self.button setTitle:title forState:UIControlStateNormal];
    if(healthy && !self.readyAt) self.readyAt=NSDate.date;
    if(healthy) self.message.text=@"  服务已就绪，可以登录或点击进入。  \n  若仍有旧的网络提示，请点一次重试。  ";
    else if(failed) self.message.text=@"  本机服务启动失败。点上方按钮查看状态。  ";
    else if(self.readyAt) self.message.text=@"  正在检查本机服务，请稍候。  ";
    else self.message.text=[NSString stringWithFormat:@"  正在准备世界 · 已用 %ld:%02ld  \n  请保持游戏在前台，等显示就绪再登录。  ",(long)elapsed/60,(long)elapsed%60];
    self.message.hidden=healthy && -self.readyAt.timeIntervalSinceNow>10;
    if(testing && ![self.service[@"hideDpsHud"] boolValue]){
        self.message.hidden=NO;
        NSString *clock=[dps[@"mode"] isEqual:@"boss"]?[NSString stringWithFormat:@"%@ · %.0f 秒",dps[@"title"]?:@"挑战",[dps[@"elapsedSeconds"] doubleValue]]:[NSString stringWithFormat:@"木桩 · 剩余 %@ 秒",dps[@"remainingSeconds"]?:@0];
        self.message.text=[NSString stringWithFormat:@"  %@ · %@ 次命中  \n  总伤害 %.0f · 平均 DPS %.0f  ",clock,dps[@"hitCount"]?:@0,[dps[@"totalDamage"] doubleValue],[dps[@"averageDps"] doubleValue]];
        if(-self.lastResponse.timeIntervalSinceNow>3 || [self.service[@"statisticsPending"] boolValue]) self.message.text=@"  战斗统计正在同步…  ";
    }
    if(lab && ![self.service[@"hideDpsHud"] boolValue]){
        self.message.hidden=NO;self.message.font=RPSTrainingFont(13);
        NSString *time=[dps[@"phase"] isEqual:@"countdown"]?[NSString stringWithFormat:@"准备 · %@",dps[@"countdown"]?:@3]:[NSString stringWithFormat:@"%.1f 秒",[dps[@"elapsedSeconds"] doubleValue]];
        self.message.text=[NSString stringWithFormat:@"  %@　DPS %.0f  \n  累计 %.0f　最高一击 %.0f  ",time,[dps[@"averageDps"] doubleValue],[dps[@"totalDamage"] doubleValue],[dps[@"maxHit"] doubleValue]];
    }
    [self updateTrainingHUD:healthy?dps:nil];
    NSDictionary *finished=[self.service[@"lastTrainingResult"] isKindOfClass:NSDictionary.class]?self.service[@"lastTrainingResult"]:nil;
    NSString *resultId=finished[@"id"];
    if(resultId.length && ![resultId isEqualToString:self.lastResultId]){
        self.lastResultId=resultId;
        NSISO8601DateFormatter *parser=[NSISO8601DateFormatter new];parser.formatOptions=NSISO8601DateFormatWithInternetDateTime|NSISO8601DateFormatWithFractionalSeconds;
        NSDate *at=[parser dateFromString:finished[@"at"]?:@""];
        if(at && [at compare:self.began]!=NSOrderedAscending)self.resultReceivedAt=NSDate.date;
    }
    if(!testing && healthy && self.resultReceivedAt && -self.resultReceivedAt.timeIntervalSinceNow<12 && ![self.service[@"hideDpsHud"] boolValue]){
        self.message.hidden=NO;
        self.message.text=[NSString stringWithFormat:@"  %@ · %@  \n  总伤害 %.0f · DPS %.0f · 在「成绩」查看占比  ",finished[@"title"]?:@"训练",finished[@"outcome"]?:@"完成",[finished[@"totalDamage"] doubleValue],[finished[@"averageDps"] doubleValue]];
    }
    if((++self.ticks%10==0 || testing || lab || [dps[@"inArena"] boolValue]) && !self.fetching) [self request:@"status" completion:^(NSDictionary *result){}];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];CGRect area=UIEdgeInsetsInsetRect(self.view.bounds,self.view.safeAreaInsets);BOOL wide=area.size.width>area.size.height;
    CGFloat offset=wide?80:118,width=MIN(wide?220:170,area.size.width*.40),left=area.origin.x+10,top=area.origin.y+offset;
    CGFloat height=MIN(90,MAX(60,(area.size.height-offset-22)/3)),next=top;
    self.trainingDetails.frame=CGRectMake(left,next,width,height);if(!self.trainingDetails.hidden)next+=height+5;
    self.trainingChart.frame=CGRectMake(left,next,width,height);if(!self.trainingChart.hidden)next+=height+5;
    self.trainingPanel.frame=CGRectMake(left,next,width,height);self.trainingPanel.font=RPSTrainingFont(height<80?10:11);self.trainingDetails.font=RPSTrainingFont(height<80?10:11);
    self.trainingInteraction.frame=CGRectMake(area.origin.x+area.size.width*.55,area.origin.y+area.size.height*.46,MIN(160,area.size.width*.40),44);
    self.trainingReport.frame=CGRectMake(area.origin.x+area.size.width*.40,CGRectGetMaxY(area)-56,120,44);
}
- (void)updateTrainingHUD:(NSDictionary *)dps {
    NSDictionary *config=dps[@"config"];BOOL exists=[dps[@"mode"] isEqual:@"lab"];
    NSDictionary *station=[dps[@"station"] isKindOfClass:NSDictionary.class]?dps[@"station"]:nil;BOOL nearby=[station[@"label"] length]>0;
    self.trainingInteraction.hidden=!nearby&&(!exists||(![dps[@"canStart"] boolValue]&&![dps[@"active"] boolValue]&&![dps[@"phase"] isEqual:@"finished"]));
    self.trainingInteraction.enabled=!self.trainingRequest;
    NSString *action=nearby?station[@"label"]:([dps[@"phase"] isEqual:@"finished"]?@"再次布置":([dps[@"active"] boolValue]?@"停止计时":@"开始挑战"));[self.trainingInteraction setTitle:action forState:UIControlStateNormal];
    self.trainingReport.hidden=!exists;
    self.trainingChart.hidden=!exists||![config[@"chart"] boolValue];self.trainingChart.points=dps[@"curve"]?:@[];[self.trainingChart setNeedsDisplay];
    self.trainingDetails.hidden=!exists||![config[@"resistanceHud"] boolValue];
    NSArray *keys=@[@"physical",@"fire",@"water",@"ice",@"electric",@"grass",@"wind",@"rock"],*names=@[@"物",@"火",@"水",@"冰",@"雷",@"草",@"风",@"岩"];
    NSMutableString *res=[NSMutableString stringWithFormat:@"  等级 %@ · 防御 %@%%\n",config[@"level"]?:@100,config[@"defense"]?:@100];
    for(NSUInteger i=0;i<keys.count;i++){NSString *value=[config[@"immunities"] containsObject:keys[i]]?@"免疫":[NSString stringWithFormat:@"%@%%",config[@"resistances"][keys[i]]?:@10];[res appendFormat:@"  %@ %@%@",names[i],value,i%2?@"\n":@"　"];}
    self.trainingDetails.text=res;
    NSDictionary *a=dps[@"activePanel"];self.trainingPanel.hidden=!exists||!a;
    if(a)self.trainingPanel.text=[NSString stringWithFormat:@"  %@\n  生命 %.0f　攻击 %.0f\n  防御 %.0f　精通 %.0f\n  暴击 %.1f%%　暴伤 %.1f%%\n  充能 %.1f%%　增伤 %.1f%%",a[@"name"]?:@"",[a[@"hp"] doubleValue],[a[@"attack"] doubleValue],[a[@"defense"] doubleValue],[a[@"mastery"] doubleValue],[a[@"crit"] doubleValue],[a[@"critDamage"] doubleValue],[a[@"recharge"] doubleValue],[a[@"elementBonus"] doubleValue]];
    [self.view setNeedsLayout];
}
- (void)trainingInteract {
    if(self.trainingRequest)return;NSDictionary *dps=self.service[@"dps"];
    NSString *section=dps[@"station"][@"section"];
    if([@[@"target",@"party",@"display",@"supplies",@"timing"] containsObject:section]){
        [self showTraining];UINavigationController *nav=(UINavigationController *)self.presentedViewController;
        if([nav.topViewController isKindOfClass:RPSBattlePanel.class]){RPSBattlePanel *panel=(RPSBattlePanel *)nav.topViewController;panel.initialSection=section;[panel.web evaluateJavaScript:[NSString stringWithFormat:@"typeof openTrainingSection==='function'&&openTrainingSection('%@')",section] completionHandler:nil];}
        return;
    }
    NSString *action=[dps[@"phase"] isEqual:@"finished"]?@"labAgain":([dps[@"active"] boolValue]?@"labStop":@"labStart");
    NSString *token=[NSString stringWithContentsOfFile:[self.storage stringByAppendingPathComponent:@"server/local-maintenance.token"] encoding:NSUTF8StringEncoding error:nil];if(!token.length)return;
    self.trainingRequest=YES;self.trainingInteraction.enabled=NO;
    NSMutableURLRequest *request=[NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:8088/local/manage/training-action"]];request.HTTPMethod=@"POST";request.timeoutInterval=6;[request setValue:token forHTTPHeaderField:@"X-Local-Maintenance"];[request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];request.HTTPBody=[NSJSONSerialization dataWithJSONObject:@{@"action":action,@"args":@{}} options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error){NSDictionary *result=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;dispatch_async(dispatch_get_main_queue(), ^{
        self.trainingRequest=NO;self.trainingInteraction.enabled=YES;if(!error&&[result[@"retcode"] isEqual:@0]){NSMutableDictionary *service=[self.service mutableCopy];service[@"dps"]=result[@"dps"]?:@{};self.service=service;[self update];}else{self.message.hidden=NO;self.message.text=result[@"message"]?:@"操作未完成，请稍后再试。";}
    });}] resume];
}
- (void)showTrainingReport {
    [self showTraining];UINavigationController *nav=(UINavigationController *)self.presentedViewController;
    if([nav.topViewController isKindOfClass:RPSBattlePanel.class]){
        RPSBattlePanel *panel=(RPSBattlePanel *)nav.topViewController;
        panel.initialSection=@"results";
        [panel.web evaluateJavaScript:@"typeof openModal==='function'&&openModal('resultsModal')" completionHandler:nil];
    }
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
    if([self.service[@"lastError"] length])state=@"上次保存未完成";
    NSString *text=[NSString stringWithFormat:@"%@\n最近确认保存：%@\n签名到期：%@",state,[self localDate:self.service[@"fullSaveAt"]],[self expiry]];
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"本机游玩" message:text preferredStyle:UIAlertControllerStyleAlert];
    [menu addAction:[UIAlertAction actionWithTitle:@"木桩训练场" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self performMenuAction:0];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"保存进度" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self performMenuAction:1];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"备份并导出" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self performMenuAction:2];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"使用手册与命令" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a){[self performMenuAction:3];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"继续游戏" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:menu animated:YES completion:nil];
}
@end
