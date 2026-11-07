// Horizon's iOS entry point. The game itself is a Rust static library
// (crates/horizon-ios, linked from crates/horizon-client/src/ios_main.rs);
// this file only gives the bundle the `main` the Mach-O loader looks for.
//
// It deliberately does not create a UIApplication or call UIApplicationMain:
// winit's iOS backend does both, from `EventLoop::run_app`, and refuses to
// start once `UIApplication.sharedApplication` exists. So this is a plain
// `main` that hands control to Rust and only returns when the app terminates.
#import <Foundation/Foundation.h>

extern int horizon_ios_main(void);

int main(int argc, char *argv[]) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        return horizon_ios_main();
    }
}
