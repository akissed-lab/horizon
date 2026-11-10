//! Aksi Home: the branded menu the iOS port opens before the game starts.
//! One screen with three tabs (Play, Settings, Account), the world card that
//! continues the last world, the accent colour and memory presets, and the
//! Ely.by sign-in door. The menu sits on the title panorama: the vanilla
//! `Title` screens are reached from here (all worlds, new world, multiplayer)
//! and come back to Home when they return to vanilla's main menu.
use super::aksi::{accent, accent_soft, accent_solid, active_preset, outline};
use super::{Game, Screen};
use horizon_client::{
    Result,
    extras::{ACCENTS, MEMORY},
    hud::{HudBatch, rgba},
    lang,
    options_ui::Page,
    text::Text,
    title::{Title, WorldEntry},
    ui,
};
use std::time::Instant;

/// The Ely.by account shown on the Account tab.
#[derive(Clone)]
pub(super) struct HomeAccount {
    pub name: String,
    pub uuid: u128,
}

/// What Home remembers between frames.
pub(super) struct HomeMenu {
    /// 0 Play, 1 Settings, 2 Account.
    pub tab: u8,
    /// The graphics options were opened from here, so they close back to Home.
    pub options_return: bool,
    worlds: Vec<WorldEntry>,
    worlds_at: Option<Instant>,
    pub account: Option<HomeAccount>,
    account_at: Option<Instant>,
}
impl Default for HomeMenu {
    fn default() -> Self {
        Self {
            tab: 0,
            options_return: false,
            worlds: Vec::new(),
            worlds_at: None,
            account: None,
            account_at: None,
        }
    }
}

/// The screen's rectangles in GUI pixels, sized from the batch.
struct Layout {
    panel: [f32; 4],
    tabs: [[f32; 4]; 3],
    content: [f32; 4],
    start: [f32; 4],
    /// Play: the last world's card, then the three doors.
    world: [f32; 4],
    doors: [[f32; 4]; 3],
    /// Settings: the accent swatches, the memory presets, then two doors.
    swatches: [[f32; 4]; ACCENTS.len()],
    presets: [[f32; 4]; MEMORY.len()],
    settings_doors: [[f32; 4]; 2],
    /// Account: the Ely.by door.
    ely: [f32; 4],
}

fn layout(w: f32, h: f32) -> Layout {
    let margin = 10.0;
    let panel = [margin, margin, w - margin * 2.0, h - margin * 2.0];
    let [x, y, pw, ph] = panel;
    let pad = 14.0;
    let inner = pw - pad * 2.0;

    // Tabs, under the brand.
    let tab_h = 18.0;
    let tab_w = 86.0;
    let tab_gap = 6.0;
    let tab_y = y + 34.0;
    let mut tabs = [[0.0; 4]; 3];
    for (i, r) in tabs.iter_mut().enumerate() {
        *r = [x + pad + i as f32 * (tab_w + tab_gap), tab_y, tab_w, tab_h];
    }

    let content_y = tab_y + tab_h + 9.0;
    let start = [x + pad, y + ph - 34.0, inner, 22.0];
    let content = [x + pad, content_y, inner, start[1] - 9.0 - content_y];

    // Play: a wide world card and three equal doors under it.
    let world = [content[0], content[1], content[2], 48.0];
    let door_gap = 6.0;
    let door_w = (inner - door_gap * 2.0) / 3.0;
    let door_y = world[1] + world[3] + 8.0;
    let mut doors = [[0.0; 4]; 3];
    for (i, r) in doors.iter_mut().enumerate() {
        *r = [
            content[0] + i as f32 * (door_w + door_gap),
            door_y,
            door_w,
            20.0,
        ];
    }

    // Settings: swatches, presets, two doors.
    let side = 20.0;
    let swatch_gap = 8.0;
    let swatch_y = content[1] + 13.0;
    let mut swatches = [[0.0; 4]; ACCENTS.len()];
    for (i, r) in swatches.iter_mut().enumerate() {
        *r = [
            content[0] + i as f32 * (side + swatch_gap),
            swatch_y,
            side,
            side,
        ];
    }
    let preset_gap = 6.0;
    let preset_w = (inner - preset_gap * 2.0) / MEMORY.len() as f32;
    let preset_y = swatch_y + side + 22.0;
    let mut presets = [[0.0; 4]; MEMORY.len()];
    for (i, r) in presets.iter_mut().enumerate() {
        *r = [
            content[0] + i as f32 * (preset_w + preset_gap),
            preset_y,
            preset_w,
            18.0,
        ];
    }
    let door2_y = preset_y + 18.0 + 12.0;
    let half = (inner - 6.0) / 2.0;
    let settings_doors = [
        [content[0], door2_y, half, 20.0],
        [content[0] + half + 6.0, door2_y, half, 20.0],
    ];

    // Account: the Ely.by door, under the status lines.
    let ely = [content[0], content[1] + 46.0, inner, 20.0];

    Layout {
        panel,
        tabs,
        content,
        start,
        world,
        doors,
        swatches,
        presets,
        settings_doors,
        ely,
    }
}

/// The game mode's name, as the world list shows it.
fn mode_name(mode: i32) -> String {
    let (key, fallback) = match mode {
        1 => ("gameMode.creative", "Creative Mode"),
        2 => ("gameMode.adventure", "Adventure Mode"),
        3 => ("gameMode.spectator", "Spectator Mode"),
        _ => ("gameMode.survival", "Survival Mode"),
    };
    lang::get_or(key, fallback)
}

impl HomeMenu {
    /// Refresh the cached world list and account file when they are stale.
    /// Worlds come from disk, so a world added through Files shows up.
    pub(super) fn refresh(&mut self) {
        let now = Instant::now();
        if self
            .worlds_at
            .is_none_or(|t| now.duration_since(t).as_secs() >= 2)
        {
            self.worlds_at = Some(now);
            self.worlds = match std::env::current_dir() {
                Ok(dir) => horizon_client::title::list_worlds(&dir.join("saves")),
                Err(_) => Vec::new(),
            };
        }
        if self
            .account_at
            .is_none_or(|t| now.duration_since(t).as_secs() >= 2)
        {
            self.account_at = Some(now);
            self.account = read_account();
        }
    }

    /// The world the Play button continues: the newest one that can open.
    fn playable(&self) -> Option<&WorldEntry> {
        self.worlds
            .iter()
            .find(|w| !w.locked && !w.corrupted && w.incompatible.is_none())
    }

    pub(super) fn set_account(&mut self, account: Option<HomeAccount>) {
        self.account = account;
        self.account_at = Some(Instant::now());
    }
}

/// `horizon-account.txt`: `name:` and `uuid:`, the signed-in Ely.by account.
/// The token is never written there.
pub(super) const ACCOUNT_FILE: &str = "horizon-account.txt";

pub(super) fn read_account() -> Option<HomeAccount> {
    let text = std::fs::read_to_string(ACCOUNT_FILE).ok()?;
    let field = |key: &str| {
        text.lines()
            .find_map(|line| line.trim_end_matches('\r').strip_prefix(key))
            .map(str::trim)
            .filter(|v| !v.is_empty())
    };
    let name = field("name:")?.to_owned();
    let uuid = field("uuid:").and_then(horizon_client::auth::parse_uuid)?;
    Some(HomeAccount { name, uuid })
}

pub(super) fn write_account(account: &HomeAccount) -> std::io::Result<()> {
    std::fs::write(
        ACCOUNT_FILE,
        format!("name:{}\nuuid:{:032x}\n", account.name, account.uuid),
    )
}

impl Game<'_> {
    /// Show Home, with no `Title` under it: the panorama comes from `render`.
    pub(super) fn open_home(&mut self) {
        self.title = None;
        self.screen = Screen::Home;
        self.capture(false);
    }

    /// iOS: vanilla's main menu becomes Aksi Home. Loading screens keep a
    /// Main-mode `Title` (`defer_world_entry` makes one), so they are left
    /// alone until the world has opened.
    pub(super) fn normalize_title_to_home(&mut self) {
        if !cfg!(target_os = "ios")
            || self.screen != Screen::Playing
            || self.pending_entry.is_some()
            || self.world_loader.is_some()
            || self.rest_loader.is_some()
        {
            return;
        }
        if self.title.as_ref().is_some_and(Title::is_main) {
            self.open_home();
        }
    }

    /// A fresh `Title` with the settings the title screens expect (the last
    /// server and the multiplayer warning), as the startup path builds it.
    pub(super) fn new_title(&mut self) -> Result<Title> {
        let mut title = Title::new(
            std::env::current_dir()?.join("saves"),
            &self.options.resources,
        )
        .with_user(|| self.options.player_name());
        title.last_server = self.settings.file.string("lastServer");
        title.skip_multiplayer_warning = self.settings.file.bool("skipMultiplayerWarning");
        Ok(title)
    }

    /// Hand a `Title` screen the frame: it draws through `hud_layers`.
    pub(super) fn show_title(&mut self, title: Title) {
        self.title = Some(title);
        self.screen = Screen::Playing;
        self.capture(false);
    }

    /// The big bottom button, and the Play tab's world card: continue the
    /// last world, or create one when there is none.
    pub(super) fn home_play(&mut self) -> Result<()> {
        let folder = self.home.playable().map(|w| w.folder.clone());
        if let Some(folder) = folder {
            self.open_world(&folder, None, None, false, None)?;
        } else {
            let mut title = self.new_title()?;
            title.begin_create();
            self.show_title(title);
        }
        Ok(())
    }

    pub(super) fn home_click(&mut self) -> Result<()> {
        let (w, h) = self.gui_size();
        let p = layout(w, h);
        let cursor = self.cursor;
        let hit = |r: &[f32; 4]| ui::hovered(cursor, r[0], r[1], r[2], r[3]);

        // The tabs.
        if let Some(i) = p.tabs.iter().position(hit) {
            self.home.tab = i as u8;
            self.audio.play_button_click();
            return Ok(());
        }
        // The start button runs the Play tab's primary action from any tab.
        if hit(&p.start) {
            self.home_play()?;
            self.audio.play_button_click();
            return Ok(());
        }
        match self.home.tab {
            0 => {
                if hit(&p.world) {
                    self.home_play()?;
                } else if hit(&p.doors[0]) {
                    let mut title = self.new_title()?;
                    title.enter_singleplayer();
                    self.show_title(title);
                } else if hit(&p.doors[1]) {
                    let mut title = self.new_title()?;
                    title.begin_create();
                    self.show_title(title);
                } else if hit(&p.doors[2]) {
                    let mut title = self.new_title()?;
                    title.open_multiplayer();
                    self.show_title(title);
                } else {
                    return Ok(());
                }
            }
            1 => {
                if let Some(i) = p.swatches.iter().position(hit) {
                    self.settings.extras.accent = i as u8;
                    self.settings.save(&Self::options_path());
                } else if let Some(i) = p.presets.iter().position(hit) {
                    self.apply_memory_preset(i);
                } else if hit(&p.settings_doors[0]) {
                    self.home.options_return = true;
                    self.open_options_at(false, Page::Graphics);
                } else if hit(&p.settings_doors[1]) {
                    self.home.options_return = true;
                    self.open_options_at(false, Page::Language);
                } else {
                    return Ok(());
                }
            }
            2 => {
                if hit(&p.ely) {
                    self.open_ely(true);
                } else {
                    return Ok(());
                }
            }
            _ => return Ok(()),
        }
        self.audio.play_button_click();
        Ok(())
    }

    pub(super) fn draw_home(&mut self, batch: &mut HudBatch) {
        self.home.refresh();
        let atlas = &self.gui.atlas;
        let (w, h) = (batch.width, batch.height);
        let p = layout(w, h);
        let [x, y, pw, ph] = p.panel;
        let accent_index = self.settings.extras.accent;
        let accent_color = accent_solid(accent_index);
        let tab = self.home.tab;

        // The panorama is drawn behind this batch, so a dim is all the menu
        // needs: the glass is translucent fills, no second shader.
        batch.fill(atlas, 0.0, 0.0, w, h, rgba(8, 7, 14, 92));

        batch.fill(
            atlas,
            x - 2.0,
            y - 2.0,
            pw + 4.0,
            ph + 4.0,
            rgba(0, 0, 0, 70),
        );
        batch.fill(atlas, x, y, pw, ph, rgba(18, 16, 28, 214));
        outline(batch, atlas, p.panel, 1.0, rgba(255, 255, 255, 34));
        batch.fill(atlas, x, y, pw, 2.0, accent_color);

        // The brand.
        let brand = Text::literal("Aksi");
        ui::text_scaled(batch, atlas, &brand, x + 14.0, y + 9.0, 1.6, accent_color);
        let sub = Text::literal("Horizon for iOS");
        let sub_w = atlas.font.width_text(&sub);
        batch.text_styled(
            atlas,
            &sub,
            x + pw - 14.0 - sub_w,
            y + 12.0,
            rgba(190, 190, 206, 170),
            true,
        );

        // Tabs: the active one carries the accent.
        let labels = [
            Text::translate("horizon.home.play", &[]),
            Text::translate("horizon.home.settings", &[]),
            Text::translate("horizon.home.account", &[]),
        ];
        for (i, r) in p.tabs.iter().enumerate() {
            let on = i as u8 == tab;
            let hover = ui::hovered(self.cursor, r[0], r[1], r[2], r[3]);
            let bg = if on {
                accent_soft(accent_index, 60)
            } else if hover {
                rgba(255, 255, 255, 26)
            } else {
                rgba(255, 255, 255, 10)
            };
            batch.fill(atlas, r[0], r[1], r[2], r[3], bg);
            if on {
                outline(batch, atlas, *r, 1.0, accent_soft(accent_index, 200));
            }
            let color = if on {
                accent_color
            } else {
                rgba(206, 206, 220, 230)
            };
            ui::centered_text(
                batch,
                atlas,
                &labels[i],
                r[0] + 4.0,
                r[1] + 5.0,
                r[2] - 8.0,
                color,
            );
        }

        match tab {
            0 => self.draw_home_play(batch, &p),
            1 => self.draw_home_settings(batch, &p),
            2 => self.draw_home_account(batch, &p),
            _ => {}
        }

        // The persistent start button: continue, or start a world.
        let has_world = self.home.playable().is_some();
        let label = Text::translate(
            if has_world {
                "horizon.home.start"
            } else {
                "horizon.home.start.new"
            },
            &[],
        );
        let hover = ui::hovered(self.cursor, p.start[0], p.start[1], p.start[2], p.start[3]);
        if hover {
            batch.fill(
                atlas,
                p.start[0],
                p.start[1],
                p.start[2],
                p.start[3],
                accent_soft(accent_index, 60),
            );
        }
        outline(batch, atlas, p.start, 2.0, accent_soft(accent_index, 220));
        ui::centered_text(
            batch,
            atlas,
            &label,
            p.start[0] + 6.0,
            p.start[1] + 7.0,
            p.start[2] - 12.0,
            if hover { u32::MAX } else { accent_color },
        );
    }

    fn draw_home_play(&self, batch: &mut HudBatch, p: &Layout) {
        let atlas = &self.gui.atlas;
        let accent_color = accent_solid(self.settings.extras.accent);
        let [x, y, w, h] = p.world;
        let world = self.home.playable().cloned();
        let hover = ui::hovered(self.cursor, x, y, w, h);
        batch.fill(
            atlas,
            x,
            y,
            w,
            h,
            if hover {
                rgba(255, 255, 255, 32)
            } else {
                rgba(255, 255, 255, 14)
            },
        );
        outline(batch, atlas, p.world, 1.0, rgba(255, 255, 255, 40));
        match world {
            Some(world) => {
                let name = Text::literal(world.name.clone());
                batch.text_styled(atlas, &name, x + 10.0, y + 9.0, u32::MAX, true);
                let mode = Text::literal(format!(
                    "{}{} · {}",
                    if world.hardcore { "Hardcore · " } else { "" },
                    mode_name(world.game_mode),
                    world.version
                ));
                batch.text_styled(
                    atlas,
                    &mode,
                    x + 10.0,
                    y + 24.0,
                    rgba(196, 196, 212, 220),
                    true,
                );
                let play = Text::translate("horizon.home.continue", &[]);
                let tw = atlas.font.width_text(&play);
                batch.text_styled(
                    atlas,
                    &play,
                    x + w - 10.0 - tw,
                    y + 18.0,
                    accent_color,
                    true,
                );
            }
            None => {
                let none = Text::translate("horizon.home.world.none", &[]);
                ui::centered_text(batch, atlas, &none, x + 10.0, y + 9.0, w - 20.0, u32::MAX);
                let hint = Text::translate("horizon.home.world.hint", &[]);
                ui::centered_text(
                    batch,
                    atlas,
                    &hint,
                    x + 10.0,
                    y + 25.0,
                    w - 20.0,
                    rgba(188, 188, 204, 220),
                );
            }
        }

        let labels = [
            Text::translate("horizon.home.all", &[]),
            Text::translate("horizon.home.new", &[]),
            Text::translate("horizon.home.multiplayer", &[]),
        ];
        for (i, r) in p.doors.iter().enumerate() {
            let hover = ui::hovered(self.cursor, r[0], r[1], r[2], r[3]);
            ui::button(
                batch, atlas, r[0], r[1], r[2], r[3], &labels[i], true, hover,
            );
        }
        let hint = Text::translate("horizon.home.play.hint", &[]);
        ui::centered_text(
            batch,
            atlas,
            &hint,
            p.content[0] + 6.0,
            p.doors[0][1] + 30.0,
            p.content[2] - 12.0,
            rgba(160, 160, 178, 200),
        );
    }

    fn draw_home_settings(&self, batch: &mut HudBatch, p: &Layout) {
        let atlas = &self.gui.atlas;
        let accent_index = self.settings.extras.accent;
        let accent_color = accent_solid(accent_index);
        let [x, ..] = p.content;

        let accent_label = Text::translate("horizon.home.accent", &[]);
        batch.text_styled(
            atlas,
            &accent_label,
            x,
            p.content[1],
            rgba(222, 222, 234, 255),
            true,
        );
        for (i, r) in p.swatches.iter().enumerate() {
            let (cr, cg, cb) = accent(i as u8);
            if i as u8 == accent_index {
                batch.fill(
                    atlas,
                    r[0] - 2.0,
                    r[1] - 2.0,
                    r[2] + 4.0,
                    r[3] + 4.0,
                    rgba(255, 255, 255, 220),
                );
            }
            batch.fill(atlas, r[0], r[1], r[2], r[3], rgba(cr, cg, cb, 255));
        }

        let memory_label = Text::translate("horizon.home.memory", &[]);
        batch.text_styled(
            atlas,
            &memory_label,
            x,
            p.swatches[0][1] + p.swatches[0][3] + 6.0,
            rgba(222, 222, 234, 255),
            true,
        );
        let selected = active_preset(&self.settings);
        for (i, r) in p.presets.iter().enumerate() {
            let hover = ui::hovered(self.cursor, r[0], r[1], r[2], r[3]);
            ui::button(
                batch,
                atlas,
                r[0],
                r[1],
                r[2],
                r[3],
                &Text::translate(MEMORY[i].label, &[]),
                true,
                hover,
            );
            if selected == Some(i) {
                outline(batch, atlas, *r, 2.0, accent_color);
            }
        }

        let labels = [
            Text::translate("horizon.home.graphics", &[]),
            Text::translate("horizon.home.language", &[]),
        ];
        for (i, r) in p.settings_doors.iter().enumerate() {
            let hover = ui::hovered(self.cursor, r[0], r[1], r[2], r[3]);
            ui::button(
                batch, atlas, r[0], r[1], r[2], r[3], &labels[i], true, hover,
            );
        }
        let hint = Text::translate("horizon.home.memory.hint", &[]);
        ui::centered_text(
            batch,
            atlas,
            &hint,
            p.content[0] + 6.0,
            p.settings_doors[0][1] + 28.0,
            p.content[2] - 12.0,
            rgba(160, 160, 178, 200),
        );
    }

    fn draw_home_account(&self, batch: &mut HudBatch, p: &Layout) {
        let atlas = &self.gui.atlas;
        let [x, y, w, ..] = p.content;
        match &self.home.account {
            Some(account) => {
                let signed = Text::translate(
                    "horizon.home.ely.signed",
                    &[Text::literal(account.name.clone())],
                );
                batch.text_styled(atlas, &signed, x, y, u32::MAX, true);
                let uuid = Text::literal(format!("{:032x}", account.uuid));
                batch.text_styled(atlas, &uuid, x, y + 14.0, rgba(166, 166, 184, 200), true);
            }
            None => {
                let none = Text::translate("horizon.home.ely.none", &[]);
                batch.text_styled(atlas, &none, x, y, rgba(206, 206, 222, 230), true);
            }
        }
        let hover = ui::hovered(self.cursor, p.ely[0], p.ely[1], p.ely[2], p.ely[3]);
        let label = Text::translate(
            if self.home.account.is_some() {
                "horizon.home.ely.manage"
            } else {
                "horizon.home.ely.signin"
            },
            &[],
        );
        ui::button(
            batch, atlas, p.ely[0], p.ely[1], p.ely[2], p.ely[3], &label, true, hover,
        );
        // The account is the only way to get a nickname and a skin today: say
        // where the files live, so the menu is not a dead end offline.
        let hint = Text::translate("horizon.home.ely.hint", &[]);
        ui::centered_text(
            batch,
            atlas,
            &hint,
            x + 6.0,
            p.ely[1] + 28.0,
            w - 12.0,
            rgba(160, 160, 178, 200),
        );
    }
}
