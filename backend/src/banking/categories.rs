use rust_decimal::Decimal;
use shared_schema::TxCategory;

const TRANSFER_MCCS: &[i16] = &[4829, 6012, 6050, 6051, 6211, 6529, 6530, 6536, 6537, 6538, 6540];
const CASH_MCCS: &[i16] = &[6010, 6011];

pub fn from_mcc(a_mcc: i16) -> TxCategory
{
    match a_mcc
    {
        mcc if CASH_MCCS.contains(&mcc) => TxCategory::Cash,
        mcc if TRANSFER_MCCS.contains(&mcc) => TxCategory::Transfer,
        5411 | 5422 | 5441 | 5451 | 5462 | 5499 | 5297 | 5298 => TxCategory::Groceries,
        5811..=5814 => TxCategory::Restaurants,
        5541 | 5542 | 5552 | 5983 => TxCategory::Fuel,
        4011 | 4111 | 4112 | 4121 | 4131 | 4784 | 4789 | 7512 | 7523 => TxCategory::Transport,
        3000..=3999 | 4411 | 4511 | 4582 | 4722 | 7011 | 7012 | 7032 | 7033 => TxCategory::Travel,
        4812 | 4814 | 4816 | 4899 | 4900 => TxCategory::Utilities,
        5122 | 5912 | 5975 | 5976 | 8011..=8099 => TxCategory::Health,
        5815..=5818 | 7832 | 7841 | 7911..=7999 => TxCategory::Entertainment,
        8211..=8299 | 5942 | 5943 => TxCategory::Education,
        1520..=1799 | 5200..=5299 | 5712..=5719 | 7210..=7299 => TxCategory::Home,
        9211..=9405 | 6300 | 6381 => TxCategory::Fees,
        5000..=5999 | 7300..=7399 => TxCategory::Shopping,
        _ => TxCategory::Other,
    }
}

pub fn detect(a_mcc: Option<i16>, a_amount: Decimal) -> TxCategory
{
    match a_mcc
    {
        Some(mcc) => from_mcc(mcc),
        None if a_amount > Decimal::ZERO => TxCategory::Income,
        None => TxCategory::Other,
    }
}

pub fn is_merchant_payment(a_mcc: Option<i16>, a_amount: Decimal) -> bool
{
    match a_mcc
    {
        Some(mcc) if a_amount < Decimal::ZERO => !matches!(
            from_mcc(mcc),
            TxCategory::Cash | TxCategory::Transfer | TxCategory::Fees
        ),
        _ => false,
    }
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn mcc_maps_to_expected_categories()
    {
        assert_eq!(from_mcc(5411), TxCategory::Groceries);
        assert_eq!(from_mcc(5812), TxCategory::Restaurants);
        assert_eq!(from_mcc(6011), TxCategory::Cash);
        assert_eq!(from_mcc(4829), TxCategory::Transfer);
        assert_eq!(from_mcc(3015), TxCategory::Travel);
        assert_eq!(from_mcc(5651), TxCategory::Shopping);
        assert_eq!(detect(None, Decimal::ONE), TxCategory::Income);
    }

    #[test]
    fn transfers_and_cash_are_not_merchants()
    {
        assert!(is_merchant_payment(Some(5411), Decimal::NEGATIVE_ONE));
        assert!(!is_merchant_payment(Some(4829), Decimal::NEGATIVE_ONE));
        assert!(!is_merchant_payment(Some(6011), Decimal::NEGATIVE_ONE));
        assert!(!is_merchant_payment(Some(5411), Decimal::ONE));
        assert!(!is_merchant_payment(None, Decimal::NEGATIVE_ONE));
    }
}
