// Horizon's iOS entry point. The game itself is a Rust static library
// (crates/horizon-ios, linked from crates/horizon-client/src/ios_main.rs);
// this file only gives the bundle the `main` the Mach-O loader looks for.
//
// It deliberately does not create a UIApplication or call UIApplicationMain:
// winit's iOS backend does both, from `EventLoop::run_app`, and refuses to
// start once `UIApplication.sharedApplication` exists. So this is a plain
// `main` that hands control to Rust and only returns when the app terminates.
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

extern int horizon_ios_main(void);

// In crates/horizon-client/src/ios_main.rs: logs the peak memory, hands the
// allocator's free pages back and flushes the log.
extern void horizon_ios_memory_warning(void);

/// Receives iOS's memory warnings. Observing the default notification center
/// needs no UIApplication, so this can be registered before winit starts one.
@interface HorizonMemoryWatcher : NSObject
- (void)memoryWarning:(NSNotification *)note;
@end

@implementation HorizonMemoryWatcher
- (void)memoryWarning:(NSNotification *)note {
    (void)note;
    horizon_ios_memory_warning();
}
@end

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        // A warning usually comes shortly before a jetsam kill on a phone; the
        // Rust side drops cached memory and flushes the log so the cause is
        // still in latest.log afterwards.
        HorizonMemoryWatcher *watcher = [HorizonMemoryWatcher new];
        [[NSNotificationCenter defaultCenter]
            addObserver:watcher
               selector:@selector(memoryWarning:)
                   name:UIApplicationDidReceiveMemoryWarningNotification
                 object:nil];
        return horizon_ios_main();
    }
}
