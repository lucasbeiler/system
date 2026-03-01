use std::convert::TryFrom;
use tss_esapi::{
    Context,
    TctiNameConf,
    interface_types::{
        algorithm::{HashingAlgorithm, PublicAlgorithm},
        key_bits::RsaKeyBits,
        resource_handles::Hierarchy,
    },
    structures::{
        Digest,
        Auth,
        PublicBuilder,
        SensitiveData,
        PublicRsaParametersBuilder,
        RsaExponent,
        RsaScheme,
        SymmetricDefinitionObject,
        Private,
        Public,
    },
    handles::KeyHandle,
    traits::{UnMarshall},
    tcti_ldr::DeviceConfig,
    attributes::ObjectAttributesBuilder,
};

/// Builds a storage-parent public template: RSA-2048, AES-128-CFB, SHA-256.
/// Mirrors: tpm2_createprimary -C o -g sha256
fn build_primary_template() -> tss_esapi::structures::Public {
    let attrs = ObjectAttributesBuilder::new()
        .with_fixed_tpm(true)
        .with_fixed_parent(true)
        .with_sensitive_data_origin(true)
        .with_user_with_auth(true)
        .with_restricted(true)
        .with_decrypt(true)
        .build()
        .expect("valid object attributes");

    let rsa_params = PublicRsaParametersBuilder::new()
        .with_symmetric(SymmetricDefinitionObject::AES_128_CFB)
        .with_scheme(RsaScheme::Null)
        .with_key_bits(RsaKeyBits::Rsa2048)
        .with_exponent(RsaExponent::default())
        .with_is_decryption_key(true)
        .with_is_signing_key(false)
        .with_restricted(true)
        .build()
        .expect("valid RSA parameters");

    PublicBuilder::new()
        .with_public_algorithm(PublicAlgorithm::Rsa)
        .with_name_hashing_algorithm(HashingAlgorithm::Sha256)
        .with_object_attributes(attrs)
        .with_rsa_parameters(rsa_params)
        .with_rsa_unique_identifier(Default::default())
        .build()
        .expect("valid public template")
}

/// Public template for a sealed-data object.
fn build_sealed_template() -> Result<tss_esapi::structures::Public, tss_esapi::Error> {
    let attrs = ObjectAttributesBuilder::new()
        .with_fixed_tpm(true)
        .with_fixed_parent(true)
        .with_no_da(false) // false = dictionary attack protections APPLY
        .with_user_with_auth(true)
        .build()
        .map_err(|e| {
            eprintln!("[!] sealed attrs failed: {:?}", e);
            e
        })?;

    PublicBuilder::new()
        .with_public_algorithm(PublicAlgorithm::KeyedHash)
        .with_name_hashing_algorithm(HashingAlgorithm::Sha256)
        .with_object_attributes(attrs)
        .with_auth_policy(Digest::default())
        .with_keyed_hash_parameters(tss_esapi::structures::PublicKeyedHashParameters::new(
            tss_esapi::structures::KeyedHashScheme::Null,
        ))
        .with_keyed_hash_unique_identifier(Default::default())
        .build()
        .map_err(|e| {
            eprintln!("[!] sealed PublicBuilder failed: {:?}", e);
            e
        })
}

/// Initialises a TPM context and creates a primary storage key under the Owner hierarchy.
/// Returns both the context (must stay alive) and the primary key handle.
pub fn create_primary() -> Result<(Context, KeyHandle), tss_esapi::Error> {
    let tcti = TctiNameConf::from_environment_variable()
        .unwrap_or_else(|_| {
            TctiNameConf::Device(DeviceConfig::default()) // /dev/tpmrm0
        });
    let mut ctx = Context::new(tcti)?;

    let template = build_primary_template();
    // println!("[+] Template built OK");

    let primary = ctx.execute_with_nullauth_session(|ctx: &mut Context| {
        ctx.create_primary(Hierarchy::Owner, template, None, None, None, None)
    })?;

    // println!("[+] Primary key created (handle: {:?})", primary.key_handle);
    Ok((ctx, primary.key_handle))
}

/// Generates cryptographically secure random bytes using the TPM's hardware RNG.
/// Mirrors: tpm2_getrandom
pub fn tpm_random_bytes(ctx: &mut Context, len: usize) -> Result<Vec<u8>, tss_esapi::Error> {
    let bytes =
        ctx.execute_with_nullauth_session(|ctx: &mut Context| ctx.get_random(len))?;
    Ok(bytes.to_vec())
}

/// Seals `secret` into the TPM under `primary_handle`, protected by `pin` as auth.
/// Mirrors: tpm2_create -C primary.ctx -g sha256 -i secret.bin -p "hex:..."
/// Returns (pub_data, priv_data), analogous to obj.pub + obj.priv.
pub fn seal_secret(
    ctx: &mut Context,
    primary_handle: KeyHandle,
    secret: &[u8],
    pin: &[u8],
) -> Result<(Public, Private), tss_esapi::Error> {
    let auth = Auth::try_from(pin)?;
    let sensitive = SensitiveData::try_from(secret)?;
    let sealed_template = build_sealed_template()?;

    let (sealed_pub, sealed_priv) =
        ctx.execute_with_nullauth_session(|ctx: &mut Context| {
            ctx.create(
                primary_handle,
                sealed_template,
                Some(auth),
                Some(sensitive),
                None,
                None,
            )
        })
        .map(|r| (r.out_public, r.out_private))?;

    println!("[+] Secret sealed into TPM");
    Ok((sealed_pub, sealed_priv))
}

/// Unseals the secret from the TPM, authenticating with `pin`.
/// A wrong PIN burns one of the daily dictionary-lockout attempts.
/// Mirrors: tpm2_unseal -c sealed.ctx -p "hex:..."
pub fn unseal_secret(
    ctx: &mut Context,
    primary_handle: KeyHandle,
    pub_bytes: &[u8],
    priv_bytes: &[u8],
    pin: &[u8],
) -> Result<Vec<u8>, tss_esapi::Error> {
    let sealed_pub = Public::unmarshall(pub_bytes)?;
    let sealed_priv = Private::try_from(priv_bytes.to_vec())?;

    let sealed_handle = ctx.execute_with_nullauth_session(|ctx: &mut Context| {
        ctx.load(primary_handle, sealed_priv, sealed_pub)
    })?;

    let auth = Auth::try_from(pin.to_vec())?;
    ctx.tr_set_auth(sealed_handle.into(), auth)?;

    let secret = ctx.execute_with_nullauth_session(|ctx: &mut Context| {
        ctx.unseal(sealed_handle.into())
    })?;

    println!("[+] Secret unsealed successfully");
    Ok(secret.to_vec())
}