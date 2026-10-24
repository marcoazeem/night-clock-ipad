#import "NC.h"

@interface NCAppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@property (strong, nonatomic) NCClockViewController *clock;
@end

@implementation NCAppDelegate

- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)opts {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.backgroundColor = UIColor.blackColor;
  self.clock = [NCClockViewController new];
  self.window.rootViewController = self.clock;
  [self.window makeKeyAndVisible];
  return YES;
}

- (void)applicationDidBecomeActive:(UIApplication *)app { [self.clock appDidBecomeActive]; }
- (void)applicationWillResignActive:(UIApplication *)app { [self.clock appWillResignActive]; }

@end

int main(int argc, char *argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass(NCAppDelegate.class));
  }
}
