// Aksi's native launcher: the UIKit menu shown before the engine starts and
// again after a world closes. It writes the player's choice to
// `horizon-launch.txt`, which `crates/horizon-client/src/game/ios_launcher.rs`
// reads, and keeps the account, skin and player-name files the game consumes.
//
// The launcher starts with `UIApplicationMain` in `main.m`; the game is started
// later, from the Play button, and winit joins this already-running UIKit
// application (see `crates/horizon-client/src/ios_main.rs`).
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Called from Rust (`game/ios_launcher.rs`) when a world closes: shows the
/// launcher over the idle game window again.
void horizon_ios_present_launcher(void);

/// `main.m` hands UIKit this delegate (`UIApplicationMain`'s fourth argument).
@interface AksiAppDelegate : UIResponder <UIApplicationDelegate>
@end

/// `Documents/Horizon`: the game's home and working directory. Created, with
/// its `saves/` and `logs/` folders, on first use.
NSString *AksiHomeDirectory(void);

/// `resources/horizon-resources.json` exists: the engine has what it needs.
BOOL AksiResourcesReady(void);

/// Appends one line to `logs/launcher.log`. Never pass passwords or tokens.
void AksiLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// The Aksi look: the accent from `horizon-launcher.txt`, glass panels,
/// labels and fields.
UIColor *AksiAccentColor(void);
UIColor *AksiTextColor(void);
UIColor *AksiDimColor(void);
void AksiStylePanel(UIView *view);
UILabel *AksiMakeLabel(NSString *text, UIFont *font, UIColor *color);
/// A small dimmed all-caps heading above a group of rows.
UILabel *AksiSectionLabel(NSString *text);
UIButton *AksiMakeButton(NSString *title, BOOL prominent);
void AksiStyleButton(UIButton *button, BOOL prominent);
UITextField *AksiMakeField(NSString *placeholder);
void AksiAlert(UIViewController *controller, NSString *title, NSString *message);

/// `horizon-launcher.txt`, the launcher's own copy of the settings it shows:
/// `accent:` 0-7 (the game's ACCENTS order), `memory:` 0-2 (economy, normal,
/// maximum), `distance:`, `fov:`, `sensitivity:` and `volume:` (percent),
/// `gui:` 0-3, `invert_y:` and `bobbing:` 0/1. A write rebuilds the file from
/// these keys, in this order (unknown keys are dropped).
NSInteger AksiAccentIndex(void);
NSInteger AksiMemoryPreset(void);
void AksiSetAccentIndex(NSInteger index);
void AksiSetMemoryPreset(NSInteger preset);
NSInteger AksiSettingNumber(NSString *key, NSInteger fallback, NSInteger minimum, NSInteger maximum);
void AksiSetSettingNumber(NSString *key, NSInteger value);

/// The signed-in account from `horizon-account.txt` (`name`, `uuid`); nil when
/// nobody is signed in.
NSDictionary<NSString *, NSString *> * _Nullable AksiReadAccount(void);

/// Writes `horizon-launch.txt` and starts the engine, or hands the choice to
/// the running winit loop when the game already started. Hides this window.
void AksiStartFromHome(NSString *launch);

/// A screen with the gradient background, the header and the body below it.
/// Subclasses fill `bodyView` (a table) or use `formStackWithSpacing:`.
@interface AksiScreenViewController : UIViewController
@property (nonatomic, strong, readonly) UIView *bodyView;
@property (nonatomic, strong, readonly, nullable) UIScrollView *scrollView;
- (void)setScreenTitle:(NSString *)title showsBack:(BOOL)showsBack;
- (UIStackView *)formStackWithSpacing:(CGFloat)spacing;
- (void)closeScreen;
@end

/// The Ely.by sign-in screen (`launcher_ely.m`).
@interface AksiAccountViewController : AksiScreenViewController
@end

NS_ASSUME_NONNULL_END
