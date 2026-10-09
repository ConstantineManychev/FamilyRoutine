use aes_gcm::aead::{Aead, KeyInit, OsRng, Payload};
use aes_gcm::{AeadCore, Aes256Gcm, Key, Nonce};
use uuid::Uuid;

use crate::domain::errors::ApiError;

const FORMAT_VERSION: u8 = 1;
const NONCE_LEN: usize = 12;

pub struct SecretBox
{
    cipher: Aes256Gcm,
}

impl SecretBox
{
    pub fn new(a_key: &[u8; 32]) -> Self
    {
        Self {
            cipher: Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(a_key)),
        }
    }

    pub fn seal(&self, a_plain: &[u8], a_aad: &[u8]) -> Result<Vec<u8>, ApiError>
    {
        let nonce = Aes256Gcm::generate_nonce(&mut OsRng);
        let ciphertext = self
            .cipher
            .encrypt(
                &nonce,
                Payload {
                    msg: a_plain,
                    aad: a_aad,
                },
            )
            .map_err(|_| ApiError::internal("secret encryption failed"))?;

        let mut sealed = Vec::with_capacity(1 + NONCE_LEN + ciphertext.len());
        sealed.push(FORMAT_VERSION);
        sealed.extend_from_slice(&nonce);
        sealed.extend_from_slice(&ciphertext);
        Ok(sealed)
    }

    pub fn open(&self, a_sealed: &[u8], a_aad: &[u8]) -> Result<Vec<u8>, ApiError>
    {
        if a_sealed.len() <= 1 + NONCE_LEN || a_sealed[0] != FORMAT_VERSION
        {
            return Err(ApiError::internal("sealed secret has unknown format"));
        }

        let (nonce, ciphertext) = a_sealed[1..].split_at(NONCE_LEN);

        self.cipher
            .decrypt(
                Nonce::from_slice(nonce),
                Payload {
                    msg: ciphertext,
                    aad: a_aad,
                },
            )
            .map_err(|_| ApiError::internal("secret decryption failed"))
    }
}

pub fn account_token_aad(a_account_id: Uuid) -> Vec<u8>
{
    let mut aad = b"family-routine/account-sync-token/v1/".to_vec();
    aad.extend_from_slice(a_account_id.as_bytes());
    aad
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn sealed_secret_round_trips_and_hides_plaintext()
    {
        let secret_box = SecretBox::new(&[7u8; 32]);
        let aad = account_token_aad(Uuid::new_v4());
        let sealed = secret_box.seal(b"monobank-token-value", &aad).unwrap();

        assert!(!sealed.windows(8).any(|window| window == b"monobank"));
        assert_eq!(secret_box.open(&sealed, &aad).unwrap(), b"monobank-token-value");
    }

    #[test]
    fn sealed_secret_is_bound_to_its_account()
    {
        let secret_box = SecretBox::new(&[7u8; 32]);
        let sealed = secret_box.seal(b"token", &account_token_aad(Uuid::new_v4())).unwrap();

        assert!(secret_box.open(&sealed, &account_token_aad(Uuid::new_v4())).is_err());
    }

    #[test]
    fn sealed_secret_requires_the_same_key()
    {
        let aad = account_token_aad(Uuid::new_v4());
        let sealed = SecretBox::new(&[7u8; 32]).seal(b"token", &aad).unwrap();

        assert!(SecretBox::new(&[8u8; 32]).open(&sealed, &aad).is_err());
    }

    #[test]
    fn every_seal_uses_a_fresh_nonce()
    {
        let secret_box = SecretBox::new(&[7u8; 32]);
        let aad = account_token_aad(Uuid::new_v4());

        assert_ne!(
            secret_box.seal(b"token", &aad).unwrap(),
            secret_box.seal(b"token", &aad).unwrap()
        );
    }
}
