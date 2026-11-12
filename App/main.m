#include <sys/stat.h>

// Compare filesystem identity, since aliases such as /var and /private/var
// can name the same directory. A genuinely changed cwd must still be rejected.
static int RPDirectoriesMatch(const char *left, const char *right) {
    struct stat a, b;
    return left && right && stat(left, &a) == 0 && stat(right, &b) == 0 &&
        S_ISDIR(a.st_mode) && S_ISDIR(b.st_mode) &&
        a.st_dev == b.st_dev && a.st_ino == b.st_ino;
}

#if defined(RP_CLIENT_FIXTURE)
// Simulator-only host for the optional observer. No game code or real account data.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#include <unistd.h>
#include <dlfcn.h>
extern BOOL RPHostStart(NSString *, NSString *, BOOL, NSError **);
extern NSDictionary *RPHostSnapshot(void);

static void RPCFixtureHTTP(NSURL *url, NSString *documents) {
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [@"{\"fixture\":\"not-an-account\",\"nonce\":\"routing-test\"}" dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    NSURLSessionConfiguration *configuration = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    configuration.timeoutIntervalForRequest = 8;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *result = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        BOOL passed = !error && [(NSHTTPURLResponse *)response statusCode] == 200 && [result[@"passed"] isEqual:@YES];
        NSDictionary *report = @{@"passed":@(passed),@"http_status":@([(NSHTTPURLResponse *)response statusCode]),
            @"error_code":@(error.code),@"method_body_query_verified_by_mock":@([result[@"passed"] isEqual:@YES]),
            @"actual_game_tested":@NO};
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
            writeToFile:[documents stringByAppendingPathComponent:@"routing-http-fixture.json"] atomically:YES];
        [session finishTasksAndInvalidate];
    }] resume];
}

@interface MiHoYoRSAEncryptor : NSObject
+ (NSString *)encryptString:(NSString *)input publicKey:(NSString *)key;
+ (NSData *)encryptData:(NSData *)input publicKey:(NSString *)key;
@end
@implementation MiHoYoRSAEncryptor
+ (NSString *)encryptString:(NSString *)input publicKey:(NSString *)key { return [@"original:" stringByAppendingString:input]; }
+ (NSData *)encryptData:(NSData *)input publicKey:(NSString *)key { return [input copy]; }
@end
@interface RPCFixtureSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation RPCFixtureSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *controller = [UIViewController new];
    controller.view.backgroundColor = UIColor.systemBackgroundColor;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(24,100,330,160)];
    label.numberOfLines = 0; label.text = @"Local observer acceptance fixture";
    [controller.view addSubview:label]; self.window.rootViewController = controller;
    [self.window makeKeyAndVisible];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        BOOL disabled = [NSProcessInfo.processInfo.arguments containsObject:@"--expect-observer-disabled"];
        BOOL routing = [NSProcessInfo.processInfo.arguments containsObject:@"--expect-local-routing"];
        NSString *sensitive = @"FIXTURE_INPUT_NEVER_RECORD";
        NSString *key = @"FIXTURE_PUBLIC_KEY_HASH_ONLY";
        NSData *input = [sensitive dataUsingEncoding:NSUTF8StringEncoding];
        NSString *encrypted = [MiHoYoRSAEncryptor encryptString:sensitive publicKey:key];
        NSData *encryptedData = [MiHoYoRSAEncryptor encryptData:input publicKey:key];
        NSURL *login = [NSURL URLWithString:[@"https://hk4e-sdk.mihoyo.com/hk4e_cn/mdk/shield/api/login?token=" stringByAppendingString:sensitive]];
        NSURL *dispatch = [NSURL URLWithString:@"https://dispatchcnglobal.yuanshen.com/query_region_list?version=fixture"];
        [NSURL URLWithString:@"https://untrusted.example/query_region_list?token=fixture"];
        [NSURL URLWithString:@"https://hk4e-sdk.mihoyo.com/private-account-path"];
        NSMutableDictionary *checks = [@{@"string_passthrough":@([encrypted isEqualToString:[@"original:" stringByAppendingString:sensitive]]),
            @"data_passthrough":@([encryptedData isEqualToData:input]),
            @"url_query_preserved":@([login.query containsString:sensitive]),
            @"login_destination_correct":@([login.host isEqualToString:(routing ? @"127.0.0.1" : @"hk4e-sdk.mihoyo.com")]),
            @"dispatch_destination_correct":@([dispatch.host isEqualToString:(routing ? @"127.0.0.1" : @"dispatchcnglobal.yuanshen.com")])} mutableCopy];
        if (routing) {
            checks[@"login_routes_to_loopback"] = @([login.host isEqual:@"127.0.0.1"] && [login.port isEqual:@8088] && [login.scheme isEqual:@"http"]);
            checks[@"dispatch_routes_to_loopback"] = @([dispatch.host isEqual:@"127.0.0.1"] && [dispatch.port isEqual:@8088]);
            NSURL *relative = [NSURL URLWithString:@"/query_cur_region?encoded=a%2Bb%2Fc%25" relativeToURL:[NSURL URLWithString:@"https://dispatchcnglobal.yuanshen.com/"]];
            checks[@"relative_url_routes_with_encoding_preserved"] = @([relative.absoluteString isEqual:@"http://127.0.0.1:8088/query_cur_region?encoded=a%2Bb%2Fc%25"]);
            BOOL untouched = YES;
            for (NSString *negative in @[@"https://mihoyo.com.evil.test/query_region_list",@"https://example.test/query_region_list",
                @"https://autopatchcn.yuanshen.com/client/data.zip",@"https://hk4e-sdk.mihoyo.com/private-account-path",
                @"ftp://dispatchcnglobal.yuanshen.com/query_region_list",@"https://dispatchcnglobal.yuanshen.com:444/query_region_list",
                @"https://fixture:fixture@dispatchcnglobal.yuanshen.com/query_region_list",@"http://127.0.0.1:8088/query_region_list"])
                untouched &= [[NSURL URLWithString:negative].absoluteString isEqual:negative];
            checks[@"unrelated_resource_and_unsupported_urls_unchanged"] = @(untouched);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{
            NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
            NSString *path = [documents stringByAppendingPathComponent:@"RuntimeIntegration/client-observations.json"];
            NSData *data = [NSData dataWithContentsOfFile:path];
            NSDictionary *report = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *raw = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
            if (disabled) {
                checks[@"unexpected_bundle_observer_disabled"] = @(data == nil);
            } else {
                NSMutableArray *urls = [NSMutableArray new];
                NSUInteger keys = 0; BOOL loaded = NO, launched = NO, registered = NO;
                for (NSDictionary *event in report[@"events"]) {
                    if ([event[@"event"] isEqual:@"library_loaded"]) loaded = YES;
                    if ([event[@"event"] isEqual:@"application_launched"]) launched = ![event[@"server_enabled"] boolValue];
                    if ([event[@"event"] isEqual:@"observers_registered"]) registered = [event[@"url"] boolValue] && [event[@"sdk_string"] boolValue] && [event[@"sdk_data"] boolValue];
                    if ([event[@"event"] isEqual:@"url_constructed"]) [urls addObject:event];
                    if ([event[@"event"] isEqual:@"sdk_public_key_used"] && [event[@"key_sha256"] length] == 64) keys++;
                }
                checks[@"dynamic_library_loaded"] = @(loaded);
                checks[@"launch_observed_without_server_start"] = @(launched);
                checks[@"objc_observers_registered"] = @(registered);
                NSSet *observedPaths = [NSSet setWithArray:[urls valueForKey:@"path"]];
                checks[@"allowed_urls_only"] = @((routing ? urls.count >= 2 : urls.count == 2) &&
                    [observedPaths containsObject:@"/hk4e_cn/mdk/shield/api/login"] && [observedPaths containsObject:@"/query_region_list"]);
                checks[@"routing_requires_opt_in"] = @([report[@"local_routing_enabled"] boolValue] == routing);
                checks[@"public_key_fingerprints_only"] = @(keys == 2 && ![raw containsString:key]);
                checks[@"no_sensitive_input_or_query"] = @(![raw containsString:sensitive] && ![raw containsString:@"token="] && ![raw containsString:@"version=fixture"]);
                checks[@"no_disallowed_hosts_or_paths"] = @(![raw containsString:@"untrusted.example"] && ![raw containsString:@"private-account-path"]);
                checks[@"no_embedded_server_started"] = @(![NSFileManager.defaultManager fileExistsAtPath:[documents stringByAppendingPathComponent:@"RuntimeIntegration/embedded-host.json"]]);
            }
            BOOL passed = YES; for (NSNumber *value in checks.allValues) passed &= value.boolValue;
            NSDictionary *result = @{@"passed":@(passed),@"checks":checks,@"environment":@"iOS Simulator fixture",
                @"actual_game_tested":@NO,@"native_private_gameplay_verified":@NO};
            [[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil]
                writeToFile:[documents stringByAppendingPathComponent:@"observer-fixture.json"] atomically:YES];
            label.text = passed ? @"Observer fixture passed" : @"Observer fixture failed";
            if (passed && routing) RPCFixtureHTTP([NSURL URLWithString:@"https://hk4e-sdk.mihoyo.com/hk4e_cn/mdk/shield/api/login?token=FIXTURE_INPUT_NEVER_RECORD&encoded=a%2Bb%2Fc%25"],documents);
            if (passed && [NSProcessInfo.processInfo.arguments containsObject:@"--probe-embedded-runtime"]) {
                // The host-local shim must not change the containing app's loader.
                void *mainHandle = dlopen(NULL, RTLD_FIRST);
                BOOL mainScopeUnchanged = mainHandle && dlsym(mainHandle,"JNI_OnLoad_java") == NULL;
                if (mainHandle) dlclose(mainHandle);
                NSString *storage = [documents stringByAppendingPathComponent:@"EmbeddedRuntime"];
                NSString *resources = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LocalRuntime"];
                NSError *error = nil;
                BOOL accepted = RPHostStart(storage,resources,NO,&error);
                NSDictionary *request = @{@"accepted":@(accepted),@"error":error.localizedDescription ?: @""};
                [[NSJSONSerialization dataWithJSONObject:request options:0 error:nil]
                    writeToFile:[documents stringByAppendingPathComponent:@"embedded-request.json"] atomically:YES];
                if (accepted) [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
                    NSDictionary *snapshot = RPHostSnapshot();
                    NSString *phase = snapshot[@"phase"];
                    if (![phase isEqual:@"probe_passed"] && ![phase isEqual:@"probe_failed"] && ![phase isEqual:@"failed"]) return;
                    [timer invalidate];
                    NSData *runtimeData = [NSData dataWithContentsOfFile:[storage stringByAppendingPathComponent:@"runtime-probe.json"]];
                    NSDictionary *runtime = runtimeData ? [NSJSONSerialization JSONObjectWithData:runtimeData options:0 error:nil] : @{};
                    NSError *repeatError = nil;
                    BOOL repeatAccepted = RPHostStart(storage,resources,NO,&repeatError);
                    BOOL runtimePassed = mainScopeUnchanged && [runtime[@"passed"] boolValue] && [snapshot[@"jvm_start_count"] isEqual:@1] &&
                        [snapshot[@"pid"] isEqual:@(getpid())] && !repeatAccepted && repeatError != nil;
                    NSDictionary *embedded = @{@"passed":@(runtimePassed),@"runtime":runtime ?: @{},
                        @"host":snapshot,@"same_process":@([snapshot[@"pid"] isEqual:@(getpid())]),
                        @"second_jvm_rejected":@(!repeatAccepted && repeatError != nil),
                        @"containing_app_loader_scope_unchanged":@(mainScopeUnchanged),@"actual_game_tested":@NO};
                    [[NSJSONSerialization dataWithJSONObject:embedded options:NSJSONWritingPrettyPrinted error:nil]
                        writeToFile:[documents stringByAppendingPathComponent:@"embedded-fixture.json"] atomically:YES];
                    label.text = runtimePassed ? @"Dynamic runtime fixture passed" : @"Dynamic runtime fixture failed";
                }];
            }
        });
    });
}
@end
@interface RPCFixtureDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation RPCFixtureDelegate
- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [[UISceneConfiguration alloc] initWithName:@"Fixture" sessionRole:session.role];
    configuration.delegateClass = RPCFixtureSceneDelegate.class;
    return configuration;
}
@end
int main(int argc,char **argv) { @autoreleasepool { return UIApplicationMain(argc,argv,nil,NSStringFromClass(RPCFixtureDelegate.class)); } }
#elif defined(RP_CLIENT_OBSERVER_ONLY)
// Optional local-only instrumentation for an explicitly configured, separately
// installed host. Loopback routing requires a separate explicit opt-in.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <unistd.h>
#include <arpa/inet.h>

extern BOOL RPHostStart(NSString *, NSString *, BOOL, NSError **);
extern NSDictionary *RPHostSnapshot(void);
extern void RPHostSceneEvent(NSString *);

static NSString *RPCReportDirectory;
static NSString *RPCServerDirectory;
static NSDictionary *RPCConfiguration;
static dispatch_queue_t RPCReportQueue;
static NSMutableArray *RPCEvents;
static NSMutableSet *RPCSeen;
static BOOL RPCPreparedServer;
static BOOL RPCHostStarted;
static BOOL RPCLocalRoutingEnabled;
static __thread BOOL RPCRecordingURL;
static __thread BOOL RPCRoutingURL;
static IMP RPCOriginalURL;
static IMP RPCOriginalRelativeURL;
static IMP RPCOriginalRSAString;
static IMP RPCOriginalRSAData;
static IMP RPCOriginalPorteLogin;
static SecKeyRef RPCLocalLoginKey;
static NSString *RPCLocalLoginAccount;
static NSLock *RPCLoginLock;
static NSDictionary *RPCPendingLogin;
static NSTimeInterval RPCPendingLoginExpires;
static NSTimeInterval RPCLoginBlockedUntil;

static void RPCWrite(NSString *name, NSDictionary *value) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted error:nil];
    [json writeToFile:[RPCReportDirectory stringByAppendingPathComponent:name] options:NSDataWritingAtomic error:nil];
}
static void RPCRecord(NSString *event, NSDictionary *details) {
    if (!RPCReportQueue) return;
    dispatch_async(RPCReportQueue, ^{
        if (RPCEvents.count >= 512) return;
        NSString *identity = [event stringByAppendingString:details.description];
        if ([RPCSeen containsObject:identity]) return;
        [RPCSeen addObject:identity];
        NSMutableDictionary *item = [details mutableCopy];
        item[@"event"] = event; item[@"time"] = @([NSDate.date timeIntervalSince1970]);
        [RPCEvents addObject:item];
        RPCWrite(@"client-observations.json", @{@"schema":@1,@"pid":@(getpid()),@"events":RPCEvents,
            @"request_bodies_recorded":@NO,@"credentials_recorded":@NO,@"local_routing_enabled":@(RPCLocalRoutingEnabled),
            @"native_game_login_verified":@NO});
    });
}
static BOOL RPCVendorHost(NSString *host) {
    host = host.lowercaseString;
    for (NSString *domain in @[@"mihoyo.com",@"hoyoverse.com",@"yuanshen.com"])
        if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) return YES;
    return NO;
}
static NSSet *RPCRoutePaths(void) {
    static NSSet *paths; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableSet *values = [NSMutableSet setWithArray:@[@"/query_region_list",@"/query_cur_region",@"/query_cur_region/dispatch",
            @"/account/risky/api/check",@"/account/ma-cn-passport/app/loginByPassword",@"/account/ma-cn-passport/token/verifySToken",
            @"/combo/box/api/config/sdk/combo",@"/combo/box/api/config/sw/precache",@"/device-fp/api/getExtList"]];
        for (NSString *game in @[@"hk4e_cn",@"hk4e_global"])
            for (NSString *suffix in @[@"mdk/shield/api/login",@"mdk/shield/api/verify",@"mdk/shield/api/loadConfig",
                @"combo/granter/login/v2/login",@"combo/granter/api/getConfig",@"combo/granter/api/compareProtocolVersion",
                @"account/ma-passport/api/getConfig",@"account/ma-passport/api/appLoginByPassword",@"account/ma-passport/token/verifySToken"])
                [values addObject:[NSString stringWithFormat:@"/%@/%@",game,suffix]];
        paths = [values copy];
    });
    return paths;
}
static void RPCObserveURL(NSURL *url) {
    if (RPCRecordingURL || ![url isKindOfClass:NSURL.class]) return;
    RPCRecordingURL = YES;
    @try {
        NSString *host = url.host.lowercaseString ?: @"";
        NSString *path = url.path ?: @"";
        // Exact paths only: never persist arbitrary URLs, query strings, headers or bodies.
        if (RPCVendorHost(host) && [RPCRoutePaths() containsObject:path])
            RPCRecord(@"url_constructed", @{@"host":host,@"path":path});
    } @finally { RPCRecordingURL = NO; }
}
static NSURL *RPCRewriteURL(NSURL *url) {
    if (!RPCLocalRoutingEnabled || RPCRoutingURL || ![url isKindOfClass:NSURL.class]) return url;
    if (!RPCVendorHost(url.host) || ![RPCRoutePaths() containsObject:url.path]) return url;
    NSString *scheme = url.scheme.lowercaseString;
    if (![@[@"https",@"http"] containsObject:scheme] || url.user.length || url.password.length ||
        (url.port && ![@[@80,@443] containsObject:url.port])) return url;
    RPCRoutingURL = YES;
    @try {
        NSURLComponents *parts = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:YES];
        // Preserve the encoded path/query byte representation. Resource/CDN URLs never match.
        parts.scheme = @"http"; parts.host = @"127.0.0.1"; parts.port = @8088;
        NSURL *result = parts.URL;
        if (result) RPCRecord(@"url_routed_to_loopback", @{@"host":url.host.lowercaseString,@"path":url.path,@"port":@8088});
        return result ?: url;
    } @finally { RPCRoutingURL = NO; }
}
static id RPCURL(id receiver, SEL selector, id value) {
    id result = ((id (*)(id,SEL,id))RPCOriginalURL)(receiver,selector,value);
    RPCObserveURL(result); return RPCRewriteURL(result);
}
static id RPCRelativeURL(id receiver, SEL selector, id value, id base) {
    id result = ((id (*)(id,SEL,id,id))RPCOriginalRelativeURL)(receiver,selector,value,base);
    RPCObserveURL(result); return RPCRewriteURL(result);
}
static void RPCObserveKey(NSString *method, id key) {
    if (![key isKindOfClass:NSString.class]) return;
    NSData *bytes = [key dataUsingEncoding:NSUTF8StringEncoding];
    if (bytes.length > 16384) return;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
    NSMutableString *hex = [NSMutableString new];
    for (NSUInteger i=0;i<sizeof(digest);i++) [hex appendFormat:@"%02x",digest[i]];
    RPCRecord(@"sdk_public_key_used", @{@"method":method,@"key_sha256":hex,@"key_bytes":@(bytes.length)});
}
static id RPCRSAString(id receiver, SEL selector, id input, id key) {
    RPCObserveKey(@"encryptString:publicKey:",key);
    return ((id (*)(id,SEL,id,id))RPCOriginalRSAString)(receiver,selector,input,key);
}
static id RPCRSAData(id receiver, SEL selector, id input, id key) {
    RPCObserveKey(@"encryptData:publicKey:",key);
    return ((id (*)(id,SEL,id,id))RPCOriginalRSAData)(receiver,selector,input,key);
}
static BOOL RPCObserveClassMethod(Class target, SEL selector, IMP replacement, NSUInteger arguments, IMP *original) {
    Method method = target ? class_getClassMethod(target,selector) : NULL;
    if (!method) return NO;
    NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
    if (signature.numberOfArguments != arguments || signature.methodReturnType[0] != '@') return NO;
    for (NSUInteger i=2;i<arguments;i++) if ([signature getArgumentTypeAtIndex:i][0] != '@') return NO;
    *original = method_getImplementation(method);
    method_setImplementation(method,replacement);
    return YES;
}
// A local test profile supplies only the configured account name and its server's
// public key. Credentials stay in the SDK; this adapter retains only one-use RSA
// ciphertexts usable for up to 30 seconds, never plaintext passwords or tokens.
static NSData *RPCEncryptLocalLogin(NSString *value) {
    NSData *plain = [value dataUsingEncoding:NSUTF8StringEncoding];
    if (!plain || plain.length > SecKeyGetBlockSize(RPCLocalLoginKey)-11) return nil;
    CFErrorRef error = NULL;
    CFDataRef encrypted = SecKeyCreateEncryptedData(RPCLocalLoginKey,kSecKeyAlgorithmRSAEncryptionPKCS1,(__bridge CFDataRef)plain,&error);
    if (error) CFRelease(error);
    return CFBridgingRelease(encrypted);
}
static void RPCCaptureLocalLogin(id account, id password) {
    if (!RPCLocalRoutingEnabled || !RPCLocalLoginKey || !RPCLoginLock) return;
    [RPCLoginLock lock];
    @try {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (![account isKindOfClass:NSString.class] || ![password isKindOfClass:NSString.class] ||
            ![account isEqualToString:RPCLocalLoginAccount]) { RPCPendingLogin = nil; return; }
        if (RPCPendingLogin && RPCPendingLoginExpires <= now) RPCPendingLogin = nil;
        if (RPCPendingLogin || RPCLoginBlockedUntil > now) {
            // Concurrent or overlapping SDK attempts cannot borrow credentials.
            RPCPendingLogin = nil; RPCLoginBlockedUntil = now+30;
            RPCRecord(@"local_login_prepare_rejected",@{@"reason":@"overlapping_attempts"});
            return;
        }
        NSData *name = RPCEncryptLocalLogin(account), *secret = RPCEncryptLocalLogin(password);
        if (!name || !secret) { RPCRecord(@"local_login_prepare_rejected",@{@"reason":@"encryption_failed"}); return; }
        RPCPendingLogin = @{@"account":[name base64EncodedStringWithOptions:0],@"password":[secret base64EncodedStringWithOptions:0]};
        RPCPendingLoginExpires = now+30;
        RPCRecord(@"local_login_encrypted",@{@"algorithm":@"RSAES-PKCS1-v1_5",@"ciphertext_bytes":@(secret.length)});
    } @finally { [RPCLoginLock unlock]; }
}
static void RPCLocalPorteLogin(id receiver, SEL selector, id account, id password, id completion) {
    RPCCaptureLocalLogin(account,password);
    ((void (*)(id,SEL,id,id,id))RPCOriginalPorteLogin)(receiver,selector,account,password,completion);
}
static BOOL RPCConfigureLocalLogin(void) {
    if (!RPCLocalRoutingEnabled) return NO;
    if (RPCOriginalPorteLogin) return YES;
    NSData *manifest = [NSData dataWithContentsOfFile:[RPCReportDirectory stringByAppendingPathComponent:@"local-login.json"]];
    if (!manifest || manifest.length > 16384) return NO;
    id profile = [NSJSONSerialization JSONObjectWithData:manifest options:0 error:nil];
    if (![profile isKindOfClass:NSDictionary.class] || ![profile[@"account"] isKindOfClass:NSString.class] ||
        ![profile[@"public_key_sha256"] isKindOfClass:NSString.class] || [profile[@"account"] length] == 0 || [profile[@"account"] length] > 128) return NO;
    NSData *der = [NSData dataWithContentsOfFile:[RPCReportDirectory stringByAppendingPathComponent:@"local-login-public-key.der"]];
    if (!der || der.length > 4096) return NO;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(der.bytes,(CC_LONG)der.length,digest);
    NSMutableString *hex = [NSMutableString new]; for (NSUInteger i=0;i<sizeof(digest);i++) [hex appendFormat:@"%02x",digest[i]];
    if (![hex isEqualToString:profile[@"public_key_sha256"]]) return NO;
    NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeRSA,(__bridge id)kSecAttrKeyClass:(__bridge id)kSecAttrKeyClassPublic};
    CFErrorRef error = NULL;
    SecKeyRef key = SecKeyCreateWithData((__bridge CFDataRef)der,(__bridge CFDictionaryRef)attributes,&error);
    if (error) CFRelease(error);
    if (!key) return NO;
    if (SecKeyGetBlockSize(key) < 128 || SecKeyGetBlockSize(key) > 512 ||
        !SecKeyIsAlgorithmSupported(key,kSecKeyOperationTypeEncrypt,kSecKeyAlgorithmRSAEncryptionPKCS1)) { CFRelease(key); return NO; }
    Class bridge = NSClassFromString(@"_TtC13MHYPorteLogin14MHYPorteBridge");
    SEL selector = NSSelectorFromString(@"loginWithAccount:password:completion:");
    Method method = bridge ? class_getClassMethod(bridge,selector) : NULL;
    NSMethodSignature *signature = method ? [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)] : nil;
    if (signature.numberOfArguments != 5 || signature.methodReturnType[0] != 'v' ||
        [signature getArgumentTypeAtIndex:2][0] != '@' || [signature getArgumentTypeAtIndex:3][0] != '@' ||
        strcmp([signature getArgumentTypeAtIndex:4],"@?") != 0) { CFRelease(key); return NO; }
    RPCLocalLoginKey = key; RPCLocalLoginAccount = [profile[@"account"] copy]; RPCLoginLock = [NSLock new];
    RPCOriginalPorteLogin = method_setImplementation(method,(IMP)RPCLocalPorteLogin);
    RPCRecord(@"local_login_adapter_registered",@{@"public_key_sha256":hex,@"key_bits":@(SecKeyGetBlockSize(key)*8),@"password_verification_bypassed":@NO});
    return YES;
}
static NSData *RPCRewrapLocalLoginBody(NSURL *url, NSData *body) {
    if (!RPCLocalRoutingEnabled || !RPCLoginLock || ![url.scheme isEqual:@"http"] ||
        ![url.host isEqual:@"127.0.0.1"] || ![url.port isEqual:@8088] ||
        ![url.path isEqual:@"/account/ma-cn-passport/app/loginByPassword"] || !body.length || body.length > 65536) return body;
    id parsed = [NSJSONSerialization JSONObjectWithData:body options:NSJSONReadingMutableContainers error:nil];
    if (![parsed isKindOfClass:NSMutableDictionary.class] || ![parsed[@"account"] isKindOfClass:NSString.class] ||
        ![parsed[@"password"] isKindOfClass:NSString.class]) return body;
    [RPCLoginLock lock];
    NSDictionary *pending = RPCPendingLogin;
    RPCPendingLogin = nil;
    BOOL valid = pending && RPCPendingLoginExpires > NSProcessInfo.processInfo.systemUptime &&
        RPCLoginBlockedUntil <= NSProcessInfo.processInfo.systemUptime;
    [RPCLoginLock unlock];
    if (!valid) return body;
    parsed[@"account"] = pending[@"account"]; parsed[@"password"] = pending[@"password"];
    NSData *rewritten = [NSJSONSerialization dataWithJSONObject:parsed options:0 error:nil];
    if (rewritten) RPCRecord(@"local_login_body_prepared",@{@"path":url.path,@"one_use":@YES});
    return rewritten ?: body;
}
// NSURL factory hooks do not see Swift URL / CoreFoundation URL construction.
// Route again at the NSURLSession task boundary, retaining the original request
// method, body, timeout, cache policy and completion/delegate behavior.
static NSURLRequest *RPCRouteRequestOnly(NSURLRequest *request) {
    if (![request isKindOfClass:NSURLRequest.class]) return request;
    NSURL *logicalURL = request.URL;
    NSString *hostHeader = [request valueForHTTPHeaderField:@"Host"].lowercaseString;
    unsigned char address[16];
    if (logicalURL.host.length && RPCVendorHost(hostHeader) && (inet_pton(AF_INET,logicalURL.host.UTF8String,address) == 1 ||
        inet_pton(AF_INET6,logicalURL.host.UTF8String,address) == 1)) {
        NSURLComponents *parts = [NSURLComponents componentsWithURL:logicalURL resolvingAgainstBaseURL:YES];
        parts.host = hostHeader;
        logicalURL = parts.URL ?: logicalURL;
    }
    RPCObserveURL(logicalURL);
    NSURL *rewritten = RPCRewriteURL(logicalURL);
    if ([rewritten isEqual:logicalURL]) return request;
    if ([rewritten isEqual:request.URL]) return request;
    NSMutableURLRequest *copy = [request mutableCopy];
    copy.URL = rewritten;
    // HTTPDNS clients can explicitly set Host. The new destination owns it.
    [copy setValue:nil forHTTPHeaderField:@"Host"];
    RPCRecord(@"request_routed_at_session", @{@"path":logicalURL.path,@"host":logicalURL.host.lowercaseString,
        @"method":request.HTTPMethod ?: @"GET",@"port":@8088});
    return copy;
}
static NSURLRequest *RPCRewriteRequest(NSURLRequest *request) {
    NSURLRequest *routed = RPCRouteRequestOnly(request);
    NSData *body = RPCRewrapLocalLoginBody(routed.URL,routed.HTTPBody);
    if (body == routed.HTTPBody) return routed;
    NSMutableURLRequest *copy = [routed mutableCopy]; copy.HTTPBody = body;
    [copy setValue:nil forHTTPHeaderField:@"Content-Length"];
    return copy;
}
typedef void (^RPCCompletion)(NSData *, NSURLResponse *, NSError *);
static RPCCompletion RPCResponseAudit(NSURL *url, RPCCompletion completion) {
    if (!completion || !RPCLocalRoutingEnabled || ![url.host isEqual:@"127.0.0.1"] ||
        ![url.port isEqual:@8088] || ![RPCRoutePaths() containsObject:url.path]) return completion;
    NSString *path = url.path;
    return ^(NSData *data, NSURLResponse *response, NSError *error) {
        NSMutableDictionary *details = [@{@"path":path,@"error_code":@(error.code)} mutableCopy];
        if ([response isKindOfClass:NSHTTPURLResponse.class]) details[@"http_status"] = @([(NSHTTPURLResponse *)response statusCode]);
        // Numeric result only; never persist response tokens, account data or text.
        if (data.length && data.length <= 1024*1024) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class] && [json[@"retcode"] isKindOfClass:NSNumber.class])
                details[@"retcode"] = json[@"retcode"];
        }
        RPCRecord(@"local_http_result", details);
        completion(data,response,error);
    };
}
static Method RPCOwnMethod(Class cls, SEL selector) {
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls,&count), result = NULL;
    for (unsigned int i=0;i<count;i++) if (method_getName(methods[i]) == selector) { result = methods[i]; break; }
    free(methods);
    return result;
}
static NSUInteger RPCInstallSessionRouting(void) {
    // Real Foundation sessions use a concrete subclass. Initialize it, then patch
    // only method implementations actually owned by NSURLSession subclasses.
    [NSURLSession sharedSession];
    NSURLSession *ephemeral = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    [ephemeral finishTasksAndInvalidate];
    unsigned int count = 0;
    Class *classes = objc_copyClassList(&count);
    NSUInteger installed = 0;
    for (unsigned int i=0;i<count;i++) {
        Class cls = classes[i], parent = cls;
        while (parent && parent != NSURLSession.class) parent = class_getSuperclass(parent);
        if (!parent) continue;
        for (NSString *name in @[@"dataTaskWithRequest:",@"dataTaskWithURL:",
            @"dataTaskWithRequest:completionHandler:",@"dataTaskWithURL:completionHandler:",
            @"uploadTaskWithRequest:fromData:",@"uploadTaskWithRequest:fromData:completionHandler:"]) {
            SEL selector = NSSelectorFromString(name);
            Method method = RPCOwnMethod(cls,selector);
            if (!method) continue;
            BOOL upload = [name hasPrefix:@"upload"], withCompletion = [name hasSuffix:@"completionHandler:"], isURL = [name hasPrefix:@"dataTaskWithURL:"];
            NSUInteger arguments = 3 + (upload ? 1 : 0) + (withCompletion ? 1 : 0);
            NSMethodSignature *signature = [NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(method)];
            BOOL valid = signature.numberOfArguments == arguments && signature.methodReturnType[0] == '@';
            for (NSUInteger a=2;valid && a<arguments;a++) valid &= [signature getArgumentTypeAtIndex:a][0] == '@';
            if (!valid) continue;
            IMP original = method_getImplementation(method), replacement = NULL;
            if (upload && withCompletion) {
                replacement = imp_implementationWithBlock(^id(id receiver, NSURLRequest *request, NSData *body, RPCCompletion completion) {
                    NSURLRequest *routed = RPCRouteRequestOnly(request);
                    NSData *encryptedBody = RPCRewrapLocalLoginBody(routed.URL,body);
                    if (encryptedBody != body) {
                        NSMutableURLRequest *copy = [routed mutableCopy]; [copy setValue:nil forHTTPHeaderField:@"Content-Length"]; routed = copy;
                    }
                    return ((id (*)(id,SEL,id,id,id))original)(receiver,selector,routed,encryptedBody,RPCResponseAudit(routed.URL,completion));
                });
            } else if (upload) {
                replacement = imp_implementationWithBlock(^id(id receiver, NSURLRequest *request, NSData *body) {
                    NSURLRequest *routed = RPCRouteRequestOnly(request);
                    NSData *encryptedBody = RPCRewrapLocalLoginBody(routed.URL,body);
                    if (encryptedBody != body) {
                        NSMutableURLRequest *copy = [routed mutableCopy]; [copy setValue:nil forHTTPHeaderField:@"Content-Length"]; routed = copy;
                    }
                    return ((id (*)(id,SEL,id,id))original)(receiver,selector,routed,encryptedBody);
                });
            } else if (withCompletion) {
                replacement = imp_implementationWithBlock(^id(id receiver, id input, RPCCompletion completion) {
                    id routed = isURL ? RPCRewriteURL(input) : RPCRewriteRequest(input);
                    NSURL *url = isURL ? routed : [(NSURLRequest *)routed URL];
                    return ((id (*)(id,SEL,id,id))original)(receiver,selector,routed,RPCResponseAudit(url,completion));
                });
            } else {
                replacement = imp_implementationWithBlock(^id(id receiver, id input) {
                    return ((id (*)(id,SEL,id))original)(receiver,selector,isURL ? RPCRewriteURL(input) : RPCRewriteRequest(input));
                });
            }
            method_setImplementation(method,replacement);
            installed++;
        }
    }
    free(classes);
    RPCRecord(@"session_routing_registered", @{@"implementations":@(installed)});
    return installed;
}
static void RPCLaunched(void) {
    RPCRecord(@"application_launched", @{@"version":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"server_enabled":@(RPCPreparedServer)});
    if (!RPCPreparedServer) return;
    NSError *error = nil;
    NSString *resources = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"LocalRuntime"];
    RPCHostStarted = RPHostStart(RPCServerDirectory,resources,YES,&error);
    RPCRecord(@"host_bootstrap", @{@"accepted":@(RPCHostStarted),@"error":error.localizedDescription ?: @"",
        @"current_directory":NSFileManager.defaultManager.currentDirectoryPath ?: @"",
        @"expected_directory":[RPCServerDirectory stringByAppendingPathComponent:@"server"],
        @"directory_identity_matches":@(RPDirectoriesMatch(".", [RPCServerDirectory stringByAppendingPathComponent:@"server"].fileSystemRepresentation))});
    if (RPCHostStarted) [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
        NSDictionary *snapshot = RPHostSnapshot();
        dispatch_async(RPCReportQueue, ^{ RPCWrite(@"embedded-host.json",snapshot); });
    }];
}
__attribute__((constructor)) static void RPCInitialize(void) {
    @autoreleasepool {
        RPCConfiguration = [NSDictionary dictionaryWithContentsOfFile:
            [NSBundle.mainBundle pathForResource:@"RuntimeIntegration" ofType:@"plist"]];
        NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
        NSString *expected = RPCConfiguration[@"BundlePrefix"];
        if (![expected isKindOfClass:NSString.class] || ![expected hasPrefix:@"local.astaps."] ||
            !([bundle isEqualToString:expected] || [bundle hasPrefix:[expected stringByAppendingString:@"."]])) return;
        if (![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] isEqual:RPCConfiguration[@"ClientVersion"]] ||
            ![[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] isEqual:RPCConfiguration[@"ClientBuild"]]) return;
        NSString *documents = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        RPCReportDirectory = [documents stringByAppendingPathComponent:@"RuntimeIntegration"];
        [NSFileManager.defaultManager createDirectoryAtPath:RPCReportDirectory withIntermediateDirectories:YES attributes:nil error:nil];
        RPCReportQueue = dispatch_queue_create("local.runtime.integration.reports",DISPATCH_QUEUE_SERIAL);
        RPCEvents = [NSMutableArray new]; RPCSeen = [NSMutableSet new];
        RPCLocalRoutingEnabled = [RPCConfiguration[@"LocalRoutingEnabled"] isEqual:@YES] ||
            [NSFileManager.defaultManager fileExistsAtPath:[RPCReportDirectory stringByAppendingPathComponent:@"enable-routing.txt"]];
        RPCRecord(@"library_loaded", @{@"bundle_id":bundle,@"mode":RPCLocalRoutingEnabled ? @"loopback" : @"observe",@"tls_validation_changed":@NO});
        RPCObserveClassMethod(NSURL.class,@selector(URLWithString:),(IMP)RPCURL,3,&RPCOriginalURL);
        RPCObserveClassMethod(NSURL.class,@selector(URLWithString:relativeToURL:),(IMP)RPCRelativeURL,4,&RPCOriginalRelativeURL);
        RPCInstallSessionRouting();
        RPCConfigureLocalLogin();
        Class crypto = NSClassFromString(@"MiHoYoRSAEncryptor");
        RPCObserveClassMethod(crypto,NSSelectorFromString(@"encryptString:publicKey:"),(IMP)RPCRSAString,4,&RPCOriginalRSAString);
        RPCObserveClassMethod(crypto,NSSelectorFromString(@"encryptData:publicKey:"),(IMP)RPCRSAData,4,&RPCOriginalRSAData);
        RPCRecord(@"observers_registered", @{@"url":@(RPCOriginalURL != NULL),@"relative_url":@(RPCOriginalRelativeURL != NULL),
            @"sdk_string":@(RPCOriginalRSAString != NULL),@"sdk_data":@(RPCOriginalRSAData != NULL)});
        RPCServerDirectory = [documents stringByAppendingPathComponent:@"LocalServer"];
        // Optional same-process trial: enabled only by an explicit local marker and
        // already supplied private payload. Set cwd during loader initialization,
        // before UIApplicationMain; coexistence with the host engine is still a test.
        NSString *marker = [RPCServerDirectory stringByAppendingPathComponent:@"enable-server.txt"];
        NSString *payload = [RPCServerDirectory stringByAppendingPathComponent:@"server-payload.zip"];
        NSString *checksum = [RPCServerDirectory stringByAppendingPathComponent:@"server-payload.sha256"];
        if ([NSFileManager.defaultManager fileExistsAtPath:marker] &&
            [NSFileManager.defaultManager fileExistsAtPath:payload] &&
            [NSFileManager.defaultManager fileExistsAtPath:checksum]) {
            NSString *working = [RPCServerDirectory stringByAppendingPathComponent:@"server"];
            [NSFileManager.defaultManager createDirectoryAtPath:working withIntermediateDirectories:YES attributes:nil error:nil];
            RPCPreparedServer = chdir(working.fileSystemRepresentation) == 0;
            RPCRecord(@"prelaunch_server_directory", @{@"prepared":@(RPCPreparedServer),
                @"current_directory":NSFileManager.defaultManager.currentDirectoryPath ?: @"",
                @"expected_directory":working,
                @"directory_identity_matches":@(RPDirectoriesMatch(".", working.fileSystemRepresentation))});
        }
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidFinishLaunchingNotification object:nil
            queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
                dispatch_async(dispatch_get_main_queue(), ^{ RPCLaunched(); });
            }];
        for (NSString *name in @[UIApplicationDidEnterBackgroundNotification,UIApplicationWillEnterForegroundNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification *notification) {
                    RPCRecord(@"lifecycle", @{@"name":notification.name});
                    if (RPCHostStarted) RPHostSceneEvent(notification.name);
                }];
        }
    }
}
#else
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
#include <dlfcn.h>

static NSArray<NSString *> *RPRuntimeMemoryArguments(BOOL server) {
    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithObject:server ? @"-Xmx2048m" : @"-Xmx256m"];
#ifdef RP_EMBEDDED_LIBRARY
    // Class metadata normally reserves 1 GiB of virtual addresses. Bound that
    // reservation when coexisting with a host engine and WebKit; keep heap size.
    [arguments addObject:@"-XX:CompressedClassSpaceSize=128m"];
#endif
    return arguments;
}

#ifdef RP_EMBEDDED_LIBRARY
// The pinned STATIC_BUILD JVM calls dlopen(NULL, RTLD_FIRST) for its native
// libraries. In a dylib host that incorrectly searches the main executable.
// Bind ONLY this image's static references to a hidden wrapper. Other images
// still bind libSystem's dlopen; no dyld interposition or global symbol override.
__attribute__((visibility("hidden")))
void *RPEmbeddedDlopen(const char *path, int mode) __asm__("_dlopen");
void *RPEmbeddedDlopen(const char *path, int mode) {
    typedef void *(*Loader)(const char *, int);
    static Loader systemLoader;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ systemLoader = (Loader)dlsym(RTLD_DEFAULT,"dlopen"); });
    if (!systemLoader) return NULL;
    if (path == NULL && (mode & RTLD_FIRST)) {
        Dl_info image = {0};
        if (!dladdr((const void *)&JNI_CreateJavaVM,&image) || !image.dli_fname) return NULL;
        return systemLoader(image.dli_fname,mode | RTLD_NOLOAD);
    }
    return systemLoader(path,mode);
}
#endif

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
static BOOL ValidServiceSnapshot(id json, NSInteger status, NSString *previousStart, long long previousTick) {
    if (status != 200 || ![json isKindOfClass:NSDictionary.class] || ![json[@"retcode"] isEqual:@0]) return NO;
    id game = json[@"game"]; if (![game isKindOfClass:NSDictionary.class]) return NO;
    id tick = game[@"tick"]; if (![tick isKindOfClass:NSDictionary.class]) return NO;
    id start = game[@"startedAt"], count = tick[@"completedCount"];
    if (![start isKindOfClass:NSString.class] || ![start length] || ![count isKindOfClass:NSNumber.class] || [count longLongValue] < 0) return NO;
    return !previousStart || ([start isEqualToString:previousStart] && [count longLongValue] > previousTick);
}
static void CheckSnapshotParser(void) {
    NSDictionary *valid = @{@"retcode":@0, @"game":@{@"startedAt":@"test-start",@"tick":@{@"completedCount":@2}}};
    BOOL passed = ValidServiceSnapshot(valid,200,nil,-1) && ValidServiceSnapshot(valid,200,@"test-start",1) &&
        !ValidServiceSnapshot(valid,200,@"different-start",1) && !ValidServiceSnapshot(valid,200,@"test-start",2) &&
        !ValidServiceSnapshot(@[],200,nil,-1) && !ValidServiceSnapshot(valid,503,nil,-1) &&
        !ValidServiceSnapshot(@{@"retcode":@0,@"game":@{}},200,nil,-1);
    WriteJSON(@"background-parser-tests.json", @{@"passed":@(passed),@"cases":@7,@"system_background_execution_tested":@NO});
}

// A finite diagnostic job, not a permanent keep-alive. All state is main-queue owned.
API_AVAILABLE(ios(26.0))
@interface RPBackgroundTrial : NSObject
@property(nonatomic,strong) BGContinuedProcessingTask *task;
@property(nonatomic,strong) NSURLSessionDataTask *request;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,strong) NSMutableArray *samples;
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,copy) NSString *runIdentifier;
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
        value.message = @"服务端就绪后，可开始一次 10 分钟的后台测试。";
        NSData *data = [NSData dataWithContentsOfFile:[Documents() stringByAppendingPathComponent:@"background-trial.json"]];
        id previous = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([previous isKindOfClass:NSDictionary.class] && [previous[@"message"] isKindOfClass:NSString.class]) {
            BOOL unfinished = [@[@"running",@"submitting"] containsObject:previous[@"state"]];
            value.message = unfinished ? @"上次测试未完成；旧记录已保留，可重新开始测试。" : [@"上次结果：" stringByAppendingString:previous[@"message"]];
        }
    });
    return value;
}
- (void)save {
    NSMutableDictionary *report = [@{@"schema":@2, @"state":self.state, @"message":self.message,
        @"identifier":self.identifier ?: @"", @"pid":@(getpid()), @"target_samples":@120,
        @"run_id":self.runIdentifier ?: @"",
        @"successful_samples":@(self.successful), @"background_samples":@(self.backgroundSamples),
        @"elapsed_seconds":@(self.began ? NSProcessInfo.processInfo.systemUptime-self.began : 0),
        @"samples":self.samples ?: @[], @"native_game_login_verified":@NO} mutableCopy];
    WriteJSON(@"background-trial.json", report);
    [NSNotificationCenter.defaultCenter postNotificationName:RuntimeChanged object:self];
}
- (void)registerTask {
    NSAssert(NSThread.isMainThread, @"Register on main queue during launch");
    if (self.registered) return;
    // Register and submit the same concrete identifier. A wildcard is a declaration,
    // not the identity of the task launched by the system.
    self.identifier = [NSBundle.mainBundle.bundleIdentifier stringByAppendingString:@".servertrial.session"];
    NSArray *permitted = [NSBundle.mainBundle objectForInfoDictionaryKey:@"BGTaskSchedulerPermittedIdentifiers"];
    if (![permitted containsObject:self.identifier]) {
        self.state = @"signing_configuration_mismatch";
        self.message = @"安装包的后台标识未与签名匹配，需要修正安装包。"; [self saveRegistration]; return;
    }
    self.registered = [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:self.identifier usingQueue:dispatch_get_main_queue() launchHandler:^(BGTask *task) {
        RPBackgroundTrial *trial = RPBackgroundTrial.shared;
        if (![task isKindOfClass:BGContinuedProcessingTask.class] || !trial.pending ||
            ![task.identifier isEqualToString:trial.identifier]) { [task setTaskCompletedWithSuccess:NO]; return; }
        trial.pending = NO; trial.task = (BGContinuedProcessingTask *)task;
        trial.state = @"running"; trial.began = NSProcessInfo.processInfo.systemUptime;
        trial.task.progress.totalUnitCount = 120;
        __weak BGContinuedProcessingTask *runningTask = trial.task;
        trial.task.expirationHandler = ^{
            dispatch_async(dispatch_get_main_queue(), ^{
                if (runningTask && RPBackgroundTrial.shared.task == runningTask)
                    [RPBackgroundTrial.shared finish:@"expired_or_system_cancelled" success:NO message:@"系统结束了后台测试，已保存完成的记录。"];
            });
        };
        trial.message = @"系统已接收测试。可切到游戏；10 分钟后查看结果。";
        Lifecycle(@"continued_task_started"); [trial save];
        trial.timer = [NSTimer scheduledTimerWithTimeInterval:5 target:trial selector:@selector(sample) userInfo:nil repeats:YES];
    }];
    if (!self.registered) { self.state = @"registration_failed"; self.message = @"系统未能注册后台测试。"; }
    else { self.state = @"registered"; self.message = @"后台测试已注册；服务端就绪后可开始。"; }
    [self saveRegistration];
}
- (void)saveRegistration {
    WriteJSON(@"background-registration.json", @{@"registered":@(self.registered), @"state":self.state,
        @"bundle_id":NSBundle.mainBundle.bundleIdentifier ?: @"", @"message":self.message,
        @"task_identifier":self.identifier ?: @"", @"pid":@(getpid()),
        @"build":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"permitted_identifiers":[NSBundle.mainBundle objectForInfoDictionaryKey:@"BGTaskSchedulerPermittedIdentifiers"] ?: @[],
        @"registered_at":@([NSDate.date timeIntervalSince1970])});
    [NSNotificationCenter.defaultCenter postNotificationName:RuntimeChanged object:self];
}
- (void)submit {
    if (!self.registered || self.task || self.pending || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    // A separate run token prevents a cancelled HTTP callback from modifying a new run.
    self.runIdentifier = NSUUID.UUID.UUIDString;
    NSString *previous = [Documents() stringByAppendingPathComponent:@"background-trial.json"];
    if ([NSFileManager.defaultManager fileExistsAtPath:previous]) {
        NSString *history = [Documents() stringByAppendingPathComponent:@"background-history"];
        [NSFileManager.defaultManager createDirectoryAtPath:history withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager copyItemAtPath:previous toPath:[history stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".json"]] error:nil];
    }
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
    if (self.pending) [BGTaskScheduler.sharedScheduler cancelTaskRequestWithIdentifier:self.identifier];
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
    NSString *run = self.runIdentifier;
    BOOL background = UIApplication.sharedApplication.applicationState == UIApplicationStateBackground;
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:
        [NSString stringWithFormat:@"http://127.0.0.1:8088/api/status?backgroundTrial=%@&sample=%lu",run,(unsigned long)self.samples.count]]];
    request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData; request.timeoutInterval = 3;
    self.request = [[NSURLSession sharedSession] dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!self.task || ![self.runIdentifier isEqualToString:run]) return;
            self.request = nil;
            NSDictionary *game = [json isKindOfClass:NSDictionary.class] && [json[@"game"] isKindOfClass:NSDictionary.class] ? json[@"game"] : nil;
            NSDictionary *tick = [game[@"tick"] isKindOfClass:NSDictionary.class] ? game[@"tick"] : nil;
            NSString *started = [game[@"startedAt"] isKindOfClass:NSString.class] ? game[@"startedAt"] : nil;
            NSNumber *completed = [tick[@"completedCount"] isKindOfClass:NSNumber.class] ? tick[@"completedCount"] : nil;
            BOOL passed = !error && ValidServiceSnapshot(json,[(NSHTTPURLResponse *)response statusCode],self.serverStart,self.previousTick);
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
        @"virtual_size_bytes": available ? @(memory.virtual_size) : NSNull.null,
        @"resident_size_bytes": available ? @(memory.resident_size) : NSNull.null,
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
#ifdef RP_EMBEDDED_LIBRARY
            void *nativeHandle = RPEmbeddedDlopen(NULL,RTLD_FIRST);
            NSMutableDictionary *lookupChecks = [NSMutableDictionary new];
            BOOL lookupPassed = nativeHandle != NULL;
            for (NSString *symbol in @[@"Java_java_lang_Class_registerNatives",@"Java_java_lang_System_registerNatives",@"JNI_OnLoad_java",@"VerifyClassForMajorVersion"]) {
                BOOL found = nativeHandle && dlsym(nativeHandle,symbol.UTF8String) != NULL;
                lookupChecks[symbol] = @(found); lookupPassed &= found;
            }
            if (nativeHandle) dlclose(nativeHandle);
            WriteJSON(@"native-lookup.json",@{@"passed":@(lookupPassed),@"checks":lookupChecks});
            if (!lookupPassed) { [self updatePhase:@"failed" status:@"内嵌运行环境缺少原生函数"]; return; }
#endif
            fprintf(stderr, "Runtime: starting JNI_CreateJavaVM, mode=%s\n", server ? "server" : "probe");
            NSMutableArray<NSString *> *arguments = [@[
                [@"-Djava.home=" stringByAppendingString:runtimeHome],
                [@"-Djava.class.path=" stringByAppendingString:[bundle stringByAppendingPathComponent:@"DeviceProbe.jar"]],
                [@"-Duser.dir=" stringByAppendingString:working], @"-Djava.awt.headless=true", @"-Xint",
                @"-Dfile.encoding=UTF-8",
                @"-Dlogback.configurationFile=prototype-logback.xml", @"-Diphone.prototype.verify=true",
                [@"--patch-module=java.base=" stringByAppendingString:[bundle stringByAppendingPathComponent:@"RuntimePatch.jar"]]
            ] mutableCopy];
            [arguments addObjectsFromArray:RPRuntimeMemoryArguments(server)];
            JavaVMOption options[16] = {0};
            if (arguments.count > sizeof(options)/sizeof(options[0])) {
                [self updatePhase:@"failed" status:@"运行环境参数数量异常"]; return;
            }
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
    else if (server && !RPDirectoriesMatch(".", [documents stringByAppendingPathComponent:@"server"].fileSystemRepresentation))
        reason = @"The process working directory differs from the prepared server directory. Relative java.io paths require the same filesystem directory; no working-directory change was made.";
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
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    UILabel *subtitle = [self label:[@"iPhone 运行验证 · " stringByAppendingString:version] style:UIFontTextStyleSubheadline]; subtitle.textColor = UIColor.secondaryLabelColor;
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
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--probe-auto-run"]) CheckSnapshotParser();
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
#endif // RP_CLIENT_FIXTURE / RP_CLIENT_OBSERVER_ONLY
