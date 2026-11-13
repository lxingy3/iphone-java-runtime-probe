#!/usr/bin/env bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'This native device build requires macOS and the Apple iPhoneOS SDK.' >&2
  exit 2
fi
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'This pinned experiment currently requires an Apple Silicon Mac.' >&2
  exit 2
fi
project_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_root"
if [[ "${PROBE_REBUILD_RUNTIME:-false}" == true ]]; then unset PROBE_RUNTIME_ARCHIVE; fi
mkdir -p build
exec > >(tee build/build.log) 2>&1
# Exercise the exact guard used by the embedding API before building the app.
python3 - <<'PY'
import json,pathlib,re,subprocess
source=pathlib.Path('App/main.m').read_text()
guard=re.search(r'static int RPDirectoriesMatch\(.*?\n\}',source,re.S).group(0)
test=r'''
#include <assert.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
GUARD
int main(void) {
    char root[]="/tmp/runtime-directory-XXXXXX", old[PATH_MAX], actual[PATH_MAX];
    char real[PATH_MAX], alias[PATH_MAX], other[PATH_MAX], file[PATH_MAX], missing[PATH_MAX];
    assert(getcwd(old,sizeof(old)) && mkdtemp(root));
    snprintf(real,sizeof(real),"%s/real",root); snprintf(alias,sizeof(alias),"%s/alias",root);
    snprintf(other,sizeof(other),"%s/other",root); snprintf(file,sizeof(file),"%s/file",root);
    snprintf(missing,sizeof(missing),"%s/missing",root);
    assert(mkdir(real,0700)==0 && mkdir(other,0700)==0 && symlink(real,alias)==0);
    FILE *f=fopen(file,"w"); assert(f); fclose(f);
    assert(chdir(alias)==0 && getcwd(actual,sizeof(actual)));
    assert(strcmp(actual,alias)!=0); // Reproduces the old text-comparison rejection.
    assert(RPDirectoriesMatch(".",alias));
    assert(RPDirectoriesMatch(real,alias));
    assert(!RPDirectoriesMatch(".",other));
    assert(!RPDirectoriesMatch(".",missing));
    assert(!RPDirectoriesMatch(file,file));
    assert(chdir(old)==0);
    assert(unlink(alias)==0 && unlink(file)==0 && rmdir(real)==0 && rmdir(other)==0 && rmdir(root)==0);
    puts("directory identity regression: PASS (alias, changed directory, missing path, regular file)");
}
'''.replace('GUARD',guard)
pathlib.Path('build/directory-identity-test.c').write_text(test)
subprocess.run(['xcrun','clang','-Wall','-Wextra','-Werror','build/directory-identity-test.c','-o','build/directory-identity-test'],check=True)
subprocess.run(['build/directory-identity-test'],check=True)
pathlib.Path('build/directory-identity-test.json').write_text(json.dumps({'passed':True,'legacy_alias_rejection_reproduced':True,'same_directory_alias_accepted':True,'different_directory_rejected':True,'missing_path_rejected':True,'regular_file_rejected':True,'actual_game_tested':False},indent=2))
PY
# Exercise the production NSURLSession boundary with URLs constructed through
# CoreFoundation (the factory-only observer misses this path). The legacy run
# creates/cancels tasks only; it never sends a request to an external server.
python3 - <<'PY'
import http.server,json,pathlib,subprocess,threading
source=pathlib.Path('App/main.m').read_text()
begin=source.index('static NSString *RPCReportDirectory;')
end=source.index('static void RPCLaunched(void)',begin)
production=source[begin:end]
harness=r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <assert.h>
PRODUCTION
static NSURL *FixtureURL(NSString *text) {
    return CFBridgingRelease(CFURLCreateWithString(kCFAllocatorDefault,(__bridge CFStringRef)text,NULL));
}
static NSDictionary *FetchRegionFixture(NSURLSession *session, NSURL *url) {
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *json = nil;
    __block BOOL success = NO;
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        success = !error && [(NSHTTPURLResponse *)response statusCode] == 200;
        dispatch_semaphore_signal(done);
    }];
    [task resume];
    assert(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0 && success);
    return json;
}
int main(int argc,char **argv) { @autoreleasepool {
    BOOL legacy = argc > 1 && strcmp(argv[1],"legacy")==0;
    RPCLocalRoutingEnabled = YES;
    RPCReportDirectory = [@"build/RuntimeHostKit" stringByAppendingPathComponent:legacy ? @"legacy-routing" : @"session-routing"];
    [NSFileManager.defaultManager createDirectoryAtPath:RPCReportDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    RPCReportQueue = dispatch_queue_create("fixture.routing.logs",DISPATCH_QUEUE_SERIAL);
    RPCEvents = [NSMutableArray new]; RPCSeen = [NSMutableSet new];
    RPCObserveClassMethod(NSURL.class,@selector(URLWithString:),(IMP)RPCURL,3,&RPCOriginalURL);
    RPCObserveClassMethod(NSURL.class,@selector(URLWithString:relativeToURL:),(IMP)RPCRelativeURL,4,&RPCOriginalRelativeURL);
    if (!legacy) assert(RPCInstallSessionRouting() > 0);
    NSURL *url = FixtureURL(@"https://passport-api.mihoyo.com/account/ma-cn-passport/app/loginByPassword?encoded=a%2Bb%2Fc%25&nonce=FIXTURE_SECRET");
    assert([url.host isEqual:@"passport-api.mihoyo.com"]);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:7];
    request.HTTPMethod = @"POST";
    request.HTTPBody = [@"FIXTURE_BODY_SECRET" dataUsingEncoding:NSUTF8StringEncoding];
    [request setValue:@"application/octet-stream" forHTTPHeaderField:@"Content-Type"];
    [request setValue:@"FIXTURE_HEADER_SECRET" forHTTPHeaderField:@"X-Fixture"];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.ephemeralSessionConfiguration];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSUInteger completions = 0;
    __block BOOL httpPassed = NO;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request completionHandler:^(NSData *data,NSURLResponse *response,NSError *error) {
        completions++;
        NSDictionary *body = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        httpPassed = !error && [(NSHTTPURLResponse *)response statusCode]==200 && [body[@"fixture_passed"] isEqual:@YES];
        dispatch_semaphore_signal(done);
    }];
    NSString *expected = legacy ? @"passport-api.mihoyo.com" : @"127.0.0.1";
    assert([task.currentRequest.URL.host isEqual:expected]);
    assert([request.URL.host isEqual:@"passport-api.mihoyo.com"]);
    assert([task.currentRequest.HTTPMethod isEqual:request.HTTPMethod]);
    assert([task.currentRequest.HTTPBody isEqual:request.HTTPBody]);
    assert(task.currentRequest.timeoutInterval == request.timeoutInterval);
    assert(task.currentRequest.cachePolicy == request.cachePolicy);
    if (legacy) {
        [task cancel];
    } else {
        assert([task.currentRequest.URL.absoluteString isEqual:@"http://127.0.0.1:8088/account/ma-cn-passport/app/loginByPassword?encoded=a%2Bb%2Fc%25&nonce=FIXTURE_SECRET"]);
        [task resume];
        assert(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
        assert(httpPassed && completions==1);
        NSArray *tasks = @[[session dataTaskWithRequest:request],
            [session dataTaskWithURL:url],
            [session dataTaskWithURL:url completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) {}],
            [session uploadTaskWithRequest:request fromData:request.HTTPBody],
            [session uploadTaskWithRequest:request fromData:request.HTTPBody completionHandler:^(NSData *d,NSURLResponse *r,NSError *e) {}],
            [NSURLSession.sharedSession dataTaskWithRequest:request]];
        for (NSURLSessionTask *other in tasks) { assert([other.currentRequest.URL.host isEqual:@"127.0.0.1"]); [other cancel]; }
        NSMutableURLRequest *dnsRequest = [request mutableCopy];
        dnsRequest.URL = FixtureURL(@"https://192.0.2.1/account/ma-cn-passport/app/loginByPassword");
        [dnsRequest setValue:@"passport-api.mihoyo.com" forHTTPHeaderField:@"Host"];
        NSURLSessionTask *dnsTask = [session dataTaskWithRequest:dnsRequest];
        assert([dnsTask.currentRequest.URL.host isEqual:@"127.0.0.1"] && ![dnsTask.currentRequest valueForHTTPHeaderField:@"Host"]);
        [dnsTask cancel];
        for (NSString *negative in @[@"https://example.test/account/ma-cn-passport/app/loginByPassword",
            @"https://passport-api.mihoyo.com.evil.test/account/ma-cn-passport/app/loginByPassword",
            @"https://autopatchcn.yuanshen.com/client/data.zip",@"https://passport-api.mihoyo.com/private-account-path",
            @"https://passport-api.mihoyo.com:444/account/ma-cn-passport/app/loginByPassword"]) {
            NSURLSessionTask *other = [session dataTaskWithURL:FixtureURL(negative)];
            assert([other.currentRequest.URL.absoluteString isEqual:negative]); [other cancel];
        }
        NSURL *region = FixtureURL(@"https://cngfdispatch.yuanshen.com/query_cur_region?version=CNRELiOS7.2.0&key_id=2&platform=3&dispatchSeed=FIXTURE_DISPATCH_SECRET&encoded=a%2Bb%2Fc%25");
        RPCConfiguration = @{};
        NSDictionary *missing = FetchRegionFixture(session,region);
        assert([missing[@"retcode"] isEqual:@0] && !missing[@"content"] && !missing[@"sign"]);
        RPCConfiguration = @{@"LocalRegionName":@"fixture_region"};
        NSDictionary *mapped = FetchRegionFixture(session,region);
        assert([mapped[@"fixture_passed"] isEqual:@YES] && [mapped[@"content"] length] && [mapped[@"sign"] length]);
        assert([region.host isEqual:@"cngfdispatch.yuanshen.com"] && [region.path isEqual:@"/query_cur_region"]);
        NSURL *alreadyLocal = FixtureURL(@"http://127.0.0.1:8088/query_cur_region?encoded=a%2Bb%2Fc%25");
        assert([RPCRewriteURL(alreadyLocal).absoluteString isEqual:@"http://127.0.0.1:8088/query_cur_region/fixture_region?encoded=a%2Bb%2Fc%25"]);
        RPCConfiguration = @{@"LocalRegionName":@"../escape"};
        assert(!RPCConfiguredRegionPath() && [RPCRewriteURL(region).path isEqual:@"/query_cur_region"]);
        RPCConfiguration = @{@"LocalRegionName":@"fixture_region"};
        [[NSJSONSerialization dataWithJSONObject:@{@"passed":@YES,@"legacy_empty_dispatch_reproduced":@YES,
            @"configured_region_response_received":@YES,@"encoded_query_preserved":@YES,@"input_url_unmodified":@YES,
            @"already_local_bare_path_mapped":@YES,@"invalid_region_name_rejected":@YES,@"real_client_signature_verified":@NO}
            options:NSJSONWritingPrettyPrinted error:nil] writeToFile:@"build/RuntimeHostKit/region-routing-regression.json" atomically:YES];
        RPCLocalRoutingEnabled = NO;
        NSURLSessionTask *disabled = [session dataTaskWithRequest:request];
        assert([disabled.currentRequest.URL.host isEqual:@"passport-api.mihoyo.com"]); [disabled cancel];
    }
    dispatch_sync(RPCReportQueue,^{});
    NSString *raw = [NSString stringWithContentsOfFile:[RPCReportDirectory stringByAppendingPathComponent:@"client-observations.json"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    for (NSString *secret in @[@"FIXTURE_SECRET",@"FIXTURE_BODY_SECRET",@"FIXTURE_HEADER_SECRET",@"FIXTURE_RESPONSE_SECRET",@"FIXTURE_DISPATCH_SECRET",@"encoded=",@"nonce="])
        assert(![raw containsString:secret]);
    NSDictionary *report = @{@"passed":@YES,@"legacy_factory_bypass_reproduced":@(legacy),@"loopback_http_verified":@(!legacy && httpPassed),
        @"request_body_method_query_preserved":@YES,@"input_request_unmodified":@YES,@"credentials_or_tokens_logged":@NO,
        @"session_variants_tested":legacy ? @0 : @7,@"actual_game_tested":@NO};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[@"build/RuntimeHostKit" stringByAppendingPathComponent:legacy ? @"request-boundary-legacy.json" : @"request-boundary-regression.json"] atomically:YES];
    [session invalidateAndCancel];
    puts(legacy ? "factory-only bypass reproduced without network traffic" : "request boundary regression: PASS");
    return 0;
} }
'''.replace('PRODUCTION',production)
pathlib.Path('build/RuntimeHostKit').mkdir(exist_ok=True)
pathlib.Path('build/request-boundary-test.m').write_text(harness)
subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation','-framework','Security','-Wno-deprecated-declarations','build/request-boundary-test.m','-o','build/request-boundary-test'],check=True)
subprocess.run(['build/request-boundary-test','legacy'],check=True,timeout=20)
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        expected='/query_cur_region/fixture_region?version=CNRELiOS7.2.0&key_id=2&platform=3&dispatchSeed=FIXTURE_DISPATCH_SECRET&encoded=a%2Bb%2Fc%25'
        value={'retcode':0,'data':{}}
        if self.path==expected:
            value={'content':'Zml4dHVyZS1yZWdpb24=','sign':'Zml4dHVyZS1zaWduYXR1cmU=','fixture_passed':True}
        data=json.dumps(value).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length','0')))
        passed=(self.path=='/account/ma-cn-passport/app/loginByPassword?encoded=a%2Bb%2Fc%25&nonce=FIXTURE_SECRET'
            and body==b'FIXTURE_BODY_SECRET' and self.headers.get('X-Fixture')=='FIXTURE_HEADER_SECRET')
        data=json.dumps({'retcode':0,'fixture_passed':passed,'token':'FIXTURE_RESPONSE_SECRET'}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=http.server.ThreadingHTTPServer(('127.0.0.1',8088),Handler)
threading.Thread(target=server.serve_forever,daemon=True).start()
try: subprocess.run(['build/request-boundary-test','fixed'],check=True,timeout=30)
finally: server.shutdown();server.server_close()
PY
# Reproduce the SDK-key mismatch through the real bridge and task-boundary code.
# The mock backend decrypts the on-wire RSA fields and verifies the password; a
# wrong password must remain rejected. The generated fixture private key is kept
# outside every uploaded artifact directory and is removed even if the test fails.
python3 - <<'PY'
import base64,http.server,json,pathlib,subprocess,threading
source=pathlib.Path('App/main.m').read_text()
begin=source.index('static NSString *RPCReportDirectory;')
production=source[begin:source.index('static void RPCLaunched(void)',begin)]
harness=r'''
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <Security/Security.h>
#include <CommonCrypto/CommonDigest.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <assert.h>
PRODUCTION
static BOOL FixtureUpload;
static NSUInteger FixtureOriginalCalls;
static NSString *FixtureExpectedAccount, *FixtureExpectedPassword;
static NSData *FixtureSDKBody(void) {
    return [NSJSONSerialization dataWithJSONObject:@{@"account":@"SDK_CIPHERTEXT_ACCOUNT",@"password":@"SDK_CIPHERTEXT_PASSWORD",@"extra":@{@"preserved":@YES}} options:0 error:nil];
}
static NSURL *FixtureURL(NSString *value) {
    return CFBridgingRelease(CFURLCreateWithString(kCFAllocatorDefault,(__bridge CFStringRef)value,NULL));
}
@interface _TtC13MHYPorteLogin14MHYPorteBridge : NSObject
+ (void)loginWithAccount:(NSString *)account password:(NSString *)password completion:(void (^)(NSInteger))completion;
@end
@implementation _TtC13MHYPorteLogin14MHYPorteBridge
+ (void)loginWithAccount:(NSString *)account password:(NSString *)password completion:(void (^)(NSInteger))completion {
    FixtureOriginalCalls++;
    assert([account isEqual:FixtureExpectedAccount] && [password isEqual:FixtureExpectedPassword]);
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:FixtureURL(@"https://passport-api.mihoyo.com/account/ma-cn-passport/app/loginByPassword?fixture=1")];
    request.HTTPMethod = @"POST";
    NSData *body = FixtureSDKBody();
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"%lu",(unsigned long)body.length] forHTTPHeaderField:@"Content-Length"];
    RPCCompletion handler = ^(NSData *data, NSURLResponse *response, NSError *error) {
        assert(!error && [(NSHTTPURLResponse *)response statusCode]==200);
        NSDictionary *answer = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        assert([answer[@"retcode"] isKindOfClass:NSNumber.class]);
        completion([answer[@"retcode"] integerValue]);
    };
    NSURLSessionTask *task;
    if (FixtureUpload) task = [NSURLSession.sharedSession uploadTaskWithRequest:request fromData:body completionHandler:handler];
    else { request.HTTPBody = body; task = [NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:handler]; }
    assert([task.currentRequest.URL.host isEqual:@"127.0.0.1"]); // No external fixture requests.
    assert([request.URL.host isEqual:@"passport-api.mihoyo.com"]);
    [task resume];
}
@end
static NSInteger FixtureLogin(NSString *account, NSString *password, BOOL upload) {
    FixtureExpectedAccount = account; FixtureExpectedPassword = password; FixtureUpload = upload;
    NSUInteger before = FixtureOriginalCalls;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSInteger result = NSIntegerMax;
    __block NSUInteger calls = 0;
    [_TtC13MHYPorteLogin14MHYPorteBridge loginWithAccount:account password:password completion:^(NSInteger value) { result=value; calls++; dispatch_semaphore_signal(done); }];
    assert(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
    assert(calls==1 && FixtureOriginalCalls==before+1);
    return result;
}
int main(void) { @autoreleasepool {
    RPCReportDirectory = @"build/local-login-fixture";
    [NSFileManager.defaultManager createDirectoryAtPath:RPCReportDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    RPCReportQueue = dispatch_queue_create("fixture.login.logs",DISPATCH_QUEUE_SERIAL);
    RPCEvents = [NSMutableArray new]; RPCSeen = [NSMutableSet new]; RPCLocalRoutingEnabled = YES;
    assert(RPCInstallSessionRouting()>0);
    assert(!RPCConfigureLocalLogin());
    NSDictionary *attributes = @{(__bridge id)kSecAttrKeyType:(__bridge id)kSecAttrKeyTypeRSA,(__bridge id)kSecAttrKeySizeInBits:@1024};
    SecKeyRef privateKey = SecKeyCreateRandomKey((__bridge CFDictionaryRef)attributes,NULL); assert(privateKey);
    SecKeyRef publicKey = SecKeyCopyPublicKey(privateKey); assert(publicKey);
    NSData *privateDER = CFBridgingRelease(SecKeyCopyExternalRepresentation(privateKey,NULL));
    NSData *publicDER = CFBridgingRelease(SecKeyCopyExternalRepresentation(publicKey,NULL));
    assert([privateDER writeToFile:@"build/local-login-fixture/private.der" atomically:YES]);
    assert([publicDER writeToFile:@"build/local-login-fixture/local-login-public-key.der" atomically:YES]);
    assert(FixtureLogin(@"fixture-user",@"Fixture-Pass-42",NO)==-10); // Old SDK key/body is not decryptable.
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(publicDER.bytes,(CC_LONG)publicDER.length,digest);
    NSMutableString *hex = [NSMutableString new]; for (NSUInteger i=0;i<sizeof(digest);i++) [hex appendFormat:@"%02x",digest[i]];
    NSMutableDictionary *profile = [@{@"account":@"fixture-user",@"public_key_sha256":@"incorrect"} mutableCopy];
    NSString *profileFile = @"build/local-login-fixture/local-login.json";
    [[NSJSONSerialization dataWithJSONObject:profile options:0 error:nil] writeToFile:profileFile atomically:YES];
    assert(!RPCConfigureLocalLogin());
    profile[@"public_key_sha256"] = hex;
    [[NSJSONSerialization dataWithJSONObject:profile options:0 error:nil] writeToFile:profileFile atomically:YES];
    RPCLocalRoutingEnabled = NO; assert(!RPCConfigureLocalLogin()); RPCLocalRoutingEnabled = YES;
    assert(RPCConfigureLocalLogin()); assert(RPCConfigureLocalLogin()); // Idempotent; original is not hooked twice.
    assert(FixtureLogin(@"fixture-user",@"Fixture-Pass-42",NO)==0);
    assert(FixtureLogin(@"fixture-user",@"Fixture-Wrong-42",YES)==-3208);
    assert(FixtureLogin(@"other-user",@"Fixture-Pass-42",NO)==-10);
    NSURL *localURL = FixtureURL(@"http://127.0.0.1:8088/account/ma-cn-passport/app/loginByPassword");
    NSData *opaque = FixtureSDKBody();
    RPCCaptureLocalLogin(@"fixture-user",@"Fixture-Pass-42");
    assert(RPCRewrapLocalLoginBody(FixtureURL(@"https://example.test/account/ma-cn-passport/app/loginByPassword"),opaque)==opaque);
    NSData *once = RPCRewrapLocalLoginBody(localURL,opaque); assert(once!=opaque);
    assert(RPCRewrapLocalLoginBody(localURL,opaque)==opaque);
    RPCCaptureLocalLogin(@"fixture-user",@"Fixture-Pass-42"); RPCPendingLoginExpires=0;
    assert(RPCRewrapLocalLoginBody(localURL,opaque)==opaque);
    RPCCaptureLocalLogin(@"fixture-user",@"Fixture-Pass-42");
    RPCCaptureLocalLogin(@"fixture-user",@"Fixture-Wrong-42");
    assert(RPCRewrapLocalLoginBody(localURL,opaque)==opaque && !RPCPendingLogin);
    dispatch_sync(RPCReportQueue,^{});
    NSString *raw = [NSString stringWithContentsOfFile:[RPCReportDirectory stringByAppendingPathComponent:@"client-observations.json"] encoding:NSUTF8StringEncoding error:nil] ?: @"";
    for (NSString *secret in @[@"fixture-user",@"Fixture-Pass-42",@"Fixture-Wrong-42",@"SDK_CIPHERTEXT_ACCOUNT",@"SDK_CIPHERTEXT_PASSWORD"]) assert(![raw containsString:secret]);
    NSDictionary *report = @{@"passed":@YES,@"legacy_decryption_error_reproduced":@YES,@"bridge_to_session_to_http_verified":@YES,
        @"correct_password_accepted":@YES,@"wrong_password_rejected":@YES,@"public_key_hash_verified":@YES,@"one_use_and_expiry_verified":@YES,
        @"overlapping_attempts_rejected":@YES,@"other_accounts_unchanged":@YES,@"callback_and_original_arguments_preserved":@YES,
        @"credentials_or_tokens_logged":@NO,@"actual_game_tested":@NO};
    assert([[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:@"build/RuntimeHostKit/local-login-regression.json" atomically:YES]);
    CFRelease(publicKey); CFRelease(privateKey);
    puts("local login regression: PASS (legacy decryption error, correct password, wrong password, scoped one-use encryption)");
    return 0;
} }
'''.replace('PRODUCTION',production)
pathlib.Path('build/local-login-test.m').write_text(harness)
subprocess.run(['xcrun','clang','-fobjc-arc','-fblocks','-framework','Foundation','-framework','Security','-Wno-deprecated-declarations','build/local-login-test.m','-o','build/local-login-test'],check=True)
def der_value(data,pos):
    tag=data[pos]; size=data[pos+1]; pos+=2
    if size&128:
        count=size&127
        if not 0<count<=4: raise ValueError('DER length')
        size=int.from_bytes(data[pos:pos+count],'big');pos+=count
    end=pos+size
    if end>len(data): raise ValueError('Truncated DER')
    return tag,data[pos:end],end
def decrypt(ciphertext):
    raw=pathlib.Path('build/local-login-fixture/private.der').read_bytes()
    tag,sequence,end=der_value(raw,0)
    if tag!=48 or end!=len(raw): raise ValueError('RSA fixture format')
    fields=[];pos=0
    while pos<len(sequence):
        tag,value,pos=der_value(sequence,pos)
        if tag!=2: raise ValueError('RSA integer')
        fields.append(int.from_bytes(value,'big'))
    if len(fields)!=9 or fields[0]!=0: raise ValueError('RSA PKCS1 fixture')
    modulus,exponent=fields[1],fields[3];size=(modulus.bit_length()+7)//8
    encoded=base64.b64decode(ciphertext,validate=True)
    if len(encoded)!=size or int.from_bytes(encoded,'big')>=modulus: raise ValueError('Ciphertext size')
    block=pow(int.from_bytes(encoded,'big'),exponent,modulus).to_bytes(size,'big')
    delimiter=block.find(b'\0',2)
    if block[:2]!=b'\0\2' or delimiter<10: raise ValueError('PKCS1 padding')
    return block[delimiter+1:].decode('utf-8')
class LoginBackend(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_POST(self):
        code=-10
        try:
            body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))))
            if self.path!='/account/ma-cn-passport/app/loginByPassword?fixture=1' or body.get('extra')!={'preserved':True}: raise ValueError('Request mutated')
            account,password=decrypt(body['account']),decrypt(body['password'])
            code=0 if account=='fixture-user' and password=='Fixture-Pass-42' else -3208
        except (ValueError,KeyError,UnicodeError): pass
        result=json.dumps({'retcode':code}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(result)));self.end_headers();self.wfile.write(result)
server=http.server.ThreadingHTTPServer(('127.0.0.1',8088),LoginBackend)
threading.Thread(target=server.serve_forever,daemon=True).start()
try: subprocess.run(['build/local-login-test'],check=True,timeout=40)
finally:
    server.shutdown();server.server_close()
    pathlib.Path('build/local-login-fixture/private.der').unlink(missing_ok=True)
PY
sdk_name="${PROBE_SDK:-iphoneos}"
# Measure the class-space reservation from the exact native argument builder.
# This desktop VM check validates the argument and telemetry contract; physical
# WebKit coexistence still requires the original device reproduction.
python3 - <<'PY'
import json,pathlib,re,subprocess
source=pathlib.Path('App/main.m').read_text()
memory=re.search(r'static NSArray<NSString \*> \*RPRuntimeMemoryArguments\(.*?\n\}',source,re.S).group(0)
fixture='''#import <Foundation/Foundation.h>
MEMORY
int main(int argc,char **argv) { @autoreleasepool {
    NSArray *args=RPRuntimeMemoryArguments(argc>1 && strcmp(argv[1],"server")==0);
    NSData *json=[NSJSONSerialization dataWithJSONObject:args options:0 error:nil];
    fwrite(json.bytes,1,json.length,stdout); return 0;
} }
'''.replace('MEMORY',memory)
pathlib.Path('build/memory-arguments.m').write_text(fixture)
profiles={}
for profile in ('standalone','embedded'):
    command=['xcrun','clang','-fobjc-arc','-framework','Foundation']
    if profile=='embedded': command+=['-DRP_EMBEDDED_LIBRARY=1']
    binary='build/memory-arguments-'+profile
    subprocess.run(command+['build/memory-arguments.m','-o',binary],check=True)
    profiles[profile]=json.loads(subprocess.check_output([binary,'server']))
    assert '-Xmx2048m' in profiles[profile]
assert profiles['standalone']==['-Xmx2048m']
assert profiles['embedded']==['-Xmx2048m','-XX:CompressedClassSpaceSize=128m']
classes=pathlib.Path('build/memory-fixture-classes');classes.mkdir(exist_ok=True)
subprocess.run(['javac','--release','17','-d',str(classes),'Java/DeviceProbe.java'],check=True)
reports={}
for profile,flags in profiles.items():
    output=pathlib.Path('build/memory-'+profile+'.json')
    subprocess.run(['java','-Xint',*flags,'-cp',str(classes),'DeviceProbe','--memory-report',str(output)],check=True,timeout=30)
    reports[profile]=json.loads(output.read_text())
    assert reports[profile]['heap_max_bytes']==2147483648
    reports[profile]['class_space_max_bytes']=next(p['max_bytes'] for p in reports[profile]['pools'] if p['name']=='Compressed Class Space')
assert reports['embedded']['class_space_max_bytes']==134217728
assert reports['standalone']['class_space_max_bytes']>reports['embedded']['class_space_max_bytes']
result={'passed':True,'heap_max_unchanged_bytes':2147483648,'class_space_before_bytes':reports['standalone']['class_space_max_bytes'],
        'class_space_after_bytes':reports['embedded']['class_space_max_bytes'],'physical_webkit_coexistence_verified':False,
        'actual_game_tested':False}
pathlib.Path('build/RuntimeHostKit/memory-reservation-regression.json').write_text(json.dumps(result,indent=2))
print('class-space reservation regression:',json.dumps(result))
PY
# macOS ships Bash 3.2, whose nounset handling rejects empty array expansion.
extra_target_flags=( --disable-warnings-as-errors )
case "$sdk_name" in
  iphoneos)
    target_conf=ios-aarch64-zero-release
    build_destination='generic/platform=iOS'
    ;;
  iphonesimulator)
    target_conf=iossim-aarch64-zero-release
    build_destination='generic/platform=iOS Simulator'
    extra_target_flags+=( '--with-extra-cflags=-target arm64-apple-ios-simulator -mios-simulator-version-min=18.5' '--with-extra-cxxflags=-target arm64-apple-ios-simulator -mios-simulator-version-min=18.5' )
    ;;
  *) echo "Unsupported test SDK: $sdk_name" >&2; exit 2 ;;
esac
export PROBE_SDK="$sdk_name"
python3 - <<'PY'
import json,os,pathlib,subprocess
sdk=subprocess.check_output(['xcrun','--sdk',os.environ['PROBE_SDK'],'--show-sdk-version'],text=True).strip()
assert tuple(map(int,sdk.split('.')[:2])) >= (27,1), 'Duo layout requires iOS 27.1 SDK or newer'
version=subprocess.check_output(['xcodebuild','-version'],text=True).strip()
pathlib.Path('build/toolchain.json').write_text(json.dumps({'sdk':sdk,'xcode':version},indent=2))
print(version, 'SDK', sdk)
PY
for command_name in xcodebuild xcrun xcodegen git python3 javac jar gmake autoconf; do
  command -v "$command_name" >/dev/null || { echo "Missing build tool: $command_name"; exit 2; }
done
if [[ -n "${PROBE_RUNTIME_ARCHIVE:-}" ]]; then
python3 - <<'PY'
import hashlib,json,os,pathlib,plistlib,zipfile
archive=pathlib.Path(os.environ['PROBE_RUNTIME_ARCHIVE'])
expected=os.environ['PROBE_RUNTIME_SHA256']
assert hashlib.sha256(archive.read_bytes()).hexdigest()==expected, 'Runtime archive checksum mismatch'
with zipfile.ZipFile(archive) as z:
    required_patch='Implement Apple ARM64 Zero signal-context PC accessors'
    assert required_patch in z.read('runtime/LOCAL-PATCHES.txt').decode(), 'Runtime lacks the required signal-context fix; rebuild or select a corrected archive'
    target_simulator=os.environ.get('PROBE_SDK','iphoneos')=='iphonesimulator'
    framework=plistlib.loads(z.read('OpenJDK.xcframework/Info.plist'))
    matching=[x for x in framework['AvailableLibraries'] if x.get('SupportedPlatform')=='ios' and (x.get('SupportedPlatformVariant')=='simulator')==target_simulator and 'arm64' in x.get('SupportedArchitectures',[])]
    assert matching, 'Runtime archive does not match the selected device/simulator target'
    for entry in z.infolist():
        p=pathlib.PurePosixPath(entry.filename)
        if p.parts[0] not in {'OpenJDK.xcframework','runtime','module-check.json'}: continue
        if p.is_absolute() or '..' in p.parts: raise ValueError('Invalid runtime archive path')
        z.extract(entry,'build')
report=json.loads(pathlib.Path('build/module-check.json').read_text())
assert not report['missing'] and len(report['modules'])==18
pathlib.Path('build/runtime-reuse-check.json').write_text(json.dumps({'sha256':expected,'sdk':os.environ.get('PROBE_SDK','iphoneos'),'signalContextPatchPresent':True,'targetMatched':True},indent=2))
print('Reused checksum-verified runtime archive:', expected)
PY
else
mobile_commit=c13417aa36f8f44755d0984b58aa735d0b41f233
if [[ ! -d build/mobile/.git ]]; then
  git init build/mobile
  git -C build/mobile remote add origin https://github.com/openjdk/mobile.git
  git -C build/mobile fetch --depth 1 origin "$mobile_commit"
  git -C build/mobile checkout --detach FETCH_HEAD
fi
test "$(git -C build/mobile rev-parse HEAD)" = "$mobile_commit"
python3 - <<'PY'
from pathlib import Path
# Zero selects bsd_zero, so it cannot reference WX helpers implemented only in
# bsd_aarch64. It interprets bytecode and does not generate executable JIT pages.
p=Path('build/mobile/src/hotspot/share/utilities/macros.hpp')
s=p.read_text()
before='''#define MACOS_AARCH64_ONLY(x) MACOS_ONLY(AARCH64_ONLY(x))
#if defined(__APPLE__) && defined(AARCH64)
#define MACOS_AARCH64 1'''
after='''#define MACOS_AARCH64_ONLY(x) NOT_ZERO(MACOS_ONLY(AARCH64_ONLY(x)))
#if defined(__APPLE__) && defined(AARCH64) && !defined(ZERO)
#define MACOS_AARCH64 1'''
if before in s:
    assert s.count(before)==1
    p.write_text(s.replace(before,after))
else:
    assert after in s, 'Unexpected upstream WX macro layout'
p=Path('build/mobile/src/hotspot/share/runtime/thread.inline.hpp')
s=p.read_text()
before='#if defined(__APPLE__) && defined(AARCH64)'
after='#ifdef MACOS_AARCH64'
if before in s:
    assert s.count(before)==1
    p.write_text(s.replace(before,after))
else:
    assert after in s, 'Unexpected upstream thread WX guard'
p=Path('build/mobile/src/hotspot/os_cpu/bsd_zero/os_bsd_zero.cpp')
s=p.read_text()
before='#if defined(AARCH64) && defined(__APPLE__)'
after='#ifdef MACOS_AARCH64'
if before in s:
    assert s.count(before)==1
    p.write_text(s.replace(before,after))
else:
    assert after in s, 'Unexpected upstream Zero OS WX guard'
# The common POSIX handler reads the interrupted PC before it can chain to a
# preinstalled native host handler. BSD Zero left these accessors unimplemented,
# aborting the whole embedding process even for a recoverable native signal.
before='''address os::Posix::ucontext_get_pc(const ucontext_t* uc) {
  ShouldNotCallThis();
  return nullptr;
}

void os::Posix::ucontext_set_pc(ucontext_t * uc, address pc) {
  ShouldNotCallThis();
}'''
after='''address os::Posix::ucontext_get_pc(const ucontext_t* uc) {
#if defined(__APPLE__) && defined(AARCH64)
  return (address)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
#else
  ShouldNotCallThis();
  return nullptr;
#endif
}

void os::Posix::ucontext_set_pc(ucontext_t * uc, address pc) {
#if defined(__APPLE__) && defined(AARCH64)
  __darwin_arm_thread_state64_set_pc_fptr(uc->uc_mcontext->__ss, (void*)pc);
#else
  ShouldNotCallThis();
#endif
}'''
s=p.read_text()
if before in s:
    assert s.count(before)==1
    p.write_text(s.replace(before,after))
else:
    assert after in s, 'Unexpected upstream Zero signal context layout'
p=Path('build/mobile/src/hotspot/os/bsd/os_bsd.cpp')
s=p.read_text()
before='#endif\n    Arguments::set_java_home(buf);'
after='''#endif
#ifdef __IOS__
    // JNI embedding initializes the bootstrap path before parsing -D options.
    const char* ios_java_home = ::getenv("JAVA_HOME");
    Arguments::set_java_home((ios_java_home != nullptr && *ios_java_home) ? ios_java_home : buf);
#else
    Arguments::set_java_home(buf);
#endif'''
if after not in s:
    assert s.count(before)==1, 'Unexpected upstream Java home initialization'
    p.write_text(s.replace(before,after))
p=Path('build/mobile/src/hotspot/share/memory/memoryReserver.cpp')
s=p.read_text()
before='''                                 ExecMem,
                                 mtCode);'''
after='''#if defined(__IOS__) && defined(ZERO)
                                 // Zero stores entry descriptors, not generated instructions.
                                 !ExecMem,
#else
                                 ExecMem,
#endif
                                 mtCode);'''
if after not in s:
    assert s.count(before)==1, 'Unexpected upstream code cache reservation'
    p.write_text(s.replace(before,after))
PY
python3 - <<'PY'
import hashlib,os,pathlib,urllib.request,zipfile
simulator=os.environ['PROBE_SDK']=='iphonesimulator'
filename='libffi-ios-sim.zip' if simulator else 'libffi-ios.zip'
checksum='701b522e3eff0263f18d4a9e487f0a7ac30050fb2af20e86b6849daa14f5781f' if simulator else '4f39fd1d53fbd69d1bdbd915413077d130daa3f6792d1b3a03a690a9cbd4dea3'
p=pathlib.Path('build')/filename
if not p.exists():
    p.write_bytes(urllib.request.urlopen('https://github.com/openjdk-mobile/ios-tools/releases/download/libffi-build/'+filename).read())
assert hashlib.sha256(p.read_bytes()).hexdigest()==checksum
with zipfile.ZipFile(p) as z:
    for name in z.namelist():
        if name.startswith('/') or '..' in pathlib.PurePosixPath(name).parts: raise ValueError('Invalid archive path')
    z.extractall('build/support')
PY
sdk_root="$(xcrun --sdk "$sdk_name" --show-sdk-path)"
mac_sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
support_root="$project_root/build/support"
cd build/mobile
# The packaging tools must use the same java.base build signature and iOS-aware
# platform enum as the target. A vendor JDK of the same feature version is insufficient.
version_options=( --with-version-opt=iphone-probe --with-vendor-name=OpenJDKMobileProbe )
host_jdk="$project_root/build/mobile/build/macos-aarch64-server-release/images/jdk"
if [[ ! -x "$host_jdk/bin/jlink" ]]; then
bash configure --with-conf-name=macos-aarch64-server-release --disable-warnings-as-errors \
  --with-jvm-variants=server --with-sysroot="$mac_sdk_root" "${version_options[@]}"
gmake CONF=macos-aarch64-server-release images
fi
test -x "$host_jdk/bin/jmod" && test -x "$host_jdk/bin/jlink"
"$host_jdk/bin/java" -version
bash configure --with-conf-name="$target_conf" \
  --openjdk-target=aarch64-macos-ios --with-jvm-variants=zero \
  "${version_options[@]}" "${extra_target_flags[@]}" \
  --with-build-jdk="$host_jdk" \
  --with-sysroot="$sdk_root" --with-libffi-include="$support_root/include/ffi" \
  --with-libffi-lib="$support_root" --with-cups-include="$mac_sdk_root/usr/include"
# iOS static libraries avoid the unsupported ELF shared-library image target.
gmake CONF="$target_conf" \
  hotspot-zero-static-libs java.base-static-libs \
  java.management-static-libs jdk.management-static-libs \
  java.base-gendata java.base-copy \
  java.logging-java java.management-java java.naming-java java.security.sasl-java \
  java.sql-java java.transaction.xa-java java.xml-java jdk.management-java jdk.unsupported-java jdk.zipfs-java \
  java.desktop-java java.datatransfer-java java.prefs-java java.scripting-java java.rmi-java \
  java.instrument-java java.security.jgss-java
cd "$project_root"
device_root="$project_root/build/mobile/build/$target_conf"
export DEVICE_ROOT="$device_root" HOST_JDK="$host_jdk"
python3 - <<'PY'
import json,os,pathlib,shutil,subprocess
device=pathlib.Path(os.environ['DEVICE_ROOT'])
host=pathlib.Path(os.environ['HOST_JDK'])
modules=['java.base','java.logging','java.management','java.naming','java.security.sasl',
         'java.sql','java.transaction.xa','java.xml','jdk.management','jdk.unsupported','jdk.zipfs',
         'java.desktop','java.datatransfer','java.prefs','java.scripting','java.rmi','java.instrument','java.security.jgss']
jmods=pathlib.Path('build/ios-jmods');jmods.mkdir(parents=True,exist_ok=True)
for module in modules:
    classes=device/'jdk/modules'/module
    if not (classes/'module-info.class').is_file(): raise SystemExit('Missing compiled module '+module)
    args=[str(host/'bin/jmod'),'create','--target-platform','ios-aarch64','--class-path',str(classes)]
    conf=device/'support/modules_conf'/module
    if conf.is_dir(): args+=['--config',str(conf)]
    libs=device/'support/modules_libs'/module
    if libs.is_dir():
        staging=pathlib.Path('build/module-data')/module
        for source in libs.rglob('*'):
            if source.is_file() and source.suffix not in {'.so','.dylib','.a','.dll','.pdb','.debuginfo'}:
                target=staging/source.relative_to(libs);target.parent.mkdir(parents=True,exist_ok=True)
                shutil.copy2(source,target)
        if staging.is_dir(): args+=['--libs',str(staging)]
    modified=device/'support/modules_legal'/module
    original=pathlib.Path('build/mobile/src')/module/'share/legal'
    notices=[device/'support/modules_legal/common',modified if modified.is_dir() else original]
    notices=[str(p) for p in notices if p.is_dir()]
    if notices: args+=['--legal-notices',os.pathsep.join(notices)]
    subprocess.run(args+[str(jmods/(module+'.jmod'))],check=True)
subprocess.run([str(host/'bin/jlink'),'--module-path',str(jmods),'--add-modules',','.join(modules),
                '--strip-debug','--no-header-files','--no-man-pages','--output','build/runtime'],check=True)
image=pathlib.Path('build/runtime')
release=(image/'release').read_text()
module_line=next(x for x in release.splitlines() if x.startswith('MODULES='))
modules=set(module_line.split('=',1)[1].strip('"').split())
required={'java.base','java.logging','java.management','java.naming','java.sql','java.xml','jdk.management','jdk.unsupported','jdk.zipfs',
          'java.desktop','java.datatransfer','java.prefs','java.scripting','java.rmi','java.instrument','java.security.jgss'}
missing=sorted(required-modules)
pathlib.Path('build/module-check.json').write_text(json.dumps({'missing':missing,'modules':sorted(modules)},indent=2))
if missing: raise SystemExit('iOS runtime is missing required modules: '+','.join(missing))
for filename in ['conf/security/java.security','lib/tzdb.dat','lib/modules']:
    if not (image/filename).is_file(): raise SystemExit('Missing runtime data: '+filename)
for filename in ['LICENSE','ASSEMBLY_EXCEPTION']:
    shutil.copy2(pathlib.Path('build/mobile')/filename,image/filename)
(image/'SOURCE.txt').write_text('OpenJDK Mobile source: https://github.com/openjdk/mobile/tree/c13417aa36f8f44755d0984b58aa735d0b41f233\n')
(image/'LOCAL-PATCHES.txt').write_text('Exclude JIT WX helpers consistently for Zero. On iOS, honor the embedding app JAVA_HOME before bootstrap path initialization. Reserve the iOS Zero entry-descriptor cache without executable permission. Implement Apple ARM64 Zero signal-context PC accessors so the existing POSIX signal chaining can run.\nReproducible patches: https://github.com/lxingy3/iphone-java-runtime-probe/blob/main/scripts/build.sh\n')
PY
libraries=( "$device_root/hotspot/variant-zero/libjvm/objs/static/libjvm.a" "$support_root/libffi.a" )
for entry in java.base/java java.base/verify java.base/zip java.base/net java.base/nio java.base/jimage java.management/management jdk.management/management_ext; do
  module="${entry%/*}"; library="${entry#*/}"
  native_library="$device_root/support/native/$module/lib$library/static/lib$library.a"
  test -f "$native_library" || { echo "Missing native iOS library: $native_library"; exit 3; }
  libraries+=( "$native_library" )
done
libtool -static -o build/libOpenJDK.a "${libraries[@]}"
mkdir -p build/include
cp "$device_root"/jdk/include/*.h build/include/
cp "$device_root"/jdk/include/ios/*.h build/include/
if [[ -e build/OpenJDK.xcframework ]]; then
  echo 'Framework already exists; use a clean checkout to rebuild.' >&2; exit 3
fi
xcodebuild -create-xcframework -library "$project_root/build/libOpenJDK.a" -headers "$project_root/build/include" -output "$project_root/build/OpenJDK.xcframework"
fi
if [[ -n "${PROBE_RUNTIME_ARCHIVE:-}" ]]; then
  # The first runtime archive omitted libverify. Older dependencies still need
  # VerifyClassForMajorVersion; compile its matching pinned source without weakening verification.
  verify_source="$project_root/build/verify-source"
  git init "$verify_source"
  git -C "$verify_source" remote add origin https://github.com/openjdk/mobile.git
  git -C "$verify_source" fetch --depth 1 --filter=blob:none origin c13417aa36f8f44755d0984b58aa735d0b41f233
  git -C "$verify_source" sparse-checkout set src/java.base/share/native/libverify src/java.base/share/native/libjava src/java.base/unix/native/libjava src/java.base/share/classes/sun/nio/fs src/hotspot/share/include src/hotspot/os
  git -C "$verify_source" checkout --detach FETCH_HEAD
  framework_library="$(find build/OpenJDK.xcframework -name libOpenJDK.a -type f)"
  test -n "$framework_library"
  xcrun nm -gU "$framework_library" > build/cached-runtime-exports.txt
  if ! grep -q ' T _VerifyClassForMajorVersion$' build/cached-runtime-exports.txt; then
  framework_headers="$(dirname "$framework_library")/Headers"
  verify_target=arm64-apple-ios18.5
  if [[ "$sdk_name" == iphonesimulator ]]; then verify_target=arm64-apple-ios18.5-simulator; fi
  xcrun --sdk "$sdk_name" clang -target "$verify_target" -isysroot "$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
    -O2 -DSTATIC_BUILD -DNDEBUG -I"$framework_headers" \
    -I"$verify_source/src/java.base/share/native/libjava" \
    -I"$verify_source/src/java.base/unix/native/libjava" \
    -I"$verify_source/src/hotspot/share/include" -I"$verify_source/src/hotspot/os/posix/include" \
    -c "$verify_source/src/java.base/share/native/libverify/check_code.c" -o build/verify.o
  libtool -static -o build/OpenJDK-with-verify.a "$framework_library" build/verify.o
  cp build/OpenJDK-with-verify.a "$framework_library"
  xcrun nm -gU "$framework_library" | grep ' T _VerifyClassForMajorVersion$'
  printf '%s\n' 'Link the pinned legacy bytecode verifier into the embedding app; retain bytecode verification.' >> build/runtime/LOCAL-PATCHES.txt
  else
    echo 'Cached runtime already contains the pinned verifier; retain the existing implementation.'
  fi
fi
runtime_source="$project_root/build/mobile"
if [[ -n "${PROBE_RUNTIME_ARCHIVE:-}" ]]; then runtime_source="$verify_source"; fi
# The iOS BsdFileSystem uses this portable implementation, omitted from the old image.
mkdir -p build/patch-source/sun/nio/fs build/java-base-patch
cp "$runtime_source/src/java.base/share/classes/sun/nio/fs/PollingWatchService.java" build/patch-source/sun/nio/fs/
javac --patch-module java.base=build/patch-source -d build/java-base-patch build/patch-source/sun/nio/fs/PollingWatchService.java
jar --create --file build/RuntimePatch.jar -C build/java-base-patch .
printf '%s\n' 'Restore the pinned portable PollingWatchService through a java.base patch JAR.' >> build/runtime/LOCAL-PATCHES.txt
mkdir -p build/java
javac --release 21 -encoding UTF-8 -d build/java Java/DeviceProbe.java
jar --create --file build/DeviceProbe.jar -C build/java .
# Package the same bootstrap as a library, without an app entry point or scene delegate.
# This is a host integration kit, not a patched game or a bundled private payload.
kit="$project_root/build/RuntimeHostKit"
mkdir -p "$kit"
framework_library="$(find build/OpenJDK.xcframework -name libOpenJDK.a -type f)"
framework_headers="$(dirname "$framework_library")/Headers"
host_target=arm64-apple-ios18.5
if [[ "$sdk_name" == iphonesimulator ]]; then host_target=arm64-apple-ios18.5-simulator; fi
xcrun --sdk "$sdk_name" clang -target "$host_target" -isysroot "$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
  -fobjc-arc -fmodules -O2 -DRP_EMBEDDED_LIBRARY=1 -I"$framework_headers" \
  -c App/main.m -o "$kit/RuntimeHostKit.o"
libtool -static -o "$kit/libRuntimeHostKit.a" "$kit/RuntimeHostKit.o"
# Optional same-process and observation libraries. They contain no game executable,
# server payload, account data, client-specific offsets, or cryptographic keys.
xcrun --sdk "$sdk_name" clang -dynamiclib -target "$host_target" -isysroot "$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
  -Wl,-all_load "$kit/libRuntimeHostKit.a" "$framework_library" \
  -framework UIKit -framework Foundation -framework BackgroundTasks -lc++ -lz \
  -install_name @loader_path/RuntimeHost.dylib -o "$kit/RuntimeHost.dylib"
# The image-local loader shim must never become a process-visible replacement.
xcrun nm -gU "$kit/RuntimeHost.dylib" > "$kit/dynamic-exports.txt"
python3 - <<'PY'
from pathlib import Path
symbols=Path('build/RuntimeHostKit/dynamic-exports.txt').read_text().splitlines()
assert not any(line.rstrip().endswith(' _dlopen') for line in symbols), 'Host loader shim escaped local image'
assert any(line.rstrip().endswith(' _JNI_OnLoad_java') for line in symbols)
PY
xcrun --sdk "$sdk_name" clang -dynamiclib -target "$host_target" -isysroot "$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
  -fobjc-arc -fmodules -O2 -DRP_CLIENT_OBSERVER_ONLY=1 App/main.m "$kit/RuntimeHost.dylib" \
  -framework UIKit -framework Foundation -framework Security -framework WebKit -framework CoreText -install_name @executable_path/Frameworks/RuntimeClientProbe.dylib \
  -o "$kit/RuntimeClientProbe.dylib"
cat > "$kit/RuntimeHostKit.h" <<'HEADER'
#import <Foundation/Foundation.h>
// Call on the main thread. The host owns its application and scenes.
FOUNDATION_EXPORT BOOL RPHostStart(NSString *documents, NSString *resources, BOOL server, NSError **error);
FOUNDATION_EXPORT NSDictionary *RPHostSnapshot(void);
FOUNDATION_EXPORT void RPHostSceneEvent(NSString *event);
HEADER
cat > "$kit/INTEGRATION.md" <<'GUIDE'
Experimental same-process runtime integration, not a native game client.
Link libRuntimeHostKit.a and OpenJDK.xcframework, with -all_load -export_dynamic,
UIKit, Foundation, BackgroundTasks, libc++, and libz. Copy runtime/, DeviceProbe.jar,
and RuntimePatch.jar into a resource directory. Preserve OpenJDK license files.
Use a dedicated private storage directory. A false return provides a host-contract
error; a true return means startup was requested, NOT that the server is ready.
Poll RPHostSnapshot on the main thread. Never create a second JVM during resize,
fold, rotation, backgrounding or scene replacement. Forward scene events explicitly.
The kit does not change process cwd or redirect native stdout/stderr.
The existing private server payload still uses relative java.io paths. Server mode
therefore requires the host to establish <storage>/server as its cwd BEFORE either
engine initializes. Real game coexistence with this requirement is UNVERIFIED;
do not inject this library into an already running game. Absolute path migration
is required before removing this guard. Probe mode does not require changing cwd.
Game binary/version/ABI checks, signing, login redirect, protocol/signature support,
actual gameplay, foreground memory budget, saving and relaunch are still required.
No game executable, game assets, keys, accounts or private saved data are in this kit.
GUIDE
xcrun nm -gU "$kit/libRuntimeHostKit.a" > "$kit/symbols.txt"
python3 - <<'PY'
import json,pathlib
p=pathlib.Path('build/RuntimeHostKit')
symbols=(p/'symbols.txt').read_text()
required=['_RPHostStart','_RPHostSnapshot','_RPHostSceneEvent']
assert all(x in symbols for x in required)
assert not any(line.rstrip().endswith(' T _main') for line in symbols.splitlines())
(p/'contract.json').write_text(json.dumps({'exported_entry_points':required,'has_app_entry_point':False,
    'game_client_included':False,'game_integration_verified':False,'runtime_coexistence_tested':False},indent=2))
PY
xcodegen generate --spec project.yml
xcodebuild -project RuntimeProbe.xcodeproj -scheme RuntimeProbe -configuration Release \
  -destination "$build_destination" -derivedDataPath build/DerivedData ARCHS=arm64 CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
if [[ "$sdk_name" == iphonesimulator ]]; then
# Isolate the linked-SDK compatibility gate using the same scene/fullscreen/
# landscape contract as the game. Only the SDK load-command field differs.
mkdir -p build/DuoGeometryLegacy.app build/DuoGeometryModern.app
xcrun --sdk "$sdk_name" clang -target "$host_target" -isysroot "$(xcrun --sdk "$sdk_name" --show-sdk-path)" -fobjc-arc -fmodules App/DuoGeometryFixture.m -framework UIKit -framework Foundation -o build/DuoGeometryModern.app/DuoGeometry
python3 - <<'PY'
import pathlib,plistlib,struct
base=pathlib.Path('build/DuoGeometryModern.app/DuoGeometry').read_bytes()
for label,sdk in [('Legacy',0x1a0200),('Modern',0x1b0100)]:
    data=bytearray(base);assert struct.unpack_from('<I',data)[0]==0xfeedfacf
    offset=32;found=0
    for _ in range(struct.unpack_from('<I',data,16)[0]):
        command,size=struct.unpack_from('<II',data,offset)
        if command==0x32:struct.pack_into('<I',data,offset+16,sdk);found+=1
        offset+=size
    assert found==1
    root=pathlib.Path('build/DuoGeometry'+label+'.app');(root/'DuoGeometry').write_bytes(data)
    info={'CFBundleExecutable':'DuoGeometry','CFBundleIdentifier':'local.astaps.DuoGeometry'+label,'CFBundleName':'DuoGeometry'+label,'CFBundlePackageType':'APPL','CFBundleShortVersionString':'1','CFBundleVersion':'1','MinimumOSVersion':'18.5','UIDeviceFamily':[1,2],'LSRequiresIPhoneOS':True,'UIRequiresFullScreen':True,'UILaunchScreen':{},'UIStatusBarHidden':True,'UISupportedInterfaceOrientations':['UIInterfaceOrientationLandscapeRight','UIInterfaceOrientationLandscapeLeft'],'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{'UIWindowSceneSessionRoleApplication':[{'UISceneClassName':'UIWindowScene','UISceneConfigurationName':'Geometry','UISceneDelegateClassName':'DuoGeometryScene'}]}}}
    (root/'Info.plist').write_bytes(plistlib.dumps(info))
PY
codesign --force --sign - build/DuoGeometryLegacy.app
codesign --force --sign - build/DuoGeometryModern.app
# Exercise the actual dynamic libraries in a small independent UIKit host. The
# negative bundle checks that an unexpected host cannot activate instrumentation.
fixture="$project_root/build/ObserverFixture.app"
mkdir -p "$fixture/Frameworks"
cp App/battle-training.html "$fixture/battle-training.html"
mkdir -p "$fixture/training-assets"
cp App/training-assets/*.png "$fixture/training-assets/"
cp "$kit/RuntimeHost.dylib" "$kit/RuntimeClientProbe.dylib" "$fixture/Frameworks/"
xcrun --sdk "$sdk_name" clang -target "$host_target" -isysroot "$(xcrun --sdk "$sdk_name" --show-sdk-path)" \
  -fobjc-arc -fmodules -O2 -DRP_CLIENT_FIXTURE=1 App/main.m \
  "$kit/RuntimeClientProbe.dylib" "$kit/RuntimeHost.dylib" -framework UIKit -framework Foundation -framework WebKit \
  -Wl,-headerpad_max_install_names -o "$fixture/ObserverFixture"
# The executable directly calls the host API; unlike the observer dylib, its
# loader directory is the app root, not Frameworks. Keep the production dylib
# identity unchanged and correct only this simulator fixture's direct import.
xcrun install_name_tool -change @loader_path/RuntimeHost.dylib \
  @executable_path/Frameworks/RuntimeHost.dylib "$fixture/ObserverFixture"
python3 - <<'PY'
import json,pathlib,plistlib,shutil,struct
p=pathlib.Path('build/ObserverFixture.app')
links=[]
for binary in [p/'ObserverFixture',p/'Frameworks/RuntimeClientProbe.dylib',p/'Frameworks/RuntimeHost.dylib']:
    data=binary.read_bytes()
    assert struct.unpack_from('<I',data)[0]==0xfeedfacf
    count=struct.unpack_from('<I',data,16)[0]; offset=32
    for _ in range(count):
        command,size=struct.unpack_from('<II',data,offset)
        if command in (0xc,0x80000018,0x8000001f):
            start=offset+struct.unpack_from('<I',data,offset+8)[0]
            name=data[start:data.index(b'\0',start)].decode()
            target=None
            if name.startswith('@loader_path/'): target=binary.parent/name[len('@loader_path/'):]
            elif name.startswith('@executable_path/'): target=p/name[len('@executable_path/'):]
            if target is not None:
                assert target.is_file(),(str(binary),name,str(target))
                links.append({'binary':str(binary.relative_to(p)),'dependency':name,'resolved':str(target.relative_to(p))})
            else: assert name.startswith(('/System/Library/','/usr/lib/')),(str(binary),name)
        offset+=size
audit=pathlib.Path('build/simulator-results');audit.mkdir(parents=True,exist_ok=True)
(audit/'fixture-link-audit.json').write_text(json.dumps({'passed':True,'links':links},indent=2))
info={'CFBundleExecutable':'ObserverFixture','CFBundleIdentifier':'local.astaps.ObserverFixture',
    'CFBundleName':'ObserverFixture','CFBundleDisplayName':'Observer fixture','CFBundlePackageType':'APPL',
    'CFBundleShortVersionString':'1.0','CFBundleVersion':'1','MinimumOSVersion':'18.5',
    'UIDeviceFamily':[1,2],'LSRequiresIPhoneOS':True,
    'UIApplicationSceneManifest':{'UIApplicationSupportsMultipleScenes':False,'UISceneConfigurations':{
        'UIWindowSceneSessionRoleApplication':[{'UISceneConfigurationName':'Fixture','UISceneDelegateClassName':'RPCFixtureSceneDelegate'}]}}}
(p/'Info.plist').write_bytes(plistlib.dumps(info))
(p/'RuntimeIntegration.plist').write_bytes(plistlib.dumps({'BundlePrefix':'local.astaps.ObserverFixture',
    'ClientVersion':'1.0','ClientBuild':'1'}))
q=pathlib.Path('build/ObserverFixtureWrong.app')
shutil.copytree(p,q,dirs_exist_ok=True)
info['CFBundleIdentifier']='local.astaps.ObserverFixtureWrong'
(q/'Info.plist').write_bytes(plistlib.dumps(info))
# A routing opt-in cannot override the exact configured bundle boundary.
(q/'RuntimeIntegration.plist').write_bytes(plistlib.dumps({'BundlePrefix':'local.astaps.ObserverFixture',
    'ClientVersion':'1.0','ClientBuild':'1','LocalRoutingEnabled':True}))
r=pathlib.Path('build/ObserverFixtureEmbedded.app')
shutil.copytree(p,r,dirs_exist_ok=True)
info['CFBundleIdentifier']='local.astaps.ObserverFixture.Embedded'
(r/'Info.plist').write_bytes(plistlib.dumps(info))
shutil.copytree('build/runtime',r/'LocalRuntime/runtime',dirs_exist_ok=True)
for name in ['DeviceProbe.jar','RuntimePatch.jar']: shutil.copy2('build/'+name,r/'LocalRuntime'/name)
s=pathlib.Path('build/ObserverFixtureRouting.app')
shutil.copytree(p,s,dirs_exist_ok=True)
info['CFBundleIdentifier']='local.astaps.ObserverFixture.Routing'
info['NSAppTransportSecurity']={'NSAllowsArbitraryLoads':True}
(s/'Info.plist').write_bytes(plistlib.dumps(info))
(s/'RuntimeIntegration.plist').write_bytes(plistlib.dumps({'BundlePrefix':'local.astaps.ObserverFixture',
    'ClientVersion':'1.0','ClientBuild':'1','LocalRoutingEnabled':True}))
PY
for fixture_path in "$fixture" "$project_root/build/ObserverFixtureWrong.app" "$project_root/build/ObserverFixtureEmbedded.app" "$project_root/build/ObserverFixtureRouting.app"; do
  codesign --force --sign - "$fixture_path/Frameworks/RuntimeHost.dylib"
  codesign --force --sign - "$fixture_path/Frameworks/RuntimeClientProbe.dylib"
  codesign --force --sign - "$fixture_path"
done
python3 - <<'PY'
import http.server,json,os,pathlib,re,shutil,signal,subprocess,threading,time
output=pathlib.Path('build/simulator-results');output.mkdir(parents=True,exist_ok=True)
def log(message):
    print(message,flush=True)
    with (output/'simulator-commands.log').open('a') as stream: stream.write(message+'\n')
def command(*args,check=True,timeout=180):
    log('Running: '+repr(args))
    try:
        result=subprocess.run(args,check=check,capture_output=True,text=True,timeout=timeout)
        if result.stdout: log(result.stdout)
        if result.stderr: log(result.stderr)
        return result
    except (subprocess.TimeoutExpired,subprocess.CalledProcessError) as failure:
        log(repr(failure))
        for value in [failure.stdout,failure.stderr]:
            if value: log(value.decode(errors='replace') if isinstance(value,bytes) else value)
        raise
inventory=json.loads(command('xcrun','simctl','list','devices','available','--json').stdout)
devices=[dict(d,runtime=runtime) for runtime,items in inventory['devices'].items() if '.iOS-' in runtime for d in items if d['name'].startswith('iPhone')]
if not devices: raise SystemExit('No available iPhone simulator runtime')
profile=os.environ.get('PROBE_DEVICE_CLASS','duo')
candidates=[d for d in devices if (d['name']!='iPhone Duo' if profile=='standard' else d['name']=='iPhone Duo')]
if not candidates: raise SystemExit('No available iPhone simulator for profile '+profile)
# New device-specific runtimes append a model identifier after the numeric
# iOS version; only the numeric version prefix participates in ordering.
def runtime_version(device):
    match=re.search(r'\.iOS-(\d+(?:-\d+)*)',device['runtime'])
    if not match: raise ValueError('Unrecognized simulator runtime identifier')
    return tuple(map(int,match.group(1).split('-')))
candidates.sort(key=runtime_version,reverse=True)
# Both Duo and ordinary-phone 27.2 runtimes have stalled before fixtures run
# under Xcode 27.1. Select a runtime no newer than this build's actual SDK.
sdk_version=tuple(map(int,json.loads(pathlib.Path('build/toolchain.json').read_text())['sdk'].split('.')))
normalize_version=lambda value:(value+(0,0,0))[:3]
compatible=[d for d in candidates if normalize_version(runtime_version(d))<=normalize_version(sdk_version)]
if not compatible: raise SystemExit('Missing SDK-compatible simulator for profile '+profile)
candidates=compatible
device=candidates[0]
# Pre-provisioned CI devices can report Booted while installd never responds.
# Create an isolated device with the same observed type/runtime; do not erase
# or modify the runner's existing devices to recover from an install timeout.
types=json.loads(command('xcrun','simctl','list','devicetypes','--json').stdout)['devicetypes']
device_type=next(t['identifier'] for t in types if t['name']==device['name'])
udid=command('xcrun','simctl','create','RuntimeProbe-'+str(os.getpid()),device_type,device['runtime']).stdout.strip()
assert re.fullmatch(r'[0-9A-Fa-f-]{36}',udid), 'Unexpected new simulator identifier'
device=dict(device,udid=udid,state='Shutdown')
(output/'device.json').write_text(json.dumps({'name':device['name'],'runtime':device['runtime'],'profile':profile,'environment':'simulator','freshDevice':True,'deviceType':device_type,'sdk':'.'.join(map(str,sdk_version))},indent=2))
command('xcrun','simctl','help',check=False)
command('xcrun','simctl','io',udid,'help',check=False)
container=None
fixture_containers={}
test_started=time.time()
observer_results=[]
result={'passed':False,'error':'No report before timeout'}
class RoutingMock(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args): pass
    def do_GET(self):
        passed=self.path in ['/local/manage/status','/local/manage/training','/local/manage/training-interaction'] and self.headers.get('X-Local-Maintenance')=='FIXTURE_MAINTENANCE'
        state={'retcode':0,'ready':passed,'fullSaveAt':'2026-11-12T12:00:00Z'}
        if self.path.endswith('/training-interaction'):state['interaction']={'inArena':True,'station':{'label':'元素设置','section':'elements'}}
        if self.path.endswith('/training'):state.update(online=True,bosses=[{'id':1,'name':'测试目标甲','available':True,'note':'选择'},{'id':2,'name':'测试目标乙','available':False,'note':'未开放'}],results=[],dps={'active':False})
        data=json.dumps(state).encode()
        self.send_response(200 if passed else 403);self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
    def do_POST(self):
        size=int(self.headers.get('Content-Length','0'))
        body=self.rfile.read(size) if 0<=size<=4096 else b''
        if self.path=='/local/manage/training-action':
            value=json.loads(body);passed=self.headers.get('X-Local-Maintenance')=='FIXTURE_MAINTENANCE' and value=={'action':'labPrepare','args':{'preset':'custom','seconds':120,'level':100,'energy':-1,'heal':True,'defense':100,'resistances':dict.fromkeys(['physical','fire','water','ice','electric','grass','wind','rock'],10),'immunities':[],'aura':'none','chart':False,'panel':False,'resistanceHud':False}}
            (output/'training-action.json').write_text(json.dumps({'passed':passed,'action':value},indent=2))
            data=json.dumps({'retcode':0 if passed else -1,'online':True,'ready':True,'message':'木桩已就位','dps':{'mode':'lab','phase':'ready','prepared':True,'active':False,'canStart':True,'remainingSeconds':120}}).encode()
            self.send_response(200);self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);return
        passed=(self.path=='/hk4e_cn/mdk/shield/api/login?token=FIXTURE_INPUT_NEVER_RECORD&encoded=a%2Bb%2Fc%25'
            and body==b'{"fixture":"not-an-account","nonce":"routing-test"}'
            and self.headers.get('Content-Type')=='application/json')
        data=json.dumps({'passed':passed}).encode()
        self.send_response(200);self.send_header('Content-Type','application/json')
        self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
mock=http.server.ThreadingHTTPServer(('127.0.0.1',8088),RoutingMock)
threading.Thread(target=mock.serve_forever,daemon=True).start()
try:
    if device['state']!='Booted': command('xcrun','simctl','boot',udid)
    command('xcrun','simctl','bootstatus',udid,'-b',timeout=240)
    geometry={}
    for label in ['Legacy','Modern']:
        bundle='local.astaps.DuoGeometry'+label
        command('xcrun','simctl','install',udid,'build/DuoGeometry'+label+'.app')
        container_path=pathlib.Path(command('xcrun','simctl','get_app_container',udid,bundle,'data').stdout.strip())
        evidence=container_path/'Documents/duo-geometry.json'
        if evidence.exists():evidence.unlink()
        launched=command('xcrun','simctl','launch',udid,bundle)
        for _ in range(15):
            if evidence.exists():break
            time.sleep(1)
        geometry[label]=json.loads(evidence.read_text())
        command('xcrun','simctl','io',udid,'screenshot','--display=3',str(output/('duo-sdk-'+label+'.png')),check=False,timeout=30)
        command('xcrun','simctl','terminate',udid,bundle,check=False,timeout=15)
    geometry['modernWindowFillsDisplay']=geometry['Modern']['windowAreaFraction']>.97
    geometry['logicalAreaGain']=(geometry['Modern']['window'][0]*geometry['Modern']['window'][1])/(geometry['Legacy']['window'][0]*geometry['Legacy']['window'][1])
    geometry['compatibilityGateObserved']=geometry['logicalAreaGain']>1.1
    geometry['actualGameTested']=False
    (output/'duo-sdk-compatibility.json').write_text(json.dumps(geometry,indent=2))
    for variant,arguments in [('ObserverFixture',[]),('ObserverFixtureWrong',['--expect-observer-disabled']),('ObserverFixtureEmbedded',['--probe-embedded-runtime']),('ObserverFixtureRouting',['--expect-local-routing'])]:
        bundle={'ObserverFixtureEmbedded':'local.astaps.ObserverFixture.Embedded','ObserverFixtureRouting':'local.astaps.ObserverFixture.Routing'}.get(variant,'local.astaps.'+variant)
        command('xcrun','simctl','install',udid,'build/'+variant+'.app')
        fixture_container=pathlib.Path(command('xcrun','simctl','get_app_container',udid,bundle,'data').stdout.strip())
        fixture_containers[variant]=fixture_container
        for old in ['observer-fixture.json','embedded-fixture.json','embedded-request.json','routing-http-fixture.json','RuntimeIntegration/client-observations.json','EmbeddedRuntime/runtime-probe.json','EmbeddedRuntime/host-status.json','EmbeddedRuntime/native-lookup.json']:
            stale=fixture_container/'Documents'/old
            if stale.is_file(): stale.unlink()
        launched=command('xcrun','simctl','launch',udid,bundle,*arguments,timeout=60)
        pid_match=re.search(re.escape(bundle)+r':\s*(\d+)',launched.stdout)
        assert pid_match, 'Missing fixture process identifier'
        fixture_pid=int(pid_match.group(1))
        fixture_report=fixture_container/'Documents/observer-fixture.json'
        for _ in range(30):
            if fixture_report.is_file(): break
            time.sleep(1)
        fixture_result=json.loads(fixture_report.read_text()) if fixture_report.is_file() else {'passed':False,'error':'No observer fixture report'}
        fixture_result['fixture']=variant
        observer_results.append(fixture_result)
        (output/(variant+'.json')).write_text(json.dumps(fixture_result,indent=2))
        observations=fixture_container/'Documents/RuntimeIntegration/client-observations.json'
        if observations.is_file(): shutil.copy2(observations,output/(variant+'-observations.json'))
        if variant=='ObserverFixtureRouting':
            http_report=fixture_container/'Documents/routing-http-fixture.json'
            for _ in range(15):
                if http_report.is_file(): break
                time.sleep(1)
            http_result=json.loads(http_report.read_text()) if http_report.is_file() else {'passed':False,'error':'No loopback HTTP report'}
            fixture_result['loopback_http']=http_result
            fixture_result['passed']=fixture_result.get('passed') is True and http_result.get('passed') is True
            support_report=fixture_container/'Documents/play-support-fixture.json'
            for _ in range(30):
                if support_report.is_file(): break
                time.sleep(1)
            support=json.loads(support_report.read_text()) if support_report.is_file() else {'passed':False,'error':'No native support report'}
            fixture_result['play_support']=support
            fixture_result['passed'] &= support.get('passed') is True
            (output/'play-support-fixture.json').write_text(json.dumps(support,indent=2))
            support_png=fixture_container/'Documents/play-support-menu.png'
            if support_png.is_file(): shutil.copy2(support_png,output/'play-support-menu.png')
            entry_png=fixture_container/'Documents/play-support-minimap-icon.png'
            if entry_png.is_file(): shutil.copy2(entry_png,output/'play-support-minimap-icon.png')
            training_png=fixture_container/'Documents/training-panel.png'
            if training_png.is_file():shutil.copy2(training_png,output/'training-panel.png')
            action_report=output/'training-action.json'
            fixture_result['passed'] &= action_report.is_file() and json.loads(action_report.read_text()).get('passed') is True
            if observations.is_file():
                raw=observations.read_text()
                fixture_result['observations_exclude_sensitive_input']=all(x not in raw for x in ['FIXTURE_INPUT_NEVER_RECORD','token=','encoded=','routing-test','not-an-account'])
                fixture_result['passed'] &= fixture_result['observations_exclude_sensitive_input']
            (output/(variant+'.json')).write_text(json.dumps(fixture_result,indent=2))
        if variant=='ObserverFixtureEmbedded':
            embedded_report=fixture_container/'Documents/embedded-fixture.json'
            for _ in range(120):
                if embedded_report.is_file(): break
                time.sleep(1)
            embedded=json.loads(embedded_report.read_text()) if embedded_report.is_file() else {'passed':False,'error':'No dynamic JVM report'}
            fixture_result['embedded_runtime']=embedded
            fixture_result['passed']=fixture_result.get('passed') is True and embedded.get('passed') is True
            (output/(variant+'.json')).write_text(json.dumps(fixture_result,indent=2))
            for evidence in [fixture_container/'Documents/embedded-request.json',fixture_container/'Documents/EmbeddedRuntime/host-status.json',fixture_container/'Documents/EmbeddedRuntime/runtime-probe.json']:
                if evidence.is_file(): shutil.copy2(evidence,output/(variant+'-'+evidence.name))
        # simctl terminate can hang during native-library global teardown and
        # block the entire CoreSimulator channel. End only our verified fixture
        # PID directly; never signal an unrelated process or use a broad pkill.
        process=command('ps','-p',str(fixture_pid),'-o','comm=',check=False,timeout=5)
        executable=process.stdout.strip()
        if executable:
            assert udid in executable and executable.endswith('/'+variant+'.app/ObserverFixture'), executable
            os.kill(fixture_pid,signal.SIGKILL)
    command('xcrun','simctl','install',udid,'build/DerivedData/Build/Products/Release-iphonesimulator/RuntimeProbe.app')
    container=pathlib.Path(command('xcrun','simctl','get_app_container',udid,'local.astaps.RuntimeProbe','data').stdout.strip())
    try:
        command('xcrun','simctl','launch','--terminate-running-process',udid,'local.astaps.RuntimeProbe','--probe-auto-run','--checksum-benchmark',timeout=60)
    except (subprocess.TimeoutExpired,subprocess.CalledProcessError):
        log('Launch did not return normally; collecting the installed app evidence anyway.')
    report=container/'Documents/runtime-probe.json'
    for _ in range(120):
        if report.is_file(): break
        time.sleep(1)
    if report.is_file(): result=json.loads(report.read_text())
    benchmark=container/'Documents/checksum-benchmark.json'
    result['checksum_benchmark']=json.loads(benchmark.read_text()) if benchmark.is_file() else {'passed':False,'error':'Missing checksum benchmark'}
    parser_report=container/'Documents/background-parser-tests.json'
    result['background_parser']=json.loads(parser_report.read_text()) if parser_report.is_file() else {'passed':False,'error':'Missing parser tests'}
    result['passed']=result.get('passed') is True and result['checksum_benchmark'].get('passed') is True and result['background_parser'].get('passed') is True and len(observer_results)==4 and all(x.get('passed') is True for x in observer_results)
except Exception as failure:
    result={'passed':False,'error':repr(failure)}
finally:
    mock.shutdown();mock.server_close()
    for variant,fixture_container in fixture_containers.items():
        for failure_report in fixture_container.rglob('hs_err_pid*.log'):
            if failure_report.stat().st_size<4_000_000:
                shutil.copy2(failure_report,output/(variant+'-'+failure_report.name))
        for relative in ['observer-fixture.json','embedded-fixture.json','embedded-request.json','routing-http-fixture.json','RuntimeIntegration/client-observations.json','EmbeddedRuntime/host-status.json','EmbeddedRuntime/runtime-probe.json','EmbeddedRuntime/jvm-output.log','EmbeddedRuntime/native-lookup.json']:
            source=fixture_container/'Documents'/relative
            if source.is_file(): shutil.copy2(source,output/(variant+'-'+source.name))
    crash_directory=pathlib.Path.home()/'Library/Logs/DiagnosticReports'
    for source in crash_directory.glob('ObserverFixture*.ips'):
        if source.stat().st_mtime>=test_started and source.stat().st_size<5_000_000:
            shutil.copy2(source,output/source.name)
    if result.get('passed') is not True:
        try:
            failure_log=command('xcrun','simctl','spawn',udid,'log','show','--last','2m','--style','compact','--predicate',
                'process == "ObserverFixture" OR eventMessage CONTAINS "local.astaps.ObserverFixture"',check=False,timeout=30)
            (output/'fixture-launch-log.txt').write_text((failure_log.stdout or '')[-200000:])
        except (subprocess.TimeoutExpired,subprocess.CalledProcessError): pass
    if container:
        for source in (container/'Documents').glob('*'):
            if source.is_file() and (source.name in ['runtime-probe.json','jvm-output.log','host-status.json','layout-history.json','checksum-benchmark.json','background-trial.json','background-registration.json','background-parser-tests.json','lifecycle.jsonl'] or source.name.startswith('hs_err_pid')):
                shutil.copy2(source,output/source.name)
    try:
        command('xcrun','simctl','io',udid,'enumerate',check=False,timeout=30)
        shot=command('xcrun','simctl','io',udid,'screenshot',str(output/'screen.png'),check=False,timeout=30)
        displays=re.findall(r'--display=(\S+)\s+([^\n]+?)\s+(\d+)x(\d+)',shot.stderr or '')
        captures=[]
        if shot.returncode==0: captures.append('screen.png')
        for identifier,name,width,height in displays:
            if not identifier.isdigit(): continue
            filename='screen-display-'+identifier+'.png'
            capture=command('xcrun','simctl','io',udid,'screenshot','--display='+identifier,str(output/filename),check=False,timeout=30)
            if capture.returncode==0: captures.append(filename)
        result['screenshots']=captures
        result['display_inventory']=[{'id':i,'name':n,'pixels':[int(w),int(h)]} for i,n,w,h in displays]
        result['fold_transitions_verified']=False
        if not captures: result['visual_capture_error']='No display screenshot was captured'
    except Exception as failure:
        result['visual_capture_error']=repr(failure)
        log('Screenshot unavailable: '+repr(failure))
result['environment']='iOS Simulator, not a physical iPhone'
result['simulator_device']=device['name']
result['duo_device_selected']=device['name']=='iPhone Duo'
result['duo_device_tested']=device['name']=='iPhone Duo' and bool(observer_results)
result['observer_fixtures']=observer_results
(output/'acceptance.json').write_text(json.dumps(result,indent=2))
print(json.dumps(result,indent=2))
if not result['passed']: raise SystemExit('Simulator runtime probe failed; inspect retained results')
PY
exit 0
fi
mkdir -p build/Payload
cp -R build/DerivedData/Build/Products/Release-iphoneos/RuntimeProbe.app build/Payload/
(cd build && zip -qr RuntimeProbe.ipa Payload)
echo 'Unsigned 0.6 experimental IPA and host integration kit created. Physical validation is still required.'
