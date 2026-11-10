//! The Aksi menu: the branded settings panel the iOS port opens from the
//! pause screen. One place for the accent colour and the memory presets, plus
//! doors to the graphics options and (later) the Ely.by sign-in.
use super::{Game, Screen};
use horizon_client::{
    Result,
    extras::{ACCENTS, MEMORY},
    hud::{HudAtlas, HudBatch, rgba},
    options_ui::Page,
    settings::Settings,
    text::Text,
    ui,
};

/// What the Aksi screen remembers: where the graphics options go back to.
pub(super) struct AksiMenu {
    /// The graphics options were opened from here, so they close back to Aksi
    /// rather than the pause menu.
    pub options_return: bool,
}
impl Default for AksiMenu {
    fn default() -> Self {
        Self {
            options_return: false,
        }
    }
}

/// The screen's rectangles in GUI pixels, sized from the batch.
struct Layout {
    panel: [f32; 4],
    swatches: [[f32; 4]; ACCENTS.len()],
    presets: [[f32; 4]; MEMORY.len()],
    ely: [f32; 4],
    graphics: [f32; 4],
    done: [f32; 4],
}

fn layout(w: f32, h: f32) -> Layout {
    let pw = (w * 0.62).clamp(240.0, 420.0);
    let ph = (h * 0.72).clamp(172.0, 210.0);
    let x = ((w - pw) / 2.0).floor();
    let y = ((h - ph) / 2.0).floor();
    let pad = 12.0;
    let inner = pw - pad * 2.0;

    // Accent swatches: 16 px squares, 6 px apart, centred.
    let side = 16.0;
    let gap = 6.0;
    let total = ACCENTS.len() as f32 * side + (ACCENTS.len() as f32 - 1.0) * gap;
    let swatch_x = x + ((pw - total) / 2.0).floor();
    let swatch_y = y + 41.0;
    let mut swatches = [[0.0; 4]; ACCENTS.len()];
    for (i, r) in swatches.iter_mut().enumerate() {
        *r = [swatch_x + i as f32 * (side + gap), swatch_y, side, side];
    }

    // Memory presets: three equal buttons.
    let bgap = 4.0;
    let bw = (inner - bgap * 2.0) / MEMORY.len() as f32;
    let by = y + 74.0;
    let mut presets = [[0.0; 4]; MEMORY.len()];
    for (i, r) in presets.iter_mut().enumerate() {
        *r = [x + pad + i as f32 * (bw + bgap), by, bw, 18.0];
    }

    let bottom = y + ph - 28.0;
    let half = (inner - 6.0) / 2.0;
    Layout {
        panel: [x, y, pw, ph],
        swatches,
        presets,
        ely: [x + pad, y + ph - 52.0, inner, 18.0],
        graphics: [x + pad, bottom, half, 20.0],
        done: [x + pad + half + 6.0, bottom, half, 20.0],
    }
}

pub(super) fn accent(index: u8) -> (u8, u8, u8) {
    let (rgb, _) = ACCENTS[(index as usize).min(ACCENTS.len() - 1)];
    (
        ((rgb >> 16) & 0xff) as u8,
        ((rgb >> 8) & 0xff) as u8,
        (rgb & 0xff) as u8,
    )
}
pub(super) fn accent_solid(index: u8) -> u32 {
    let (r, g, b) = accent(index);
    rgba(r, g, b, 255)
}
pub(super) fn accent_soft(index: u8, alpha: u8) -> u32 {
    let (r, g, b) = accent(index);
    rgba(r, g, b, alpha)
}

/// A one-colour frame around `r`, `t` GUI pixels thick.
pub(super) fn outline(batch: &mut HudBatch, atlas: &HudAtlas, r: [f32; 4], t: f32, color: u32) {
    let [x, y, w, h] = r;
    batch.fill(atlas, x - t, y - t, w + t * 2.0, t, color);
    batch.fill(atlas, x - t, y + h, w + t * 2.0, t, color);
    batch.fill(atlas, x - t, y, t, h, color);
    batch.fill(atlas, x + w, y, t, h, color);
}

/// The pause menu's Aksi pill, in the top-left corner. Android's profile
/// button owns (12, 12) there, so the pill sits below it on Android.
pub(super) fn pill_rect() -> [f32; 4] {
    let y = if cfg!(target_os = "android") {
        30.0
    } else {
        10.0
    };
    [10.0, y, 52.0, 18.0]
}

/// Draws the pill: a dark translucent chip with the accent around it, so the
/// brand reads from the pause menu before the Aksi screen opens.
pub(super) fn draw_pill(
    batch: &mut HudBatch,
    atlas: &HudAtlas,
    cursor: (f32, f32),
    accent_index: u8,
) {
    let [x, y, w, h] = pill_rect();
    let hover = ui::hovered(cursor, x, y, w, h);
    let color = accent_solid(accent_index);
    let bg = if hover {
        accent_soft(accent_index, 70)
    } else {
        rgba(10, 9, 16, 170)
    };
    batch.fill(atlas, x, y, w, h, bg);
    outline(batch, atlas, [x, y, w, h], 1.0, color);
    let label = Text::translate("horizon.aksi.title", &[]);
    let tw = atlas.font.width_text(&label);
    batch.text_styled(
        atlas,
        &label,
        x + ((w - tw) / 2.0).floor(),
        y + 5.0,
        color,
        true,
    );
}

/// The preset whose values the settings already have, if any.
pub(super) fn active_preset(settings: &Settings) -> Option<usize> {
    MEMORY.iter().position(|p| {
        settings.render_distance == p.render_distance
            && settings.simulation_distance == p.simulation_distance
            && settings.max_fps == p.max_fps
            && (settings.entity_distance - p.entity_distance).abs() < 0.01
            && settings.particles == p.particles
    })
}

impl Game<'_> {
    pub(super) fn open_aksi(&mut self) {
        // The screen shows over the paused world.
        self.screen = Screen::Aksi;
        self.capture(false);
    }

    pub(super) fn close_aksi(&mut self) {
        self.screen = Screen::Paused;
        self.aksi.options_return = false;
    }

    pub(super) fn aksi_click(&mut self) -> Result<()> {
        let (w, h) = self.gui_size();
        let p = layout(w, h);
        let cursor = self.cursor;
        if let Some(i) = p
            .swatches
            .iter()
            .position(|r| ui::hovered(cursor, r[0], r[1], r[2], r[3]))
        {
            self.settings.extras.accent = i as u8;
            self.settings.save(&Self::options_path());
            self.audio.play_button_click();
            return Ok(());
        }
        if let Some(i) = p
            .presets
            .iter()
            .position(|r| ui::hovered(cursor, r[0], r[1], r[2], r[3]))
        {
            self.apply_memory_preset(i);
            self.audio.play_button_click();
            return Ok(());
        }
        if ui::hovered(
            cursor,
            p.graphics[0],
            p.graphics[1],
            p.graphics[2],
            p.graphics[3],
        ) {
            self.aksi.options_return = true;
            self.open_options_at(false, Page::Graphics);
            self.audio.play_button_click();
            return Ok(());
        }
        if ui::hovered(cursor, p.ely[0], p.ely[1], p.ely[2], p.ely[3]) {
            self.open_ely(false);
            self.audio.play_button_click();
            return Ok(());
        }
        if ui::hovered(cursor, p.done[0], p.done[1], p.done[2], p.done[3]) {
            self.close_aksi();
            self.audio.play_button_click();
        }
        Ok(())
    }

    /// Sets the settings a memory preset names, saves them and applies them.
    pub(super) fn apply_memory_preset(&mut self, index: usize) {
        let Some(p) = MEMORY.get(index).copied() else {
            return;
        };
        self.settings.render_distance = p.render_distance;
        self.settings.simulation_distance = p.simulation_distance;
        self.settings.max_fps = p.max_fps;
        self.settings.entity_distance = p.entity_distance;
        self.settings.particles = p.particles;
        self.settings.save(&Self::options_path());
        self.apply_settings();
        log::info!(
            "Horizon: memory preset {}: render distance {}, simulation {}, {} FPS",
            p.label,
            p.render_distance,
            p.simulation_distance,
            p.max_fps
        );
    }

    pub(super) fn draw_aksi(&mut self, batch: &mut HudBatch) {
        // The Ely.by button shows the account Home cached.
        self.home.refresh();
        let atlas = &self.gui.atlas;
        let (w, h) = (batch.width, batch.height);
        let p = layout(w, h);
        let accent_index = self.settings.extras.accent;
        let accent_color = accent_solid(accent_index);
        let [x, y, pw, ph] = p.panel;

        // The same in-world dim the pause menu uses, so the glass panel sits on
        // the blurred world instead of over a bright one.
        ui::menu_background(batch, atlas, 0.0, 0.0, w, h, true);

        // A translucent panel over the blurred world: the glass look without a
        // second shader.
        batch.fill(
            atlas,
            x - 2.0,
            y - 2.0,
            pw + 4.0,
            ph + 4.0,
            rgba(0, 0, 0, 90),
        );
        batch.fill(atlas, x, y, pw, ph, rgba(20, 18, 30, 200));
        outline(batch, atlas, p.panel, 1.0, rgba(255, 255, 255, 36));
        // The accent line along the top edge.
        batch.fill(atlas, x, y, pw, 2.0, accent_color);

        let title = Text::translate("horizon.aksi.title", &[]);
        ui::text_scaled(batch, atlas, &title, x + 12.0, y + 8.0, 1.5, accent_color);
        let sub = Text::literal("Horizon");
        let sub_w = atlas.font.width_text(&sub);
        batch.text_styled(
            atlas,
            &sub,
            x + pw - 12.0 - sub_w,
            y + 12.0,
            rgba(200, 200, 214, 180),
            true,
        );

        let color_label = Text::translate("horizon.aksi.color", &[]);
        batch.text_styled(
            atlas,
            &color_label,
            x + 12.0,
            y + 30.0,
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

        let memory_label = Text::translate("horizon.aksi.memory", &[]);
        batch.text_styled(
            atlas,
            &memory_label,
            x + 12.0,
            y + 64.0,
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

        // RAM and the render distance it pays for.
        let kb = horizon_client::settings::physical_memory_kb();
        let ram = if kb == 0 {
            "—".to_owned()
        } else {
            format!("{:.1}", kb as f64 / (1024.0 * 1024.0))
        };
        let info = Text::translate(
            "horizon.aksi.info",
            &[
                Text::literal(ram),
                Text::literal(self.settings.render_distance.to_string()),
            ],
        );
        ui::centered_text(
            batch,
            atlas,
            &info,
            x + 8.0,
            y + 99.0,
            pw - 16.0,
            rgba(196, 196, 210, 255),
        );
        if ph >= 200.0 {
            let hint = Text::translate("horizon.aksi.hint", &[]);
            ui::centered_text(
                batch,
                atlas,
                &hint,
                x + 8.0,
                y + 111.0,
                pw - 16.0,
                rgba(150, 150, 166, 255),
            );
        }

        // The Ely.by door: it shows the account Home cached.
        let ely_label = match &self.home.account {
            Some(account) => Text::translate(
                "horizon.aksi.ely.signed",
                &[Text::literal(account.name.clone())],
            ),
            None => Text::translate("horizon.aksi.ely", &[]),
        };
        let ely_hover = ui::hovered(self.cursor, p.ely[0], p.ely[1], p.ely[2], p.ely[3]);
        ui::button(
            batch, atlas, p.ely[0], p.ely[1], p.ely[2], p.ely[3], &ely_label, true, ely_hover,
        );

        let graphics_hover = ui::hovered(
            self.cursor,
            p.graphics[0],
            p.graphics[1],
            p.graphics[2],
            p.graphics[3],
        );
        ui::button(
            batch,
            atlas,
            p.graphics[0],
            p.graphics[1],
            p.graphics[2],
            p.graphics[3],
            &Text::translate("horizon.aksi.graphics", &[]),
            true,
            graphics_hover,
        );
        let done_hover = ui::hovered(self.cursor, p.done[0], p.done[1], p.done[2], p.done[3]);
        // The Done button carries the accent colour, so the brand reads even
        // from the pause menu.
        outline(batch, atlas, p.done, 2.0, accent_soft(accent_index, 180));
        ui::button(
            batch,
            atlas,
            p.done[0],
            p.done[1],
            p.done[2],
            p.done[3],
            &Text::translate("horizon.aksi.done", &[]),
            true,
            done_hover,
        );
    }
}
