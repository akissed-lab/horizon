//! Horizon on iOS: the crate root of `horizon-ios` (a static library linked
//! into a signed `.app`, IOS.md). It sits beside `main.rs` so `mod game;`
//! compiles the same game; this file only replaces `main` with a C entry
//! point that `packaging/ios/main.m` calls.
//!
//! winit's iOS backend calls `UIApplicationMain` itself, from
//! `EventLoop::run_app`, and refuses to run once `UIApplication` exists. So
//! nothing here may start UIKit first: `main.m` is a plain `main` that calls
//! [`horizon_ios_main`] before any application object is created.
#![cfg(target_os = "ios")]
#![allow(dead_code)]
mod game;

use horizon_client::{crash, logging};

#[global_allocator]
static ALLOCATOR: horizon_threads::Allocator = horizon_threads::Allocator;

/// The mod API level this game serves, kept in the program for the launcher
/// to read (`horizon_mods::api_level::MARK`). The C entry point reads it, so
/// the linker keeps it.
static MOD_API_LEVEL: [u8; 27] = horizon_mods::api_level::MARK;

/// Called by `main` in `packaging/ios/main.m`. Never returns in practice:
/// `EventLoop::run_app` ends in `UIApplicationMain`.
#[unsafe(no_mangle)]
pub extern "C" fn horizon_ios_main() -> i32 {
    horizon_threads::configure_allocator();
    std::hint::black_box(&MOD_API_LEVEL);
    horizon_client::telemetry::mark_start();
    // The game's home: `Documents/Horizon` in the app's container. With
    // `UIFileSharingEnabled` and `LSSupportsOpeningDocumentsInPlace` in
    // Info.plist it shows up in the Files app and in Finder, so resources and
    // worlds can be copied in and saves copied out without a Mac in between.
    let container = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|| std::path::PathBuf::from("."));
    let home = container.join("Documents").join("Horizon");
    let _ = std::fs::create_dir_all(&home);
    // SAFETY: nothing else runs yet; the game reads these on this thread.
    unsafe {
        std::env::set_var("HORIZON_HOME", &home);
        if std::env::var_os("HORIZON_RESOURCES").is_none() {
            std::env::set_var("HORIZON_RESOURCES", home.join("resources"));
        }
        std::env::set_var(
            "HORIZON_CACHE",
            container.join("Library").join("Caches").join("horizon"),
        );
        // `spikes.txt` in the game folder (a number of milliseconds) turns on HORIZON_SPIKES:
        // frames slower than that log their timings, without a debug build.
        if let Ok(text) = std::fs::read_to_string(home.join("spikes.txt"))
            && text.trim().parse::<f32>().is_ok()
        {
            std::env::set_var("HORIZON_SPIKES", text.trim());
        }
    }
    let _ = std::env::set_current_dir(&home);
    logging::init(&home, "Render thread");
    log::info!("Horizon {} (iOS) home {}", crash::version(), home.display());
    crash::install(home.clone(), "client");
    raise_open_file_limit();
    // A panic here is already in the crash report (crash::install). Catch it
    // so the log is flushed and the return value says what happened; iOS then
    // shows the usual "app stopped" dialog or the watchdog kills the process.
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(game::run)) {
        Ok(Err(error)) => {
            log::error!("Horizon: {error}");
            crash::report_error(&home, "client", &*error);
        }
        Ok(Ok(())) => {}
        Err(_) => log::error!("Horizon: the game thread panicked"),
    }
    logging::flush();
    0
}

/// The JVM raises its open-file limit to the hard limit as it starts
/// (`-XX:+MaxFDLimit`), and the game opens a region file and a socket per
/// chunk and player. iOS lets an app raise its soft limit up to the hard one.
fn raise_open_file_limit() {
    use rustix::process::{Resource, Rlimit, getrlimit, setrlimit};
    let limit = getrlimit(Resource::Nofile);
    let Some(hard) = limit.maximum else {
        return;
    };
    if limit.current.is_some_and(|soft| hard <= soft) {
        return;
    }
    let to = Rlimit {
        current: Some(hard),
        maximum: limit.maximum,
    };
    match setrlimit(Resource::Nofile, to) {
        Ok(()) => log::info!("Open file limit raised from {:?} to {hard:?}", limit.current),
        Err(e) => log::warn!("Open file limit stays at {:?}: {e}", limit.current),
    }
}
