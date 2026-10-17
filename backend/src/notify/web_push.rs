use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use ring::rand::{SecureRandom, SystemRandom};
use ring::{aead, agreement, hkdf, signature};

const PUBLIC_KEY_LEN: usize = 65;
const PRIVATE_KEY_LEN: usize = 32;
const AUTH_LEN: usize = 16;
const SALT_LEN: usize = 16;
const KEY_LEN: usize = 16;
const NONCE_LEN: usize = 12;
const IKM_LEN: usize = 32;
const RECORD_SIZE: u32 = 4096;
const LAST_RECORD: u8 = 2;
const MAX_PAYLOAD_LEN: usize = 3000;
const JWT_TTL_SEC: i64 = 12 * 3600;
const PKCS8_LEN: usize = 138;
const PKCS8_PRIVATE_AT: usize = 36;
const PKCS8_PUBLIC_AT: usize = 73;

struct Len(usize);

impl hkdf::KeyType for Len
{
    fn len(&self) -> usize
    {
        self.0
    }
}

fn derive(a_salt: &[u8], a_ikm: &[u8], a_info: &[u8], a_len: usize) -> Result<Vec<u8>, String>
{
    let prk = hkdf::Salt::new(hkdf::HKDF_SHA256, a_salt).extract(a_ikm);
    let info = [a_info];
    let okm = prk
        .expand(&info, Len(a_len))
        .map_err(|_| "hkdf expand failed".to_string())?;
    let mut out = vec![0u8; a_len];
    okm.fill(&mut out).map_err(|_| "hkdf fill failed".to_string())?;
    Ok(out)
}

fn decode_key(a_value: &str, a_len: usize, a_name: &str) -> Result<Vec<u8>, String>
{
    let bytes = URL_SAFE_NO_PAD
        .decode(a_value.trim().trim_end_matches('='))
        .map_err(|_| format!("{a_name} must be base64url"))?;
    if bytes.len() != a_len
    {
        return Err(format!("{a_name} must be {a_len} bytes"));
    }
    Ok(bytes)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Subscription
{
    pub endpoint: String,
    pub p256dh: Vec<u8>,
    pub auth: Vec<u8>,
}

impl Subscription
{
    pub fn parse(a_endpoint: &str, a_p256dh: &str, a_auth: &str) -> Result<Self, String>
    {
        Ok(Self {
            endpoint: a_endpoint.to_string(),
            p256dh: decode_key(a_p256dh, PUBLIC_KEY_LEN, "p256dh")?,
            auth: decode_key(a_auth, AUTH_LEN, "auth")?,
        })
    }
}

pub struct VapidKeys
{
    pair: signature::EcdsaKeyPair,
    public: Vec<u8>,
    subject: String,
}

impl VapidKeys
{
    pub fn from_base64(a_public: &str, a_private: &str, a_subject: &str) -> Result<Self, String>
    {
        let public = decode_key(a_public, PUBLIC_KEY_LEN, "VAPID_PUBLIC_KEY")?;
        let private = decode_key(a_private, PRIVATE_KEY_LEN, "VAPID_PRIVATE_KEY")?;
        let pair = signature::EcdsaKeyPair::from_private_key_and_public_key(
            &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
            &private,
            &public,
            &SystemRandom::new(),
        )
        .map_err(|_| "VAPID_PRIVATE_KEY does not match VAPID_PUBLIC_KEY".to_string())?;
        let subject = a_subject.trim().to_string();
        if !(subject.starts_with("mailto:") || subject.starts_with("https://"))
        {
            return Err("VAPID_SUBJECT must start with mailto: or https://".into());
        }
        Ok(Self { pair, public, subject })
    }

    pub fn public_base64(&self) -> String
    {
        URL_SAFE_NO_PAD.encode(&self.public)
    }

    pub fn authorization(&self, a_endpoint: &str, a_now: i64) -> Result<String, String>
    {
        let url = reqwest::Url::parse(a_endpoint).map_err(|_| "bad endpoint".to_string())?;
        let audience = url.origin().ascii_serialization();
        let header = URL_SAFE_NO_PAD.encode(br#"{"typ":"JWT","alg":"ES256"}"#);
        let claims = serde_json::json!({ "aud": audience, "exp": a_now + JWT_TTL_SEC, "sub": self.subject });
        let body = URL_SAFE_NO_PAD.encode(claims.to_string());
        let signing_input = format!("{header}.{body}");
        let signed = self
            .pair
            .sign(&SystemRandom::new(), signing_input.as_bytes())
            .map_err(|_| "vapid signing failed".to_string())?;
        Ok(format!(
            "vapid t={signing_input}.{}, k={}",
            URL_SAFE_NO_PAD.encode(signed.as_ref()),
            self.public_base64()
        ))
    }
}

pub fn generate_vapid() -> Result<(String, String), String>
{
    let rng = SystemRandom::new();
    let pkcs8 = signature::EcdsaKeyPair::generate_pkcs8(&signature::ECDSA_P256_SHA256_FIXED_SIGNING, &rng)
        .map_err(|_| "key generation failed".to_string())?;
    let bytes = pkcs8.as_ref();
    if bytes.len() != PKCS8_LEN
    {
        return Err("unexpected key format".into());
    }
    let private = &bytes[PKCS8_PRIVATE_AT..PKCS8_PRIVATE_AT + PRIVATE_KEY_LEN];
    let public = &bytes[PKCS8_PUBLIC_AT..PKCS8_PUBLIC_AT + PUBLIC_KEY_LEN];
    signature::EcdsaKeyPair::from_private_key_and_public_key(
        &signature::ECDSA_P256_SHA256_FIXED_SIGNING,
        private,
        public,
        &rng,
    )
    .map_err(|_| "generated key does not verify".to_string())?;
    Ok((URL_SAFE_NO_PAD.encode(public), URL_SAFE_NO_PAD.encode(private)))
}

pub fn encrypt(a_payload: &[u8], a_subscription: &Subscription) -> Result<Vec<u8>, String>
{
    if a_payload.len() > MAX_PAYLOAD_LEN
    {
        return Err("payload too large".into());
    }
    let rng = SystemRandom::new();
    let local = agreement::EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng)
        .map_err(|_| "ephemeral key failed".to_string())?;
    let local_public = local
        .compute_public_key()
        .map_err(|_| "ephemeral public key failed".to_string())?
        .as_ref()
        .to_vec();
    let peer = agreement::UnparsedPublicKey::new(&agreement::ECDH_P256, &a_subscription.p256dh);
    let shared = agreement::agree_ephemeral(local, &peer, |secret| secret.to_vec())
        .map_err(|_| "subscription key rejected".to_string())?;

    let mut salt = [0u8; SALT_LEN];
    rng.fill(&mut salt).map_err(|_| "random failed".to_string())?;
    let (key, nonce) = content_keys(
        &shared,
        &a_subscription.auth,
        &a_subscription.p256dh,
        &local_public,
        &salt,
    )?;

    let mut record = a_payload.to_vec();
    record.push(LAST_RECORD);
    let sealing = aead::LessSafeKey::new(
        aead::UnboundKey::new(&aead::AES_128_GCM, &key).map_err(|_| "content key failed".to_string())?,
    );
    let nonce = aead::Nonce::try_assume_unique_for_key(&nonce).map_err(|_| "nonce failed".to_string())?;
    sealing
        .seal_in_place_append_tag(nonce, aead::Aad::empty(), &mut record)
        .map_err(|_| "encryption failed".to_string())?;

    let mut body = Vec::with_capacity(SALT_LEN + 5 + PUBLIC_KEY_LEN + record.len());
    body.extend_from_slice(&salt);
    body.extend_from_slice(&RECORD_SIZE.to_be_bytes());
    body.push(u8::try_from(local_public.len()).map_err(|_| "key too long".to_string())?);
    body.extend_from_slice(&local_public);
    body.extend_from_slice(&record);
    Ok(body)
}

fn content_keys(
    a_shared: &[u8],
    a_auth: &[u8],
    a_receiver_public: &[u8],
    a_sender_public: &[u8],
    a_salt: &[u8],
) -> Result<(Vec<u8>, Vec<u8>), String>
{
    let mut key_info = b"WebPush: info\0".to_vec();
    key_info.extend_from_slice(a_receiver_public);
    key_info.extend_from_slice(a_sender_public);
    let ikm = derive(a_auth, a_shared, &key_info, IKM_LEN)?;
    let key = derive(a_salt, &ikm, b"Content-Encoding: aes128gcm\0", KEY_LEN)?;
    let nonce = derive(a_salt, &ikm, b"Content-Encoding: nonce\0", NONCE_LEN)?;
    Ok((key, nonce))
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn open(
        a_body: &[u8],
        a_receiver: agreement::EphemeralPrivateKey,
        a_receiver_public: &[u8],
        a_auth: &[u8],
    ) -> Vec<u8>
    {
        let salt = &a_body[..SALT_LEN];
        let key_len = usize::from(a_body[SALT_LEN + 4]);
        let sender_public = &a_body[SALT_LEN + 5..SALT_LEN + 5 + key_len];
        let mut record = a_body[SALT_LEN + 5 + key_len..].to_vec();
        let peer = agreement::UnparsedPublicKey::new(&agreement::ECDH_P256, sender_public);
        let shared = agreement::agree_ephemeral(a_receiver, &peer, |secret| secret.to_vec()).unwrap();
        let (key, nonce) = content_keys(&shared, a_auth, a_receiver_public, sender_public, salt).unwrap();
        let opening = aead::LessSafeKey::new(aead::UnboundKey::new(&aead::AES_128_GCM, &key).unwrap());
        let plain = opening
            .open_in_place(
                aead::Nonce::try_assume_unique_for_key(&nonce).unwrap(),
                aead::Aad::empty(),
                &mut record,
            )
            .unwrap()
            .to_vec();
        assert_eq!(plain.last(), Some(&LAST_RECORD));
        plain[..plain.len() - 1].to_vec()
    }

    #[test]
    fn payload_round_trips_through_the_browser_keys()
    {
        let rng = SystemRandom::new();
        let receiver = agreement::EphemeralPrivateKey::generate(&agreement::ECDH_P256, &rng).unwrap();
        let receiver_public = receiver.compute_public_key().unwrap().as_ref().to_vec();
        let auth = [7u8; AUTH_LEN];
        let subscription = Subscription::parse(
            "https://fcm.googleapis.com/fcm/send/abc",
            &URL_SAFE_NO_PAD.encode(&receiver_public),
            &URL_SAFE_NO_PAD.encode(auth),
        )
        .unwrap();
        let payload = r#"{"title":"Молоко"}"#.as_bytes();
        let body = encrypt(payload, &subscription).unwrap();
        assert_eq!(&body[SALT_LEN..SALT_LEN + 4], &RECORD_SIZE.to_be_bytes());
        assert_eq!(open(&body, receiver, &receiver_public, &auth), payload.to_vec());
    }

    #[test]
    fn vapid_keys_sign_a_verifiable_token()
    {
        let (public, private) = generate_vapid().unwrap();
        let keys = VapidKeys::from_base64(&public, &private, "mailto:admin@example.com").unwrap();
        let header = keys
            .authorization("https://fcm.googleapis.com/fcm/send/abc", 1_700_000_000)
            .unwrap();
        let token = header
            .strip_prefix("vapid t=")
            .and_then(|rest| rest.split(", k=").next())
            .unwrap();
        let (signing_input, signature_b64) = token.rsplit_once('.').unwrap();
        let claims: serde_json::Value = serde_json::from_slice(
            &URL_SAFE_NO_PAD
                .decode(signing_input.split('.').nth(1).unwrap())
                .unwrap(),
        )
        .unwrap();
        assert_eq!(claims["aud"], "https://fcm.googleapis.com");
        assert_eq!(claims["sub"], "mailto:admin@example.com");
        let verifier = signature::UnparsedPublicKey::new(
            &signature::ECDSA_P256_SHA256_FIXED,
            URL_SAFE_NO_PAD.decode(&public).unwrap(),
        );
        verifier
            .verify(
                signing_input.as_bytes(),
                &URL_SAFE_NO_PAD.decode(signature_b64).unwrap(),
            )
            .unwrap();
        assert!(header.ends_with(&format!("k={public}")));
    }

    #[test]
    fn mismatched_or_malformed_keys_are_rejected()
    {
        let (public, _) = generate_vapid().unwrap();
        let (_, other_private) = generate_vapid().unwrap();
        assert!(VapidKeys::from_base64(&public, &other_private, "mailto:a@b.c").is_err());
        assert!(VapidKeys::from_base64("short", &other_private, "mailto:a@b.c").is_err());
        let (public, private) = generate_vapid().unwrap();
        assert!(VapidKeys::from_base64(&public, &private, "admin@example.com").is_err());
        assert!(Subscription::parse("https://x", "AAAA", "AAAA").is_err());
    }
}
