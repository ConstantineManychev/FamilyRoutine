const NUMERIC_CODES: &[(u16, &str)] = &[
    (36, "AUD"),
    (124, "CAD"),
    (156, "CNY"),
    (203, "CZK"),
    (208, "DKK"),
    (348, "HUF"),
    (376, "ILS"),
    (392, "JPY"),
    (398, "KZT"),
    (410, "KRW"),
    (498, "MDL"),
    (578, "NOK"),
    (643, "RUB"),
    (752, "SEK"),
    (756, "CHF"),
    (826, "GBP"),
    (840, "USD"),
    (933, "BYN"),
    (941, "RSD"),
    (946, "RON"),
    (949, "TRY"),
    (975, "BGN"),
    (978, "EUR"),
    (980, "UAH"),
    (981, "GEL"),
    (985, "PLN"),
];

const ZERO_DECIMAL_CODES: &[&str] = &["JPY", "KRW", "VND", "CLP", "ISK", "UGX", "XAF", "XOF"];
const THREE_DECIMAL_CODES: &[&str] = &["KWD", "BHD", "JOD", "OMR", "TND", "LYD", "IQD"];

pub fn alpha_from_numeric(a_code: i64) -> Option<&'static str>
{
    NUMERIC_CODES
        .iter()
        .find(|(numeric, _)| i64::from(*numeric) == a_code)
        .map(|(_, alpha)| *alpha)
}

pub fn minor_exponent(a_alpha: &str) -> u32
{
    if ZERO_DECIMAL_CODES.contains(&a_alpha)
    {
        0
    }
    else if THREE_DECIMAL_CODES.contains(&a_alpha)
    {
        3
    }
    else
    {
        2
    }
}

pub fn is_valid_alpha(a_code: &str) -> bool
{
    a_code.len() == 3 && a_code.bytes().all(|byte| byte.is_ascii_uppercase())
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn maps_common_monobank_currencies()
    {
        assert_eq!(alpha_from_numeric(980), Some("UAH"));
        assert_eq!(alpha_from_numeric(978), Some("EUR"));
        assert_eq!(alpha_from_numeric(1), None);
        assert_eq!(minor_exponent("UAH"), 2);
        assert_eq!(minor_exponent("JPY"), 0);
        assert!(is_valid_alpha("EUR"));
        assert!(!is_valid_alpha("eur"));
    }
}
