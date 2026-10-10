use rust_decimal::Decimal;
use shared_schema::TxCategory;

const TRANSFER_MCCS: &[i16] = &[4829, 6012, 6050, 6051, 6211, 6529, 6530, 6536, 6537, 6538, 6540];
const CASH_MCCS: &[i16] = &[6010, 6011];
const CARD_PAYMENT_PREFIXES: &[&str] = &["vdp", "vdc", "vda", "pos"];

const TEXT_RULES: &[(TxCategory, &[&str])] = &[
    (
        TxCategory::Cash,
        &[
            "atm",
            "cash withdrawal",
            "cash lodgement",
            "lodgement",
            "lodgment",
            "cash deposit",
            "банкомат",
            "видача готівки",
            "зняття готівки",
            "поповнення готівкою",
            "внесення готівки",
        ],
    ),
    (
        TxCategory::Income,
        &[
            "salary",
            "payroll",
            "wages",
            "зарплата",
            "заробітна плата",
            "dividend",
            "interest earned",
        ],
    ),
    (
        TxCategory::Fees,
        &[
            "fee",
            "fees",
            "charge",
            "charges",
            "stamp duty",
            "комісія",
            "overdraft interest",
        ],
    ),
    (
        TxCategory::Transfer,
        &[
            "transfer",
            "trf",
            "sepa",
            "mobi",
            "revolut",
            "wise",
            "monobank",
            "paypal",
            "переказ",
            "обмін валюти",
            "з картки",
            "на картку",
            "currency exchange",
        ],
    ),
    (
        TxCategory::Groceries,
        &[
            "tesco",
            "lidl",
            "aldi",
            "dunnes",
            "supervalu",
            "centra",
            "spar",
            "londis",
            "mace",
            "iceland",
            "eurospar",
            "marks spencer",
            "m s",
            "asian market",
            "сільпо",
            "атб",
            "novus",
            "фора",
            "ашан",
            "варус",
            "metro",
            "eko market",
            "велмарт",
        ],
    ),
    (
        TxCategory::Restaurants,
        &[
            "costa",
            "starbucks",
            "insomnia",
            "butlers",
            "mcdonalds",
            "mcdonald s",
            "burger king",
            "kfc",
            "subway",
            "supermacs",
            "apache pizza",
            "dominos",
            "domino s",
            "just eat",
            "deliveroo",
            "uber eats",
            "cafe",
            "coffee",
            "restaurant",
            "pizza",
            "bar",
            "pub",
            "glovo",
            "пузата хата",
            "кафе",
            "ресторан",
        ],
    ),
    (
        TxCategory::Transport,
        &[
            "leap",
            "luas",
            "dublin bus",
            "irish rail",
            "bus eireann",
            "uber",
            "bolt",
            "free now",
            "freenow",
            "taxi",
            "parking",
            "toll",
            "eflow",
            "укрзалізниця",
            "uklon",
            "таксі",
            "метро",
        ],
    ),
    (
        TxCategory::Fuel,
        &[
            "circle k",
            "applegreen",
            "maxol",
            "texaco",
            "topaz",
            "okko",
            "wog",
            "socar",
            "upg",
            "shell",
            "petrol",
        ],
    ),
    (
        TxCategory::Utilities,
        &[
            "electric ireland",
            "bord gais",
            "energia",
            "sse airtricity",
            "flogas",
            "panda",
            "irish water",
            "eir",
            "vodafone",
            "three ireland",
            "virgin media",
            "sky",
            "київстар",
            "lifecell",
            "водоканал",
            "обленерго",
        ],
    ),
    (
        TxCategory::Health,
        &[
            "pharmacy",
            "chemist",
            "boots",
            "lloyds",
            "hickeys",
            "doctor",
            "dental",
            "hospital",
            "аптека",
            "клініка",
        ],
    ),
    (
        TxCategory::Entertainment,
        &[
            "netflix",
            "spotify",
            "disney",
            "apple com bill",
            "google play",
            "steam",
            "playstation",
            "xbox",
            "cinema",
            "odeon",
            "imc",
            "omniplex",
            "ticketmaster",
            "кіно",
            "мегого",
        ],
    ),
    (
        TxCategory::Travel,
        &[
            "ryanair",
            "aer lingus",
            "booking com",
            "airbnb",
            "hotel",
            "hostel",
            "expedia",
            "wizz",
        ],
    ),
    (
        TxCategory::Education,
        &[
            "school",
            "college",
            "university",
            "udemy",
            "coursera",
            "книгарня",
            "school books",
        ],
    ),
    (
        TxCategory::Home,
        &[
            "ikea",
            "woodies",
            "b q",
            "homebase",
            "harvey norman",
            "rent",
            "епіцентр",
            "jysk",
        ],
    ),
    (
        TxCategory::Shopping,
        &[
            "amazon",
            "penneys",
            "primark",
            "zara",
            "h m",
            "tk maxx",
            "currys",
            "argos",
            "smyths",
            "rozetka",
            "allo",
            "comfy",
            "foxtrot",
            "aliexpress",
            "temu",
            "ebay",
        ],
    ),
];

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

pub fn detect(a_mcc: Option<i16>, a_amount: Decimal, a_text: &str) -> TxCategory
{
    match a_mcc
    {
        Some(mcc) => from_mcc(mcc),
        None => from_text(a_text).unwrap_or(
            if a_amount > Decimal::ZERO
            {
                TxCategory::Income
            }
            else
            {
                TxCategory::Other
            },
        ),
    }
}

pub fn from_text(a_text: &str) -> Option<TxCategory>
{
    let words = words(a_text);
    if words.is_empty()
    {
        return None;
    }

    TEXT_RULES
        .iter()
        .find(|(_, phrases)| phrases.iter().any(|phrase| contains_phrase(&words, phrase)))
        .map(|(category, _)| *category)
}

pub fn is_card_payment_text(a_text: &str) -> bool
{
    words(a_text)
        .first()
        .is_some_and(|first| CARD_PAYMENT_PREFIXES.contains(&first.as_str()))
}

pub fn is_merchant_payment(a_mcc: Option<i16>, a_amount: Decimal, a_text: &str) -> bool
{
    if a_amount >= Decimal::ZERO
    {
        return false;
    }

    match a_mcc
    {
        Some(mcc) => !matches!(
            from_mcc(mcc),
            TxCategory::Cash | TxCategory::Transfer | TxCategory::Fees
        ),
        None => is_card_payment_text(a_text),
    }
}

fn words(a_text: &str) -> Vec<String>
{
    a_text
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|word| !word.is_empty())
        .map(str::to_lowercase)
        .collect()
}

fn contains_phrase(a_words: &[String], a_phrase: &str) -> bool
{
    let phrase: Vec<&str> = a_phrase.split(' ').collect();
    a_words
        .windows(phrase.len())
        .any(|window| window.iter().zip(&phrase).all(|(word, part)| word == part))
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
        assert_eq!(detect(None, Decimal::ONE, ""), TxCategory::Income);
    }

    #[test]
    fn text_rules_categorize_payments_without_mcc()
    {
        let minus = Decimal::NEGATIVE_ONE;
        assert_eq!(detect(None, minus, "VDP-TESCO STORES 3092"), TxCategory::Groceries);
        assert_eq!(detect(None, minus, "VDC-COSTA COFFEE"), TxCategory::Restaurants);
        assert_eq!(detect(None, minus, "ATM WITHDRAWAL DUBLIN"), TxCategory::Cash);
        assert_eq!(detect(None, Decimal::ONE, "CASH LODGEMENT"), TxCategory::Cash);
        assert_eq!(detect(None, Decimal::ONE, "SALARY ACME LTD"), TxCategory::Income);
        assert_eq!(detect(None, minus, "SEPA TRANSFER TO MONOBANK"), TxCategory::Transfer);
        assert_eq!(detect(None, minus, "D/D ELECTRIC IRELAND"), TxCategory::Utilities);
        assert_eq!(detect(None, minus, "Переказ на картку"), TxCategory::Transfer);
        assert_eq!(detect(None, minus, "SPARKASSE PAYMENT"), TxCategory::Other);
        assert_eq!(detect(None, minus, "COFFEEHOUSE"), TxCategory::Other);
        assert_eq!(detect(Some(5411), minus, "ATM"), TxCategory::Groceries);
    }

    #[test]
    fn card_payments_without_mcc_create_merchants()
    {
        assert!(is_merchant_payment(None, Decimal::NEGATIVE_ONE, "VDP-TESCO STORES"));
        assert!(!is_merchant_payment(None, Decimal::NEGATIVE_ONE, "SEPA TRANSFER"));
        assert!(!is_merchant_payment(None, Decimal::ONE, "VDP-TESCO STORES"));
    }

    #[test]
    fn transfers_and_cash_are_not_merchants()
    {
        assert!(is_merchant_payment(Some(5411), Decimal::NEGATIVE_ONE, ""));
        assert!(!is_merchant_payment(Some(4829), Decimal::NEGATIVE_ONE, ""));
        assert!(!is_merchant_payment(Some(6011), Decimal::NEGATIVE_ONE, ""));
        assert!(!is_merchant_payment(Some(5411), Decimal::ONE, ""));
        assert!(!is_merchant_payment(None, Decimal::NEGATIVE_ONE, ""));
    }
}
