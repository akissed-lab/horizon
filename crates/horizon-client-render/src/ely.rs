//! Ely.by sign-in for the iOS port: the authserver call that turns a nickname
//! and password into the account's UUID, and the skin the skinsystem serves
//! for a nickname. Both run off the game thread (they block on the network);
//! the access token stays in this process's memory and is never logged or
//! written anywhere, and the password is dropped as soon as the request ends.
use std::time::Duration;

/// Authlib's authenticate endpoint, as Ely.by mirrors it.
pub const AUTH_URL: &str = "https://authserver.ely.by/auth/authenticate";
/// The skin PNG and its metadata, by nickname.
pub const SKIN_URL: &str = "https://skinsystem.ely.by/skins/";
pub const TEXTURES_URL: &str = "https://skinsystem.ely.by/textures/";
/// A skin is 64x64 at most: anything much larger is not one.
const MAX_SKIN_BYTES: u64 = 512 * 1024;

/// A signed-in Ely.by account. The access token is private and hidden from
/// `Debug`; nothing serialises this type.
pub struct Account {
    pub name: String,
    pub uuid: u128,
    access_token: String,
}
impl Account {
    /// For tests and harnesses.
    pub fn new(name: &str, uuid: u128, access_token: &str) -> Self {
        Self {
            name: name.to_owned(),
            uuid,
            access_token: access_token.to_owned(),
        }
    }
    /// The bearer token for Ely.by's own services (unused by the game today).
    pub fn access_token(&self) -> &str {
        &self.access_token
    }
}
impl std::fmt::Debug for Account {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Account")
            .field("name", &self.name)
            .field("uuid", &format!("{:032x}", self.uuid))
            .field("access_token", &"<hidden>")
            .finish()
    }
}

/// Why signing in failed, in the terms the sign-in screen can explain.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Error {
    /// Wrong nickname or password (ForbiddenOperationException).
    Credentials,
    /// The account has two-factor auth on: the password field takes
    /// `password:token` instead.
    TwoFactor,
    /// Too many attempts (429, "Too many requests").
    RateLimited,
    /// No answer from Ely.by, or a 5xx.
    Unavailable,
    /// Anything else, with Ely.by's own message.
    Response(String),
}
impl Error {
    /// The language key for the sign-in screen's status line; `Response`
    /// carries the service's own text instead.
    pub fn message_key(&self) -> Option<&'static str> {
        match self {
            Self::Credentials => Some("horizon.ely.error.credentials"),
            Self::TwoFactor => Some("horizon.ely.error.twofactor"),
            Self::RateLimited => Some("horizon.ely.error.ratelimited"),
            Self::Unavailable => Some("horizon.ely.error.unavailable"),
            Self::Response(_) => None,
        }
    }
    /// The service's message, when it gave one.
    pub fn message(&self) -> Option<&str> {
        match self {
            Self::Response(message) => Some(message),
            _ => None,
        }
    }
}

/// A skin the skinsystem served, ready to be written as `horizon-skin.png`
/// (the local skin pipeline in the game processes it).
pub struct Skin {
    pub png: Vec<u8>,
    pub slim: bool,
}

fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout(Duration::from_secs(15))
        .user_agent(&format!("Horizon/{}", horizon_core::release::VERSION))
        .build()
}

/// A client token for the request: Ely.by only echoes it back, so any
/// unpredictable value will do.
fn client_token() -> String {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default();
    format!("{:016x}{:016x}", now.as_secs(), now.subsec_nanos())
}

/// Turn an authserver error response into [`Error`], like authlib's
/// AuthenticationException subclasses. "Account protected with two factor
/// auth." is Ely.by's own note.
fn from_response(status: u16, body: &str) -> Error {
    let v: serde_json::Value = serde_json::from_str(body).unwrap_or_default();
    let error = v.get("error").and_then(|e| e.as_str()).unwrap_or("");
    let message = v
        .get("errorMessage")
        .and_then(|m| m.as_str())
        .unwrap_or("")
        .to_owned();
    let lower = message.to_lowercase();
    if lower.contains("two factor") || lower.contains("two-factor") {
        return Error::TwoFactor;
    }
    if error == "ForbiddenOperationException" || status == 401 || status == 403 {
        return Error::Credentials;
    }
    if status == 429 || lower.contains("too many requests") {
        return Error::RateLimited;
    }
    if status >= 500 {
        return Error::Unavailable;
    }
    if message.is_empty() {
        Error::Response(format!("Status: {status}"))
    } else {
        Error::Response(message)
    }
}

/// Sign in to Ely.by with a nickname and password. Blocks: call it off the
/// game thread, and drop the password right after.
pub fn sign_in(nick: &str, password: &str) -> Result<Account, Error> {
    debug_assert!(!nick.is_empty());
    let body = serde_json::json!({
        "username": nick,
        "password": password,
        "clientToken": client_token(),
        "agent": { "name": "Minecraft", "version": 1 },
    })
    .to_string();
    let response = agent()
        .post(AUTH_URL)
        .set("Content-Type", "application/json; charset=utf-8")
        .send_string(&body);
    let text = match response {
        Ok(response) => response.into_string().unwrap_or_default(),
        Err(ureq::Error::Status(status, response)) => {
            return Err(from_response(
                status,
                &response.into_string().unwrap_or_default(),
            ));
        }
        Err(ureq::Error::Transport(_)) => return Err(Error::Unavailable),
    };
    let v: serde_json::Value =
        serde_json::from_str(&text).map_err(|_| Error::Response("invalid response".into()))?;
    let token = v
        .get("accessToken")
        .and_then(|t| t.as_str())
        .filter(|t| !t.is_empty())
        .ok_or(Error::Credentials)?;
    let profile = v.get("selectedProfile").ok_or(Error::Credentials)?;
    let name = profile
        .get("name")
        .and_then(|n| n.as_str())
        .filter(|n| !n.is_empty())
        .ok_or(Error::Credentials)?
        .to_owned();
    let uuid = profile
        .get("id")
        .and_then(|u| u.as_str())
        .and_then(crate::auth::parse_uuid)
        .ok_or(Error::Credentials)?;
    Ok(Account::new(&name, uuid, token))
}

/// The skin Ely.by serves for a nickname: `Ok(None)` when the account has
/// none (204/404). The PNG's size is checked here so the game's skin pipeline
/// only ever sees a real 64x64 or 64x32 skin.
pub fn fetch_skin(name: &str) -> Result<Option<Skin>, Error> {
    let Some(png) = fetch_bytes(&format!("{SKIN_URL}{name}.png"))? else {
        return Ok(None);
    };
    if !png.starts_with(b"\x89PNG\r\n\x1a\n") {
        return Err(Error::Response("the skin is not a PNG".into()));
    }
    let (w, h, _) = crate::hud::decode_bytes(&png)
        .map_err(|_| Error::Response("the skin is not a readable PNG".into()))?;
    if !(w == 64 && (h == 64 || h == 32)) {
        return Err(Error::Response(format!("the skin is {w}x{h}, not 64x64")));
    }
    let slim = fetch_textures(name).unwrap_or(None);
    Ok(Some(Skin {
        png,
        slim: slim.unwrap_or(false),
    }))
}

/// `SKIN.metadata.model == "slim"`; no textures document is the classic model.
fn fetch_textures(name: &str) -> Result<Option<bool>, Error> {
    let Some(body) = fetch_bytes(&format!("{TEXTURES_URL}{name}"))? else {
        return Ok(None);
    };
    let v: serde_json::Value = serde_json::from_slice(&body).unwrap_or_default();
    Ok(Some(
        v.pointer("/SKIN/metadata/model").and_then(|m| m.as_str()) == Some("slim"),
    ))
}

/// GET a small body; 204/404 is `Ok(None)`. A larger body than a skin could
/// be is refused instead of read.
fn fetch_bytes(url: &str) -> Result<Option<Vec<u8>>, Error> {
    use std::io::Read;
    match agent().get(url).call() {
        Ok(response) => {
            let mut body = Vec::new();
            response
                .into_reader()
                .take(MAX_SKIN_BYTES)
                .read_to_end(&mut body)
                .map_err(|_| Error::Unavailable)?;
            // The skinsystem answers 204 with an empty body for "no skin";
            // ureq reports that as a success, not a status error.
            Ok((!body.is_empty()).then_some(body))
        }
        Err(ureq::Error::Status(204 | 404, _)) => Ok(None),
        Err(ureq::Error::Status(status, response)) => Err(from_response(
            status,
            &response.into_string().unwrap_or_default(),
        )),
        Err(ureq::Error::Transport(_)) => Err(Error::Unavailable),
    }
}

#[cfg(test)]
mod tests {
    use super::{Error, from_response};

    #[test]
    fn errors_read_like_ely_by() {
        let e = |status, body| from_response(status, body);
        assert_eq!(
            e(
                403,
                r#"{"error":"ForbiddenOperationException","errorMessage":"Invalid credentials. Invalid username or password."}"#
            ),
            Error::Credentials
        );
        assert_eq!(
            e(
                403,
                r#"{"error":"ForbiddenOperationException","errorMessage":"Account protected with two factor auth."}"#
            ),
            Error::TwoFactor
        );
        assert_eq!(
            e(429, r#"{"errorMessage":"Too many requests"}"#),
            Error::RateLimited
        );
        assert_eq!(e(503, "down"), Error::Unavailable);
        assert_eq!(
            e(400, r#"{"errorMessage":"Bad request"}"#),
            Error::Response("Bad request".into())
        );
        assert_eq!(
            Error::Credentials.message_key(),
            Some("horizon.ely.error.credentials")
        );
        assert_eq!(Error::Response("x".into()).message(), Some("x"));
    }
}
