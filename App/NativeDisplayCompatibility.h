// UIKit may replace the screen backing the same Unity window during a resize.
// Preserve the running display connection and let Unity resize its surface.
#import <objc/message.h>
#import <objc/runtime.h>
#include <stdlib.h>

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

typedef struct {
    __unsafe_unretained Class displayClass;
    Ivar connections;
    Ivar screen;
} RPSDisplayRegistry;

static NSUInteger RPSPrimaryScreenMoves;
static RPSDisplayRegistry RPSGameDisplayRegistry;

static BOOL RPSHasDrawingSurface(id display) {
    return display && ((void *(*)(id, SEL))objc_msgSend)(display, sel_registerName("surface")) != NULL;
}

static id RPSActivePrimary(id manager, UIView *view, RPSDisplayRegistry registry) {
    if (!NSThread.isMainThread || !view.window.windowScene || view.window.hidden) return nil;
    id primary = RPSGetObject(manager, @"mainDisplay");
    if (![primary isKindOfClass:registry.displayClass] || RPSGetObject(primary, @"view") != view
        || !RPSHasDrawingSurface(primary)) return nil;
    return primary;
}

static BOOL RPSMovePrimary(id manager, id primary, UIView *view, id screen,
                           RPSDisplayRegistry registry, BOOL *changed) {
    if (changed) *changed = NO;
    if (!screen || !primary || CGRectIsEmpty(view.bounds) || CGRectIsEmpty(view.window.bounds)) return NO;
    NSMapTable *connections = object_getIvar(manager, registry.connections);
    if (![connections isKindOfClass:NSMapTable.class]) return NO;
    id previous = RPSGetObject(primary, @"screen");
    if (!previous) return NO;
    id destination = [connections objectForKey:screen];
    if (destination && destination != primary &&
        (![destination isKindOfClass:registry.displayClass] || RPSHasDrawingSurface(destination)
         || RPSGetObject(destination, @"window") || RPSGetObject(destination, @"view"))) return NO;
    if (previous == screen && destination == primary &&
        RPSGetObject(primary, @"window") == view.window) return YES;

    [connections setObject:primary forKey:screen];
    if (previous != screen) {
        object_setIvar(primary, registry.screen, screen);
        if ([connections objectForKey:previous] == primary) [connections removeObjectForKey:previous];
        RPSPrimaryScreenMoves++;
    }
    ((void (*)(id, SEL, UIWindow *, UIView *))objc_msgSend)(
        primary, sel_registerName("createWithWindow:andView:"), view.window, view);
    [view setNeedsLayout];
    if (changed) *changed = YES;
    return YES;
}

static BOOL RPSInstallRegistryHooks(Class managerClass, Class displayClass,
                                    UIView *(^viewProvider)(void), id (^screenProvider)(UIWindow *),
                                    RPSDisplayRegistry *installedRegistry) {
    if (!managerClass || !displayClass || !viewProvider || !screenProvider ||
        !RPSMethodMatches(managerClass, @"mainDisplay", "@", @[]) ||
        !RPSMethodMatches(managerClass, @"registerScreen:", "v", @[@"@"]) ||
        !RPSMethodMatches(managerClass, @"screenDidDisconnect:", "v", @[@"@"]) ||
        !RPSMethodMatches(managerClass, @"updateDisplayListInUnity", "v", @[]) ||
        !RPSMethodMatches(displayClass, @"screen", "@", @[]) ||
        !RPSMethodMatches(displayClass, @"view", "@", @[]) ||
        !RPSMethodMatches(displayClass, @"window", "@", @[]) ||
        !RPSMethodMatches(displayClass, @"createWithWindow:andView:", "v", @[@"@", @"@"])) return NO;
    Method surface = class_getInstanceMethod(displayClass, sel_registerName("surface"));
    if (!surface || method_getNumberOfArguments(surface) != 2) return NO;
    char *surfaceReturn = method_copyReturnType(surface);
    BOOL pointerResult = surfaceReturn && surfaceReturn[0] == '^';
    free(surfaceReturn);
    if (!pointerResult) return NO;

    RPSDisplayRegistry registry = {displayClass,
        class_getInstanceVariable(managerClass, "_displayConnection"),
        class_getInstanceVariable(displayClass, "_screen")};
    if (!registry.connections || !registry.screen ||
        strcmp(ivar_getTypeEncoding(registry.connections), "@\"NSMapTable\"") ||
        strcmp(ivar_getTypeEncoding(registry.screen), "@\"UIScreen\"")) return NO;

    SEL registerScreen = sel_registerName("registerScreen:");
    Method registration = class_getInstanceMethod(managerClass, registerScreen);
    IMP originalRegister = method_getImplementation(registration);
    class_replaceMethod(managerClass, registerScreen, imp_implementationWithBlock(^(id receiver, id screen) {
        if (NSThread.isMainThread) {
            UIView *view = viewProvider();
            id primary = RPSActivePrimary(receiver, view, registry);
            if (primary && (screen == screenProvider(view.window)
                || screen == RPSGetObject(primary, @"screen")) &&
                RPSMovePrimary(receiver, primary, view, screen, registry, NULL)) return;
        }
        ((void (*)(id, SEL, id))originalRegister)(receiver, registerScreen, screen);
    }), method_getTypeEncoding(registration));

    SEL screenDidDisconnect = sel_registerName("screenDidDisconnect:");
    SEL updateDisplayList = sel_registerName("updateDisplayListInUnity");
    Method disconnection = class_getInstanceMethod(managerClass, screenDidDisconnect);
    IMP originalDisconnect = method_getImplementation(disconnection);
    class_replaceMethod(managerClass, screenDidDisconnect, imp_implementationWithBlock(^(id receiver, NSNotification *notice) {
        if (NSThread.isMainThread) {
            UIView *view = viewProvider();
            id primary = RPSActivePrimary(receiver, view, registry);
            if (primary && notice.object == RPSGetObject(primary, @"screen")) {
                // A disconnect may arrive before the scene publishes its new screen.
                // Keep the live surface until UIKit has an attached destination.
                BOOL changed;
                RPSMovePrimary(receiver, primary, view, screenProvider(view.window), registry, &changed);
                if (changed) ((void (*)(id, SEL))objc_msgSend)(receiver, updateDisplayList);
                return;
            }
        }
        ((void (*)(id, SEL, id))originalDisconnect)(receiver, screenDidDisconnect, notice);
    }), method_getTypeEncoding(disconnection));
    if (installedRegistry) *installedRegistry = registry;
    return YES;
}

@interface RPSDisplayCompatibility : NSObject
+ (BOOL)installForDisplayClass:(Class)cls surfaceProvider:(UIView *(^)(void))provider;
+ (BOOL)installRegistryForManagerClass:(Class)manager displayClass:(Class)display
                         viewProvider:(UIView *(^)(void))viewProvider screenProvider:(id (^)(UIWindow *))screenProvider;
+ (BOOL)bindPrimaryDisplay:(id)display surface:(UIView *)surface;
+ (BOOL)syncGameDisplay:(UIView *)view;
+ (void)install;
+ (NSDictionary *)snapshot;
@end
static NSUInteger RPSDisplayRepairs,RPSDisplayLookups;
static BOOL RPSDisplayInstalled,RPSLookupInstalled;
@implementation RPSDisplayCompatibility
+ (BOOL)installRegistryForManagerClass:(Class)manager displayClass:(Class)display
                         viewProvider:(UIView *(^)(void))viewProvider screenProvider:(id (^)(UIWindow *))screenProvider {
    return RPSInstallRegistryHooks(manager, display, viewProvider, screenProvider, NULL);
}

+ (BOOL)syncGameDisplay:(UIView *)view {
    if (!RPSGameDisplayRegistry.connections) return YES;
    if (!NSThread.isMainThread || !view.window.windowScene) return NO;
    id manager = RPSGetObject(NSClassFromString(@"DisplayManager"), @"Instance");
    id primary = RPSActivePrimary(manager, view, RPSGameDisplayRegistry);
    BOOL changed;
    BOOL bound = RPSMovePrimary(manager, primary, view, view.window.windowScene.screen, RPSGameDisplayRegistry, &changed);
    if (changed) ((void (*)(id, SEL))objc_msgSend)(manager, sel_registerName("updateDisplayListInUnity"));
    return bound;
}

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
        Class connection = NSClassFromString(@"DisplayConnection");
        UIView *(^viewProvider)(void) = ^UIView *{ return RPSCurrentGameSurface(); };
        RPSDisplayInstalled=[self installForDisplayClass:connection surfaceProvider:viewProvider];
        Class manager=NSClassFromString(@"DisplayManager");SEL selector=NSSelectorFromString(@"objectForKeyedSubscript:");
        if (RPSDisplayInstalled) {
            RPSInstallRegistryHooks(manager, connection, viewProvider,
                ^id(UIWindow *window){ return window.windowScene.screen; }, &RPSGameDisplayRegistry);
        }
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
+ (NSDictionary *)snapshot{return @{@"primaryBindingHook":@(RPSDisplayInstalled),@"displayLookupHook":@(RPSLookupInstalled),@"primaryRebinds":@(RPSDisplayRepairs),@"displayLookups":@(RPSDisplayLookups),@"primaryScreenRegistryHook":@(RPSGameDisplayRegistry.connections!=NULL),@"primaryScreenMoves":@(RPSPrimaryScreenMoves)};}
@end
