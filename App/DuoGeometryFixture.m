// Standalone geometry probe. No game code, assets, accounts or runtime payload.
#import <UIKit/UIKit.h>
@interface DuoGeometryController : UIViewController
@end
@implementation DuoGeometryController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {return UIInterfaceOrientationMaskLandscape;}
- (BOOL)shouldAutorotate {return YES;}
- (BOOL)prefersStatusBarHidden {return YES;}
- (void)loadView {self.view=[UIView new];self.view.backgroundColor=UIColor.systemTealColor;}
@end
@interface DuoGeometryScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation DuoGeometryScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window=[[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];self.window.rootViewController=[DuoGeometryController new];[self.window makeKeyAndVisible];
}
- (void)sceneDidBecomeActive:(UIScene *)scene {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        UIWindowScene *ws=(UIWindowScene *)scene;CGRect w=self.window.bounds,s=ws.screen.bounds,v=self.window.rootViewController.view.bounds;
        NSDictionary *report=@{@"window":@[@(w.size.width),@(w.size.height)],@"screen":@[@(s.size.width),@(s.size.height)],@"root":@[@(v.size.width),@(v.size.height)],@"windowAreaFraction":@(w.size.width*w.size.height/(s.size.width*s.size.height)),@"rootFillsWindow":@(fabs(w.size.width*w.size.height-v.size.width*v.size.height)<1),@"bundle":NSBundle.mainBundle.bundleIdentifier};
        NSString *documents=NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject;
        [[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:nil] writeToFile:[documents stringByAppendingPathComponent:@"duo-geometry.json"] atomically:YES];
    });
}
@end
@interface DuoGeometryApp : UIResponder <UIApplicationDelegate>
@end
@implementation DuoGeometryApp
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(DuoGeometryApp.class));}}
