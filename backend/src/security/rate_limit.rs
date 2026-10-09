use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use crate::domain::errors::ApiError;

const MAX_TRACKED_KEYS: usize = 50_000;

pub struct Rule
{
    pub limit: u32,
    pub period: Duration,
}

pub const LOGIN_PER_IP: Rule = Rule {
    limit: 30,
    period: Duration::from_secs(15 * 60),
};
pub const LOGIN_PER_EMAIL: Rule = Rule {
    limit: 10,
    period: Duration::from_secs(15 * 60),
};
pub const REGISTER_PER_IP: Rule = Rule {
    limit: 10,
    period: Duration::from_secs(60 * 60),
};
pub const INVITE_CREATE_PER_USER: Rule = Rule {
    limit: 30,
    period: Duration::from_secs(60 * 60),
};
pub const INVITE_ACCEPT_PER_USER: Rule = Rule {
    limit: 10,
    period: Duration::from_secs(60 * 60),
};
pub const INVITE_ACCEPT_PER_IP: Rule = Rule {
    limit: 30,
    period: Duration::from_secs(60 * 60),
};

struct Window
{
    started: Instant,
    period: Duration,
    count: u32,
}

#[derive(Default)]
pub struct RateLimiter
{
    windows: Mutex<HashMap<String, Window>>,
}

impl RateLimiter
{
    pub fn hit(&self, a_key: &str, a_rule: &Rule) -> Result<(), ApiError>
    {
        let now = Instant::now();
        let mut windows = self
            .windows
            .lock()
            .map_err(|_| ApiError::internal("rate limiter poisoned"))?;

        if windows.len() >= MAX_TRACKED_KEYS
        {
            windows.retain(|_, window| now.duration_since(window.started) < window.period);
        }

        if windows.len() >= MAX_TRACKED_KEYS && !windows.contains_key(a_key)
        {
            return Err(ApiError::TooManyRequests(a_rule.period.as_secs()));
        }

        let window = windows.entry(a_key.to_string()).or_insert(Window {
            started: now,
            period: a_rule.period,
            count: 0,
        });

        if now.duration_since(window.started) >= window.period
        {
            window.started = now;
            window.period = a_rule.period;
            window.count = 0;
        }

        if window.count >= a_rule.limit
        {
            let retry_after = window
                .period
                .saturating_sub(now.duration_since(window.started))
                .as_secs()
                .max(1);
            return Err(ApiError::TooManyRequests(retry_after));
        }

        window.count += 1;
        Ok(())
    }

    pub fn reset(&self, a_key: &str)
    {
        if let Ok(mut windows) = self.windows.lock()
        {
            windows.remove(a_key);
        }
    }

    pub fn purge(&self)
    {
        let now = Instant::now();
        if let Ok(mut windows) = self.windows.lock()
        {
            windows.retain(|_, window| now.duration_since(window.started) < window.period);
        }
    }
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn limit_is_enforced_per_key()
    {
        let limiter = RateLimiter::default();
        let rule = Rule {
            limit: 2,
            period: Duration::from_secs(60),
        };

        assert!(limiter.hit("a", &rule).is_ok());
        assert!(limiter.hit("a", &rule).is_ok());
        assert!(matches!(limiter.hit("a", &rule), Err(ApiError::TooManyRequests(_))));
        assert!(limiter.hit("b", &rule).is_ok());

        limiter.reset("a");
        assert!(limiter.hit("a", &rule).is_ok());
    }
}
