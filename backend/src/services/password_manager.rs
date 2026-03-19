use crate::domain::errors::ApiError;
use argon2::{
    password_hash::{rand_core::OsRng, PasswordHasher, PasswordVerifier, SaltString},
    Argon2, PasswordHash,
};

pub fn generate_password_hash(plain_password: &str) -> Result<String, ApiError> {
    let cryptographic_salt = SaltString::generate(&mut OsRng);
    let argon2_instance = Argon2::default();
    
    argon2_instance
        .hash_password(plain_password.as_bytes(), &cryptographic_salt)
        .map_err(|_| ApiError::HashError)
        .map(|hashed_password| hashed_password.to_string())
}

pub fn verify_password_hash(plain_password: &str, hashed_password: &str) -> Result<(), ApiError> {
    let parsed_password_hash = PasswordHash::new(hashed_password).map_err(|_| ApiError::HashError)?;
    let argon2_instance = Argon2::default();

    argon2_instance
        .verify_password(plain_password.as_bytes(), &parsed_password_hash)
        .map_err(|_| ApiError::InvalidCredentials)
}