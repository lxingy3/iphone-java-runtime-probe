// Simulator-only reproduction of the primary-display binding contract.
// The real client's assertion branch is independently replayed from its binary.
@interface RPFixtureDisplay : NSObject
@property(nonatomic,strong) id screen;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIView *view;
@property(nonatomic) NSUInteger externalCreates,binds;
- (void)createView:(BOOL)render showRightAway:(BOOL)show;
- (void)createWithWindow:(UIWindow *)window andView:(UIView *)view;
@end
@implementation RPFixtureDisplay
- (void)createView:(BOOL)render showRightAway:(BOOL)show {
    UIScreen *main=nil;for(UIScene *scene in UIApplication.sharedApplication.connectedScenes)if([scene isKindOfClass:UIWindowScene.class]){main=((UIWindowScene *)scene).screen;break;}
    NSAssert(self.screen!=main,@"Primary display requires its existing window and view");
    self.externalCreates++;if(!self.view)self.view=[UIView new];
}
- (void)createWithWindow:(UIWindow *)window andView:(UIView *)view {self.window=window;self.view=view;self.binds++;}
@end

@interface RPFixtureRegistryDisplay : NSObject
@property(nonatomic,strong) UIScreen *screen;
@property(nonatomic,strong) UIWindow *window;
@property(nonatomic,strong) UIView *view;
@property(nonatomic) void *surface;
- (void)createWithWindow:(UIWindow *)window andView:(UIView *)view;
@end
@implementation RPFixtureRegistryDisplay
- (void)createWithWindow:(UIWindow *)window andView:(UIView *)view {
    self.window = window;
    self.view = view;
}
@end

@interface RPFixtureDisplayManager : NSObject {
    NSMapTable *_displayConnection;
}
@property(nonatomic,strong) RPFixtureRegistryDisplay *mainDisplay;
@property(nonatomic) NSUInteger destroyed;
- (instancetype)initWithView:(UIView *)view screen:(UIScreen *)screen;
- (void)registerScreen:(UIScreen *)screen;
- (void)screenDidDisconnect:(NSNotification *)notice;
- (void)updateDisplayListInUnity;
- (RPFixtureRegistryDisplay *)connection:(UIScreen *)screen;
- (NSUInteger)presentableConnections;
@end
@implementation RPFixtureDisplayManager
- (instancetype)initWithView:(UIView *)view screen:(UIScreen *)screen {
    if ((self = [super init])) {
        _displayConnection = [NSMapTable strongToStrongObjectsMapTable];
        _mainDisplay = [RPFixtureRegistryDisplay new];
        _mainDisplay.screen = screen;
        [_mainDisplay createWithWindow:view.window andView:view];
        static char renderedSurface;
        _mainDisplay.surface = &renderedSurface;
        [_displayConnection setObject:_mainDisplay forKey:screen];
    }
    return self;
}
- (void)registerScreen:(UIScreen *)screen {
    RPFixtureRegistryDisplay *display = [RPFixtureRegistryDisplay new];
    display.screen = screen;
    [_displayConnection setObject:display forKey:screen];
}
- (void)screenDidDisconnect:(NSNotification *)notice {
    RPFixtureRegistryDisplay *display = [_displayConnection objectForKey:notice.object];
    if (display.surface) {
        display.surface = NULL;
        self.destroyed++;
    }
    [_displayConnection removeObjectForKey:notice.object];
    [self updateDisplayListInUnity];
}
- (void)updateDisplayListInUnity {}
- (RPFixtureRegistryDisplay *)connection:(UIScreen *)screen { return [_displayConnection objectForKey:screen]; }
- (NSUInteger)presentableConnections {
    NSUInteger count = 0;
    for (RPFixtureRegistryDisplay *display in _displayConnection.objectEnumerator) if (display.surface) count++;
    return count;
}
@end

static void RPCDisplayRegistryFixture(NSMutableDictionary *checks, UIView *view, Class compatibility) {
    UIScreen *first = (UIScreen *)[NSObject new];
    UIScreen *second = (UIScreen *)[NSObject new];
    UIScreen *external = (UIScreen *)[NSObject new];
    NSNotification *firstOff = [NSNotification notificationWithName:@"FixtureDisconnect" object:first];
    NSNotification *secondOff = [NSNotification notificationWithName:@"FixtureDisconnect" object:second];
    RPFixtureDisplayManager *baseline = [[RPFixtureDisplayManager alloc] initWithView:view screen:first];
    [baseline registerScreen:second];
    [baseline screenDidDisconnect:firstOff];
    checks[@"baseline_registry_disconnect_stops_presenting"] = @(baseline.destroyed == 1 && [baseline presentableConnections] == 0);

    __block UIScreen *activeScreen = first;
    __weak UIView *activeView = view;
    SEL install = sel_registerName("installRegistryForManagerClass:displayClass:viewProvider:screenProvider:");
    BOOL installed = ((BOOL (*)(id, SEL, Class, Class, id, id))objc_msgSend)(compatibility, install,
        RPFixtureDisplayManager.class, RPFixtureRegistryDisplay.class,
        ^UIView *{ return activeView; }, ^id(UIWindow *window){ return activeScreen; });
    checks[@"registry_hooks_match_display_abi"] = @(installed);

    RPFixtureDisplayManager *manager = [[RPFixtureDisplayManager alloc] initWithView:view screen:first];
    RPFixtureRegistryDisplay *primary = manager.mainDisplay;
    void *drawing = primary.surface;
    [manager registerScreen:first];
    checks[@"duplicate_primary_registration_preserves_surface"] = @([manager connection:first] == primary && [manager presentableConnections] == 1);

    [manager registerScreen:second];
    checks[@"waiting_for_scene_screen_keeps_rendering_old_connection"] = @([manager connection:first] == primary && [manager presentableConnections] == 1);
    activeScreen = second;
    [manager screenDidDisconnect:firstOff];
    checks[@"connect_before_disconnect_transfers_original_surface"] = @(
        [manager connection:first] == nil && [manager connection:second] == primary && primary.screen == second &&
        primary.surface == drawing && [manager presentableConnections] == 1 && manager.destroyed == 0);
    activeScreen = first;
    [manager registerScreen:first];
    [manager screenDidDisconnect:secondOff];
    checks[@"return_and_late_disconnect_preserve_one_surface"] = @(
        [manager connection:first] == primary && [manager connection:second] == nil &&
        primary.surface == drawing && [manager presentableConnections] == 1 && manager.destroyed == 0);

    [manager screenDidDisconnect:firstOff];
    checks[@"disconnect_before_geometry_does_not_destroy_primary"] = @(
        [manager connection:first] == primary && primary.surface == drawing && [manager presentableConnections] == 1);
    activeScreen = second;
    [manager registerScreen:second];
    checks[@"late_geometry_moves_preserved_surface"] = @(
        [manager connection:second] == primary && [manager connection:first] == nil &&
        manager.mainDisplay == primary && primary.surface == drawing && [manager presentableConnections] == 1);

    [manager registerScreen:external];
    RPFixtureRegistryDisplay *other = [manager connection:external];
    static char externalDrawing;
    other.surface = &externalDrawing;
    activeScreen = external;
    [manager screenDidDisconnect:secondOff];
    checks[@"live_external_destination_is_not_replaced"] = @(
        [manager connection:external] == other && [manager connection:second] == primary && [manager presentableConnections] == 2);
    [manager screenDidDisconnect:[NSNotification notificationWithName:@"FixtureDisconnect" object:external]];
    checks[@"external_disconnect_uses_original_removal"] = @(
        manager.destroyed == 1 && [manager connection:external] == nil && [manager connection:second] == primary);

    CGRect previousBounds = view.bounds;
    activeScreen = first;
    view.bounds = CGRectZero;
    [manager screenDidDisconnect:secondOff];
    BOOL held = [manager connection:second] == primary && primary.surface == drawing;
    view.bounds = previousBounds;
    [manager registerScreen:first];
    checks[@"zero_area_transition_defers_until_window_is_sized"] = @(
        held && [manager connection:first] == primary && [manager connection:second] == nil &&
        [manager presentableConnections] == 1);
}

static void RPCDisplayFixture(NSString *documents,UIWindow *window) {
    NSMutableDictionary *checks=[NSMutableDictionary new];
    RPFixtureDisplay *main=[RPFixtureDisplay new];main.screen=window.windowScene.screen;
    BOOL threw=NO;@try{[main createView:YES showRightAway:YES];}@catch(NSException *error){threw=[error.name isEqual:NSInternalInconsistencyException];}
    checks[@"baseline_primary_display_assertion_reproduced"]=@(threw);
    Class compatibility=NSClassFromString(@"RPSDisplayCompatibility");
    UIView *surface=window.rootViewController.view;
    UIEdgeInsets originalInsets=window.rootViewController.additionalSafeAreaInsets;
    BOOL installed=((BOOL(*)(id,SEL,Class,id))objc_msgSend)(compatibility,sel_registerName("installForDisplayClass:surfaceProvider:"),RPFixtureDisplay.class,^UIView *{return surface;});
    checks[@"scoped_hook_installed"]=@(installed);
    CGRect originalBounds=surface.bounds;BOOL transitions=YES;
    CGSize sizes[]={{951,669},{467,669},{951,669},{669,951},{669,460},{669,951}};
    for(int repeat=0;repeat<20;repeat++)for(int n=0;n<6;n++){
        surface.bounds=(CGRect){CGPointZero,sizes[n]};main.view=nil;main.window=nil;
        @try{[main createView:YES showRightAway:YES];}@catch(NSException *error){transitions=NO;}
        transitions &= main.view==surface&&main.window==window&&CGSizeEqualToSize(surface.bounds.size,sizes[n]);
    }
    checks[@"resize_rebinds_existing_primary_surface_120_times"]=@(transitions&&main.binds==120&&main.externalCreates==0);
    NSUInteger before=main.binds;[main createView:YES showRightAway:NO];
    checks[@"already_bound_display_is_idempotent"]=@(main.binds==before);
    RPFixtureDisplay *external=[RPFixtureDisplay new];external.screen=[NSObject new];
    [external createView:YES showRightAway:NO];checks[@"external_display_creation_preserved"]=@(external.externalCreates==1&&external.view!=surface);

    // Transitional absence must not steal another live surface or mutate UIKit
    // from the render thread. Exercise the production binding method directly.
    BOOL (^bind)(id,UIView *)=^BOOL(id display,UIView *view){
        return ((BOOL(*)(id,SEL,id,id))objc_msgSend)(compatibility,sel_registerName("bindPrimaryDisplay:surface:"),display,view);
    };
    NSUInteger boundCount=main.binds;
    UIView *detached=[UIView new];
    checks[@"missing_or_detached_host_leaves_binding_intact"]=@(!bind(main,nil)&&!bind(main,detached)&&main.view==surface&&main.binds==boundCount);
    __block BOOL offMainAccepted=YES,usedBackgroundThread=NO;
    dispatch_semaphore_t finished=dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        usedBackgroundThread=!NSThread.isMainThread;offMainAccepted=bind(main,surface);
        dispatch_semaphore_signal(finished);
    });
    BOOL completed=dispatch_semaphore_wait(finished,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC))==0;
    checks[@"render_thread_cannot_rebind_uikit_surface"]=@(completed&&usedBackgroundThread&&!offMainAccepted&&main.binds==boundCount);
    UIView *other=[UIView new];[surface addSubview:other];
    main.view=other;
    checks[@"another_attached_surface_is_not_replaced"]=@(!bind(main,surface)&&main.view==other&&main.binds==boundCount);
    [other removeFromSuperview];
    checks[@"retired_surface_can_be_replaced"]=@(bind(main,surface)&&main.view==surface&&main.binds==boundCount+1);
    IMP wrapper=class_getMethodImplementation(RPFixtureDisplay.class,sel_registerName("createView:showRightAway:"));
    BOOL installedAgain=((BOOL(*)(id,SEL,Class,id))objc_msgSend)(compatibility,sel_registerName("installForDisplayClass:surfaceProvider:"),RPFixtureDisplay.class,^UIView *{return surface;});
    checks[@"duplicate_install_preserves_one_wrapper"]=@(installedAgain&&wrapper==class_getMethodImplementation(RPFixtureDisplay.class,sel_registerName("createView:showRightAway:")));
    Class invalid=objc_allocateClassPair(NSObject.class,"RPFixtureIncompatibleDisplay",0);
    IMP wrong=imp_implementationWithBlock(^int(id receiver,BOOL render,BOOL show){return 0;});
    class_addMethod(invalid,sel_registerName("createView:showRightAway:"),wrong,"i@:BB");
    objc_registerClassPair(invalid);
    BOOL accepted=((BOOL(*)(id,SEL,Class,id))objc_msgSend)(compatibility,sel_registerName("installForDisplayClass:surfaceProvider:"),invalid,^UIView *{return surface;});
    checks[@"incompatible_signature_is_rejected_without_swizzle"]=@(!accepted&&wrong==class_getMethodImplementation(invalid,sel_registerName("createView:showRightAway:")));
    surface.bounds=originalBounds;
    RPCDisplayRegistryFixture(checks, surface, compatibility);
    checks[@"game_button_insets_preserved"]=@(UIEdgeInsetsEqualToEdgeInsets(originalInsets,window.rootViewController.additionalSafeAreaInsets));
    checks[@"camera_surface_keeps_full_bounds"]=@(CGRectEqualToRect(originalBounds,surface.bounds));
    checks[@"display_bridge_preserves_key_window"]=@(window.isKeyWindow);
    BOOL passed=YES;for(NSNumber *value in checks.allValues)passed &= value.boolValue;
    NSDictionary *report=@{@"passed":@(passed),@"checks":checks,@"physical_device_tested":@NO};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"display-compatibility-fixture.json"] atomically:YES];
}
