// Independent UIKit/Metal observer. Contains no game code, resources or accounts.
// The driver changes Simulator screen configuration; this app never assigns view bounds.
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <unistd.h>

static NSString *RPDocuments(void) {
    return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
}
static NSString *RPIdentity(id object) {return object?[NSString stringWithFormat:@"%p",(__bridge void *)object]:@"nil";}
static NSArray *RPSize(CGSize size) {return @[@(size.width),@(size.height)];}

@interface RPSystemSurface : UIView
@end
@implementation RPSystemSurface
+ (Class)layerClass {return CAMetalLayer.class;}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *layer=(CAMetalLayer *)self.layer;
    CGFloat scale=self.window.windowScene.screen.scale;
    if(scale>0&&self.bounds.size.width>0&&self.bounds.size.height>0){
        layer.contentsScale=scale;
        layer.drawableSize=CGSizeMake(round(self.bounds.size.width*scale),round(self.bounds.size.height*scale));
    }
}
@end

@interface RPSystemController : UIViewController
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) CADisplayLink *link;
@property(nonatomic,copy) NSString *launchID,*firstScreen,*geometryError;
@property(nonatomic,strong) NSMutableArray *events;
@property(nonatomic) NSUInteger request,submitted,completed,lastFrameRequest;
@property(nonatomic) NSInteger red,green;
@property(nonatomic) BOOL rendering,lastReadback;
@end
@implementation RPSystemController
- (void)loadView {self.view=[RPSystemSurface new];self.view.backgroundColor=UIColor.blackColor;}
- (BOOL)prefersStatusBarHidden {return YES;}
- (BOOL)shouldAutorotate {return YES;}
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskAll;}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.launchID=NSUUID.UUID.UUIDString;self.events=[NSMutableArray new];
    self.device=MTLCreateSystemDefaultDevice();self.queue=[self.device newCommandQueue];
    CAMetalLayer *layer=(CAMetalLayer *)self.view.layer;
    layer.device=self.device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=NO;
    CGColorSpaceRef space=CGColorSpaceCreateWithName(kCGColorSpaceSRGB);layer.colorspace=space;CGColorSpaceRelease(space);
    self.red=47;self.green=73;
    self.link=[CADisplayLink displayLinkWithTarget:self selector:@selector(draw)];
    self.link.preferredFrameRateRange=CAFrameRateRangeMake(10,30,30);
    [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [NSTimer scheduledTimerWithTimeInterval:.2 repeats:YES block:^(NSTimer *timer){[self readRequest];[self snapshot];}];
    for(NSNotificationName name in @[UIScreenDidConnectNotification,UIScreenDidDisconnectNotification,UIScreenModeDidChangeNotification,UIApplicationDidBecomeActiveNotification,UIApplicationWillResignActiveNotification]){
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note){
            [self.events addObject:@{@"name":note.name,@"at":@([NSDate.date timeIntervalSince1970]),@"object":RPIdentity(note.object)}];
            if(self.events.count>100)[self.events removeObjectAtIndex:0];
        }];
    }
}
- (void)readRequest {
    NSData *data=[NSData dataWithContentsOfFile:[RPDocuments() stringByAppendingPathComponent:@"system-display-request.json"]];
    NSDictionary *value=data?[NSJSONSerialization JSONObjectWithData:data options:0 error:nil]:nil;
    NSUInteger request=[value[@"sequence"] unsignedIntegerValue];if(!request||request==self.request)return;
    self.request=request;self.red=31+(request*53)%190;self.green=17+(request*29)%210;self.geometryError=@"";
    if(value[@"orientation"]&&self.view.window.windowScene){
        UIInterfaceOrientationMask mask=[value[@"orientation"] unsignedIntegerValue];
        UIWindowSceneGeometryPreferencesIOS *preference=[[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
        [self.view.window.windowScene requestGeometryUpdateWithPreferences:preference errorHandler:^(NSError *error){self.geometryError=error.localizedDescription;}];
    }
}
- (void)draw {
    if(self.rendering||UIApplication.sharedApplication.applicationState!=UIApplicationStateActive||!self.view.window||self.view.window.hidden)return;
    CAMetalLayer *layer=(CAMetalLayer *)self.view.layer;
    if(layer.drawableSize.width<1||layer.drawableSize.height<1)return;
    id<CAMetalDrawable> drawable=[layer nextDrawable];if(!drawable)return;
    self.rendering=YES;NSUInteger sequence=self.request;NSInteger red=self.red,green=self.green;
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=drawable.texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(red/255.,green/255.,0,1);
    id<MTLCommandBuffer> command=[self.queue commandBuffer];[[command renderCommandEncoderWithDescriptor:pass] endEncoding];
    id<MTLBuffer> pixel=[self.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(1,1,1) toBuffer:pixel destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];[blit endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> buffer){
        const uint8_t *bytes=pixel.contents;
        BOOL valid=buffer.status==MTLCommandBufferStatusCompleted&&abs((int)bytes[2]-(int)red)<=1&&abs((int)bytes[1]-(int)green)<=1&&bytes[0]==0&&bytes[3]==255;
        dispatch_async(dispatch_get_main_queue(),^{self.completed++;self.lastFrameRequest=sequence;self.lastReadback=valid;self.rendering=NO;});
    }];
    [command presentDrawable:drawable];self.submitted++;[command commit];
}
- (void)snapshot {
    UIWindow *window=self.view.window;UIWindowScene *scene=window.windowScene;UIScreen *screen=scene.screen;
    if(!self.firstScreen&&screen)self.firstScreen=RPIdentity(screen);
    CAMetalLayer *layer=(CAMetalLayer *)self.view.layer;
    NSMutableArray *screens=[NSMutableArray new];
    for(UIScreen *item in UIScreen.screens)[screens addObject:@{@"identity":RPIdentity(item),@"bounds":RPSize(item.bounds.size),@"native":RPSize(item.nativeBounds.size),@"scale":@(item.scale)}];
    NSDictionary *report=@{@"scope":@"Independent system-driven UIKit/Metal simulator observer",@"actualGameRendererTested":@NO,@"physicalHingeTested":@NO,
        @"at":@([NSDate.date timeIntervalSince1970]),@"pid":@(getpid()),@"launchID":self.launchID,@"sequence":@(self.request),@"lastFrameSequence":@(self.lastFrameRequest),
        @"submitted":@(self.submitted),@"completed":@(self.completed),@"readbackValid":@(self.lastReadback),@"red":@(self.red),@"green":@(self.green),
        @"screen":RPIdentity(screen),@"firstScreen":self.firstScreen?:@"nil",@"screens":screens,@"scene":scene.session.persistentIdentifier?:@"nil",
        @"active":@(scene.activationState==UISceneActivationStateForegroundActive),@"orientation":@(scene.interfaceOrientation),
        @"window":RPSize(window.bounds.size),@"view":RPSize(self.view.bounds.size),@"drawable":RPSize(layer.drawableSize),@"scale":@(layer.contentsScale),
        @"geometryError":self.geometryError?:@"",@"events":self.events};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[RPDocuments() stringByAppendingPathComponent:@"system-display-state.json"] atomically:YES];
}
@end

@interface RPSystemScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation RPSystemScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];self.window.rootViewController=[RPSystemController new];[self.window makeKeyAndVisible];
}
@end
@interface RPSystemApp : UIResponder <UIApplicationDelegate>
@end
@implementation RPSystemApp
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(RPSystemApp.class));}}
