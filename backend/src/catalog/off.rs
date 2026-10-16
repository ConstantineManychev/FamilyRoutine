use std::collections::BTreeMap;
use std::time::Duration;

use reqwest::StatusCode;
use rust_decimal::prelude::FromPrimitive;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use shared_schema::{ItemKind, NutritionDto, ProductInfoDto};

const REQUEST_TIMEOUT: Duration = Duration::from_secs(6);
const CONNECT_TIMEOUT: Duration = Duration::from_secs(3);
const USER_AGENT: &str = "FamilyRoutine/1.0";
const NAME_LANGS: [&str; 8] = ["uk", "ru", "en", "pl", "de", "fr", "ja", "zh"];
const GENERIC_NAME: &str = "";
pub const MAX_NAME_CHARS: usize = 200;
pub const MAX_BRAND_CHARS: usize = 60;
pub const MAX_QUANTITY_CHARS: usize = 30;
pub const MAX_KCAL: f64 = 1000.0;
pub const MAX_GRAMS: f64 = 100.0;
const KJ_PER_KCAL: f64 = 4.184;

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct OffProduct
{
    pub names: BTreeMap<String, String>,
    pub brand: Option<String>,
    pub quantity: Option<String>,
    pub nutrition: NutritionDto,
}

#[derive(Debug, PartialEq)]
pub enum OffOutcome
{
    Found(OffProduct),
    NotFound,
    Unavailable,
}

pub struct OffClient
{
    http: reqwest::Client,
    base_url: Option<String>,
}

impl OffClient
{
    pub fn new(a_base_url: Option<&str>) -> Result<Self, String>
    {
        let http = reqwest::Client::builder()
            .timeout(REQUEST_TIMEOUT)
            .connect_timeout(CONNECT_TIMEOUT)
            .user_agent(USER_AGENT)
            .build()
            .map_err(|err| format!("open food facts http client: {err}"))?;

        Ok(Self {
            http,
            base_url: a_base_url.map(|url| url.trim_end_matches('/').to_string()),
        })
    }

    pub async fn fetch(&self, a_barcode: &str) -> OffOutcome
    {
        let Some(base_url) = self.base_url.as_deref()
        else
        {
            return OffOutcome::Unavailable;
        };

        let response = match self
            .http
            .get(format!("{base_url}/api/v2/product/{a_barcode}"))
            .query(&[("fields", requested_fields())])
            .send()
            .await
        {
            Ok(response) => response,
            Err(err) =>
            {
                tracing::warn!("open food facts request failed: {}", err.without_url());
                return OffOutcome::Unavailable;
            }
        };

        let status = response.status();
        if status == StatusCode::NOT_FOUND
        {
            return OffOutcome::NotFound;
        }
        if !status.is_success()
        {
            tracing::warn!("open food facts answered {status}");
            return OffOutcome::Unavailable;
        }

        match response.json::<Value>().await
        {
            Ok(payload) => parse_payload(&payload).map_or(OffOutcome::NotFound, OffOutcome::Found),
            Err(_) => OffOutcome::Unavailable,
        }
    }
}

impl OffProduct
{
    pub fn to_info(&self, a_barcode: &str, a_lang: Option<&str>) -> ProductInfoDto
    {
        let name = self.name_for(a_lang);
        ProductInfoDto {
            kind: Some(ItemKind::Food),
            suggested_name: suggest_name(name.as_deref(), self.brand.as_deref(), self.quantity.as_deref()),
            name,
            brand: self.brand.clone(),
            quantity: self.quantity.clone(),
            barcode: Some(a_barcode.to_string()),
            nutrition: (!self.nutrition.is_empty()).then(|| self.nutrition.clone()),
        }
    }

    fn name_for(&self, a_lang: Option<&str>) -> Option<String>
    {
        let lang = a_lang.map(str::to_lowercase);
        let name = lang
            .iter()
            .map(String::as_str)
            .chain([GENERIC_NAME, "uk", "en"])
            .find_map(|key| self.names.get(key))
            .or_else(|| self.names.values().next())
            .cloned();
        name
    }
}

pub fn requested_fields() -> String
{
    let names = NAME_LANGS.iter().map(|lang| format!("product_name_{lang}"));
    ["code", "product_name", "brands", "quantity", "nutriments"]
        .into_iter()
        .map(str::to_string)
        .chain(names)
        .collect::<Vec<_>>()
        .join(",")
}

pub fn parse_payload(a_payload: &Value) -> Option<OffProduct>
{
    if a_payload["status"].as_i64() == Some(0)
    {
        return None;
    }
    let product = a_payload.get("product").filter(|product| product.is_object())?;

    let mut names = BTreeMap::new();
    if let Some(name) = clean(product["product_name"].as_str(), MAX_NAME_CHARS)
    {
        names.insert(GENERIC_NAME.to_string(), name);
    }
    for lang in NAME_LANGS
    {
        if let Some(name) = clean(product[format!("product_name_{lang}")].as_str(), MAX_NAME_CHARS)
        {
            names.insert(lang.to_string(), name);
        }
    }

    let brand = product["brands"]
        .as_str()
        .and_then(|brands| brands.split(',').find_map(|brand| clean(Some(brand), MAX_BRAND_CHARS)));
    let quantity = clean(product["quantity"].as_str(), MAX_QUANTITY_CHARS);
    let nutrition = parse_nutrition(&product["nutriments"]);

    let is_empty = names.is_empty() && brand.is_none() && nutrition.is_empty();
    (!is_empty).then_some(OffProduct {
        names,
        brand,
        quantity,
        nutrition,
    })
}

fn parse_nutrition(a_nutriments: &Value) -> NutritionDto
{
    let kcal = number(&a_nutriments["energy-kcal_100g"])
        .or_else(|| number(&a_nutriments["energy_100g"]).map(|kj| kj / KJ_PER_KCAL));

    NutritionDto {
        kcal: bounded(kcal, MAX_KCAL),
        prot: bounded(number(&a_nutriments["proteins_100g"]), MAX_GRAMS),
        fat: bounded(number(&a_nutriments["fat_100g"]), MAX_GRAMS),
        carb: bounded(number(&a_nutriments["carbohydrates_100g"]), MAX_GRAMS),
        piece_g: None,
    }
}

fn number(a_value: &Value) -> Option<f64>
{
    match a_value
    {
        Value::Number(number) => number.as_f64(),
        Value::String(text) => text.trim().replace(',', ".").parse().ok(),
        _ => None,
    }
}

pub fn bounded(a_value: Option<f64>, a_max: f64) -> Option<Decimal>
{
    a_value
        .filter(|value| value.is_finite() && (0.0..=a_max).contains(value))
        .and_then(Decimal::from_f64)
        .map(|value| value.round_dp(2).normalize())
}

pub fn clean(a_value: Option<&str>, a_max_chars: usize) -> Option<String>
{
    let text: String = a_value?
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .filter(|chr| !chr.is_control())
        .take(a_max_chars)
        .collect();
    let text = text.trim().to_string();
    (!text.is_empty()).then_some(text)
}

pub fn suggest_name(a_name: Option<&str>, a_brand: Option<&str>, a_quantity: Option<&str>) -> Option<String>
{
    let name = a_name?;
    let lower = name.to_lowercase();
    let mut parts = vec![name.to_string()];
    for extra in [a_brand, a_quantity].into_iter().flatten()
    {
        if !lower.contains(&extra.to_lowercase())
        {
            parts.push(extra.to_string());
        }
    }
    Some(parts.join(" ").chars().take(MAX_NAME_CHARS).collect())
}

#[cfg(test)]
mod tests
{
    use std::str::FromStr;

    use serde_json::json;

    use super::*;

    #[test]
    fn requested_fields_limit_the_payload()
    {
        let fields = requested_fields();
        assert!(fields.starts_with("code,product_name,brands,quantity,nutriments,product_name_uk"));
        assert!(!fields.contains("image"));
    }

    #[test]
    fn product_is_parsed_with_names_brand_and_nutrition()
    {
        let payload = json!({
            "code": "4820000000017",
            "status": 1,
            "product": {
                "product_name": "Молоко 2,5%",
                "product_name_en": "Milk 2.5%",
                "brands": "Галичина, Galychyna",
                "quantity": " 900  г ",
                "nutriments": {
                    "energy-kcal_100g": 52,
                    "proteins_100g": "2.8",
                    "fat_100g": 2.5,
                    "carbohydrates_100g": 4.7,
                    "salt_100g": 0.1
                }
            }
        });

        let product = parse_payload(&payload).unwrap();
        assert_eq!(product.brand.as_deref(), Some("Галичина"));
        assert_eq!(product.quantity.as_deref(), Some("900 г"));
        assert_eq!(product.nutrition.kcal, Some(Decimal::from(52)));
        assert_eq!(product.nutrition.prot, Some(Decimal::from_str("2.8").unwrap()));

        let info = product.to_info("4820000000017", Some("ru"));
        assert_eq!(info.name.as_deref(), Some("Молоко 2,5%"));
        assert_eq!(info.suggested_name.as_deref(), Some("Молоко 2,5% Галичина 900 г"));
        assert_eq!(
            product.to_info("4820000000017", Some("en")).name.as_deref(),
            Some("Milk 2.5%")
        );
    }

    #[test]
    fn kilojoules_are_converted_and_impossible_values_dropped()
    {
        let payload = json!({
            "status": 1,
            "product": {
                "product_name": "Масло",
                "nutriments": { "energy_100g": 3700, "fat_100g": 182, "proteins_100g": -1 }
            }
        });

        let nutrition = parse_payload(&payload).unwrap().nutrition;
        assert_eq!(nutrition.kcal, Some(Decimal::from_str("884.32").unwrap()));
        assert_eq!(nutrition.fat, None);
        assert_eq!(nutrition.prot, None);
    }

    #[test]
    fn missing_or_empty_products_are_not_found()
    {
        assert_eq!(
            parse_payload(&json!({ "status": 0, "status_verbose": "product not found" })),
            None
        );
        assert_eq!(
            parse_payload(&json!({ "status": 1, "product": { "product_name": " " } })),
            None
        );
    }

    #[test]
    fn suggested_name_does_not_repeat_brand_or_size()
    {
        assert_eq!(
            suggest_name(Some("Galychyna milk 900 g"), Some("Galychyna"), Some("900 g")).as_deref(),
            Some("Galychyna milk 900 g")
        );
        assert_eq!(suggest_name(None, Some("Brand"), None), None);
    }
}
