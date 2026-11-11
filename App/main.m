#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <jni.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

@interface ProbeController : UIViewController
@property(nonatomic,strong) UITextView *output;
@property(nonatomic,strong) UIButton *runButton;
@end

@implementation ProbeController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.output = [UITextView new];
    self.output.editable = NO;
    self.output.font = [UIFont systemFontOfSize:17];
    self.output.text = @"这是本机运行能力测试，还不是游戏。\n\n点击运行后请保持此 App 在前台。结果保存在“文件”中的本机运行测试目录。";
    self.runButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.runButton setTitle:@"运行测试" forState:UIControlStateNormal];
    [self.runButton addTarget:self action:@selector(runProbe) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[self.output,self.runButton]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 16;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
      [stack.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
      [stack.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
      [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
      [stack.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-20],
      [self.runButton.heightAnchor constraintEqualToConstant:50]
    ]];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.runButton.enabled && [NSProcessInfo.processInfo.arguments containsObject:@"--probe-auto-run"])
        [self runProbe];
}
- (void)runProbe {
    self.runButton.enabled = NO; // A process can initialize this JVM only once.
    self.output.text = @"正在测试本机运行环境…";
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^{
        @autoreleasepool {
            NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
            NSString *bundle = NSBundle.mainBundle.resourcePath;
            chdir(documents.fileSystemRepresentation);
            NSString *log = [documents stringByAppendingPathComponent:@"jvm-output.log"];
            freopen(log.fileSystemRepresentation,"a",stdout);
            freopen(log.fileSystemRepresentation,"a",stderr);
            NSArray<NSString*> *arguments = @[
              [@"-Djava.home=" stringByAppendingString:[bundle stringByAppendingPathComponent:@"runtime"]],
              [@"-Djava.class.path=" stringByAppendingString:[bundle stringByAppendingPathComponent:@"DeviceProbe.jar"]],
              [@"-Duser.dir=" stringByAppendingString:documents], @"-Djava.awt.headless=true", @"-Xint", @"-Xmx256m"
            ];
            JavaVMOption options[6] = {0};
            for (NSUInteger i=0;i<arguments.count;i++) options[i].optionString = strdup(arguments[i].UTF8String);
            JavaVMInitArgs settings = {0};
            settings.version = JNI_VERSION_1_8;
            settings.nOptions = (jint)arguments.count;
            settings.options = options;
            settings.ignoreUnrecognized = JNI_FALSE;
            JavaVM *vm = NULL;
            JNIEnv *env = NULL;
            jint result = JNI_CreateJavaVM(&vm,(void**)&env,&settings);
            NSString *message = [NSString stringWithFormat:@"Java 启动返回值：%d。详情见 jvm-output.log。",result];
            if (result == JNI_OK) {
                jclass cls = (*env)->FindClass(env,"DeviceProbe");
                jmethodID method = cls ? (*env)->GetStaticMethodID(env,cls,"run","()V") : NULL;
                if (method) (*env)->CallStaticVoidMethod(env,cls,method);
                if ((*env)->ExceptionCheck(env)) {
                    (*env)->ExceptionDescribe(env);
                    (*env)->ExceptionClear(env);
                    message = @"Java 测试失败。详情见 jvm-output.log。";
                } else if (method) {
                    NSString *report = [documents stringByAppendingPathComponent:@"runtime-probe.json"];
                    message = [NSString stringWithContentsOfFile:report encoding:NSUTF8StringEncoding error:nil] ?: @"没有找到测试结果。";
                }
                // Do not destroy the VM before UIKit starts, or block UIKit on JVM worker threads.
                (*vm)->DetachCurrentThread(vm);
            }
            for (NSUInteger i=0;i<arguments.count;i++) free(options[i].optionString);
            fflush(stdout); fflush(stderr);
            dispatch_async(dispatch_get_main_queue(), ^{ self.output.text = message; });
        }
    });
}
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication*)app didFinishLaunchingWithOptions:(NSDictionary*)options {
    self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController = [ProbeController new];
    [self.window makeKeyAndVisible];
    return YES;
}
@end
int main(int argc,char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(AppDelegate.class)); }
}
