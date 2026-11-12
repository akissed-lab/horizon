// Horizon's iOS entry point. The game itself is a Rust static library
// (crates/horizon-ios, linked from crates/horizon-client/src/ios_main.rs);
// this file gives the bundle the `main` the Mach-O loader looks for and starts
// the native launcher (`packaging/ios/launcher.m`) as the app's first screen.
//
// UIKit starts here, before the engine: the launcher owns the window and the
// player only reaches the game by pressing Play, which calls `horizon_ios_main`.
// winit's iOS backend was patched to join an already-running UIApplication
// instead of calling `UIApplicationMain` itself (see
// third_party/winit/src/platform_impl/ios/event_loop.rs), so this order works
// and the engine's window appears on top of the launcher.
#import <UIKit/UIKit.h>

#import "launcher.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AksiAppDelegate class]));
    }
}
