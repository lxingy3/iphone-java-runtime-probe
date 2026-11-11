#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <BackgroundTasks/BackgroundTasks.h>
#include <CommonCrypto/CommonDigest.h>
#include <sys/stat.h>
#include <jni.h>
#include <mach/mach.h>
#include <unistd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static NSString * const RuntimeChanged = @"RuntimeChanged";
static NSString *RPHostDocuments;
static NSString *RPHostResources;
static BOOL RPEmbeddedHost;
static NSString *Documents(void) {
    if (RPHostDocuments) return RPHostDocuments;
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}
static void WriteJSON(NSString *name, id value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    [data writeToFile:[Documents() stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}
static void Lifecycle(NSString *event) {
    NSDictionary *record = @{@"event":event, @"time":@([NSDate.date timeIntervalSince1970]),
        @"monotonic":@(NSProcessInfo.processInfo.systemUptime), @"pid":@(getpid()),
        @"application_state":@(UIApplication.sharedApplication.applicationState)};
    NSData *json = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    NSString *path = [Documents() stringByAppendingPathComponent:@"lifecycle.jsonl"];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!file) { [NSData.data writeToFile:path atomically:YES]; file = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [file seekToEndOfFile]; [file writeData:json]; [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
}

// A finite diagnostic job, not a permanent keep-alive. All state is main-queue owned.
API_AVAILABLE(ios(26.0))
@interface RPBackgroundTrial : NSObject
@property(nonatomic,strong) BGContinuedProcessingTask *task;
@property(nonatomic,strong) NSURLSessionDataTask *request;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSMutableArray *samples;
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,copy) NSString *state;
@property(nonatomic,copy) NSString *message;
@property(nonatomic,copy) NSString *serverStart;
@property(nonatomic) BOOL registered;
@property(nonatomic) BOOL pending;
@property(nonatomic) double began;
@property(nonatomic) double previousSample;
@property(nonatomic) long long previousTick;
@property(nonatomic) NSInteger successful;
@property(nonatomic) NSInteger backgroundSamples;
+ (instancetype)shared;
- (void)registerTask;
- (void)submit;
- (void)finish:(NSString *)state success:(BOOL)success message:(NSString *)message;
- (void)sample;
@end

@implementation RPBackgroundTrial
+ (instancetype)shared {
    static RPBackgroundTrial *value; static dispatch_once_t once;
    dispatch_once(&once, ^{ value = [RPBackgroundTrial new]; value.state = @"idle";
        value.message = @"服务端就绪后，可开始一次 10 分钟的后台测试。"; });
    return value;
}
- (void)save {
    NSMutableDictionary *report = [@{@"schema":@1, @"state":self.state, @"message":self.message,
        @"identifier":self.identifier ?: @"", @"pid":@(getpid()), @"target_samples":@120,
        @"successful_samples":@(self.successful), @"background_samples":@(self.backgroundSamples),
        @"elapsed_seconds":@(self.began ? NSProcessInfo.processInfo.systemUptime-self.began : 0),
        @"samples":self.samples ?: @[], @"native_game_login_verified":@NO} mutableCopy];
    WriteJSON(@"background-trial.json", report);
    [NSNotificationCenter.defaultCenter postNotificationName:RuntimeChanged object:self];
}
- (void)registerTask {
    NSAssert(NSThread.isMainThread, @"Register on main queue during launch");
    NSString *pattern = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".servertrial.*"];
    NSArray *permitted = [NSBundle.mainBundle objectForInfoDictionaryKey:@"BGTaskSchedulerPermittedIdentifiers"];
    if (![permitted containsObject:pattern]) {
        self.state = @"signing_configuration_mismatch";
        self.message = @"安装包的后台标识未与签名匹配，需要修正安装包。"; [self save]; return;
    }
    self.registered = [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:pattern usingQueue:dispatch_get_main_queue() launchHandler:^(BGTask *task) {
        RPBackgroundTrial *trial = RPBackgroundTrial.shared;
        if (![task isKindOfClass:BGContinuedProcessingTask.class] || !trial.pending ||
            ![task.identifier isEqualToString:trial.identifier]) { [task setTaskCompletedWithSuccess:NO]; return; }
        trial.pending = NO; trial.task = (BGContinuedProcessingTask *)task;
        trial.state = @"running"; trial.began = NSProcessInfo.processInfo.systemUptime;
        trial.task.progress.totalUnitCount = 120;
        trial.task.expirationHandler = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                [RPBackgroundTrial.shared finish:@"expired_or_system_cancelled" success:NO message:@"系统结束了后台测试，已保存完成的记录。"];
            });
        };
        trial.message = @"系统已接收测试。可切到游戏；10 分钟后查看结果。";
        Lifecycle(@"continued_task_started"); [trial save];
        trial.timer = [NSTimer scheduledTimerWithTimeInterval:5 target:trial selector:@selector(sample) userInfo:nil repeats:YES];
    }];
    if (!self.registered) { self.state = @"registration_failed"; self.message = @"系统未能注册后台测试。"; }
    [self save];
}
- (void)submit {
    if (!self.registered || self.task || self.pending || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    self.identifier = [NSString stringWithFormat:@"%@.servertrial.%@", NSBundle.mainBundle.bundleIdentifier, NSUUID.UUID.UUIDString];
    self.samples = [NSMutableArray new]; self.successful = 0; self.backgroundSamples = 0;
    self.began = 0; self.previousSample = 0; self.previousTick = -1; self.serverStart = nil;
    self.pending = YES; self.state = @"submitting"; self.message = @"正在向系统申请本次测试…";
    BGContinuedProcessingTaskRequest *request = [[BGContinuedProcessingTaskRequest alloc]
        initWithIdentifier:self.identifier title:@"本机服务连通性测试" subtitle:@"120 次检查，约 10 分钟"];
    request.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;
    NSError *error = nil;
    if (![BGTaskScheduler.sharedScheduler submitTaskRequest:request error:&error]) {
        self.pending = NO; self.state = @"submission_rejected";
        self.message = [NSString stringWithFormat:@"系统未批准：%@（%ld）",error.domain,(long)error.code];
    }
    [self save];
}
- (void)finish:(NSString *)state success:(BOOL)success message:(NSString *)message {
    if (!self.task && !self.pending) return;
    [self.timer invalidate]; self.timer = nil;
    [self.request cancel]; self.request = nil;
    self.state = state; self.message = message; self.pending = NO;
    BGContinuedProcessingTask *task = self.task; self.task = nil;
    task.expirationHandler = nil;
    Lifecycle([@"continued_task_" stringByAppendingString:state]); [self save];
    [task setTaskCompletedWithSuccess:success];
    // End only this diagnostic job. Do not claim to stop or restart the existing JVM.
}
- (void)sample {
    if (!self.task || self.request) return;
    double now = NSProcessInfo.processInfo.systemUptime;
    double gap = now - (self.previousSample ?: self.began);
    if (gap > 15 || now-self.began > 630) {
        [self finish:@"interrupted" success:NO message:@"检查间隔出现中断，不能判定为持续后台运行。记录已保存。"]; return;
    }
    self.previousSample = now;
    NSString *run = self.identifier;
    BOOL background = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        [NSString stringWithFormat:@"http://127.0.0.1:8088/api/status?backgroundTrial=%@&sample=%lu",run,(unsigned long)self.samples.count]]];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData; request.timeoutInterval = 3;
    self.request = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.task || ![self.identifier isEqualToString:run]) return;
            self.request = nil;
            NSDictionary *game = [json isKindOfClass:NSDictionary.class] && [json[@"game"] isKindOfClass:NSDictionary.class] ? json[@"game"] : nil;
            NSDictionary *tick = [game[@"tick"] isKindOfClass:NSDictionary.class] ? game[@"tick"] : nil;
            NSString *started = [game[@"startedAt"] isKindOfClass:NSString.class] ? game[@"startedAt"] : nil;
            NSNumber *completed = [tick[@"completedCount"] isKindOfClass:NSNumber.class] ? tick[@"completedCount"] : nil;
            BOOL passed = !error && [(NSHTTPURLResponse *)response statusCode] == 200 && [json[@"retcode"] isEqual:@0] && started && completed;
            if (passed && self.serverStart) passed = [started isEqualToString:self.serverStart] && completed.longLongValue > self.previousTick;
            if (passed) { self.serverStart = started; self.previousTick = completed.longLongValue; self.successful++; }
            if (background && passed) self.backgroundSamples++;
            [self.samples addObject:@{@"elapsed_seconds":@(now-self.began), @"gap_seconds":@(gap),
                @"background":@(background), @"passed":@(passed), @"startedAt":started ?: @"",
                @"tick":completed ?: @(-1), @"error_code":@(error.code)}];
            self.task.progress.completedUnitCount = self.samples.count;
            [self.task updateTitle:@"本机服务连通性测试" subtitle:[NSString stringWithFormat:@"已检查 %lu / 120 次",(unsigned long)self.samples.count]];
            self.message = [NSString stringWithFormat:@"已检查 %lu / 120 次；后台响应 %ld 次。",(unsigned long)self.samples.count,(long)self.backgroundSamples];
            [self save];
            if (!passed) [self finish:@"service_check_failed" success:NO message:@"服务响应中断或发生重启，已停止并保存检查结果。"];
            else if (self.samples.count == 120) {
                [self finish:@"completed" success:YES message:self.backgroundSamples >= 24 ?
                    @"120 次检查完成，包含至少 24 条后台响应记录。游戏连接仍需单独验证。" :
                    @"120 次检查完成，但后台样本不足，尚不能确认后台运行能力。"];
            }
        });
    }];
    [self.request resume];
}
@end

// Stream the archive through the native SHA implementation, outside the Zero interpreter.
static NSString *NativeSHA256(NSString *path, void (^progress)(unsigned long long, unsigned long long)) {
    FILE *input = fopen(path.fileSystemRepresentation, "rb");
    if (!input) return nil;
    struct stat info; if (fstat(fileno(input), &info) != 0) { fclose(input); return nil; }
    unsigned char *buffer = malloc(1024 * 1024);
    if (!buffer) { fclose(input); return nil; }
    CC_SHA256_CTX context; CC_SHA256_Init(&context);
    unsigned long long done = 0, total = (unsigned long long)info.st_size;
    NSTimeInterval last = 0;
    for (size_t count; (count = fread(buffer, 1, 1024 * 1024, input)) > 0;) {
        CC_SHA256_Update(&context, buffer, (CC_LONG)count); done += count;
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (progress && (now - last >= 0.25 || done == total)) { progress(done, total); last = now; }
    }
    BOOL failed = ferror(input) != 0; fclose(input); free(buffer);
    if (failed || done != total) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &context);
    char hex[CC_SHA256_DIGEST_LENGTH * 2 + 1];
    for (int i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) snprintf(hex + 2*i, 3, "%02x", digest[i]);
    return [NSString stringWithUTF8String:hex];
}

// Same bytes and file for both implementations; run only in the simulator test harness.
static BOOL ChecksumBenchmark(JNIEnv *env, jclass cls) {
    NSString *path = [Documents() stringByAppendingPathComponent:@"checksum-fixture.bin"];
    unsigned char *buffer = malloc(1024 * 1024); if (!buffer) return NO;
    for (NSUInteger i = 0; i < 1024 * 1024; i++) buffer[i] = (unsigned char)(i % 256);
    FILE *output = fopen(path.fileSystemRepresentation, "wb");
    if (!output) { free(buffer); return NO; }
    BOOL written = YES;
    for (int i = 0; i < 16; i++) if (fwrite(buffer, 1, 1024 * 1024, output) != 1024 * 1024) written = NO;
    fclose(output); free(buffer); if (!written) return NO;
    NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
    NSString *nativeHash = NativeSHA256(path, nil);
    double nativeSeconds = NSProcessInfo.processInfo.systemUptime - start;
    jmethodID method = (*env)->GetStaticMethodID(env, cls, "sha256File", "(Ljava/lang/String;)Ljava/lang/String;");
    if (!method) return NO;
    jstring filename = (*env)->NewStringUTF(env, path.UTF8String);
    start = NSProcessInfo.processInfo.systemUptime;
    jstring value = (jstring)(*env)->CallStaticObjectMethod(env, cls, method, filename);
    double javaSeconds = NSProcessInfo.processInfo.systemUptime - start;
    (*env)->DeleteLocalRef(env, filename);
    if ((*env)->ExceptionCheck(env) || !value) return NO;
    const char *raw = (*env)->GetStringUTFChars(env, value, NULL);
    NSString *javaHash = raw ? [NSString stringWithUTF8String:raw] : nil;
    if (raw) (*env)->ReleaseStringUTFChars(env, value, raw); (*env)->DeleteLocalRef(env, value);
    NSString *expected = @"341aacac661ccb210720bedaa9ead5d668fe5ea41a73532fc147c71e34040df1";
    BOOL passed = [nativeHash isEqualToString:expected] && [javaHash isEqualToString:expected];
    WriteJSON(@"checksum-benchmark.json", @{@"passed":@(passed), @"bytes":@(16*1024*1024),
        @"native_seconds":@(nativeSeconds), @"java_seconds":@(javaSeconds),
        @"native_sha256":nativeHash ?: @"", @"java_sha256":javaHash ?: @""});
    fprintf(stderr, "Checksum benchmark: native=%.3fs Java Zero=%.3fs equal=%d\n", nativeSeconds, javaSeconds, passed);
    return passed;
}

// A process owns its JVM; scene replacement and resizing never initialize another one.
@interface RuntimeSession : NSObject
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL serverMode;
@property(nonatomic) BOOL ready;
@property(nonatomic) NSInteger starts;
@property(nonatomic) double preparationProgress;
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
        instance.preparationProgress = -1;
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
        @"preparation_progress": @(self.preparationProgress),
        @"footprint_bytes": available ? @(memory.phys_footprint) : NSNull.null,
        @"ios": UIDevice.currentDevice.systemVersion,
        @"foreground": @(UIApplication.sharedApplication.applicationState == UIApplicationStateActive)
    });
    [NSNotificationCenter.defaultCenter postNotificationName:RuntimeChanged object:self];
}
- (void)updatePhase:(NSString *)phase status:(NSString *)status {
    dispatch_async(dispatch_get_main_queue(), ^{
        self.phase = phase; self.status = status;
        if ([phase isEqualToString:@"preparing_payload"]) { self.preparationProgress = 0; self.detail = @"首次解压资源，请保持 App 在前台。完成后会保留资源和存档。"; }
        if ([phase isEqualToString:@"starting_server"]) { self.preparationProgress = -1; self.detail = @"正在载入服务端，详细过程显示在运行日志中。"; }
        if ([phase isEqualToString:@"failed"]) UIApplication.sharedApplication.idleTimerDisabled = NO;
        [self publish];
    });
}
- (void)tick {
    if ([self.phase isEqualToString:@"preparing_payload"]) {
        NSData *data = [NSData dataWithContentsOfFile:[Documents() stringByAppendingPathComponent:@"payload-progress.json"]];
        NSDictionary *progress = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([progress isKindOfClass:NSDictionary.class] && [progress[@"total_files"] doubleValue] > 0) {
            self.preparationProgress = [progress[@"completed_files"] doubleValue] / [progress[@"total_files"] doubleValue];
            self.status = [NSString stringWithFormat:@"正在解压资源：%@ / %@ 个文件", progress[@"completed_files"], progress[@"total_files"]];
        }
    }
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
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    self.phase = @"starting_runtime"; self.status = @"正在启动运行环境…";
    self.detail = server ? @"首次准备资源需要一些时间，请保持 App 在前台。" : @"正在检查网络、存储和基础运行能力。";
    self.heartbeat = [NSTimer scheduledTimerWithTimeInterval:3 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    [self publish];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool {
            NSString *documents = Documents();
            NSString *working = server ? [documents stringByAppendingPathComponent:@"server"] : documents;
            if (![NSFileManager.defaultManager createDirectoryAtPath:working withIntermediateDirectories:YES attributes:nil error:nil] ||
                (!RPEmbeddedHost && chdir(working.fileSystemRepresentation) != 0)) {
                [self updatePhase:@"failed" status:@"无法准备本机存储目录"]; return;
            }
            NSString *bundle = RPHostResources ?: NSBundle.mainBundle.resourcePath;
            NSString *runtimeHome = [bundle stringByAppendingPathComponent:@"runtime"];
            setenv("JAVA_HOME", runtimeHome.fileSystemRepresentation, 1);
            NSString *log = [documents stringByAppendingPathComponent:@"jvm-output.log"];
            if (!RPEmbeddedHost) {
                freopen(log.fileSystemRepresentation, "a", stdout); freopen(log.fileSystemRepresentation, "a", stderr);
                setvbuf(stdout, NULL, _IOLBF, 0); setvbuf(stderr, NULL, _IOLBF, 0);
            }
            NSString *nativeDigest = nil;
            if (server) {
                NSString *expected = [[NSString stringWithContentsOfFile:[documents stringByAppendingPathComponent:@"server-payload.sha256"]
                    encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].lowercaseString;
                NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
                if (expected.length != 64 || [expected rangeOfCharacterFromSet:invalid].location != NSNotFound) {
                    [self updatePhase:@"failed" status:@"资源包校验信息缺失或无效"]; return;
                }
                NSString *marker = [[NSString stringWithContentsOfFile:[working stringByAppendingPathComponent:@".payload-ready.sha256"]
                    encoding:NSUTF8StringEncoding error:nil] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                if (marker && ![marker isEqualToString:expected]) {
                    [self updatePhase:@"failed" status:@"已有资源版本不同，已保留原存档并停止准备"]; return;
                }
                if ([marker isEqualToString:expected]) {
                    nativeDigest = expected;
                    fprintf(stderr, "Payload: using completed preparation marker\n");
                } else {
                    [self updatePhase:@"verifying_payload" status:@"正在校验资源包：0%"];
                    NSTimeInterval began = NSProcessInfo.processInfo.systemUptime;
                    nativeDigest = NativeSHA256([documents stringByAppendingPathComponent:@"server-payload.zip"], ^(unsigned long long done, unsigned long long total) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            self.preparationProgress = total ? (double)done / (double)total : 0;
                            self.status = [NSString stringWithFormat:@"正在校验资源包：%.0f%%", self.preparationProgress * 100];
                            self.detail = [NSString stringWithFormat:@"已读取 %.1f / %.1f MB。测试期间将保持亮屏。",done/1000000.0,total/1000000.0];
                            [self publish];
                        });
                    });
                    double seconds = NSProcessInfo.processInfo.systemUptime - began;
                    BOOL matched = [nativeDigest isEqualToString:expected];
                    WriteJSON(@"payload-checksum.json", @{@"passed":@(matched), @"method":@"iOS native SHA-256",
                        @"seconds":@(seconds), @"actual_sha256":nativeDigest ?: @""});
                    fprintf(stderr, "Payload: native SHA-256 completed in %.3f seconds, match=%d\n", seconds, matched);
                    if (!matched) { [self updatePhase:@"failed" status:@"资源包读取或校验失败"]; return; }
                }
                [self updatePhase:@"starting_runtime" status:@"校验完成，正在启动运行环境…"];
            }
            fprintf(stderr, "Runtime: starting JNI_CreateJavaVM, mode=%s\n", server ? "server" : "probe");
            NSArray<NSString *> *arguments = @[
                [@"-Djava.home=" stringByAppendingString:runtimeHome],
                [@"-Djava.class.path=" stringByAppendingString:[bundle stringByAppendingPathComponent:@"DeviceProbe.jar"]],
                [@"-Duser.dir=" stringByAppendingString:working], @"-Djava.awt.headless=true", @"-Xint",
                server ? @"-Xmx2048m" : @"-Xmx256m", @"-Dfile.encoding=UTF-8",
                @"-Dlogback.configurationFile=prototype-logback.xml", @"-Diphone.prototype.verify=true",
                [@"--patch-module=java.base=" stringByAppendingString:[bundle stringByAppendingPathComponent:@"RuntimePatch.jar"]]
            ];
            JavaVMOption options[10] = {0};
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
                    jmethodID prepare = (*env)->GetStaticMethodID(env, cls, "prepareServer", "(Ljava/lang/String;Ljava/lang/String;)V");
                    if (prepare) {
                        jstring source = (*env)->NewStringUTF(env, documents.UTF8String);
                        jstring digest = (*env)->NewStringUTF(env, nativeDigest.UTF8String);
                        (*env)->CallStaticVoidMethod(env, cls, prepare, source, digest);
                        (*env)->DeleteLocalRef(env, source); (*env)->DeleteLocalRef(env, digest);
                    }
                    if (prepare && !(*env)->ExceptionCheck(env)) {
                        [self updatePhase:@"starting_server" status:@"正在载入服务端和存档…"];
                        jmethodID start = (*env)->GetStaticMethodID(env, cls, "startServer", "()V");
                        if (start) (*env)->CallStaticVoidMethod(env, cls, start); else successful = NO;
                    } else successful = NO;
                } else if (cls) {
                    if ([NSProcessInfo.processInfo.arguments containsObject:@"--checksum-benchmark"]) successful = ChecksumBenchmark(env, cls);
                    if (successful) {
                        jmethodID run = (*env)->GetStaticMethodID(env, cls, "run", "()V");
                        if (run) (*env)->CallStaticVoidMethod(env, cls, run); else successful = NO;
                    }
                } else successful = NO;
                if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionDescribe(env); (*env)->ExceptionClear(env); successful = NO; }
                (*vm)->DetachCurrentThread(vm);
            }
            fflush(stdout); fflush(stderr);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!successful) {
                    UIApplication.sharedApplication.idleTimerDisabled = NO;
                    self.phase = @"failed"; self.status = @"本次测试未完成";
                    self.detail = @"详细原因已保存到运行日志。重新尝试前请关闭并重新打开此 App。";
                } else if (!server) {
                    UIApplication.sharedApplication.idleTimerDisabled = NO;
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

// Public host entry points. The host retains its own application/scene delegates.
// Do not switch another application's working directory or redirect its stdio.
__attribute__((visibility("default"))) BOOL RPHostStart(NSString *documents, NSString *resources, BOOL server, NSError **error) {
    NSCAssert(NSThread.isMainThread, @"Host bootstrap requires the main thread");
    NSString *reason = nil;
    if (RuntimeSession.shared.started) reason = @"This process already owns a JVM; restart the containing app to change modes.";
    else if (!documents.isAbsolutePath || !resources.isAbsolutePath) reason = @"The host must supply absolute private storage and resource paths.";
    else if (server && ![NSFileManager.defaultManager.currentDirectoryPath isEqualToString:[documents stringByAppendingPathComponent:@"server"]])
        reason = @"This server payload still uses relative java.io paths. The host must establish the server working directory before initializing either engine; arbitrary injection is not supported.";
    if (reason) { if (error) *error = [NSError errorWithDomain:@"RuntimeHostKit" code:1 userInfo:@{NSLocalizedDescriptionKey:reason}]; return NO; }
    RPHostDocuments = documents.copy; RPHostResources = resources.copy; RPEmbeddedHost = YES;
    if (![NSFileManager.defaultManager createDirectoryAtPath:documents withIntermediateDirectories:YES attributes:nil error:error]) return NO;
    [RuntimeSession.shared startServer:server]; return YES;
}
__attribute__((visibility("default"))) NSDictionary *RPHostSnapshot(void) {
    NSCAssert(NSThread.isMainThread, @"Host snapshots require the main thread");
    RuntimeSession *s = RuntimeSession.shared;
    return @{@"phase":s.phase, @"ready":@(s.ready), @"jvm_start_count":@(s.starts), @"pid":@(getpid()), @"game_integration_verified":@NO};
}
__attribute__((visibility("default"))) void RPHostSceneEvent(NSString *event) {
    NSCAssert(NSThread.isMainThread, @"Host lifecycle requires the main thread");
    Lifecycle(event); [RuntimeSession.shared publish];
}

#ifndef RP_EMBEDDED_LIBRARY
@interface ControlsController : UIViewController
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) UILabel *detailLabel;
@property(nonatomic,strong) UIButton *probeButton;
@property(nonatomic,strong) UIButton *serverButton;
@property(nonatomic,strong) UIButton *backgroundButton;
@property(nonatomic,strong) UIButton *cancelButton;
@property(nonatomic,strong) UILabel *backgroundLabel;
@property(nonatomic,strong) UIProgressView *progressView;
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
    UILabel *subtitle = [self label:@"iPhone 运行验证 · 0.5" style:UIFontTextStyleSubheadline]; subtitle.textColor = UIColor.secondaryLabelColor;
    self.statusLabel = [self label:@"" style:UIFontTextStyleTitle2]; self.detailLabel = [self label:@"" style:UIFontTextStyleBody];
    self.probeButton = [self button:@"检查运行环境" action:@selector(runProbe) prominent:NO];
    self.serverButton = [self button:@"测试本机服务端" action:@selector(runServer) prominent:YES];
    self.backgroundButton = [self button:@"测试后台运行 · 10 分钟" action:@selector(runBackground) prominent:NO];
    self.cancelButton = [self button:@"结束后台测试" action:@selector(cancelBackground) prominent:NO];
    self.backgroundLabel = [self label:@"此系统不支持持续后台测试。" style:UIFontTextStyleBody];
    self.progressView = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
    UILabel *note = [self label:@"此版本用于验证运行能力，还不是完整游戏。服务端测试需要已传入的本机资源包。" style:UIFontTextStyleFootnote];
    note.textColor = UIColor.secondaryLabelColor;
    UIStackView *content = [[UIStackView alloc] initWithArrangedSubviews:@[title,subtitle,self.statusLabel,self.detailLabel,self.progressView,self.serverButton,self.backgroundButton,self.backgroundLabel,self.cancelButton,self.probeButton,note]];
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
    self.progressView.hidden = !([session.phase isEqualToString:@"verifying_payload"] || [session.phase isEqualToString:@"preparing_payload"]);
    self.progressView.progress = session.preparationProgress < 0 ? 0 : (float)session.preparationProgress;
    self.backgroundButton.enabled = NO; self.cancelButton.hidden = YES;
    if (@available(iOS 26.0, *)) {
        RPBackgroundTrial *trial = RPBackgroundTrial.shared;
        self.backgroundLabel.text = trial.message;
        self.backgroundButton.enabled = session.ready && trial.registered && !trial.task && !trial.pending;
        self.cancelButton.hidden = !trial.task && !trial.pending;
    }
}
- (void)runProbe { [RuntimeSession.shared startServer:NO]; }
- (void)runServer { [RuntimeSession.shared startServer:YES]; }
- (void)runBackground { if (@available(iOS 26.0, *)) [RPBackgroundTrial.shared submit]; }
- (void)cancelBackground {
    if (@available(iOS 26.0, *)) [RPBackgroundTrial.shared finish:@"cancelled_in_app" success:NO message:@"已结束本次后台测试；服务端仍遵循系统前后台规则。"];
}
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
- (void)sceneDidBecomeActive:(UIScene *)scene { RPHostSceneEvent(@"scene_active"); }
- (void)sceneWillResignActive:(UIScene *)scene { RPHostSceneEvent(@"scene_inactive"); }
- (void)sceneDidEnterBackground:(UIScene *)scene { RPHostSceneEvent(@"scene_background"); }
- (void)sceneWillEnterForeground:(UIScene *)scene { RPHostSceneEvent(@"scene_foreground"); }
@end

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation AppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    Lifecycle(@"application_launch");
    if (@available(iOS 26.0, *)) [RPBackgroundTrial.shared registerTask];
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Runtime" sessionRole:session.role];
    configuration.delegateClass = SceneDelegate.class; return configuration;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(AppDelegate.class)); }
}
#endif
