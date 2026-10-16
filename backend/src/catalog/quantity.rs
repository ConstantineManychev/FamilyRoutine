use std::str::FromStr;

use rust_decimal::{Decimal, RoundingStrategy};
use shared_schema::{ItemKind, NetMeasure, ProductInfoDto};

const NET_SCALE: u32 = 1;
const MAX_NET: i64 = 1_000_000;
const MAX_PACK_COUNT: i64 = 1000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PackQuantity
{
    pub net: Decimal,
    pub measure: NetMeasure,
    pub piece: Option<Decimal>,
}

#[derive(Debug, Clone, PartialEq)]
enum Token
{
    Number(Decimal),
    Word(String),
    Times,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Amount
{
    value: Decimal,
    measure: NetMeasure,
}

fn unit_factor(a_word: &str, a_next: Option<&str>) -> Option<(NetMeasure, Decimal, usize)>
{
    let grams = |a_factor: &str| Some((NetMeasure::G, Decimal::from_str(a_factor).ok()?, 1));
    let millis = |a_factor: &str| Some((NetMeasure::Ml, Decimal::from_str(a_factor).ok()?, 1));
    match a_word
    {
        "g" | "gr" | "grs" | "gram" | "grams" | "gramm" | "gramme" | "grammes" | "г" | "гр" | "грамм" =>
        {
            grams("1")
        }
        "kg" | "kgs" | "kilo" | "kilogram" | "kilograms" | "кг" => grams("1000"),
        "mg" | "мг" => grams("0.001"),
        "lb" | "lbs" => grams("453.592"),
        "oz" => grams("28.3495"),
        "fl" if a_next == Some("oz") => Some((NetMeasure::Ml, Decimal::from_str("29.5735").ok()?, 2)),
        "ml" | "мл" => millis("1"),
        "cl" => millis("10"),
        "dl" => millis("100"),
        "l" | "lt" | "ltr" | "liter" | "liters" | "litre" | "litres" | "л" => millis("1000"),
        _ => None,
    }
}

fn tokenize(a_text: &str) -> Vec<Token>
{
    let chars: Vec<char> = a_text.to_lowercase().chars().collect();
    let mut tokens = Vec::new();
    let mut index = 0;
    while index < chars.len()
    {
        let ch = chars[index];
        if ch.is_ascii_digit()
        {
            let start = index;
            while index < chars.len()
                && (chars[index].is_ascii_digit()
                    || ((chars[index] == '.' || chars[index] == ',')
                        && chars.get(index + 1).is_some_and(char::is_ascii_digit)))
            {
                index += 1;
            }
            let raw: String = chars[start..index]
                .iter()
                .map(|ch| {
                    if *ch == ','
                    {
                        '.'
                    }
                    else
                    {
                        *ch
                    }
                })
                .collect();
            if let Ok(value) = Decimal::from_str(&raw)
            {
                tokens.push(Token::Number(value));
            }
            continue;
        }
        if ch == '×' || ch == '*'
        {
            tokens.push(Token::Times);
            index += 1;
            continue;
        }
        if ch.is_alphabetic()
        {
            let start = index;
            while index < chars.len() && chars[index].is_alphabetic()
            {
                index += 1;
            }
            let word: String = chars[start..index].iter().collect();
            tokens.push(
                if word == "x" || word == "х"
                {
                    Token::Times
                }
                else
                {
                    Token::Word(word)
                },
            );
            continue;
        }
        index += 1;
    }
    tokens
}

fn amount_at(a_tokens: &[Token], a_index: usize) -> Option<(Amount, usize)>
{
    let Token::Number(value) = a_tokens.get(a_index)?
    else
    {
        return None;
    };
    let Token::Word(word) = a_tokens.get(a_index + 1)?
    else
    {
        return None;
    };
    let next = match a_tokens.get(a_index + 2)
    {
        Some(Token::Word(next)) => Some(next.as_str()),
        _ => None,
    };
    let (measure, factor, words) = unit_factor(word, next)?;
    Some((
        Amount {
            value: *value * factor,
            measure,
        },
        1 + words,
    ))
}

fn count_at(a_tokens: &[Token], a_index: usize) -> Option<Decimal>
{
    match a_tokens.get(a_index)?
    {
        Token::Number(value)
            if value.fract().is_zero() && *value >= Decimal::TWO && *value <= Decimal::from(MAX_PACK_COUNT) =>
        {
            Some(*value)
        }
        _ => None,
    }
}

fn multipack_at(a_tokens: &[Token], a_index: usize) -> Option<(Decimal, Amount)>
{
    if let (Some(count), Some(Token::Times)) = (count_at(a_tokens, a_index), a_tokens.get(a_index + 1))
    {
        if let Some((amount, _)) = amount_at(a_tokens, a_index + 2)
        {
            return Some((count, amount));
        }
    }
    let (amount, used) = amount_at(a_tokens, a_index)?;
    match a_tokens.get(a_index + used)
    {
        Some(Token::Times) => count_at(a_tokens, a_index + used + 1).map(|count| (count, amount)),
        _ => None,
    }
}

fn rounded(a_value: Decimal) -> Decimal
{
    a_value
        .round_dp_with_strategy(NET_SCALE, RoundingStrategy::MidpointAwayFromZero)
        .normalize()
}

pub fn parse_quantity(a_text: &str) -> Option<PackQuantity>
{
    let tokens = tokenize(a_text);
    let multipack = (0..tokens.len()).find_map(|index| multipack_at(&tokens, index));
    let single = (0..tokens.len()).find_map(|index| amount_at(&tokens, index).map(|(amount, _)| amount));

    let quantity = match multipack
    {
        Some((count, piece)) => PackQuantity {
            net: rounded(piece.value * count),
            measure: piece.measure,
            piece: Some(rounded(piece.value)),
        },
        None =>
        {
            let amount = single?;
            PackQuantity {
                net: rounded(amount.value),
                measure: amount.measure,
                piece: None,
            }
        }
    };

    let is_valid = quantity.net > Decimal::ZERO
        && quantity.net <= Decimal::from(MAX_NET)
        && quantity.piece.is_none_or(|piece| piece > Decimal::ZERO);
    is_valid.then_some(quantity)
}

pub fn with_quantity(mut a_info: ProductInfoDto) -> ProductInfoDto
{
    let Some(quantity) = a_info.quantity.as_deref().and_then(parse_quantity)
    else
    {
        return a_info;
    };
    a_info.net_qty = Some(quantity.net);
    a_info.net_measure = Some(quantity.measure);
    if let (Some(piece), Some(ItemKind::Food) | None) = (quantity.piece, a_info.kind)
    {
        a_info.nutrition.get_or_insert_with(Default::default).piece_g = Some(piece);
    }
    a_info
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn dec(a_value: &str) -> Decimal
    {
        Decimal::from_str(a_value).unwrap()
    }

    fn single(a_net: &str, a_measure: NetMeasure) -> Option<PackQuantity>
    {
        Some(PackQuantity {
            net: dec(a_net),
            measure: a_measure,
            piece: None,
        })
    }

    fn pack(a_net: &str, a_piece: &str, a_measure: NetMeasure) -> Option<PackQuantity>
    {
        Some(PackQuantity {
            net: dec(a_net),
            measure: a_measure,
            piece: Some(dec(a_piece)),
        })
    }

    #[test]
    fn single_packages_are_normalized_to_grams_and_millilitres()
    {
        assert_eq!(parse_quantity("400 g"), single("400", NetMeasure::G));
        assert_eq!(parse_quantity("400g"), single("400", NetMeasure::G));
        assert_eq!(parse_quantity("℮ 400 g"), single("400", NetMeasure::G));
        assert_eq!(parse_quantity("0.5 kg"), single("500", NetMeasure::G));
        assert_eq!(parse_quantity("0,5 кг"), single("500", NetMeasure::G));
        assert_eq!(parse_quantity("1.5 l"), single("1500", NetMeasure::Ml));
        assert_eq!(parse_quantity("1,5 L"), single("1500", NetMeasure::Ml));
        assert_eq!(parse_quantity("330 ml"), single("330", NetMeasure::Ml));
        assert_eq!(parse_quantity("33 cl"), single("330", NetMeasure::Ml));
        assert_eq!(parse_quantity("900 мл"), single("900", NetMeasure::Ml));
        assert_eq!(parse_quantity("200 гр."), single("200", NetMeasure::G));
        assert_eq!(parse_quantity("12 fl oz"), single("354.9", NetMeasure::Ml));
    }

    #[test]
    fn multipacks_give_the_total_and_one_piece()
    {
        assert_eq!(parse_quantity("6 x 50 g"), pack("300", "50", NetMeasure::G));
        assert_eq!(parse_quantity("4x125g"), pack("500", "125", NetMeasure::G));
        assert_eq!(parse_quantity("4 × 125 g"), pack("500", "125", NetMeasure::G));
        assert_eq!(parse_quantity("2 х 1,5 л"), pack("3000", "1500", NetMeasure::Ml));
        assert_eq!(parse_quantity("500 g (4 x 125 g)"), pack("500", "125", NetMeasure::G));
        assert_eq!(parse_quantity("250 ml x 4"), pack("1000", "250", NetMeasure::Ml));
    }

    #[test]
    fn product_info_gets_the_net_and_the_piece_weight()
    {
        let info = with_quantity(ProductInfoDto {
            kind: Some(ItemKind::Food),
            name: None,
            brand: None,
            quantity: Some("4 x 125 g".into()),
            suggested_name: None,
            barcode: None,
            nutrition: None,
            net_qty: None,
            net_measure: None,
        });
        assert_eq!(info.net_qty, Some(dec("500")));
        assert_eq!(info.net_measure, Some(NetMeasure::G));
        assert_eq!(info.nutrition.unwrap().piece_g, Some(dec("125")));
    }

    #[test]
    fn counts_without_mass_and_garbage_are_ignored()
    {
        assert_eq!(parse_quantity("6 pcs"), None);
        assert_eq!(parse_quantity("max"), None);
        assert_eq!(parse_quantity(""), None);
        assert_eq!(parse_quantity("0 g"), None);
        assert_eq!(parse_quantity("1.5 x 2 g"), single("2", NetMeasure::G));
    }
}
