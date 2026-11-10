//! The Ely.by sign-in screen: a nickname and a password, the authserver call
//! off the game thread, and the local skin pipeline fed from the skinsystem.
//! The password is dropped once the request has been sent; the access token
//! stays in this process's memory only. What is kept across launches is
//! `horizon-account.txt` (the name and UUID, for display) and
//! `horizon-player.txt` (the nickname the game joins with).
use super::{Game, Screen, home};
use horizon_client::{
    Result,
    ely::{self, Account, Skin},
    hud::{HudBatch, rgba},
    offline_name, preedit,
    text::Text,
    ui,
};
use std::sync::mpsc::{self, TryRecvError};

type Outcome = std::result::Result<(Account, Option<Skin>), ely::Error>;

/// What the sign-in panel says under the fields.
pub(super) enum Status {
    Ready,
    Busy,
    Message(Text),
    /// A field is wrong before the request even leaves (empty password...).
    Problem(Text),
    Error(ely::Error),
}

pub(super) struct ElyMenu {
    /// The Home tab opened this, so Done returns to Home rather than Aksi.
    pub from_home: bool,
    pub nick: String,
    pub password: String,
    /// 0 the nickname, 1 the password.
    pub focus: u8,
    pub status: Status,
    pub busy: bool,
    rx: Option<mpsc::Receiver<Outcome>>,
}
impl Default for ElyMenu {
    fn default() -> Self {
        Self {
            from_home: false,
            nick: String::new(),
            password: String::new(),
            focus: 0,
            status: Status::Ready,
            busy: false,
            rx: None,
        }
    }
}

/// The screen's rectangles in GUI pixels, sized from the batch.
struct Layout {
    panel: [f32; 4],
    nick: [f32; 4],
    password: [f32; 4],
    sign_in: [f32; 4],
    sign_out: [f32; 4],
    done: [f32; 4],
}

fn layout(w: f32, h: f32, lifted: bool) -> Layout {
    let pw = (w * 0.52).clamp(280.0, 340.0);
    let ph = 140.0;
    let mut x = ((w - pw) / 2.0).floor();
    if x < 12.0 {
        x = 12.0;
    }
    let mut y = ((h - ph) / 2.0).floor();
    // The soft keyboard covers the bottom of the screen: lift the panel above
    // it while a field is focused, keeping it out of the status bar.
    if lifted {
        y = (y - h * 0.18).max(12.0);
    }
    let pad = 14.0;
    let inner = pw - pad * 2.0;
    let field_x = x + pad + 82.0;
    let field_w = x + pw - pad - field_x;
    let nick_y = y + 34.0;
    let password_y = y + 60.0;
    let gap = 6.0;
    let bw = (inner - gap * 2.0) / 3.0;
    let button_y = y + ph - 30.0;
    Layout {
        panel: [x, y, pw, ph],
        nick: [field_x, nick_y, field_w, 20.0],
        password: [field_x, password_y, field_w, 20.0],
        sign_in: [x + pad, button_y, bw, 20.0],
        sign_out: [x + pad + bw + gap, button_y, bw, 20.0],
        done: [x + pad + (bw + gap) * 2.0, button_y, bw, 20.0],
    }
}

/// `horizon-player.txt`: the nickname the game joins servers with.
fn write_player_name(name: &str) {
    let path = std::env::current_dir()
        .unwrap_or_default()
        .join(offline_name::FILE);
    if let Err(e) = std::fs::write(&path, format!("name:{name}\n")) {
        log::warn!(
            "Horizon: could not keep the player name in {}: {e}",
            path.display()
        );
    }
}

fn remove_skin() {
    let _ = std::fs::remove_file("horizon-skin.png");
    let _ = std::fs::remove_file("horizon-skin.txt");
}

fn write_skin(skin: &Skin) {
    if let Err(e) = std::fs::write("horizon-skin.png", &skin.png) {
        log::warn!("Horizon: could not write the Ely.by skin: {e}");
        return;
    }
    let model = if skin.slim {
        "model:slim"
    } else {
        "model:classic"
    };
    if let Err(e) = std::fs::write("horizon-skin.txt", format!("{model}\n")) {
        log::warn!("Horizon: could not write the skin model: {e}");
    }
}

impl Game<'_> {
    pub(super) fn open_ely(&mut self, from_home: bool) {
        self.screen = Screen::Ely;
        self.ely.from_home = from_home;
        self.ely.focus = 0;
        self.ely.status = Status::Ready;
        self.home.refresh();
        if let Some(account) = &self.home.account
            && self.ely.nick.is_empty()
        {
            self.ely.nick = account.name.clone();
        }
        self.capture(false);
    }

    pub(super) fn close_ely(&mut self) {
        // Drop the reply: a sign-in still in flight finishes in its own
        // thread, but its result no longer belongs to this screen.
        self.ely.rx = None;
        self.ely.busy = false;
        self.ely.password.clear();
        self.screen = if self.ely.from_home {
            Screen::Home
        } else {
            Screen::Aksi
        };
        self.capture(false);
    }

    fn ely_insert(&mut self, text: &str) {
        let field = if self.ely.focus == 0 {
            &mut self.ely.nick
        } else {
            &mut self.ely.password
        };
        for c in text.chars().filter(|c| !c.is_control()) {
            let limit = if self.ely.focus == 0 { 32 } else { 128 };
            if field.chars().count() >= limit {
                break;
            }
            field.push(c);
        }
    }

    pub(super) fn ely_text(&mut self, text: &str) {
        self.ely_insert(text);
    }

    pub(super) fn ely_backspace(&mut self) {
        let field = if self.ely.focus == 0 {
            &mut self.ely.nick
        } else {
            &mut self.ely.password
        };
        field.pop();
    }

    pub(super) fn ely_submit(&mut self) {
        if self.ely.busy {
            return;
        }
        if !offline_name::is_valid(self.ely.nick.trim()) {
            self.ely.status = Status::Problem(Text::translate("horizon.ely.error.nick", &[]));
            return;
        }
        if self.ely.password.is_empty() {
            self.ely.status = Status::Problem(Text::translate("horizon.ely.error.password", &[]));
            return;
        }
        let nick = self.ely.nick.trim().to_owned();
        let password = std::mem::take(&mut self.ely.password);
        let (tx, rx) = mpsc::channel();
        self.ely.rx = Some(rx);
        self.ely.busy = true;
        self.ely.status = Status::Busy;
        std::thread::spawn(move || {
            let result = ely::sign_in(&nick, &password).map(|account| {
                // A missing skin only means the account has none: it does not
                // fail the sign-in.
                let skin = ely::fetch_skin(&account.name).ok().flatten();
                (account, skin)
            });
            let _ = tx.send(result);
        });
    }

    pub(super) fn ely_sign_out(&mut self) {
        let _ = std::fs::remove_file(home::ACCOUNT_FILE);
        remove_skin();
        self.options.player_name = None;
        self.home.set_account(None);
        self.ely.password.clear();
        self.ely.status = Status::Message(Text::translate("horizon.ely.status.signedout", &[]));
    }

    /// Poll a sign-in running on its own thread: write the account, the
    /// nickname and the skin, then show who is signed in.
    pub(super) fn poll_ely(&mut self) {
        let Some(rx) = &self.ely.rx else {
            return;
        };
        let outcome = rx.try_recv();
        let outcome = match outcome {
            Ok(outcome) => outcome,
            Err(TryRecvError::Empty) => return,
            Err(TryRecvError::Disconnected) => Err(ely::Error::Unavailable),
        };
        self.ely.rx = None;
        self.ely.busy = false;
        match outcome {
            Ok((account, skin)) => {
                let info = home::HomeAccount {
                    name: account.name.clone(),
                    uuid: account.uuid,
                };
                if let Err(e) = home::write_account(&info) {
                    log::warn!("Horizon: could not keep the Ely.by account: {e}");
                }
                write_player_name(&info.name);
                self.options.player_name = Some(info.name.clone());
                match &skin {
                    Some(skin) => write_skin(skin),
                    None => remove_skin(),
                }
                self.home.set_account(Some(info.clone()));
                self.ely.status = Status::Message(Text::translate(
                    if skin.is_some() {
                        "horizon.ely.status.signedin"
                    } else {
                        "horizon.ely.status.noskin"
                    },
                    &[Text::literal(info.name)],
                ));
                self.ely.password.clear();
                // The token is not needed by the game: drop the account with it.
                drop(account);
            }
            Err(error) => self.ely.status = Status::Error(error),
        }
    }

    pub(super) fn ely_click(&mut self) -> Result<()> {
        let (w, h) = self.gui_size();
        let lifted = self.ely_lifted();
        let p = layout(w, h, lifted);
        let cursor = self.cursor;
        let hit = |r: &[f32; 4]| ui::hovered(cursor, r[0], r[1], r[2], r[3]);
        if hit(&p.nick) {
            self.ely.focus = 0;
        } else if hit(&p.password) {
            self.ely.focus = 1;
        } else if hit(&p.sign_in) {
            self.ely_submit();
        } else if hit(&p.sign_out) {
            if self.home.account.is_some() {
                self.ely_sign_out();
            }
        } else if hit(&p.done) {
            self.close_ely();
        } else {
            return Ok(());
        }
        self.audio.play_button_click();
        Ok(())
    }

    /// Keyboard events while the sign-in screen owns the frame.
    pub(super) fn ely_key(&mut self, event: &winit::event::KeyEvent) {
        use winit::{
            event::ElementState,
            keyboard::{KeyCode, PhysicalKey},
        };
        if event.state != ElementState::Pressed {
            return;
        }
        match event.physical_key {
            PhysicalKey::Code(KeyCode::Escape) => {
                self.close_ely();
                return;
            }
            PhysicalKey::Code(KeyCode::Tab) => {
                self.ely.focus = 1 - self.ely.focus;
                return;
            }
            PhysicalKey::Code(KeyCode::Enter | KeyCode::NumpadEnter) => {
                self.ely_submit();
                return;
            }
            PhysicalKey::Code(KeyCode::Backspace | KeyCode::Delete) => {
                self.ely_backspace();
                return;
            }
            _ => {}
        }
        let Some(text) = &event.text else {
            return;
        };
        if text.contains('\n') || text.contains('\r') {
            self.ely_submit();
            return;
        }
        self.ely_insert(text);
    }

    fn ely_lifted(&self) -> bool {
        cfg!(any(target_os = "android", target_os = "ios")) && self.ely.focus <= 1
    }

    pub(super) fn draw_ely(&mut self, batch: &mut HudBatch) {
        let atlas = &self.gui.atlas;
        let (w, h) = (batch.width, batch.height);
        let p = layout(w, h, self.ely_lifted());
        let accent_index = self.settings.extras.accent;
        let accent_color = super::aksi::accent_solid(accent_index);
        let [x, y, pw, ph] = p.panel;

        batch.fill(
            atlas,
            x - 2.0,
            y - 2.0,
            pw + 4.0,
            ph + 4.0,
            rgba(0, 0, 0, 90),
        );
        batch.fill(atlas, x, y, pw, ph, rgba(20, 18, 30, 220));
        super::aksi::outline(batch, atlas, p.panel, 1.0, rgba(255, 255, 255, 36));
        batch.fill(atlas, x, y, pw, 2.0, accent_color);

        let title = Text::translate("horizon.ely.title", &[]);
        ui::text_scaled(batch, atlas, &title, x + 14.0, y + 9.0, 1.3, accent_color);

        let nick_label = Text::translate("horizon.ely.nick", &[]);
        batch.text_styled(
            atlas,
            &nick_label,
            x + 14.0,
            p.nick[1] + 6.0,
            rgba(222, 222, 234, 255),
            true,
        );
        let password_label = Text::translate("horizon.ely.password", &[]);
        batch.text_styled(
            atlas,
            &password_label,
            x + 14.0,
            p.password[1] + 6.0,
            rgba(222, 222, 234, 255),
            true,
        );

        // The fields: plain rectangles, the focused one carries the accent.
        let field = |batch: &mut HudBatch, r: [f32; 4], value: &str, mask: bool, focus: bool| {
            batch.fill(atlas, r[0], r[1], r[2], r[3], rgba(0, 0, 0, 120));
            super::aksi::outline(
                batch,
                atlas,
                r,
                1.0,
                if focus {
                    accent_color
                } else {
                    rgba(255, 255, 255, 54)
                },
            );
            let shown = if mask {
                "*".repeat(value.chars().count())
            } else {
                value.to_owned()
            };
            let text = Text::literal(shown);
            batch.text_styled(atlas, &text, r[0] + 5.0, r[1] + 6.0, u32::MAX, true);
            atlas.font.width_text(&text)
        };
        let nick_focus = self.ely.focus == 0;
        let nick_w = field(batch, p.nick, &self.ely.nick, false, nick_focus);
        let pass_focus = self.ely.focus == 1;
        let pass_w = field(batch, p.password, &self.ely.password, true, pass_focus);
        // The input method's candidate window goes under the focused field's
        // caret (mobile keyboards ask for it).
        let (caret, caret_w) = if nick_focus {
            (p.nick, nick_w)
        } else {
            (p.password, pass_w)
        };
        preedit::report_caret(caret[0] + 5.0 + caret_w, caret[1] + 4.0, 12.0);

        let status = match &self.ely.status {
            Status::Ready => Some((
                Text::translate("horizon.ely.status.ready", &[]),
                rgba(196, 196, 212, 230),
            )),
            Status::Busy => Some((
                Text::translate("horizon.ely.status.busy", &[]),
                accent_color,
            )),
            Status::Message(text) => Some((text.clone(), rgba(150, 226, 160, 255))),
            Status::Problem(text) => Some((text.clone(), rgba(255, 120, 120, 255))),
            Status::Error(error) => Some((
                error.message_key().map_or_else(
                    || {
                        Text::literal(
                            error
                                .message()
                                .filter(|m| !m.is_empty())
                                .unwrap_or("Ely.by refused the sign-in.")
                                .to_owned(),
                        )
                    },
                    |key| Text::translate(key, &[]),
                ),
                rgba(255, 120, 120, 255),
            )),
        };
        if let Some((text, color)) = status {
            ui::centered_text(batch, atlas, &text, x + 10.0, y + 88.0, pw - 20.0, color);
        }

        let sign_in = Text::translate("horizon.ely.signin", &[]);
        let sign_out = Text::translate("horizon.ely.signout", &[]);
        let done = Text::translate("horizon.ely.done", &[]);
        let sign_in_hover = ui::hovered(
            self.cursor,
            p.sign_in[0],
            p.sign_in[1],
            p.sign_in[2],
            p.sign_in[3],
        );
        ui::button(
            batch,
            atlas,
            p.sign_in[0],
            p.sign_in[1],
            p.sign_in[2],
            p.sign_in[3],
            &sign_in,
            !self.ely.busy,
            sign_in_hover,
        );
        let sign_out_active = self.home.account.is_some();
        let sign_out_hover = ui::hovered(
            self.cursor,
            p.sign_out[0],
            p.sign_out[1],
            p.sign_out[2],
            p.sign_out[3],
        );
        ui::button(
            batch,
            atlas,
            p.sign_out[0],
            p.sign_out[1],
            p.sign_out[2],
            p.sign_out[3],
            &sign_out,
            sign_out_active,
            sign_out_hover,
        );
        let done_hover = ui::hovered(self.cursor, p.done[0], p.done[1], p.done[2], p.done[3]);
        ui::button(
            batch, atlas, p.done[0], p.done[1], p.done[2], p.done[3], &done, true, done_hover,
        );
    }
}
