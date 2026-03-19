use axum::{
    async_trait,
    extract::FromRequestParts,
    http::{request::Parts, StatusCode},
};
use axum_extra::extract::CookieJar;
use jsonwebtoken::{decode, DecodingKey, Validation};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Serialize, Deserialize)]
pub struct AuthClaims {
    pub sub: Uuid,
    pub exp: usize,
}

pub struct AuthenticatedUser(pub Uuid);

#[async_trait]
impl<S> FromRequestParts<S> for AuthenticatedUser
where
    S: Send + Sync,
{
    type Rejection = StatusCode;

    async fn from_request_parts(parts: &mut Parts, _state: &S) -> Result<Self, Self::Rejection> {
        let jar = CookieJar::from_headers(&parts.headers);
        
        let token = jar.get("jwt_token")
            .map(|c| c.value().to_string())
            .or_else(|| {
                parts.headers
                    .get("Authorization")
                    .and_then(|h| h.to_str().ok())
                    .and_then(|h| h.strip_prefix("Bearer "))
                    .map(|s| s.to_string())
            })
            .ok_or(StatusCode::UNAUTHORIZED)?;

        let secret = std::env::var("JWT_SECRET").unwrap_or_else(|_| "very_secret_key_123".into());
        
        let token_data = decode::<AuthClaims>(
            &token,
            &DecodingKey::from_secret(secret.as_ref()),
            &Validation::default(),
        ).map_err(|_| StatusCode::UNAUTHORIZED)?;

        Ok(AuthenticatedUser(token_data.claims.sub))
    }
}