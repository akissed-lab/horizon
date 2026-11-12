// The launcher's Ely.by sign-in screen. The request runs through NSURLSession
// (the system's TLS stack), not the game's Rust HTTP client: on iOS this is the
// path that actually gets out to authserver.ely.by, and its errors spell out
// what went wrong. The password is never logged or written; only the nickname,
// UUID and skin are kept, as `horizon-account.txt`, `horizon-player.txt`,
// `horizon-skin.png` and `horizon-skin.txt`.
#import "launcher.h"
#import <QuartzCore/QuartzCore.h>
#include <string.h>

static NSString *const AksiElyAccountFile = @"horizon-account.txt";
static NSString *const AksiElyPlayerFile = @"horizon-player.txt";
static NSString *const AksiElySkinFile = @"horizon-skin.png";
static NSString *const AksiElySkinModelFile = @"horizon-skin.txt";
static NSString *const AksiElyAuthURL = @"https://authserver.ely.by/auth/authenticate";
static NSString *const AksiElySkinURL = @"https://skinsystem.ely.by/skins/";
static NSString *const AksiElyTexturesURL = @"https://skinsystem.ely.by/textures/";

static NSString *AksiElyPath(NSString *name) {
    return [AksiHomeDirectory() stringByAppendingPathComponent:name];
}

static BOOL AksiElyWrite(NSString *path, NSString *text) {
    NSError *error = nil;
    BOOL ok = [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error];
    if (!ok) {
        AksiLog(@"ely: write %@ failed: %@", path.lastPathComponent, error.localizedDescription);
    }
    return ok;
}

static NSString *AksiElyVersion(void) {
    NSString *version = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    return version.length ? version : @"?";
}

static BOOL AksiElyValidName(NSString *name) {
    if (name.length < 1 || name.length > 16) {
        return NO;
    }
    for (NSUInteger i = 0; i < name.length; i++) {
        unichar c = [name characterAtIndex:i];
        if (c <= 32 || c >= 127) {
            return NO;
        }
    }
    return YES;
}

static NSString *AksiElyErrorText(NSInteger status, NSDictionary *json, NSError *error) {
    if (error) {
        return @"Нет связи с Ely.by. Проверьте подключение к интернету и попробуйте снова.";
    }
    NSString *message = [json[@"errorMessage"] isKindOfClass:[NSString class]] ? json[@"errorMessage"] : @"";
    NSString *code = [json[@"error"] isKindOfClass:[NSString class]] ? json[@"error"] : @"";
    NSString *lower = message.lowercaseString;
    if ([lower containsString:@"two factor"] || [lower containsString:@"two-factor"]) {
        return @"На аккаунте включена двухфакторная защита. Введите пароль как "
               @"password:код из приложения-аутентификатора.";
    }
    if (status == 401 || status == 403 || [code isEqualToString:@"ForbiddenOperationException"]) {
        return @"Неверный никнейм или пароль.";
    }
    if (status == 429 || [lower containsString:@"too many requests"]) {
        return @"Слишком много попыток входа. Подождите немного и попробуйте снова.";
    }
    if (status >= 500) {
        return @"Сервер Ely.by сейчас недоступен. Попробуйте позже.";
    }
    if (message.length) {
        return message;
    }
    return [NSString stringWithFormat:@"Ely.by ответил ошибкой (HTTP %ld).", (long)status];
}

static void AksiElyRemoveSkin(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:AksiElyPath(AksiElySkinFile) error:NULL];
    [fm removeItemAtPath:AksiElyPath(AksiElySkinModelFile) error:NULL];
}

@interface AksiAccountViewController ()
- (void)refresh;
- (void)setStatus:(NSString *)status error:(BOOL)error;
- (void)signInTapped;
- (void)signOutTapped;
- (void)fetchSkin:(NSString *)name;
- (void)fetchSkinModel:(NSString *)name;
- (void)handleAuth:(NSDictionary *)json
             status:(NSInteger)status
              error:(NSError *)error
               nick:(NSString *)nick;
@end

@implementation AksiAccountViewController {
    UIView *_profilePanel;
    UIImageView *_skinView;
    UILabel *_nameLabel;
    UILabel *_uuidLabel;
    UIButton *_signOutButton;
    UITextField *_nickField;
    UITextField *_passwordField;
    UIButton *_signInButton;
    UILabel *_statusLabel;
    NSURLSession *_session;
    BOOL _signingIn;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setScreenTitle:@"Аккаунт" showsBack:YES];
    UIStackView *stack = [self formStackWithSpacing:10.0];

    [stack addArrangedSubview:AksiSectionLabel(@"ПРОФИЛЬ")];

    _profilePanel = [[UIView alloc] init];
    _profilePanel.translatesAutoresizingMaskIntoConstraints = NO;
    AksiStylePanel(_profilePanel);
    _skinView = [[UIImageView alloc] init];
    _skinView.translatesAutoresizingMaskIntoConstraints = NO;
    _skinView.contentMode = UIViewContentModeScaleAspectFit;
    _skinView.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.05];
    _skinView.layer.cornerRadius = 12.0;
    _skinView.layer.cornerCurve = kCACornerCurveContinuous;
    _skinView.clipsToBounds = YES;
    _nameLabel = AksiMakeLabel(@"", [UIFont systemFontOfSize:18 weight:UIFontWeightSemibold],
                               AksiTextColor());
    _uuidLabel = AksiMakeLabel(@"", [UIFont systemFontOfSize:11], AksiDimColor());
    _signOutButton = AksiMakeButton(@"Выйти", NO);
    [_signOutButton addTarget:self
                       action:@selector(signOutTapped)
             forControlEvents:UIControlEventTouchUpInside];
    [_profilePanel addSubview:_skinView];
    [_profilePanel addSubview:_nameLabel];
    [_profilePanel addSubview:_uuidLabel];
    [_profilePanel addSubview:_signOutButton];
    [NSLayoutConstraint activateConstraints:@[
        [_skinView.leadingAnchor constraintEqualToAnchor:_profilePanel.leadingAnchor constant:14.0],
        [_skinView.topAnchor constraintEqualToAnchor:_profilePanel.topAnchor constant:14.0],
        [_skinView.widthAnchor constraintEqualToConstant:64.0],
        [_skinView.heightAnchor constraintEqualToConstant:64.0],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_skinView.trailingAnchor constant:14.0],
        [_nameLabel.topAnchor constraintEqualToAnchor:_profilePanel.topAnchor constant:16.0],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_profilePanel.trailingAnchor
                                                           constant:-14.0],
        [_uuidLabel.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_uuidLabel.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:2.0],
        [_uuidLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_profilePanel.trailingAnchor
                                                           constant:-14.0],
        [_signOutButton.leadingAnchor constraintEqualToAnchor:_skinView.trailingAnchor constant:14.0],
        [_signOutButton.topAnchor constraintEqualToAnchor:_uuidLabel.bottomAnchor constant:10.0],
        [_signOutButton.bottomAnchor constraintEqualToAnchor:_profilePanel.bottomAnchor constant:-14.0],
        [_signOutButton.widthAnchor constraintGreaterThanOrEqualToConstant:90.0],
    ]];
    [stack addArrangedSubview:_profilePanel];

    [stack setCustomSpacing:18.0 afterView:_profilePanel];
    [stack addArrangedSubview:AksiSectionLabel(@"ВОЙТИ ЧЕРЕЗ ELY.BY")];

    _nickField = AksiMakeField(@"Никнейм");
    _nickField.textContentType = UITextContentTypeUsername;
    _nickField.returnKeyType = UIReturnKeyNext;
    [stack addArrangedSubview:_nickField];

    _passwordField = AksiMakeField(@"Пароль");
    _passwordField.textContentType = UITextContentTypePassword;
    _passwordField.secureTextEntry = YES;
    _passwordField.returnKeyType = UIReturnKeyGo;
    [_passwordField addTarget:self
                       action:@selector(signInTapped)
             forControlEvents:UIControlEventEditingDidEndOnExit];
    [stack addArrangedSubview:_passwordField];

    _signInButton = AksiMakeButton(@"Войти", YES);
    [_signInButton addTarget:self
                      action:@selector(signInTapped)
            forControlEvents:UIControlEventTouchUpInside];
    [stack setCustomSpacing:14.0 afterView:_passwordField];
    [stack addArrangedSubview:_signInButton];

    _statusLabel = AksiMakeLabel(@"", [UIFont systemFontOfSize:13], AksiDimColor());
    [stack addArrangedSubview:_statusLabel];

    UILabel *hint = AksiMakeLabel(
        @"Пароль отправляется только в Ely.by и нигде не сохраняется. Никнейм и скин "
        @"записываются в Documents/Horizon, и игра подхватывает их при входе в мир.",
        [UIFont systemFontOfSize:13], AksiDimColor());
    [stack setCustomSpacing:14.0 afterView:_statusLabel];
    [stack addArrangedSubview:hint];

    [self refresh];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self refresh];
}

- (NSURLSession *)session {
    if (!_session) {
        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = 20.0;
        configuration.timeoutIntervalForResource = 30.0;
        configuration.HTTPAdditionalHeaders =
            @{@"User-Agent" : [NSString stringWithFormat:@"Aksi/%@", AksiElyVersion()]};
        _session = [NSURLSession sessionWithConfiguration:configuration];
    }
    return _session;
}

- (void)refresh {
    if (!self.isViewLoaded) {
        return;
    }
    NSDictionary<NSString *, NSString *> *account = AksiReadAccount();
    _profilePanel.hidden = account == nil;
    if (account) {
        _nameLabel.text = account[@"name"];
        NSString *uuid = account[@"uuid"];
        if (uuid.length == 32) {
            NSString *pretty = [NSString stringWithFormat:@"%@-%@-%@-%@-%@",
                                                          [uuid substringWithRange:NSMakeRange(0, 8)],
                                                          [uuid substringWithRange:NSMakeRange(8, 4)],
                                                          [uuid substringWithRange:NSMakeRange(12, 4)],
                                                          [uuid substringWithRange:NSMakeRange(16, 4)],
                                                          [uuid substringWithRange:NSMakeRange(20, 12)]];
            _uuidLabel.text = pretty;
        } else {
            _uuidLabel.text = uuid;
        }
        UIImage *skin = [UIImage imageWithContentsOfFile:AksiElyPath(AksiElySkinFile)];
        _skinView.image = skin;
        _skinView.hidden = skin == nil;
    } else {
        _nameLabel.text = @"";
        _uuidLabel.text = @"";
        _skinView.image = nil;
        _skinView.hidden = YES;
    }
}

- (void)setStatus:(NSString *)status error:(BOOL)error {
    _statusLabel.text = status ?: @"";
    _statusLabel.textColor = error ? [UIColor colorWithRed:1.0 green:0.45 blue:0.45 alpha:1.0]
                                   : AksiDimColor();
}

- (void)setSigningIn:(BOOL)signing {
    _signingIn = signing;
    _signInButton.enabled = !signing;
    _signInButton.alpha = signing ? 0.55 : 1.0;
    _nickField.enabled = !signing;
    _passwordField.enabled = !signing;
}

- (void)signInTapped {
    if (_signingIn) {
        return;
    }
    [self.view endEditing:YES];
    NSString *nick = [_nickField.text stringByTrimmingCharactersInSet:
                                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    NSString *password = _passwordField.text ?: @"";

    if (!AksiElyValidName(nick)) {
        [self setStatus:@"Никнейм: 1–16 латинских букв, цифр или символов подчёркивания." error:YES];
        return;
    }
    if (password.length == 0) {
        [self setStatus:@"Введите пароль." error:YES];
        return;
    }

    NSDictionary *body = @{
        @"username" : nick,
        @"password" : password,
        @"clientToken" : [NSUUID UUID].UUIDString,
        @"agent" : @{@"name" : @"Minecraft", @"version" : @1},
    };
    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:&jsonError];
    if (!data) {
        [self setStatus:@"Не удалось собрать запрос." error:YES];
        return;
    }
    NSMutableURLRequest *request =
        [NSMutableURLRequest requestWithURL:[NSURL URLWithString:AksiElyAuthURL]];
    request.HTTPMethod = @"POST";
    [request setValue:@"application/json; charset=utf-8" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Aksi/%@", AksiElyVersion()]
   forHTTPHeaderField:@"User-Agent"];
    request.HTTPBody = data;
    request.timeoutInterval = 20.0;

    AksiLog(@"ely: authenticating %@", nick);
    [self setSigningIn:YES];
    [self setStatus:@"Вход в Ely.by…" error:NO];
    // Drop the password copy as soon as the request owns its body; the field is
    // cleared again on success.
    password = nil;
    __weak AksiAccountViewController *weakSelf = self;
    NSURLSessionDataTask *task = [[self session]
        dataTaskWithRequest:request
          completionHandler:^(NSData *responseData, NSURLResponse *response, NSError *error) {
              NSInteger status = [(NSHTTPURLResponse *)response statusCode];
              NSDictionary *json = nil;
              if (responseData.length) {
                  id parsed = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:NULL];
                  if ([parsed isKindOfClass:[NSDictionary class]]) {
                      json = parsed;
                  }
              }
              dispatch_async(dispatch_get_main_queue(), ^{
                  [weakSelf handleAuth:json status:status error:error nick:nick];
              });
          }];
    [task resume];
}

- (void)handleAuth:(NSDictionary *)json
             status:(NSInteger)status
              error:(NSError *)error
               nick:(NSString *)nick {
    [self setSigningIn:NO];
    if (error || status != 200) {
        AksiLog(@"ely: auth failed, HTTP %ld%@", (long)status,
                error ? [@", " stringByAppendingString:error.localizedDescription] : @"");
        [self setStatus:AksiElyErrorText(status, json, error) error:YES];
        return;
    }
    NSString *token = [json[@"accessToken"] isKindOfClass:[NSString class]] ? json[@"accessToken"] : @"";
    NSDictionary *profile =
        [json[@"selectedProfile"] isKindOfClass:[NSDictionary class]] ? json[@"selectedProfile"] : nil;
    NSString *name = [profile[@"name"] isKindOfClass:[NSString class]] ? profile[@"name"] : @"";
    NSString *uuid = [profile[@"id"] isKindOfClass:[NSString class]] ? profile[@"id"] : @"";
    uuid = [[uuid lowercaseString] stringByReplacingOccurrencesOfString:@"-" withString:@""];
    NSCharacterSet *nonHex =
        [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet];
    BOOL valid = token.length > 0 && name.length > 0 && uuid.length == 32 &&
                 [uuid rangeOfCharacterFromSet:nonHex].location == NSNotFound;
    if (!valid) {
        AksiLog(@"ely: incomplete profile for %@", nick);
        [self setStatus:@"Ely.by вернул неполный профиль. Попробуйте ещё раз." error:YES];
        return;
    }

    // Only what the game needs is kept; the access token dies with this block.
    NSString *account = [NSString stringWithFormat:@"name:%@\nuuid:%@\n", name, uuid];
    AksiElyWrite(AksiElyPath(AksiElyAccountFile), account);
    AksiElyWrite(AksiElyPath(AksiElyPlayerFile), [NSString stringWithFormat:@"name:%@\n", name]);
    token = nil;

    _passwordField.text = @"";
    _nickField.text = name;
    [self setStatus:[NSString stringWithFormat:@"Вы вошли как %@. Загружаю скин…", name] error:NO];
    AksiLog(@"ely: signed in as %@ (%@)", name, uuid);
    [self refresh];
    [self fetchSkin:name];
}

- (void)fetchSkin:(NSString *)name {
    NSString *encoded = [name stringByAddingPercentEncodingWithAllowedCharacters:
                                  [NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:
                           [NSString stringWithFormat:@"%@%@.png", AksiElySkinURL, encoded]];
    __weak AksiAccountViewController *weakSelf = self;
    NSURLSessionDataTask *task = [[self session]
        dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                NSInteger status = [(NSHTTPURLResponse *)response statusCode];
                BOOL png = [data length] >= 8 &&
                           memcmp(data.bytes, "\x89PNG\r\n\x1a\n", 8) == 0;
                UIImage *image = png ? [UIImage imageWithData:data] : nil;
                // Measure the pixels, not `size` (which is in points and
                // depends on the image's scale).
                size_t width = image.CGImage ? CGImageGetWidth(image.CGImage) : 0;
                size_t height = image.CGImage ? CGImageGetHeight(image.CGImage) : 0;
                BOOL usable = width == 64 && (height == 64 || height == 32) &&
                              data.length <= 512 * 1024;
                if (error || status != 200 || !usable) {
                    AksiLog(@"ely: no skin for %@ (HTTP %ld)", name, (long)status);
                    dispatch_async(dispatch_get_main_queue(), ^{
                        AksiElyRemoveSkin();
                        [weakSelf setStatus:[NSString stringWithFormat:
                                                          @"Вы вошли как %@. Скин не найден — останется "
                                                          @"стандартный.",
                                                          name]
                                      error:NO];
                        [weakSelf refresh];
                    });
                    return;
                }
                dispatch_async(dispatch_get_main_queue(), ^{
                    BOOL ok = [data writeToFile:AksiElyPath(AksiElySkinFile) atomically:YES];
                    // Classic until the textures document says otherwise.
                    AksiElyWrite(AksiElyPath(AksiElySkinModelFile), @"model:classic\n");
                    [weakSelf setStatus:ok ? [NSString stringWithFormat:@"Вы вошли как %@.", name]
                                           : @"Вы вошли, но скин не сохранился."
                                 error:!ok];
                    [weakSelf refresh];
                    [weakSelf fetchSkinModel:name];
                });
            }];
    [task resume];
}

- (void)fetchSkinModel:(NSString *)name {
    NSString *encoded = [name stringByAddingPercentEncodingWithAllowedCharacters:
                                  [NSCharacterSet URLPathAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:
                           [NSString stringWithFormat:@"%@%@", AksiElyTexturesURL, encoded]];
    __weak AksiAccountViewController *weakSelf = self;
    NSURLSessionDataTask *task = [[self session]
        dataTaskWithURL:url
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                if (error || [(NSHTTPURLResponse *)response statusCode] != 200 || !data.length) {
                    return;
                }
                id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
                if (![parsed isKindOfClass:[NSDictionary class]]) {
                    return;
                }
                NSDictionary *skin = parsed[@"SKIN"];
                NSDictionary *metadata =
                    [skin isKindOfClass:[NSDictionary class]] ? skin[@"metadata"] : nil;
                NSString *model = [metadata isKindOfClass:[NSDictionary class]] ? metadata[@"model"] : nil;
                BOOL slim = [model isKindOfClass:[NSString class]] && [model isEqualToString:@"slim"];
                dispatch_async(dispatch_get_main_queue(), ^{
                    AksiElyWrite(AksiElyPath(AksiElySkinModelFile),
                                 slim ? @"model:slim\n" : @"model:classic\n");
                    [weakSelf refresh];
                });
            }];
    [task resume];
}

- (void)signOutTapped {
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:AksiElyPath(AksiElyAccountFile) error:NULL];
    AksiElyRemoveSkin();
    _passwordField.text = @"";
    [self setStatus:@"Вы вышли из Ely.by. Никнейм останется для офлайн-игры." error:NO];
    AksiLog(@"ely: signed out");
    [self refresh];
}

@end
