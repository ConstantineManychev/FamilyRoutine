use std::sync::Arc;

use sqlx::PgPool;

use crate::banking::BankClients;
use crate::config::AppConfig;
use crate::security::crypto::SecretBox;
use crate::security::password::PasswordService;
use crate::security::rate_limit::RateLimiter;

#[derive(Clone)]
pub struct AppState
{
    pub db: PgPool,
    pub cfg: Arc<AppConfig>,
    pub secret_box: Arc<SecretBox>,
    pub passwords: Arc<PasswordService>,
    pub limiter: Arc<RateLimiter>,
    pub banks: Arc<BankClients>,
}

impl AppState
{
    pub fn new(a_db: PgPool, a_cfg: AppConfig) -> Result<Self, String>
    {
        let secret_box = SecretBox::new(&a_cfg.data_key);
        let passwords = PasswordService::new(a_cfg.password_pepper.clone());
        let banks = BankClients::new(&a_cfg.banks)?;

        Ok(Self {
            db: a_db,
            cfg: Arc::new(a_cfg),
            secret_box: Arc::new(secret_box),
            passwords: Arc::new(passwords),
            limiter: Arc::new(RateLimiter::default()),
            banks: Arc::new(banks),
        })
    }
}
