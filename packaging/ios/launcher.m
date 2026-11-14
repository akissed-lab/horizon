// Aksi's native launcher: the UIKit menu that is on screen before the engine
// exists, and that comes back when a world closes (Rust calls
// `horizon_ios_present_launcher`). It writes `horizon-launch.txt` for the Rust
// side (`crates/horizon-client/src/game/ios_launcher.rs`), and keeps the
// account, skin and player-name files the game consumes.
//
// The launcher owns the UIApplication: `main.m` starts it with
// `UIApplicationMain`. The engine starts only when Play is pressed, through
// `horizon_ios_main` (winit joins the running application); later Play presses
// call `horizon_ios_launch_action`, which hands the choice to the running
// game loop. See IOS.md.
#import "launcher.h"
#import <QuartzCore/QuartzCore.h>
#include <math.h>
#include <stdio.h>

extern int horizon_ios_main(void);
extern void horizon_ios_launch_action(void);
extern void horizon_ios_memory_warning(void);

NSNotificationName const AksiAccentChangedNotification = @"AksiAccentChangedNotification";

static NSString *const AksiLauncherSettingsFile = @"horizon-launcher.txt";
static NSString *const AksiLaunchFile = @"horizon-launch.txt";
static NSString *const AksiAccountFile = @"horizon-account.txt";

// The accent colours in the game's `ACCENTS` order (extras.rs): violet first.
static const uint32_t AksiAccentRGB[8] = {
    0x8B5CF6, 0x3B82F6, 0x14B8A6, 0x22C55E,
    0xF59E0B, 0xF43F5E, 0xEAB308, 0xE5E7EB,
};

static UIWindow *gLauncherWindow;
static UINavigationController *gLauncherNavigation;
static UIWindow *gGameWindow;
static BOOL gEngineStarted;
static BOOL gStarting;

static void AksiRestyleTree(UIView *view);

#pragma mark - Files and paths

NSString *AksiHomeDirectory(void) {
    static NSString *home;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        home = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/Horizon"];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:NULL];
        for (NSString *folder in @[@"saves", @"logs"]) {
            [fm createDirectoryAtPath:[home stringByAppendingPathComponent:folder]
          withIntermediateDirectories:YES
                           attributes:nil
                                error:NULL];
        }
    });
    return home;
}

static NSString *AksiPath(NSString *name) {
    return [AksiHomeDirectory() stringByAppendingPathComponent:name];
}

BOOL AksiResourcesReady(void) {
    return [[NSFileManager defaultManager]
        fileExistsAtPath:AksiPath(@"resources/horizon-resources.json")];
}

void AksiLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    static NSDateFormatter *formatter;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = @"HH:mm:ss.SSS";
    });

    @synchronized(lock) {
        NSLog(@"[Aksi] %@", message);
        NSString *path = AksiPath(@"logs/launcher.log");
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
        if ([attributes[NSFileSize] unsignedLongLongValue] > 512 * 1024) {
            [fm removeItemAtPath:path error:NULL];
        }
        NSString *line = [NSString stringWithFormat:@"[%@] %@\n",
                                                   [formatter stringFromDate:[NSDate date]], message];
        FILE *file = fopen(path.fileSystemRepresentation, "a");
        if (file) {
            fputs(line.UTF8String, file);
            fclose(file);
        }
    }
}

static BOOL AksiWrite(NSString *path, NSString *text) {
    NSError *error = nil;
    BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!ok) {
        AksiLog(@"write %@ failed: %@", path.lastPathComponent, error.localizedDescription);
    }
    return ok;
}

/// `key:value` lines, as the game's small text files use them.
static NSDictionary<NSString *, NSString *> *AksiReadValues(NSString *path) {
    NSString *text = [NSString stringWithContentsOfFile:path
                                               encoding:NSUTF8StringEncoding
                                                  error:NULL];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:
                                      [NSCharacterSet newlineCharacterSet]]) {
        NSRange colon = [line rangeOfString:@":"];
        if (colon.location == NSNotFound) {
            continue;
        }
        NSString *key = [line substringToIndex:colon.location];
        NSString *value = [[line substringFromIndex:colon.location + 1]
            stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        values[key] = value;
    }
    return values;
}

NSDictionary<NSString *, NSString *> * _Nullable AksiReadAccount(void) {
    NSDictionary *values = AksiReadValues(AksiPath(AksiAccountFile));
    NSString *name = values[@"name"];
    NSString *uuid = values[@"uuid"];
    if (name.length == 0 || uuid.length == 0) {
        return nil;
    }
    return @{@"name" : name, @"uuid" : uuid};
}

static NSString *AksiVersion(void) {
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    return version.length ? version : @"?";
}

#pragma mark - Launcher settings

/// Every key the launcher writes, in the order the file keeps them. The Rust
/// side reads them in this order too: `memory` first, then the explicit
/// `distance` that overrides the preset.
static NSArray<NSString *> *AksiSettingKeys(void) {
    return @[ @"accent", @"memory", @"distance", @"fov", @"sensitivity", @"volume", @"gui",
              @"invert_y", @"bobbing" ];
}

NSInteger AksiSettingNumber(NSString *key,
                            NSInteger fallback,
                            NSInteger minimum,
                            NSInteger maximum) {
    NSDictionary *values = AksiReadValues(AksiPath(AksiLauncherSettingsFile));
    NSString *text = values[key];
    if (text.length == 0) {
        return fallback;
    }
    NSInteger value = text.integerValue;
    if (value < minimum || value > maximum) {
        return fallback;
    }
    return value;
}

void AksiSetSettingNumber(NSString *key, NSInteger value) {
    NSMutableDictionary *values =
        [AksiReadValues(AksiPath(AksiLauncherSettingsFile)) mutableCopy];
    values[key] = [NSString stringWithFormat:@"%ld", (long)value];
    NSMutableString *text = [NSMutableString string];
    for (NSString *name in AksiSettingKeys()) {
        if (values[name]) {
            [text appendFormat:@"%@:%@\n", name, values[name]];
        }
    }
    AksiWrite(AksiPath(AksiLauncherSettingsFile), text);
}

NSInteger AksiAccentIndex(void) {
    return AksiSettingNumber(@"accent", 0, 0, 7);
}

NSInteger AksiMemoryPreset(void) {
    return AksiSettingNumber(@"memory", 1, 0, 2);
}

void AksiSetAccentIndex(NSInteger index) {
    AksiSetSettingNumber(@"accent", MAX(0, MIN(index, 7)));
}

void AksiSetMemoryPreset(NSInteger preset) {
    AksiSetSettingNumber(@"memory", MAX(0, MIN(preset, 2)));
}

#pragma mark - Look

UIColor *AksiTextColor(void) {
    return [UIColor colorWithWhite:0.96 alpha:1.0];
}

UIColor *AksiDimColor(void) {
    return [UIColor colorWithWhite:0.68 alpha:1.0];
}

UIColor *AksiAccentColor(void) {
    uint32_t rgb = AksiAccentRGB[AksiAccentIndex()];
    return [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                           green:((rgb >> 8) & 0xff) / 255.0
                            blue:(rgb & 0xff) / 255.0
                           alpha:1.0];
}

static UIColor *AksiPanelColor(void) {
    return [UIColor colorWithWhite:1.0 alpha:0.07];
}

void AksiStylePanel(UIView *view) {
    view.backgroundColor = AksiPanelColor();
    view.layer.cornerRadius = 18.0;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    view.layer.borderWidth = 1.0;
    view.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    view.clipsToBounds = YES;
}

UILabel *AksiMakeLabel(NSString *text, UIFont *font, UIColor *color) {
    UILabel *label = [[UILabel alloc] init];
    label.text = text;
    label.font = font;
    label.textColor = color;
    label.numberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

UILabel *AksiSectionLabel(NSString *text) {
    UILabel *label = AksiMakeLabel(text,
                                   [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
                                   AksiDimColor());
    return label;
}

static const NSInteger AksiProminentButtonTag = 0x0A51;

void AksiStyleButton(UIButton *button, BOOL prominent) {
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    if (prominent) {
        button.tag = AksiProminentButtonTag;
        button.backgroundColor = AksiAccentColor();
        [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
        button.layer.cornerRadius = 16.0;
        button.layer.cornerCurve = kCACornerCurveContinuous;
        button.clipsToBounds = YES;
    } else {
        AksiStylePanel(button);
        [button setTitleColor:AksiTextColor() forState:UIControlStateNormal];
    }
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:50.0].active = YES;
}

UIButton *AksiMakeButton(NSString *title, BOOL prominent) {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
    [button setTitle:title forState:UIControlStateNormal];
    button.contentEdgeInsets = UIEdgeInsetsMake(10, 18, 10, 18);
    AksiStyleButton(button, prominent);
    return button;
}

UITextField *AksiMakeField(NSString *placeholder) {
    UITextField *field = [[UITextField alloc] init];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.placeholder = placeholder;
    field.font = [UIFont systemFontOfSize:17];
    field.textColor = AksiTextColor();
    field.tintColor = AksiAccentColor();
    field.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.06];
    field.layer.cornerRadius = 12.0;
    field.layer.cornerCurve = kCACornerCurveContinuous;
    field.layer.borderWidth = 1.0;
    field.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.14].CGColor;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 12, 44)];
    field.leftViewMode = UITextFieldViewModeAlways;
    field.rightView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 44)];
    field.rightViewMode = UITextFieldViewModeAlways;
    field.attributedPlaceholder =
        [[NSAttributedString alloc] initWithString:placeholder
                                        attributes:@{NSForegroundColorAttributeName :
                                                         [UIColor colorWithWhite:0.55 alpha:1.0]}];
    [field.heightAnchor constraintEqualToConstant:48.0].active = YES;
    return field;
}

void AksiAlert(UIViewController *controller, NSString *title, NSString *message) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Menu row

/// A glass card with a heading and a detail line; the buttons on the home
/// screen and the world list are made of these.
@interface AksiMenuRow : UIButton
@property (nonatomic, strong) UILabel *heading;
@property (nonatomic, strong) UILabel *subheading;
@property (nonatomic) BOOL prominent;
- (instancetype)initWithHeading:(NSString *)heading
                         detail:(NSString *)detail
                      prominent:(BOOL)prominent;
- (void)setHeadingText:(NSString *)heading detail:(NSString *)detail;
- (void)refreshStyle;
@end

@implementation AksiMenuRow
- (instancetype)initWithHeading:(NSString *)heading
                         detail:(NSString *)detail
                      prominent:(BOOL)prominent {
    self = [super initWithFrame:CGRectZero];
    if (!self) {
        return nil;
    }
    _prominent = prominent;
    self.translatesAutoresizingMaskIntoConstraints = NO;
    self.titleLabel.hidden = YES;

    _heading = AksiMakeLabel(heading,
                             [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
                             AksiTextColor());
    _subheading = AksiMakeLabel(detail ?: @"", [UIFont systemFontOfSize:13], AksiDimColor());
    [self addSubview:_heading];
    [self addSubview:_subheading];
    [NSLayoutConstraint activateConstraints:@[
        [_heading.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:18.0],
        [_heading.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                          constant:-18.0],
        [_heading.topAnchor constraintEqualToAnchor:self.topAnchor constant:11.0],
        [_subheading.leadingAnchor constraintEqualToAnchor:_heading.leadingAnchor],
        [_subheading.trailingAnchor constraintLessThanOrEqualToAnchor:self.trailingAnchor
                                                            constant:-18.0],
        [_subheading.topAnchor constraintEqualToAnchor:_heading.bottomAnchor constant:2.0],
        [_subheading.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-11.0],
        [self.heightAnchor constraintGreaterThanOrEqualToConstant:58.0],
    ]];
    [self refreshStyle];
    return self;
}

- (void)setHeadingText:(NSString *)heading detail:(NSString *)detail {
    self.heading.text = heading;
    self.subheading.text = detail ?: @"";
}

- (void)refreshStyle {
    if (self.prominent) {
        self.backgroundColor = AksiAccentColor();
        self.layer.cornerRadius = 18.0;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        self.layer.borderWidth = 0.0;
        self.clipsToBounds = YES;
        self.heading.textColor = [UIColor whiteColor];
        self.subheading.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.78];
    } else {
        AksiStylePanel(self);
        self.heading.textColor = AksiTextColor();
        self.subheading.textColor = AksiDimColor();
    }
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.82 : 1.0;
}
@end

// Declared here, before the home screen's implementation sends them `alloc`:
// the settings screen itself comes later, with its own section.
@interface AksiSettingsViewController : AksiScreenViewController
@end

static void AksiRestyleTree(UIView *view) {
    if ([view isKindOfClass:[AksiMenuRow class]]) {
        [(AksiMenuRow *)view refreshStyle];
    } else if (view.tag == AksiProminentButtonTag) {
        view.backgroundColor = AksiAccentColor();
    }
    for (UIView *child in view.subviews) {
        AksiRestyleTree(child);
    }
}

#pragma mark - Screen base

@implementation AksiScreenViewController {
    CAGradientLayer *_gradient;
    UIView *_header;
    UIView *_body;
    UILabel *_titleLabel;
    UIButton *_backButton;
    UIScrollView *_scrollView;
    UIStackView *_contentStack;
}

- (UIView *)bodyView {
    return _body;
}

- (UIScrollView *)scrollView {
    return _scrollView;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];

    _gradient = [CAGradientLayer layer];
    [self.view.layer insertSublayer:_gradient atIndex:0];

    _header = [[UIView alloc] init];
    _header.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_header];

    _backButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _backButton.translatesAutoresizingMaskIntoConstraints = NO;
    [_backButton setImage:[UIImage systemImageNamed:@"chevron.left"]
                 forState:UIControlStateNormal];
    _backButton.tintColor = AksiTextColor();
    AksiStylePanel(_backButton);
    _backButton.layer.cornerRadius = 20.0;
    [_backButton.widthAnchor constraintEqualToConstant:40.0].active = YES;
    [_backButton.heightAnchor constraintEqualToConstant:40.0].active = YES;
    [_backButton addTarget:self
                    action:@selector(closeScreen)
          forControlEvents:UIControlEventTouchUpInside];

    _titleLabel = AksiMakeLabel(@"", [UIFont systemFontOfSize:30 weight:UIFontWeightHeavy],
                                AksiTextColor());

    UIStackView *headerRow =
        [[UIStackView alloc] initWithArrangedSubviews:@[ _backButton, _titleLabel ]];
    headerRow.axis = UILayoutConstraintAxisHorizontal;
    headerRow.alignment = UIStackViewAlignmentCenter;
    headerRow.spacing = 12.0;
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [_header addSubview:headerRow];
    [NSLayoutConstraint activateConstraints:@[
        [_header.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor
                                          constant:6.0],
        [_header.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [_header.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],
        [_header.heightAnchor constraintEqualToConstant:44.0],
        [headerRow.leadingAnchor constraintEqualToAnchor:_header.leadingAnchor],
        [headerRow.trailingAnchor constraintLessThanOrEqualToAnchor:_header.trailingAnchor],
        [headerRow.centerYAnchor constraintEqualToAnchor:_header.centerYAnchor],
    ]];

    _body = [[UIView alloc] init];
    _body.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:_body];
    [NSLayoutConstraint activateConstraints:@[
        [_body.topAnchor constraintEqualToAnchor:_header.bottomAnchor constant:6.0],
        [_body.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:20.0],
        [_body.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-20.0],
        [_body.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor
                                           constant:-10.0],
    ]];

    [self updateGradient];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(accentChanged)
                                                 name:AksiAccentChangedNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardChanged:)
                                                 name:UIKeyboardWillChangeFrameNotification
                                               object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    _gradient.frame = self.view.bounds;
}

- (void)updateGradient {
    UIColor *accent = AksiAccentColor();
    _gradient.colors = @[
        (__bridge id)[accent colorWithAlphaComponent:0.34].CGColor,
        (__bridge id)[UIColor colorWithRed:0.055 green:0.052 blue:0.085 alpha:1.0].CGColor,
        (__bridge id)[UIColor colorWithRed:0.016 green:0.016 blue:0.026 alpha:1.0].CGColor,
    ];
    _gradient.startPoint = CGPointMake(0.0, 0.0);
    _gradient.endPoint = CGPointMake(1.0, 1.0);
}

- (void)accentChanged {
    [self updateGradient];
    AksiRestyleTree(self.view);
}

- (void)keyboardChanged:(NSNotification *)note {
    if (!_scrollView) {
        return;
    }
    CGRect frame = [note.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect local = [self.view convertRect:frame fromView:nil];
    CGFloat overlap = MAX(0.0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(local));
    _scrollView.contentInset = UIEdgeInsetsMake(0, 0, overlap, 0);
    _scrollView.scrollIndicatorInsets = _scrollView.contentInset;
}

- (void)setScreenTitle:(NSString *)title showsBack:(BOOL)showsBack {
    _titleLabel.text = title;
    _backButton.hidden = !showsBack;
}

- (UIStackView *)formStackWithSpacing:(CGFloat)spacing {
    if (!_scrollView) {
        _scrollView = [[UIScrollView alloc] init];
        _scrollView.translatesAutoresizingMaskIntoConstraints = NO;
        _scrollView.alwaysBounceVertical = YES;
        _scrollView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
        [_body addSubview:_scrollView];

        _contentStack = [[UIStackView alloc] init];
        _contentStack.axis = UILayoutConstraintAxisVertical;
        _contentStack.alignment = UIStackViewAlignmentFill;
        _contentStack.translatesAutoresizingMaskIntoConstraints = NO;
        [_scrollView addSubview:_contentStack];

        UILayoutGuide *content = _scrollView.contentLayoutGuide;
        UILayoutGuide *frame = _scrollView.frameLayoutGuide;
        NSLayoutConstraint *fillWidth =
            [_contentStack.widthAnchor constraintEqualToAnchor:frame.widthAnchor constant:-8.0];
        fillWidth.priority = UILayoutPriorityDefaultHigh;
        [NSLayoutConstraint activateConstraints:@[
            [_scrollView.topAnchor constraintEqualToAnchor:_body.topAnchor],
            [_scrollView.leadingAnchor constraintEqualToAnchor:_body.leadingAnchor],
            [_scrollView.trailingAnchor constraintEqualToAnchor:_body.trailingAnchor],
            [_scrollView.bottomAnchor constraintEqualToAnchor:_body.bottomAnchor],
            [_contentStack.topAnchor constraintEqualToAnchor:content.topAnchor constant:2.0],
            [_contentStack.bottomAnchor constraintEqualToAnchor:content.bottomAnchor constant:-24.0],
            [_contentStack.leadingAnchor constraintGreaterThanOrEqualToAnchor:content.leadingAnchor],
            [_contentStack.trailingAnchor constraintLessThanOrEqualToAnchor:content.trailingAnchor],
            [_contentStack.centerXAnchor constraintEqualToAnchor:frame.centerXAnchor],
            [_contentStack.widthAnchor constraintLessThanOrEqualToConstant:640.0],
            fillWidth,
        ]];
    }
    _contentStack.spacing = spacing;
    return _contentStack;
}

- (void)closeScreen {
    if (self.navigationController.viewControllers.count > 1) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}

@end

#pragma mark - Home

@interface AksiHomeViewController : AksiScreenViewController
- (void)refresh;
@end

@interface AksiHomeViewController ()
@property (nonatomic, strong) AksiMenuRow *playRow;
@property (nonatomic, strong) AksiMenuRow *accountRow;
@property (nonatomic, strong) UIView *warningPanel;
@property (nonatomic, strong) UILabel *footerLabel;
- (void)push:(UIViewController *)controller;
@end

@implementation AksiHomeViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setScreenTitle:@"Aksi" showsBack:NO];
    UIStackView *stack = [self formStackWithSpacing:10.0];

    UILabel *subtitle = AksiMakeLabel(@"Minecraft: Java Edition · iOS", [UIFont systemFontOfSize:13],
                                      AksiDimColor());
    [stack addArrangedSubview:subtitle];
    [stack setCustomSpacing:16.0 afterView:subtitle];

    // The engine cannot start without the prepared resources: say where they
    // go instead of failing on Play.
    self.warningPanel = [[UIView alloc] init];
    self.warningPanel.translatesAutoresizingMaskIntoConstraints = NO;
    self.warningPanel.backgroundColor =
        [[UIColor colorWithRed:0.98 green:0.62 blue:0.15 alpha:1.0] colorWithAlphaComponent:0.14];
    self.warningPanel.layer.cornerRadius = 16.0;
    self.warningPanel.layer.cornerCurve = kCACornerCurveContinuous;
    self.warningPanel.layer.borderWidth = 1.0;
    self.warningPanel.layer.borderColor =
        [[UIColor colorWithRed:0.98 green:0.62 blue:0.15 alpha:1.0] colorWithAlphaComponent:0.5].CGColor;
    UILabel *warning = AksiMakeLabel(
        @"Ресурсы Minecraft не найдены. Скопируйте содержимое папки resources в "
        @"Documents/Horizon/resources (см. IOS.md).",
        [UIFont systemFontOfSize:14],
        [UIColor colorWithRed:1.0 green:0.82 blue:0.55 alpha:1.0]);
    [self.warningPanel addSubview:warning];
    [NSLayoutConstraint activateConstraints:@[
        [warning.topAnchor constraintEqualToAnchor:self.warningPanel.topAnchor constant:12.0],
        [warning.leadingAnchor constraintEqualToAnchor:self.warningPanel.leadingAnchor constant:14.0],
        [warning.trailingAnchor constraintEqualToAnchor:self.warningPanel.trailingAnchor constant:-14.0],
        [warning.bottomAnchor constraintEqualToAnchor:self.warningPanel.bottomAnchor constant:-12.0],
    ]];
    [stack addArrangedSubview:self.warningPanel];
    [stack setCustomSpacing:16.0 afterView:self.warningPanel];

    self.playRow = [[AksiMenuRow alloc] initWithHeading:@"Запустить игру"
                                                detail:@"Миры и создание — в самой игре"
                                             prominent:YES];
    [self.playRow addTarget:self
                     action:@selector(playTapped)
           forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.playRow];
    [stack setCustomSpacing:18.0 afterView:self.playRow];

    UILabel *appLabel = AksiSectionLabel(@"ПРИЛОЖЕНИЕ");
    [stack addArrangedSubview:appLabel];

    AksiMenuRow *settings = [[AksiMenuRow alloc] initWithHeading:@"Настройки"
                                                         detail:@"Акцент, графика, управление"
                                                      prominent:NO];
    [settings addTarget:self
                  action:@selector(settingsTapped)
        forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:settings];

    self.accountRow = [[AksiMenuRow alloc] initWithHeading:@"Аккаунт" detail:@"" prominent:NO];
    [self.accountRow addTarget:self
                        action:@selector(accountTapped)
              forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:self.accountRow];

    self.footerLabel = AksiMakeLabel(@"", [UIFont systemFontOfSize:12], AksiDimColor());
    self.footerLabel.textAlignment = NSTextAlignmentCenter;
    [stack addArrangedSubview:self.footerLabel];
    [stack setCustomSpacing:18.0 afterView:self.accountRow];

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (void)refresh {
    if (!self.isViewLoaded) {
        return;
    }
    NSDictionary<NSString *, NSString *> *account = AksiReadAccount();
    [self.accountRow setHeadingText:@"Аккаунт"
                             detail:account ? [NSString stringWithFormat:@"Ely.by · %@", account[@"name"]]
                                            : @"Ely.by или свой скин"];

    BOOL ready = AksiResourcesReady();
    self.warningPanel.hidden = ready;
    self.playRow.enabled = ready;
    self.playRow.alpha = ready ? 1.0 : 0.55;
    [self.playRow setHeadingText:@"Запустить игру"
                          detail:ready ? @"Миры и создание — в самой игре"
                                       : @"Сначала добавьте файлы игры"];
    self.footerLabel.text = [NSString stringWithFormat:@"Aksi %@ · Horizon", AksiVersion()];
}

- (void)playTapped {
    if (!AksiResourcesReady()) {
        AksiAlert(self, @"Нет ресурсов Minecraft",
                  @"Скопируйте содержимое resources в Documents/Horizon/resources. Без него "
                  @"движок не может начать.");
        return;
    }
    // The game's own title screen and world list are the launcher now: one
    // screen, so many worlds, servers and new worlds are the game's business.
    AksiStartFromHome(@"title:");
}

- (void)settingsTapped {
    [self push:[[AksiSettingsViewController alloc] init]];
}

- (void)accountTapped {
    [self push:[[AksiAccountViewController alloc] init]];
}

- (void)push:(UIViewController *)controller {
    [self.navigationController pushViewController:controller animated:YES];
}

@end

#pragma mark - Settings

/// The render distance a memory preset implies (extras.rs `MEMORY`). The
/// launch file's explicit `distance:` overrides it, so the launcher writes both
/// whenever the preset changes.
static NSInteger AksiMemoryDistance(NSInteger preset) {
    switch (preset) {
        case 0:
            return 4;
        case 2:
            return 12;
        default:
            return 8;
    }
}

/// A glass card with a title on the left and a control on the right.
static UIView *AksiControlPanel(NSString *title, UIView *control) {
    UIView *panel = [[UIView alloc] init];
    panel.translatesAutoresizingMaskIntoConstraints = NO;
    AksiStylePanel(panel);
    UILabel *label = AksiMakeLabel(title, [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold],
                                   AksiTextColor());
    [panel addSubview:label];
    [panel addSubview:control];
    [NSLayoutConstraint activateConstraints:@[
        [label.leadingAnchor constraintEqualToAnchor:panel.leadingAnchor constant:16.0],
        [label.topAnchor constraintEqualToAnchor:panel.topAnchor constant:13.0],
        [label.bottomAnchor constraintEqualToAnchor:panel.bottomAnchor constant:-13.0],
        [label.trailingAnchor constraintLessThanOrEqualToAnchor:control.leadingAnchor
                                                       constant:-12.0],
        [control.trailingAnchor constraintEqualToAnchor:panel.trailingAnchor constant:-14.0],
        [control.centerYAnchor constraintEqualToAnchor:panel.centerYAnchor],
        [panel.heightAnchor constraintGreaterThanOrEqualToConstant:56.0],
    ]];
    return panel;
}

@interface AksiSliderRow : UIView
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic) NSInteger value;
@property (nonatomic, copy) void (^onChange)(NSInteger value);
- (instancetype)initWithTitle:(NSString *)title
                      minimum:(NSInteger)minimum
                      maximum:(NSInteger)maximum
                       suffix:(NSString *)suffix;
@end

@implementation AksiSliderRow {
    UILabel *_valueLabel;
    NSString *_suffix;
}

- (instancetype)initWithTitle:(NSString *)title
                      minimum:(NSInteger)minimum
                      maximum:(NSInteger)maximum
                       suffix:(NSString *)suffix {
    self = [super initWithFrame:CGRectZero];
    if (!self) {
        return nil;
    }
    _suffix = [suffix copy];
    self.translatesAutoresizingMaskIntoConstraints = NO;
    AksiStylePanel(self);

    UILabel *titleLabel = AksiMakeLabel(title,
                                        [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold],
                                        AksiTextColor());
    _valueLabel = AksiMakeLabel(
        @"", [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightMedium],
        AksiAccentColor());
    _valueLabel.textAlignment = NSTextAlignmentRight;

    _slider = [[UISlider alloc] init];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    _slider.minimumValue = (float)minimum;
    _slider.maximumValue = (float)maximum;
    _slider.minimumTrackTintColor = AksiAccentColor();
    _slider.maximumTrackTintColor = [UIColor colorWithWhite:1.0 alpha:0.16];
    _slider.thumbTintColor = [UIColor whiteColor];
    [_slider addTarget:self
                  action:@selector(sliderMoved:)
        forControlEvents:UIControlEventValueChanged];

    [self addSubview:titleLabel];
    [self addSubview:_valueLabel];
    [self addSubview:_slider];
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16.0],
        [titleLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:12.0],
        [titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_valueLabel.leadingAnchor
                                                            constant:-8.0],
        [_valueLabel.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16.0],
        [_valueLabel.firstBaselineAnchor constraintEqualToAnchor:titleLabel.firstBaselineAnchor],
        [_slider.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12.0],
        [_slider.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12.0],
        [_slider.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4.0],
        [_slider.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8.0],
    ]];
    [self setValue:minimum];
    return self;
}

- (void)setValue:(NSInteger)value {
    _value = value;
    self.slider.value = (float)value;
    _valueLabel.text = [NSString stringWithFormat:@"%ld%@", (long)value, _suffix ?: @""];
}

- (void)sliderMoved:(UISlider *)sender {
    NSInteger value = (NSInteger)lroundf(sender.value);
    if (value == self.value) {
        // Between two steps: leave the file alone, the thumb is already snapped.
        sender.value = (float)self.value;
        return;
    }
    [self setValue:value];
    if (self.onChange) {
        self.onChange(value);
    }
}

@end

@implementation AksiSettingsViewController {
    NSArray<UIButton *> *_swatches;
    UILabel *_memoryDetail;
    AksiSliderRow *_distanceRow;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setScreenTitle:@"Настройки" showsBack:YES];
    UIStackView *stack = [self formStackWithSpacing:10.0];

    [stack addArrangedSubview:AksiSectionLabel(@"АКЦЕНТ")];
    UIView *swatchPanel = [[UIView alloc] init];
    swatchPanel.translatesAutoresizingMaskIntoConstraints = NO;
    AksiStylePanel(swatchPanel);
    UIStackView *swatches = [[UIStackView alloc] init];
    swatches.axis = UILayoutConstraintAxisHorizontal;
    swatches.alignment = UIStackViewAlignmentCenter;
    swatches.spacing = 12.0;
    swatches.translatesAutoresizingMaskIntoConstraints = NO;
    [swatchPanel addSubview:swatches];
    [NSLayoutConstraint activateConstraints:@[
        [swatches.leadingAnchor constraintEqualToAnchor:swatchPanel.leadingAnchor constant:16.0],
        [swatches.topAnchor constraintEqualToAnchor:swatchPanel.topAnchor constant:14.0],
        [swatches.bottomAnchor constraintEqualToAnchor:swatchPanel.bottomAnchor constant:-14.0],
        [swatches.trailingAnchor constraintLessThanOrEqualToAnchor:swatchPanel.trailingAnchor
                                                          constant:-16.0],
    ]];
    NSMutableArray<UIButton *> *buttons = [NSMutableArray array];
    for (NSInteger i = 0; i < 8; i++) {
        UIButton *swatch = [UIButton buttonWithType:UIButtonTypeCustom];
        swatch.translatesAutoresizingMaskIntoConstraints = NO;
        swatch.tag = i;
        uint32_t rgb = AksiAccentRGB[i];
        swatch.backgroundColor = [UIColor colorWithRed:((rgb >> 16) & 0xff) / 255.0
                                                 green:((rgb >> 8) & 0xff) / 255.0
                                                  blue:(rgb & 0xff) / 255.0
                                                 alpha:1.0];
        swatch.layer.cornerRadius = 17.0;
        [NSLayoutConstraint activateConstraints:@[
            [swatch.widthAnchor constraintEqualToConstant:34.0],
            [swatch.heightAnchor constraintEqualToConstant:34.0],
        ]];
        [swatch addTarget:self
                      action:@selector(accentTapped:)
            forControlEvents:UIControlEventTouchUpInside];
        [swatches addArrangedSubview:swatch];
        [buttons addObject:swatch];
    }
    _swatches = buttons;
    [stack addArrangedSubview:swatchPanel];
    [self updateSwatches];

    [stack addArrangedSubview:AksiSectionLabel(@"ПАМЯТЬ")];
    UISegmentedControl *memory =
        [[UISegmentedControl alloc] initWithItems:@[ @"Экономно", @"Обычно", @"Максимум" ]];
    memory.translatesAutoresizingMaskIntoConstraints = NO;
    memory.selectedSegmentIndex = AksiMemoryPreset();
    memory.selectedSegmentTintColor = AksiAccentColor();
    [memory setTitleTextAttributes:@{NSForegroundColorAttributeName : AksiTextColor()}
                          forState:UIControlStateNormal];
    [memory setTitleTextAttributes:@{NSForegroundColorAttributeName : [UIColor whiteColor]}
                          forState:UIControlStateSelected];
    [memory addTarget:self action:@selector(memoryChanged:) forControlEvents:UIControlEventValueChanged];
    [stack setCustomSpacing:14.0 afterView:swatchPanel];
    [stack addArrangedSubview:memory];

    _memoryDetail = AksiMakeLabel(@"", [UIFont systemFontOfSize:13], AksiDimColor());
    [stack addArrangedSubview:_memoryDetail];
    [self updateMemoryDetail];

    [stack setCustomSpacing:18.0 afterView:_memoryDetail];
    [stack addArrangedSubview:AksiSectionLabel(@"ГРАФИКА")];

    _distanceRow = [[AksiSliderRow alloc] initWithTitle:@"Дальность прорисовки"
                                                minimum:2
                                                maximum:32
                                                 suffix:@" чанков"];
    [_distanceRow setValue:AksiSettingNumber(@"distance",
                                             AksiMemoryDistance(AksiMemoryPreset()), 2, 32)];
    _distanceRow.onChange = ^(NSInteger value) {
        AksiSetSettingNumber(@"distance", value);
    };
    [stack addArrangedSubview:_distanceRow];

    UISegmentedControl *gui = [[UISegmentedControl alloc] initWithItems:@[ @"Авто", @"1", @"2", @"3" ]];
    gui.translatesAutoresizingMaskIntoConstraints = NO;
    gui.selectedSegmentIndex = MIN(AksiSettingNumber(@"gui", 0, 0, 4), 3);
    gui.selectedSegmentTintColor = AksiAccentColor();
    [gui setTitleTextAttributes:@{NSForegroundColorAttributeName : AksiTextColor()}
                       forState:UIControlStateNormal];
    [gui setTitleTextAttributes:@{NSForegroundColorAttributeName : [UIColor whiteColor]}
                       forState:UIControlStateSelected];
    [gui addTarget:self action:@selector(guiChanged:) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:AksiControlPanel(@"Масштаб интерфейса", gui)];

    UISwitch *bobbing = [[UISwitch alloc] init];
    bobbing.translatesAutoresizingMaskIntoConstraints = NO;
    bobbing.onTintColor = AksiAccentColor();
    bobbing.on = AksiSettingNumber(@"bobbing", 1, 0, 1) == 1;
    [bobbing addTarget:self action:@selector(bobbingChanged:)
        forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:AksiControlPanel(@"Покачивание камеры", bobbing)];

    [stack addArrangedSubview:AksiSectionLabel(@"УПРАВЛЕНИЕ")];
    AksiSliderRow *fov = [[AksiSliderRow alloc] initWithTitle:@"Угол обзора"
                                                      minimum:30
                                                      maximum:110
                                                       suffix:@"°"];
    [fov setValue:AksiSettingNumber(@"fov", 70, 30, 110)];
    fov.onChange = ^(NSInteger value) {
        AksiSetSettingNumber(@"fov", value);
    };
    [stack addArrangedSubview:fov];

    AksiSliderRow *sensitivity = [[AksiSliderRow alloc] initWithTitle:@"Чувствительность"
                                                              minimum:1
                                                              maximum:100
                                                               suffix:@"%"];
    [sensitivity setValue:AksiSettingNumber(@"sensitivity", 50, 1, 100)];
    sensitivity.onChange = ^(NSInteger value) {
        AksiSetSettingNumber(@"sensitivity", value);
    };
    [stack addArrangedSubview:sensitivity];

    UISwitch *invertY = [[UISwitch alloc] init];
    invertY.translatesAutoresizingMaskIntoConstraints = NO;
    invertY.onTintColor = AksiAccentColor();
    invertY.on = AksiSettingNumber(@"invert_y", 0, 0, 1) == 1;
    [invertY addTarget:self action:@selector(invertYChanged:)
        forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:AksiControlPanel(@"Инвертировать мышь по Y", invertY)];

    [stack addArrangedSubview:AksiSectionLabel(@"ЗВУК")];
    AksiSliderRow *volume = [[AksiSliderRow alloc] initWithTitle:@"Громкость"
                                                         minimum:0
                                                         maximum:100
                                                          suffix:@"%"];
    [volume setValue:AksiSettingNumber(@"volume", 100, 0, 100)];
    volume.onChange = ^(NSInteger value) {
        AksiSetSettingNumber(@"volume", value);
    };
    [stack addArrangedSubview:volume];

    UILabel *note = AksiMakeLabel(
        @"Значения применяются, когда мир открывается, и при следующем запуске. Пресет памяти "
        @"задаёт остальные лимиты: симуляцию, FPS и частицы.",
        [UIFont systemFontOfSize:13], AksiDimColor());
    [stack setCustomSpacing:18.0 afterView:volume];
    [stack addArrangedSubview:note];
}

- (void)updateSwatches {
    NSInteger selected = AksiAccentIndex();
    for (UIButton *swatch in _swatches) {
        BOOL on = swatch.tag == selected;
        swatch.layer.borderWidth = on ? 3.0 : 1.0;
        swatch.layer.borderColor = on ? [UIColor whiteColor].CGColor
                                      : [UIColor colorWithWhite:1.0 alpha:0.18].CGColor;
    }
}

- (void)updateMemoryDetail {
    switch (AksiMemoryPreset()) {
        case 0:
            _memoryDetail.text = @"4 чанка, симуляция 4, 45 FPS, меньше частиц.";
            break;
        case 2:
            _memoryDetail.text = @"12 чанков, симуляция 8, 120 FPS, все частицы.";
            break;
        default:
            _memoryDetail.text = @"8 чанков, симуляция 6, 60 FPS.";
            break;
    }
}

- (void)accentTapped:(UIButton *)sender {
    AksiSetAccentIndex(sender.tag);
    [self updateSwatches];
    [[NSNotificationCenter defaultCenter] postNotificationName:AksiAccentChangedNotification
                                                        object:nil];
}

- (void)memoryChanged:(UISegmentedControl *)sender {
    NSInteger preset = sender.selectedSegmentIndex;
    AksiSetMemoryPreset(preset);
    // Rust reads `memory` before the explicit `distance`, so the distance has to
    // move with the preset or an old hand-picked value would win.
    NSInteger distance = AksiMemoryDistance(preset);
    AksiSetSettingNumber(@"distance", distance);
    [_distanceRow setValue:distance];
    [self updateMemoryDetail];
}

- (void)guiChanged:(UISegmentedControl *)sender {
    AksiSetSettingNumber(@"gui", sender.selectedSegmentIndex);
}

- (void)bobbingChanged:(UISwitch *)sender {
    AksiSetSettingNumber(@"bobbing", sender.isOn ? 1 : 0);
}

- (void)invertYChanged:(UISwitch *)sender {
    AksiSetSettingNumber(@"invert_y", sender.isOn ? 1 : 0);
}

@end

#pragma mark - App delegate

/// The launcher is portrait, the game inside winit is landscape. iOS asks the
/// app delegate about every window, so the mask follows the window on top.
@interface AksiNavigationController : UINavigationController
@end

@implementation AksiNavigationController

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskPortrait;
}

- (BOOL)shouldAutorotate {
    return YES;
}

@end

/// Ask the system to turn the screen now. The delegate's mask only says which
/// orientations are allowed; on iOS 16 a scene geometry request is what
/// actually rotates a window that is already visible (`attemptRotation...` is
/// the older fallback and no longer enough).
static void AksiRequestOrientation(UIInterfaceOrientationMask mask) {
    UIWindow *window = nil;
    for (UIWindow *candidate in [UIApplication sharedApplication].windows) {
        if (candidate.isKeyWindow) {
            window = candidate;
            break;
        }
    }
    if (!window) {
        window = gLauncherWindow;
    }
    if (@available(iOS 16.0, *)) {
        UIWindowScene *scene = window.windowScene;
        if (scene) {
            UIWindowSceneGeometryPreferencesIOS *preferences =
                [[UIWindowSceneGeometryPreferencesIOS alloc] initWithInterfaceOrientations:mask];
            [scene requestGeometryUpdateWithPreferences:preferences
                                           errorHandler:^(NSError *error) {
                                               AksiLog(@"orientation: %@",
                                                       error.localizedDescription);
                                           }];
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    [UIViewController attemptRotationToDeviceOrientation];
#pragma clang diagnostic pop
}

@implementation AksiAppDelegate

- (BOOL)application:(UIApplication *)application
    didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    (void)application;
    (void)launchOptions;
    AksiHomeDirectory();
    AksiLog(@"launcher: start, resources %@, account %@", AksiResourcesReady() ? @"ready" : @"missing",
            AksiReadAccount() ? @"signed in" : @"none");

    AksiHomeViewController *home = [[AksiHomeViewController alloc] init];
    AksiNavigationController *navigation =
        [[AksiNavigationController alloc] initWithRootViewController:home];
    navigation.navigationBarHidden = YES;

    UIWindow *window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    window.backgroundColor = [UIColor blackColor];
    // Above the engine's window (which winit creates at the normal level), so the
    // launcher covers the idle game when it comes back after a world closes.
    window.windowLevel = UIWindowLevelNormal + 1.0;
    window.rootViewController = navigation;
    [window makeKeyAndVisible];

    gLauncherWindow = window;
    gLauncherNavigation = navigation;
    AksiRequestOrientation(UIInterfaceOrientationMaskPortrait);
    return YES;
}

- (void)applicationDidReceiveMemoryWarning:(UIApplication *)application {
    (void)application;
    horizon_ios_memory_warning();
}

- (UIInterfaceOrientationMask)application:(UIApplication *)application
    supportedInterfaceOrientationsForWindow:(UIWindow *)window {
    (void)application;
    // Per window, so the two masks never fight: the launcher is portrait, and
    // the engine's winit window is landscape (its view controller says the
    // same). iOS asks the key window, and `AksiRequestOrientation` turns the
    // scene to match it. Before Play there is only the launcher.
    if (!gEngineStarted || gLauncherWindow == nil || window == gLauncherWindow) {
        return UIInterfaceOrientationMaskPortrait;
    }
    return UIInterfaceOrientationMaskLandscape;
}

@end

#pragma mark - Starting the game

/// The window winit created when the engine started; it stays visible under
/// the launcher.
static UIWindow *AksiFindGameWindow(void) {
    if (gGameWindow) {
        return gGameWindow;
    }
    // The engine's window was just made key and visible, so prefer the key
    // window; the keyboard's text-effects window is never key. Fall back to the
    // last non-launcher window if the key window is not visible yet.
    UIWindow *fallback = nil;
    for (UIWindow *window in [UIApplication sharedApplication].windows) {
        if (window == gLauncherWindow) {
            continue;
        }
        fallback = window;
        if (window.isKeyWindow) {
            gGameWindow = window;
            return gGameWindow;
        }
    }
    gGameWindow = fallback;
    return gGameWindow;
}

void AksiStartFromHome(NSString *launch) {
    if (launch.length == 0) {
        return;
    }
    if (!gLauncherWindow) {
        return;
    }
    if (gStarting) {
        return;
    }
    gStarting = YES;

    NSString *text = [launch stringByAppendingString:@"\n"];
    if (!AksiWrite(AksiPath(AksiLaunchFile), text)) {
        gStarting = NO;
        AksiAlert(gLauncherNavigation.viewControllers.firstObject, @"Не удалось сохранить выбор",
                  @"Проверьте свободное место на устройстве и попробуйте снова.");
        return;
    }
    AksiLog(@"launch: %@", [launch componentsSeparatedByCharactersInSet:
                                        [NSCharacterSet newlineCharacterSet]].firstObject);
    [gLauncherWindow endEditing:YES];

    if (!gEngineStarted) {
        gEngineStarted = YES;
        // Let the button's touch finish before the engine takes over the main
        // thread and creates its own window.
        dispatch_async(dispatch_get_main_queue(), ^{
            int code = horizon_ios_main();
            UIWindow *game = AksiFindGameWindow();
            if (game) {
                [game makeKeyAndVisible];
            }
            gLauncherWindow.hidden = YES;
            gStarting = NO;
            if (code != 0) {
                gLauncherWindow.hidden = NO;
                [gLauncherWindow makeKeyAndVisible];
                AksiRequestOrientation(UIInterfaceOrientationMaskPortrait);
                AksiAlert(gLauncherNavigation.viewControllers.firstObject,
                          @"Игра не запустилась",
                          @"Подробности в Documents/Horizon/logs/latest.log.");
            } else {
                AksiRequestOrientation(UIInterfaceOrientationMaskLandscape);
            }
        });
        return;
    }

    UIWindow *game = AksiFindGameWindow();
    if (game) {
        [game makeKeyAndVisible];
    }
    gLauncherWindow.hidden = YES;
    gStarting = NO;
    AksiRequestOrientation(UIInterfaceOrientationMaskLandscape);
    // The engine is already running: hand the choice to its loop, which wakes
    // the leaked `App` through the event-loop proxy.
    horizon_ios_launch_action();
}

void horizon_ios_present_launcher(void) {
    void (^present)(void) = ^{
        if (!gLauncherWindow) {
            return;
        }
        AksiLog(@"launcher: presented again");
        [gLauncherWindow endEditing:YES];
        [gLauncherNavigation popToRootViewControllerAnimated:NO];
        AksiHomeViewController *home = (AksiHomeViewController *)gLauncherNavigation.viewControllers.firstObject;
        [home refresh];
        gLauncherWindow.hidden = NO;
        [gLauncherWindow makeKeyAndVisible];
        AksiRequestOrientation(UIInterfaceOrientationMaskPortrait);
    };
    if ([NSThread isMainThread]) {
        present();
    } else {
        dispatch_async(dispatch_get_main_queue(), present);
    }
}
