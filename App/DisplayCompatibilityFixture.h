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
static void RPCDisplayFixture(NSString *documents,UIWindow *window) {
    NSMutableDictionary *checks=[NSMutableDictionary new];
    RPFixtureDisplay *main=[RPFixtureDisplay new];main.screen=window.windowScene.screen;
    BOOL threw=NO;@try{[main createView:YES showRightAway:YES];}@catch(NSException *error){threw=[error.name isEqual:NSInternalInconsistencyException];}
    checks[@"baseline_primary_display_assertion_reproduced"]=@(threw);
    Class compatibility=NSClassFromString(@"RPSDisplayCompatibility");
    UIView *surface=window.rootViewController.view;
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
    surface.bounds=originalBounds;
    UIViewController *root=window.rootViewController;UIEdgeInsets original=root.additionalSafeAreaInsets;
    for(int i=0;i<100;i++)((void(*)(id,SEL,id))objc_msgSend)(compatibility,sel_registerName("applyComfortInsetsToSurface:"),surface);
    UIEdgeInsets first=root.additionalSafeAreaInsets;
    for(int i=0;i<100;i++)((void(*)(id,SEL,id))objc_msgSend)(compatibility,sel_registerName("applyComfortInsetsToSurface:"),surface);
    checks[@"touch_insets_do_not_accumulate"]=@(UIEdgeInsetsEqualToEdgeInsets(first,root.additionalSafeAreaInsets));
    checks[@"camera_surface_keeps_full_bounds"]=@(CGRectEqualToRect(originalBounds,surface.bounds));
    checks[@"display_bridge_preserves_key_window"]=@(window.isKeyWindow);
    root.additionalSafeAreaInsets=original;
    BOOL passed=YES;for(NSNumber *value in checks.allValues)passed &= value.boolValue;
    NSDictionary *report=@{@"passed":@(passed),@"checks":checks,@"physical_device_tested":@NO};
    [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"display-compatibility-fixture.json"] atomically:YES];
}
