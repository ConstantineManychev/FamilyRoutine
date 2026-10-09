use std::sync::Arc;

use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::{Algorithm, Argon2, Params, Version};

use crate::domain::errors::ApiError;

pub struct PasswordService
{
    pepper: Arc<Vec<u8>>,
    dummy_hash: Arc<String>,
}

impl PasswordService
{
    pub fn new(a_pepper: Vec<u8>) -> Self
    {
        let pepper = Arc::new(a_pepper);
        let dummy_hash = hash_blocking(&pepper, "dummy-password-for-timing-equalization")
            .expect("argon2 must be able to hash the dummy password");

        Self {
            pepper,
            dummy_hash: Arc::new(dummy_hash),
        }
    }

    pub async fn hash(&self, a_password: String) -> Result<String, ApiError>
    {
        let pepper = self.pepper.clone();

        tokio::task::spawn_blocking(move || hash_blocking(&pepper, &a_password))
            .await
            .map_err(ApiError::internal)?
    }

    pub async fn verify(&self, a_password: String, a_hash: String, a_is_peppered: bool) -> Result<bool, ApiError>
    {
        let pepper = self.pepper.clone();

        tokio::task::spawn_blocking(move || verify_blocking(&pepper, &a_password, &a_hash, a_is_peppered))
            .await
            .map_err(ApiError::internal)?
    }

    pub async fn burn_time(&self, a_password: String)
    {
        let _ = self.verify(a_password, self.dummy_hash.as_ref().clone(), true).await;
    }
}

fn peppered_argon(a_pepper: &[u8]) -> Result<Argon2<'_>, ApiError>
{
    Argon2::new_with_secret(a_pepper, Algorithm::Argon2id, Version::V0x13, Params::default())
        .map_err(|_| ApiError::internal("argon2 configuration"))
}

fn hash_blocking(a_pepper: &[u8], a_password: &str) -> Result<String, ApiError>
{
    let salt = SaltString::generate(&mut OsRng);

    peppered_argon(a_pepper)?
        .hash_password(a_password.as_bytes(), &salt)
        .map(|hash| hash.to_string())
        .map_err(|_| ApiError::internal("argon2 hashing"))
}

fn verify_blocking(a_pepper: &[u8], a_password: &str, a_hash: &str, a_is_peppered: bool) -> Result<bool, ApiError>
{
    let parsed = PasswordHash::new(a_hash).map_err(|_| ApiError::internal("stored password hash is malformed"))?;

    let result = if a_is_peppered
    {
        peppered_argon(a_pepper)?.verify_password(a_password.as_bytes(), &parsed)
    }
    else
    {
        Argon2::default().verify_password(a_password.as_bytes(), &parsed)
    };

    Ok(result.is_ok())
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[tokio::test]
    async fn peppered_hash_verifies_only_with_the_same_pepper()
    {
        let service = PasswordService::new(vec![1u8; 32]);
        let hash = service.hash("correct horse battery".into()).await.unwrap();

        assert!(service
            .verify("correct horse battery".into(), hash.clone(), true)
            .await
            .unwrap());
        assert!(!service
            .verify("wrong password".into(), hash.clone(), true)
            .await
            .unwrap());

        let other = PasswordService::new(vec![2u8; 32]);
        assert!(!other.verify("correct horse battery".into(), hash, true).await.unwrap());
    }

    #[tokio::test]
    async fn legacy_unpeppered_hash_still_verifies()
    {
        let salt = SaltString::generate(&mut OsRng);
        let legacy = Argon2::default()
            .hash_password(b"legacy password", &salt)
            .unwrap()
            .to_string();
        let service = PasswordService::new(vec![1u8; 32]);

        assert!(service.verify("legacy password".into(), legacy, false).await.unwrap());
    }
}
