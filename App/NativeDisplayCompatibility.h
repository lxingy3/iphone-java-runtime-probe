// Scene changes can make the engine request the primary display through its
// external-display path. Rebind the existing host surface; never create a
// competing window, suppress assertions globally, or resize the render view.
#import <objc/message.h>
#import <objc/runtime.h>

static id RPSGetObject(id object,NSString *name) {
    SEL selector=NSSelectorFromString(name);
    return [object respondsToSelector:selector]?((id(*)(id,SEL))objc_msgSend)(object,selector):nil;
}
static UIView *RPSUnitySurfaceIn(UIView *view) {
    if([NSStringFromClass(view.class) isEqual:@"UnityView"])return view;
    for(UIView *child in view.subviews){UIView *found=RPSUnitySurfaceIn(child);if(found)return found;}
    return nil;
}
static UIView *RPSCurrentGameSurface(void) {
    if(!NSThread.isMainThread)return nil;
    id direct=RPSGetObject(UIApplication.sharedApplication.delegate,@"unityView");
    UIView *delegateSurface=[direct isKindOfClass:UIView.class]?direct:nil;
    if(delegateSurface.window.windowScene&&delegateSurface.window.windowScene.activationState==UISceneActivationStateForegroundActive &&
       !delegateSurface.window.hidden)return delegateSurface;
    for(UIScene *scene in UIApplication.sharedApplication.connectedScenes){
        if(![scene isKindOfClass:UIWindowScene.class]||scene.activationState!=UISceneActivationStateForegroundActive)continue;
        for(UIWindow *window in ((UIWindowScene *)scene).windows){
            if(window.hidden||window.windowLevel!=UIWindowLevelNormal)continue;
            UIView *view=RPSUnitySurfaceIn(window.rootViewController.view);if(view)return view;
        }
    }
    // During a scene's activation transition UIKit can temporarily have no
    // foreground-active scene. Only the engine's own attached view is eligible.
    return delegateSurface.window&&!delegateSurface.window.hidden?delegateSurface:nil;
}
static BOOL RPSMethodMatches(Class cls,NSString *name,const char *result,NSArray<NSString *> *arguments) {
    Method method=class_getInstanceMethod(cls,NSSelectorFromString(name));if(!method||method_getNumberOfArguments(method)!=arguments.count+2)return NO;
    char type[64]={0};method_getReturnType(method,type,sizeof(type));if(strcmp(type,result))return NO;
    for(NSUInteger i=0;i<arguments.count;i++){method_getArgumentType(method,(unsigned)i+2,type,sizeof(type));if(![arguments[i] containsString:[NSString stringWithUTF8String:type]])return NO;}
    return YES;
}
@interface RPSDisplayCompatibility : NSObject
+ (BOOL)installForDisplayClass:(Class)cls surfaceProvider:(UIView *(^)(void))provider;
+ (BOOL)bindPrimaryDisplay:(id)display surface:(UIView *)surface;
+ (void)install;
+ (NSDictionary *)snapshot;
@end
static NSUInteger RPSDisplayRepairs,RPSDisplayLookups;
static BOOL RPSDisplayInstalled,RPSLookupInstalled;
@implementation RPSDisplayCompatibility
+ (BOOL)bindPrimaryDisplay:(id)display surface:(UIView *)surface {
    if(!NSThread.isMainThread||!surface.window||!surface.window.windowScene)return NO;
    UIWindow *window=surface.window;
    if(RPSGetObject(display,@"screen")!=window.windowScene.screen)return NO;
    UIView *bound=RPSGetObject(display,@"view");
    if(bound&&bound!=surface){
        UIWindow *oldWindow=bound.window;
        BOOL retired=!oldWindow||oldWindow.hidden||
            (oldWindow!=window&&oldWindow.windowScene.activationState!=UISceneActivationStateForegroundActive);
        if(!retired)return NO;
    }
    if(bound!=surface||RPSGetObject(display,@"window")!=window){
        ((void(*)(id,SEL,id,id))objc_msgSend)(display,NSSelectorFromString(@"createWithWindow:andView:"),window,surface);
        RPSDisplayRepairs++;
    }
    return YES;
}
+ (BOOL)installForDisplayClass:(Class)cls surfaceProvider:(UIView *(^)(void))provider {
    if(!cls||!provider||!RPSMethodMatches(cls,@"createView:showRightAway:","v",@[@"Bc",@"Bc"])||
       !RPSMethodMatches(cls,@"createWithWindow:andView:","v",@[@"@",@"@"]))return NO;
    for(NSString *getter in @[@"screen",@"view",@"window"])if(!RPSMethodMatches(cls,getter,"@",@[]))return NO;
    static NSMutableSet *installed; if(!installed)installed=[NSMutableSet new];
    NSString *name=NSStringFromClass(cls);if([installed containsObject:name])return YES;
    SEL selector=NSSelectorFromString(@"createView:showRightAway:");Method method=class_getInstanceMethod(cls,selector);IMP original=method_getImplementation(method);
    IMP wrapper=imp_implementationWithBlock(^(id receiver,BOOL render,BOOL show){
        if(NSThread.isMainThread&&[self bindPrimaryDisplay:receiver surface:provider()])return;
        ((void(*)(id,SEL,BOOL,BOOL))original)(receiver,selector,render,show);
    });
    class_replaceMethod(cls,selector,wrapper,method_getTypeEncoding(method));[installed addObject:name];return YES;
}
+ (void)install {
    static dispatch_once_t once;dispatch_once(&once,^{
        RPSDisplayInstalled=[self installForDisplayClass:NSClassFromString(@"DisplayConnection") surfaceProvider:^UIView *{return RPSCurrentGameSurface();}];
        Class manager=NSClassFromString(@"DisplayManager");SEL selector=NSSelectorFromString(@"objectForKeyedSubscript:");
        if(RPSDisplayInstalled&&RPSMethodMatches(manager,NSStringFromSelector(selector),"@",@[@"@"])){
            Method method=class_getInstanceMethod(manager,selector);IMP original=method_getImplementation(method);
            IMP wrapper=imp_implementationWithBlock(^id(id receiver,id key){
                id display=((id(*)(id,SEL,id))original)(receiver,selector,key);
                if(NSThread.isMainThread){RPSDisplayLookups++;[self bindPrimaryDisplay:display surface:RPSCurrentGameSurface()];}
                return display;
            });
            class_replaceMethod(manager,selector,wrapper,method_getTypeEncoding(method));RPSLookupInstalled=YES;
        }
    });
}
+ (NSDictionary *)snapshot{return @{@"primaryBindingHook":@(RPSDisplayInstalled),@"displayLookupHook":@(RPSLookupInstalled),@"primaryRebinds":@(RPSDisplayRepairs),@"displayLookups":@(RPSDisplayLookups)};}
@end
