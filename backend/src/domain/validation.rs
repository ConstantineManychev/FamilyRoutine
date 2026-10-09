use chrono::{NaiveDate, Utc};

use crate::domain::errors::ApiError;

pub const MAX_NAME_LEN: usize = 100;
pub const MAX_EMAIL_LEN: usize = 254;
pub const MIN_PASSWORD_LEN: usize = 10;
pub const MAX_PASSWORD_LEN: usize = 128;
pub const MIN_SYNC_TOKEN_LEN: usize = 16;
pub const MAX_SYNC_TOKEN_LEN: usize = 256;

pub fn clean_name(a_value: &str, a_field: &'static str) -> Result<String, ApiError>
{
    clean_text(a_value, 1, MAX_NAME_LEN, a_field)
}

pub fn clean_text(a_value: &str, a_min_len: usize, a_max_len: usize, a_field: &'static str)
    -> Result<String, ApiError>
{
    let value = a_value.trim();
    let len = value.chars().count();

    if len < a_min_len || len > a_max_len || value.chars().any(char::is_control)
    {
        return Err(ApiError::Validation(a_field));
    }

    Ok(value.to_string())
}

pub fn clean_optional_text(
    a_value: Option<&str>,
    a_max_len: usize,
    a_field: &'static str,
) -> Result<Option<String>, ApiError>
{
    match a_value.map(str::trim).filter(|value| !value.is_empty())
    {
        None => Ok(None),
        Some(value) => clean_text(value, 1, a_max_len, a_field).map(Some),
    }
}

pub fn normalize_email(a_value: &str) -> Result<String, ApiError>
{
    let email = a_value.trim().to_lowercase();

    let is_shape_valid = email.len() <= MAX_EMAIL_LEN
        && !email.chars().any(|ch| ch.is_whitespace() || ch.is_control())
        && match email.split_once('@')
        {
            Some((local, domain)) =>
            {
                !local.is_empty()
                    && !domain.contains('@')
                    && domain.contains('.')
                    && !domain.starts_with('.')
                    && !domain.ends_with('.')
                    && !domain.contains("..")
            }
            None => false,
        };

    if !is_shape_valid
    {
        return Err(ApiError::Validation("email"));
    }

    Ok(email)
}

pub fn check_password(a_value: &str) -> Result<(), ApiError>
{
    let len = a_value.chars().count();

    if !(MIN_PASSWORD_LEN..=MAX_PASSWORD_LEN).contains(&len)
    {
        return Err(ApiError::Validation("password"));
    }

    Ok(())
}

pub fn check_login_password(a_value: &str) -> Result<(), ApiError>
{
    if a_value.is_empty() || a_value.chars().count() > MAX_PASSWORD_LEN
    {
        return Err(ApiError::InvalidCredentials);
    }

    Ok(())
}

pub fn check_birth_date(a_value: NaiveDate) -> Result<(), ApiError>
{
    let min_date = NaiveDate::from_ymd_opt(1900, 1, 1).ok_or_else(|| ApiError::internal("min birth date"))?;

    if a_value < min_date || a_value > Utc::now().date_naive()
    {
        return Err(ApiError::Validation("birth_date"));
    }

    Ok(())
}

pub fn clean_mask(a_value: Option<&str>) -> Result<Option<String>, ApiError>
{
    match a_value.map(str::trim).filter(|value| !value.is_empty())
    {
        None => Ok(None),
        Some(value) if value.len() == 4 && value.chars().all(|ch| ch.is_ascii_digit()) => Ok(Some(value.to_string())),
        Some(_) => Err(ApiError::Validation("mask")),
    }
}

pub fn clean_sync_token(a_value: &str) -> Result<String, ApiError>
{
    let token = a_value.trim();
    let is_valid = (MIN_SYNC_TOKEN_LEN..=MAX_SYNC_TOKEN_LEN).contains(&token.len())
        && token.chars().all(|ch| ch.is_ascii_graphic());

    if !is_valid
    {
        return Err(ApiError::Validation("sync_token"));
    }

    Ok(token.to_string())
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn email_is_normalized_and_validated()
    {
        assert_eq!(
            normalize_email("  John.Doe@Example.COM ").unwrap(),
            "john.doe@example.com"
        );
        assert!(normalize_email("no-at-sign").is_err());
        assert!(normalize_email("a@b").is_err());
        assert!(normalize_email("a@@b.com").is_err());
        assert!(normalize_email("a b@c.com").is_err());
        assert!(normalize_email("a@.com").is_err());
    }

    #[test]
    fn mask_accepts_only_last_four_digits()
    {
        assert_eq!(clean_mask(Some("1234")).unwrap(), Some("1234".to_string()));
        assert_eq!(clean_mask(Some("  ")).unwrap(), None);
        assert_eq!(clean_mask(None).unwrap(), None);
        assert!(clean_mask(Some("4111111111111111")).is_err());
        assert!(clean_mask(Some("12a4")).is_err());
    }

    #[test]
    fn password_length_is_enforced()
    {
        assert!(check_password("short").is_err());
        assert!(check_password("long-enough-password").is_ok());
        assert!(check_password(&"x".repeat(MAX_PASSWORD_LEN + 1)).is_err());
    }

    #[test]
    fn names_reject_control_characters_and_overflow()
    {
        assert_eq!(clean_name("  Family  ", "name").unwrap(), "Family");
        assert!(clean_name("", "name").is_err());
        assert!(clean_name("bad\u{0}name", "name").is_err());
        assert!(clean_name(&"x".repeat(MAX_NAME_LEN + 1), "name").is_err());
    }

    #[test]
    fn sync_token_must_be_printable()
    {
        assert!(clean_sync_token("uAbCdEfGhIjKlMnOpQrStUvWxYz0123456789").is_ok());
        assert!(clean_sync_token("short").is_err());
        assert!(clean_sync_token("has space inside the token value").is_err());
    }
}
