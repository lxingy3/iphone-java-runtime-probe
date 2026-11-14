// Independent simulator host: real Metal drawables, synthetic window geometry.
// This does not contain or claim to test the game's renderer or physical hinge.
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import "NativeDisplayCompatibility.h"

@interface RPTransitionDisplay : NSObject
@property(nonatomic,strong) id screen;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIView *view;
@property(nonatomic) NSUInteger externalCreates,binds;
- (void)createView:(BOOL)render showRightAway:(BOOL)show;
- (void)createWithWindow:(UIWindow *)window andView:(UIView *)view;
@end
@implementation RPTransitionDisplay
- (void)createView:(BOOL)render showRightAway:(BOOL)show {
    NSAssert(self.screen!=self.window.windowScene.screen,@"Primary display needs the host surface");
    self.externalCreates++;
}
- (void)createWithWindow:(UIWindow *)window andView:(UIView *)view {
    self.window=window;self.view=view;self.binds++;
}
@end

@interface RPTransitionSurface : UIView
@end
@implementation RPTransitionSurface
+ (Class)layerClass{return CAMetalLayer.class;}
@end

@interface RPTransitionRunner : NSObject
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) RPTransitionSurface *surface;
@property(nonatomic,strong) RPTransitionDisplay *display;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) NSArray<NSDictionary *> *steps;
@property(nonatomic,strong) NSMutableArray *results;
@property(nonatomic) NSUInteger index,frames,presented;
@property(nonatomic) BOOL done,baseline;
- (void)next;
@end
@implementation RPTransitionRunner
- (void)finish:(NSString *)failure {
    if(self.done)return;self.done=YES;
    BOOL passed=!failure.length&&self.results.count==self.steps.count;
    for(NSDictionary *row in self.results)passed&=[row[@"passed"] boolValue];
    NSDictionary *report=@{@"passed":@(passed),@"failure":failure?:@"",@"steps":self.results,
        @"framesReadBack":@(self.frames),@"drawablesPresented":@(self.presented),
        @"baseline":@(self.baseline),@"syntheticWindowGeometry":@YES,
        @"physicalHingeTested":@NO,@"actualGameRendererTested":@NO};
    NSString *doc=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil]
        writeToFile:[doc stringByAppendingPathComponent:@"display-transition-fixture.json"] atomically:YES];
}
- (void)renderStep:(NSDictionary *)step binding:(BOOL)binding touch:(BOOL)touch {
    CAMetalLayer *layer=(CAMetalLayer *)self.surface.layer;
    id<CAMetalDrawable> drawable=[layer nextDrawable];
    if(!drawable){[self finish:@"Metal returned no drawable"];return;}
    NSUInteger sequence=self.index;
    uint8_t red=(uint8_t)(31+(sequence*53)%190),green=(uint8_t)(17+(sequence*29)%210);
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=drawable.texture;
    pass.colorAttachments[0].loadAction=MTLLoadActionClear;
    pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.colorAttachments[0].clearColor=MTLClearColorMake(red/255.,green/255.,0,1);
    id<MTLCommandBuffer> command=[self.queue commandBuffer];
    [[command renderCommandEncoderWithDescriptor:pass] endEncoding];
    id<MTLBuffer> pixel=[self.device newBufferWithLength:256 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromTexture:drawable.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(1,1,1) toBuffer:pixel destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256];
    [blit endEncoding];
    __block BOOL completed=NO,presented=NO,readback=NO;
    __weak RPTransitionRunner *weak=self;
    void (^advance)(void)=^{
        RPTransitionRunner *runner=weak;
        if(!runner||runner.done||runner.index!=sequence||!completed||!presented)return;
        NSMutableDictionary *row=[step mutableCopy];
        row[@"binding"]=@(binding);row[@"touchRoundTrip"]=@(touch);row[@"pixelChanged"]=@(readback);row[@"presented"]=@YES;
        row[@"passed"]=@(binding&&touch&&readback);
        [runner.results addObject:row];runner.index++;
        dispatch_async(dispatch_get_main_queue(),^{[runner next];});
    };
    [drawable addPresentedHandler:^(id<MTLDrawable> value){
        dispatch_async(dispatch_get_main_queue(),^{presented=value.presentedTime>0;weak.presented+=presented;advance();});
    }];
    [command addCompletedHandler:^(id<MTLCommandBuffer> value){
        const uint8_t *bytes=pixel.contents;
        BOOL valid=value.status==MTLCommandBufferStatusCompleted&&abs((int)bytes[2]-red)<=1&&abs((int)bytes[1]-green)<=1&&bytes[0]==0&&bytes[3]==255;
        dispatch_async(dispatch_get_main_queue(),^{completed=YES;readback=valid;weak.frames++;advance();});
    }];
    [command presentDrawable:drawable];[command commit];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if(weak&&!weak.done&&weak.index==sequence)[weak finish:!completed?@"GPU command stalled":@"Drawable presentation stalled"];
    });
}
- (void)next {
    if(self.done)return;
    if(self.index==self.steps.count){[self finish:nil];return;}
    NSDictionary *step=self.steps[self.index];
    UIView *host=self.window.rootViewController.view;
    NSUInteger mode=self.index%4;
    if(!self.surface||mode==2){
        [self.surface removeFromSuperview];
        // Mode 2 deliberately leaves the old detached surface in DisplayConnection.
        self.surface=[RPTransitionSurface new];[host addSubview:self.surface];
        CAMetalLayer *layer=(CAMetalLayer *)self.surface.layer;
        layer.device=self.device;layer.pixelFormat=MTLPixelFormatBGRA8Unorm;layer.framebufferOnly=NO;
    }
    if(mode==0){self.display.view=nil;self.display.window=nil;}
    else if(mode==3){
        UIWindow *retired=[[UIWindow alloc] initWithWindowScene:self.window.windowScene];
        retired.hidden=YES;retired.rootViewController=[UIViewController new];
        UIView *old=[UIView new];[retired.rootViewController.view addSubview:old];
        self.display.view=old;self.display.window=retired;
    }
    CGFloat width=[step[@"width"] doubleValue],height=[step[@"height"] doubleValue];
    CGFloat angle=[step[@"turn"] doubleValue]*M_PI_2;
    self.surface.transform=CGAffineTransformIdentity;self.surface.bounds=CGRectMake(0,0,width,height);
    CGFloat fit=MIN(host.bounds.size.width/(fabs(cos(angle))*width+fabs(sin(angle))*height),host.bounds.size.height/(fabs(sin(angle))*width+fabs(cos(angle))*height));
    self.surface.center=CGPointMake(CGRectGetMidX(host.bounds),CGRectGetMidY(host.bounds));
    self.surface.transform=CGAffineTransformScale(CGAffineTransformMakeRotation(angle),fit,fit);
    CAMetalLayer *layer=(CAMetalLayer *)self.surface.layer;
    // Pixel dimensions deliberately change; points and pixels are not interchangeable.
    layer.contentsScale=[step[@"scale"] doubleValue];layer.drawableSize=CGSizeMake(round(width*layer.contentsScale),round(height*layer.contentsScale));
    self.display.screen=self.window.windowScene.screen;
    BOOL binding=YES;
    @try{[self.display createView:YES showRightAway:YES];}@catch(NSException *error){binding=NO;}
    binding&=self.display.window==self.window&&self.display.view==self.surface;
    CGPoint p=CGPointMake(width*.31,height*.63),global=[self.surface convertPoint:p toView:host],back=[host convertPoint:global toView:self.surface];
    BOOL touch=hypot(p.x-back.x,p.y-back.y)<.01&&[host hitTest:global withEvent:nil]==self.surface;
    [self renderStep:step binding:binding touch:touch];
}
@end

static void RPCStartDisplayTransitions(UIWindow *window) {
    static RPTransitionRunner *runner;if(runner)return;
    runner=[RPTransitionRunner new];runner.window=window;runner.results=[NSMutableArray new];
    runner.device=MTLCreateSystemDefaultDevice();runner.queue=[runner.device newCommandQueue];
    runner.display=[RPTransitionDisplay new];
    runner.baseline=[NSProcessInfo.processInfo.arguments containsObject:@"--baseline-display-binding"];
    if(!runner.device||!runner.queue){[runner finish:@"Metal device unavailable"];return;}
    if(!runner.baseline){
        __weak RPTransitionRunner *weak=runner;
        if(![RPSDisplayCompatibility installForDisplayClass:RPTransitionDisplay.class surfaceProvider:^UIView *{return weak.surface;}]){
            [runner finish:@"Display binding hook was not installed"];return;
        }
    }
    // State labels are coverage profiles, not claimed hardware measurements.
    NSArray *states=@[
        @{@"name":@"inner-full",@"width":@951,@"height":@669,@"scale":@2},
        @{@"name":@"inner-left-half",@"width":@467,@"height":@669,@"scale":@2},
        @{@"name":@"inner-right-half",@"width":@467,@"height":@669,@"scale":@2},
        @{@"name":@"inner-narrow",@"width":@320,@"height":@669,@"scale":@2},
        @{@"name":@"inner-wide",@"width":@623,@"height":@669,@"scale":@2},
        @{@"name":@"inner-stacked",@"width":@669,@"height":@460,@"scale":@2},
        @{@"name":@"outer-compact",@"width":@375,@"height":@812,@"scale":@3}];
    NSMutableArray *steps=[NSMutableArray new];
    for(NSInteger turn=0;turn<4;turn++)for(NSDictionary *from in states)for(NSDictionary *to in states){
        if(from==to)continue;
        NSMutableDictionary *row=[to mutableCopy];row[@"from"]=from[@"name"];row[@"turn"]=@(turn);
        // Visit both source and destination, preserving the engine connection.
        NSMutableDictionary *source=[from mutableCopy];source[@"from"]=@"sequence";source[@"turn"]=@(turn);
        [steps addObject:source];[steps addObject:row];
    }
    for(NSInteger n=0;n<40;n++)[steps addObject:@{@"name":@"divider-drag",@"from":@"divider-drag",@"width":@(320+(n<20?n:39-n)*31),@"height":@669,@"scale":@2,@"turn":@0}];
    runner.steps=steps;[runner next];
}
