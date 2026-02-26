use std::path::Path;
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use libcryptsetup_rs::{
    TokenInput,
    LibcryptErr,
    CryptLuks2TokenHandle,
    c_uint,
    consts::{flags::CryptActivate, flags::CryptVolumeKey, vals::EncryptionFormat},
    CryptInit,
};
use serde_json::json;

/// Formats a block device (or image) as LUKS2 and adds `key_data` to keyslot 0.
pub fn luks_format(dev: &Path, key_data: &[u8]) -> Result<c_uint, LibcryptErr> {
    let mut device = CryptInit::init(dev)?;
    device.context_handle().format::<()>(
        EncryptionFormat::Luks2,
        ("aes", "xts-plain"),
        None,
        libcryptsetup_rs::Either::Right(256 / 8),
        None,
    )?;

    let keyslot = device.keyslot_handle().add_by_key(
        None,
        None,
        key_data,
        CryptVolumeKey::empty(),
    )?;

    Ok(keyslot)
}

/// Opens a LUKS2 device with `final_key` and maps it as `/dev/mapper/<name>`.
pub fn luks_open(dev: &Path, final_key: &[u8], name: &str) -> Result<(), LibcryptErr> {
    let mut device = CryptInit::init(dev)?;
    device.context_handle().load::<()>(Some(EncryptionFormat::Luks2), None)?;

    device.activate_handle().activate_by_passphrase(
        Some(name),
        None,
        final_key,
        CryptActivate::empty(),
    )?;

    println!("[+] LUKS opened at /dev/mapper/{}", name);
    Ok(())
}

/// Writes salt, sealed-object public blob, and sealed-object private blob as
/// JSON tokens inside the LUKS2 header (slots 1, 2, 3).
pub fn luks2_store_tpm_tokens(
    dev: &Path,
    salt: &[u8],
    pub_bytes: &[u8],
    priv_bytes: &[u8],
) -> Result<(), LibcryptErr> {
    let mut device = CryptInit::init(dev)?;
    device.context_handle().load::<()>(Some(EncryptionFormat::Luks2), None)?;

    let tokens: [(u32, &str, &[u8]); 3] = [
        (1, "user.salt",     salt),
        (2, "user.obj_pub",  pub_bytes),
        (3, "user.obj_priv", priv_bytes),
    ];

    for (id, token_type, data) in tokens {
        let value = json!({
            "type":            token_type,
            "keyslots":        [],
            "key_description": BASE64.encode(data),
        });
        device.token_handle().json_set(TokenInput::ReplaceToken(id, &value))?;
    }

    Ok(())
}

/// Reads salt, sealed-object public blob, and sealed-object private blob from
/// the LUKS2 header tokens (slots 1, 2, 3).
pub fn luks2_load_tpm_tokens(
    dev: &Path,
) -> Result<(Vec<u8>, Vec<u8>, Vec<u8>), LibcryptErr> {
    let mut device = CryptInit::init(dev)?;
    device.context_handle().load::<()>(Some(EncryptionFormat::Luks2), None)?;

    let mut token = device.token_handle();

    let salt       = read_token(&mut token, 1)?;
    let pub_bytes  = read_token(&mut token, 2)?;
    let priv_bytes = read_token(&mut token, 3)?;

    Ok((salt, pub_bytes, priv_bytes))
}

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn read_token(token: &mut CryptLuks2TokenHandle, id: u32) -> Result<Vec<u8>, LibcryptErr> {
    let json = token.json_get(id)?;

    let encoded = json["key_description"]
        .as_str()
        .ok_or(LibcryptErr::Other("missing key_description".to_string()))?;

    BASE64.decode(encoded).map_err(|e| LibcryptErr::Other(e.to_string()))
}