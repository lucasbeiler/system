mod luks;
mod tpm;

use argon2::Argon2;
use base64::{Engine, engine::general_purpose::STANDARD as BASE64};
use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::{
    io::{self, Write},
    path::PathBuf,
};
use tss_esapi::traits::Marshall;

type HmacSha256 = Hmac<Sha256>;

// ---------------------------------------------------------------------------
// Crypto helpers
// ---------------------------------------------------------------------------

/// Derives a 64-byte key from `password` + `salt` using Argon2.
/// The caller splits the output into two 32-byte halves:
///   - slice_a: HMAC key used to derive the final LUKS passphrase
///   - slice_b: TPM auth (PIN) that protects the sealed object
fn derive_key(password: &str, salt: &[u8]) -> Vec<u8> {
    let argon2 = Argon2::default();
    let mut output = [0u8; 64];
    argon2
        .hash_password_into(password.as_bytes(), salt, &mut output)
        .expect("Argon2 hashing failed");
    output.to_vec()
}

/// Computes HMAC-SHA-256 of `data` under `key`.
fn compute_hmac(key: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(key).expect("HMAC key error");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

// ---------------------------------------------------------------------------
// High-level workflows
// ---------------------------------------------------------------------------

/// First-run setup:
///   1. Creates a TPM primary key and generates fresh entropy.
///   2. Derives slice_a / slice_b from the password.
///   3. Generates a random secret and seals it into the TPM (auth = slice_b).
///   4. Derives the LUKS key as HMAC(slice_a, secret).
///   5. Formats the LUKS image and stores the TPM tokens in its header.
fn setup(password: &str, device: &str) -> Result<(), Box<dyn std::error::Error>> {
    let (mut ctx, primary_handle) = tpm::create_primary()?;

    let salt = tpm::tpm_random_bytes(&mut ctx, 64)?;
    let kdf_output = derive_key(password, &salt);
    let (slice_a, slice_b) = kdf_output.split_at(32);

    let secret = tpm::tpm_random_bytes(&mut ctx, 64)?;
    let final_key = compute_hmac(slice_a, &secret);

    // println!("[+] Slice A:          {}", hex::encode(slice_a));
    // println!("[+] Slice B:          {}", hex::encode(slice_b));
    // println!("[+] Secret (base64):  {}", BASE64.encode(&secret));

    let (sealed_pub, sealed_priv) =
        tpm::seal_secret(&mut ctx, primary_handle, &secret, slice_b)?;

    let device_path = PathBuf::from(device);
    luks::luks_format(&device_path, &final_key).map_err(|e| e.to_string())?;
    luks::luks2_store_tpm_tokens(
        &device_path,
        &salt,
        &sealed_pub.marshall()?,
        sealed_priv.as_ref(),
    )?;

    // println!("[+] Final key (hex):  {}", hex::encode(&final_key));
    // println!("[+] Setup complete. Tokens written to LUKS header.");
    Ok(())
}

/// Unlock:
///   1. Reads salt + TPM blobs from the LUKS header.
///   2. Re-derives slice_a / slice_b from the password (entered by user) + stored salt.
///   3. Unseals the secret from the TPM (auth = slice_b).
///   4. Re-derives the LUKS key as HMAC(slice_a, secret).
///   5. Opens the LUKS device.
fn unlock(password: &str, device: &str) -> Result<Vec<u8>, Box<dyn std::error::Error>> {
    let device_path = PathBuf::from(device);

    let (salt, pub_bytes, priv_bytes) = luks::luks2_load_tpm_tokens(&device_path)?;

    let kdf_output = derive_key(password, &salt);
    let (slice_a, slice_b) = kdf_output.split_at(32);

    let (mut ctx, primary_handle) = tpm::create_primary()?;
    let secret =
        tpm::unseal_secret(&mut ctx, primary_handle, &pub_bytes, &priv_bytes, slice_b)?;

    // println!("[+] Slice A:          {}", hex::encode(slice_a));
    // println!("[+] Slice B:          {}", hex::encode(slice_b));
    // println!("[+] Secret (base64):  {}", BASE64.encode(&secret));

    let final_key = compute_hmac(slice_a, &secret);

    luks::luks_open(&device_path, &final_key, "data")
        .map_err(|e| e.to_string())?;

    println!("[+] Unlock complete.");
    Ok(final_key)
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn read_password() -> Result<String, Box<dyn std::error::Error>> {
    let password = rpassword::prompt_password("Enter passphrase: ")?;
    Ok(password.trim().to_string())
}

fn usage(program: &str) {
    eprintln!("Usage: {} <setup|unlock> <device>", program);
    eprintln!();
    eprintln!("  setup   Format the LUKS image and seal a new secret into the TPM");
    eprintln!("  unlock  Unseal the secret from the TPM and open the LUKS device");
}

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let args: Vec<String> = std::env::args().collect();

    if args.len() != 3 {
        usage(&args[0]);
        std::process::exit(1);
    }

    match args[1].as_str() {
        "setup" => {
            let password = read_password()?;
            setup(&password, &args[2])?;
        }
        "unlock" => {
            let password = read_password()?;
            unlock(&password, &args[2])?;
        }
        other => {
            eprintln!("[!] Unknown action: '{}'", other);
            usage(&args[0]);
            std::process::exit(1);
        }
    }

    Ok(())
}