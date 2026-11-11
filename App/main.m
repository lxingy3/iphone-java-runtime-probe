#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <jni.h>
#include <mach/mach.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString * const RuntimeChanged = @"RuntimeChanged";
static NSString *Documents(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}
static void WriteJSON(NSString *name, id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[Documents() stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}

// A process owns its JVM; scene replacement and resizing never initialize another one.
@interface RuntimeSession : NSObject
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL serverMode;
@property(nonatomic) BOOL ready;
@property(nonatomic) NSInteger starts;
@property(nonatomic,copy) NSString *phase;
@property(nonatomic,copy) NSString *status;
@property(nonatomic,copy) NSString *detail;
@property(nonatomic,strong) NSDate *startedAt;
@property(nonatomic,strong) NSTimer *heartbeat;
+ (instancetype)shared;
- (void)startServer:(BOOL)server;
- (void)publish;
@end

@implementation RuntimeSession
+ (instancetype)shared {
    static RuntimeSession *instance; static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [RuntimeSession new]; instance.phase = @"idle"; instance.status = @"等待开始";
        instance.detail = @"先验证运行环境，再测试服务端。\n测试期间请保持此 App 在前台。";
    });
    return instance;
}
- (void)publish {
    NSAssert(NSThread.isMainThread, @"Session updates belong to the main thread");
    struct task_vm_info memory = {0}; mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    BOOL available = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&memory, &count) == KERN_SUCCESS;
    WriteJSON(@"host-status.json", @{
        @"phase": self.phase, @"server_mode": @(self.serverMode), @"http_ready": @(self.ready),
        @"jvm_start_count": @(self.starts), @"pid": @(getpid()),
        @"elapsed_seconds": @(self.startedAt ? -self.startedAt.timeIntervalSinceNow : 0),
        @"footprint_bytes": available ? @(memory.phys_footprint) : NSNull.null,
        @"ios": UIDevice.currentDevice.systemVersion,
        @"foreground": @(UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
    });
    [NSNotificationCenter.defaultCenter postNotificationName:RuntimeChanged object:self];
}
- (void)updatePhase:(NSString *)phase status:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{ self.phase = phase; self.status = status; [self publish]; });
}
- (void)tick {
    [self publish];
    if (!self.serverMode || [self.phase isEqualToString:@"failed"] || self.ready) return;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"http://127.0.0.1:8088/status/server"]];
    request.timeoutInterval = 2;
    [[[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || !data) return;
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class] || ![json[@"retcode"] isEqual:@0]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([self.phase isEqualToString:@"failed"]) return;
            self.ready = YES; self.phase = @"listening"; self.status = @"服务端已响应";
            self.detail = @"本机服务已启动，正在记录内存和运行状态。\n游戏客户端和后台持续运行仍需另行验证。";
            [self publish];
        });
    }] resume];
}
- (void)startServer:(BOOL)server {
    NSAssert(NSThread.isMainThread, @"Start from the main thread");
    if (self.started) return;
    self.started = YES; self.serverMode = server; self.starts++; self.startedAt = NSDate.date;
    self.phase = @"starting_runtime"; self.status = @"正在启动运行环境…";
    self.detail = server ? @"首次准备资源需要一些时间，请保持 App 在前台。" : @"正在检查网络、存储和基础运行能力。";
    self.heartbeat = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self publish];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *documents = Documents();
            NSString *working = server ? [documents stringByAppendingPathComponent:@"server"] : documents;
            if (![NSFileManager.defaultManager createDirectoryAtPath:working withIntermediateDirectories:YES attributes:nil error:nil] ||
                chdir(working.fileSystemRepresentation) != 0) {
                [self updatePhase:@"failed" status:@"无法准备本机存储目录"]; return;
            }
            NSString *bundle = NSBundle.mainBundle.resourcePath;
            NSString *runtimeHome = [bundle stringByAppendingPathComponent:@"runtime"];
            setenv("JAVA_HOME", runtimeHome.fileSystemRepresentation, 1);
            NSString *log = [documents stringByAppendingPathComponent:@"jvm-output.log"];
            freopen(log.fileSystemRepresentation, "a", stdout); freopen(log.fileSystemRepresentation, "a", stderr);
            setvbuf(stdout, NULL, _IOLBF, 0); setvbuf(stderr, NULL, _IOLBF, 0);
            fprintf(stderr, "Runtime: starting JNI_CreateJavaVM, mode=%s\n", server ? "server" : "probe");
            NSArray<NSString *> *arguments = @[
                [@"-Djava.home=" stringByAppendingString:runtimeHome],
                [@"-Djava.class.path=" stringByAppendingString:[bundle stringByAppendingPathComponent:@"DeviceProbe.jar"]],
                [@"-Duser.dir=" stringByAppendingString:working], @"-Djava.awt.headless=true", @"-Xint",
                server ? @"-Xmx2048m" : @"-Xmx256m", @"-Dfile.encoding=UTF-8",
                @"-Dlogback.configurationFile=prototype-logback.xml", @"-Diphone.prototype.verify=true"
            ];
            JavaVMOption options[9] = {0};
            for (NSUInteger i = 0; i < arguments.count; i++) options[i].optionString = strdup(arguments[i].UTF8String);
            JavaVMInitArgs settings = {0}; settings.version = JNI_VERSION_1_8;
            settings.nOptions = (jint)arguments.count; settings.options = options; settings.ignoreUnrecognized = JNI_FALSE;
            JavaVM *vm = NULL; JNIEnv *env = NULL;
            jint result = JNI_CreateJavaVM(&vm, (void **)&env, &settings);
            fprintf(stderr, "Runtime: JNI_CreateJavaVM returned %d\n", result);
            for (NSUInteger i = 0; i < arguments.count; i++) free(options[i].optionString);
            BOOL successful = result == JNI_OK;
            if (successful) {
                jclass cls = (*env)->FindClass(env, "DeviceProbe");
                if (server && cls) {
                    [self updatePhase:@"preparing_payload" status:@"正在准备本机服务资源…"];
                    jmethodID prepare = (*env)->GetStaticMethodID(env, cls, "prepareServer", "(Ljava/lang/String;)V");
                    if (prepare) {
                        jstring source = (*env)->NewStringUTF(env, documents.UTF8String);
                        (*env)->CallStaticVoidMethod(env, cls, prepare, source); (*env)->DeleteLocalRef(env, source);
                    }
                    if (prepare && !(*env)->ExceptionCheck(env)) {
                        [self updatePhase:@"starting_server" status:@"正在载入服务端和存档…"];
                        jmethodID start = (*env)->GetStaticMethodID(env, cls, "startServer", "()V");
                        if (start) (*env)->CallStaticVoidMethod(env, cls, start); else successful = NO;
                    } else successful = NO;
                } else if (cls) {
                    jmethodID run = (*env)->GetStaticMethodID(env, cls, "run", "()V");
                    if (run) (*env)->CallStaticVoidMethod(env, cls, run); else successful = NO;
                } else successful = NO;
                if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); successful = NO; }
                (*vm)->DetachCurrentThread(vm);
            }
            fflush(stdout); fflush(stderr);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!successful) {
                    self.phase = @"failed"; self.status = @"本次测试未完成";
                    self.detail = @"详细原因已保存到运行日志。重新尝试前请关闭并重新打开此 App。";
                } else if (!server) {
                    NSData *data = [NSData dataWithContentsOfFile:[documents stringByAppendingPathComponent:@"runtime-probe.json"]];
                    id report = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                    BOOL passed = [report isKindOfClass:NSDictionary.class] && [report[@"passed"] isEqual:@YES];
                    self.phase = passed ? @"probe_passed" : @"probe_failed";
                    self.status = passed ? @"运行环境检查通过" : @"运行环境检查未通过";
                    self.detail = @"结果已保存。切换测试项目时，请关闭并重新打开此 App。";
                }
                [self publish];
            });
        }
    });
}
@end

@interface ControlsController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *detailLabel;
@property(nonatomic,strong) UIButton *probeButton;
@property(nonatomic,strong) UIButton *serverButton;
@property(nonatomic,copy) NSString *lastGeometry;
@end
@implementation ControlsController
- (UILabel *)label:(NSString *)text style:(UIFontTextStyle)style {
    UILabel *label = [UILabel new]; label.text = text; label.numberOfLines = 0;
    label.font = [UIFont preferredFontForTextStyle:style]; label.adjustsFontForContentSizeCategory = YES; return label;
}
- (UIButton *)button:(NSString *)title action:(SEL)action prominent:(BOOL)prominent {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    UIButtonConfiguration *config = prominent ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.tintedButtonConfiguration;
    config.title = title; config.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    config.contentInsets = NSDirectionalEdgeInsetsMake(14,16,14,16); button.configuration = config;
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:52].active = YES; return button;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
    UIScrollView *scroll = [UIScrollView new]; scroll.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:scroll];
    UILabel *title = [self label:@"本机运行测试" style:UIFontTextStyleLargeTitle];
    UILabel *subtitle = [self label:@"iPhone 运行验证 · 0.2" style:UIFontTextStyleSubheadline]; subtitle.textColor = UIColor.secondaryLabelColor;
    self.statusLabel = [self label:@"" style:UIFontTextStyleTitle2]; self.detailLabel = [self label:@"" style:UIFontTextStyleBody];
    self.probeButton = [self button:@"检查运行环境" action:@selector(runProbe) prominent:NO];
    self.serverButton = [self button:@"测试本机服务端" action:@selector(runServer) prominent:YES];
    UILabel *note = [self label:@"此版本用于验证运行能力，还不是完整游戏。服务端测试需要已传入的本机资源包。" style:UIFontTextStyleFootnote];
    note.textColor = UIColor.secondaryLabelColor;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[title,subtitle,self.statusLabel,self.detailLabel,self.probeButton,self.serverButton,note]];
    content.axis = UILayoutConstraintAxisVertical; content.spacing = 18; content.translatesAutoresizingMaskIntoConstraints = NO; [scroll addSubview:content];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [scroll.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor], [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [content.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
        [content.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
        [content.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
        [content.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:RuntimeChanged object:nil]; [self refresh];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh {
    RuntimeSession *session = RuntimeSession.shared; self.statusLabel.text = session.status; self.detailLabel.text = session.detail;
    self.probeButton.enabled = !session.started; self.serverButton.enabled = !session.started;
}
- (void)runProbe { [RuntimeSession.shared startServer:NO]; }
- (void)runServer { [RuntimeSession.shared startServer:YES]; }
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--probe-auto-run"]) [self runProbe];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews]; if (!self.view.window) return;
    CGRect window = self.view.window.bounds, bounds = self.view.bounds; UIEdgeInsets safe = self.view.safeAreaInsets;
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@",NSStringFromCGRect(window),NSStringFromCGRect(bounds),NSStringFromUIEdgeInsets(safe)];
    if ([signature isEqualToString:self.lastGeometry]) return; self.lastGeometry = signature;
    static NSMutableArray *history; if (!history) history = [NSMutableArray new];
    [history addObject:@{
        @"time": @([NSDate.date timeIntervalSince1970]), @"pid": @(getpid()), @"jvm_start_count": @(RuntimeSession.shared.starts),
        @"window": @[@(window.size.width),@(window.size.height)], @"view": @[@(bounds.size.width),@(bounds.size.height)],
        @"safe_area": @[@(safe.top),@(safe.left),@(safe.bottom),@(safe.right)], @"display_scale": @(self.traitCollection.displayScale)
    }];
    if (history.count > 80) [history removeObjectAtIndex:0]; WriteJSON(@"layout-history.json", history);
}
@end

@interface LogController : UIViewController
@property(nonatomic,strong) UITextView *output;
@end
@implementation LogController
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.output = [UITextView new]; self.output.editable = NO; self.output.selectable = YES;
    self.output.font = [UIFontMetrics.defaultMetrics scaledFontForFont:[UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular]];
    self.output.adjustsFontForContentSizeCategory = YES; self.output.accessibilityLabel = @"测试结果与运行日志";
    self.output.textContainerInset = UIEdgeInsetsMake(20,16,20,16); self.output.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.output]; UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [self.output.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor], [self.output.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [self.output.topAnchor constraintEqualToAnchor:safe.topAnchor], [self.output.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor]
    ]];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(refresh) name:RuntimeChanged object:nil]; [self refresh];
}
- (void)dealloc { [NSNotificationCenter.defaultCenter removeObserver:self]; }
- (void)refresh {
    NSString *name = RuntimeSession.shared.serverMode ? @"jvm-output.log" : @"runtime-probe.json";
    NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:[Documents() stringByAppendingPathComponent:name]]; NSString *text = nil;
    if (file) {
        unsigned long long length = [file seekToEndOfFile]; [file seekToFileOffset:length > 32768 ? length - 32768 : 0];
        text = [[NSString alloc] initWithData:[file readDataToEndOfFile] encoding:NSUTF8StringEncoding]; [file closeFile];
    }
    text = text ?: @"运行后，结果和日志会显示在这里。\n\n调整窗口时，运行中的测试保留在同一进程。";
    if (![text isEqualToString:self.output.text]) { CGPoint position = self.output.contentOffset; self.output.text = text; self.output.contentOffset = position; }
}
@end

@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation SceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    ControlsController *controls = [ControlsController new]; LogController *logs = [LogController new];
    if (@available(iOS 27.1, *)) {
        // System arrangements respond to window geometry and active hinge reserved regions.
        UIArrangementViewController *arrangement = [UIArrangementViewController new];
        [arrangement setViewController:controls forPlacement:UIArrangementViewControllerViewPlacementPrimary];
        [arrangement setViewController:logs forPlacement:UIArrangementViewControllerViewPlacementSecondary];
        self.window.rootViewController = arrangement;
    } else {
        UISplitViewController *split = [[UISplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
        controls.title = @"本机运行测试"; logs.title = @"测试日志";
        [split setViewController:[[UINavigationController alloc] initWithRootViewController:controls] forColumn:UISplitViewControllerColumnPrimary];
        [split setViewController:[[UINavigationController alloc] initWithRootViewController:logs] forColumn:UISplitViewControllerColumnSecondary];
        self.window.rootViewController = split;
    }
    [self.window makeKeyAndVisible];
}
- (void)sceneDidBecomeActive:(UIScene *)scene { [RuntimeSession.shared publish]; }
- (void)sceneWillResignActive:(UIScene *)scene { [RuntimeSession.shared publish]; }
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Runtime" sessionRole:session.role];
    configuration.delegateClass = SceneDelegate.class; return configuration;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
