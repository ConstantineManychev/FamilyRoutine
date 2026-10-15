use reqwest::RequestBuilder;
use serde_json::{json, Map, Value};
use shared_schema::AiModelDto;

use super::{is_version, AiTarget, ReadError, ReceiptImage, Usage, VisionTask, MAX_OUTPUT_TOKENS};

const KEY_HEADER: &str = "x-goog-api-key";
const MODEL_PREFIX: &str = "models/";
const FAMILY_PREFIX: &str = "gemini-";
const MODELS_PAGE_SIZE: u32 = 1000;
const GENERATE_METHOD: &str = "generateContent";
const KEY_ERROR_REASONS: [&str; 2] = ["API_KEY_INVALID", "API_KEY_SERVICE_BLOCKED"];
const REFUSAL_REASONS: [&str; 6] = [
    "SAFETY",
    "RECITATION",
    "BLOCKLIST",
    "PROHIBITED_CONTENT",
    "SPII",
    "IMAGE_SAFETY",
];
const UNSUITABLE_PARTS: [&str; 7] = ["embedding", "tts", "image", "live", "audio", "computer-use", "robotics"];

pub fn read_request(
    a_http: &reqwest::Client,
    a_base: &str,
    a_target: &AiTarget,
    a_image: &ReceiptImage,
    a_task: &VisionTask,
) -> RequestBuilder
{
    a_http
        .post(format!(
            "{}/v1beta/models/{}:{GENERATE_METHOD}",
            a_base.trim_end_matches('/'),
            a_target.model
        ))
        .header(KEY_HEADER, &a_target.api_key)
        .json(&request_body(a_image, a_task))
}

pub fn models_request(a_http: &reqwest::Client, a_base: &str, a_api_key: &str) -> RequestBuilder
{
    a_http
        .get(format!(
            "{}/v1beta/models?pageSize={MODELS_PAGE_SIZE}",
            a_base.trim_end_matches('/')
        ))
        .header(KEY_HEADER, a_api_key)
}

pub fn parse_reply(a_payload: &Value) -> Result<(String, Usage), ReadError>
{
    if a_payload["promptFeedback"]["blockReason"].is_string()
    {
        return Err(ReadError::Refused);
    }

    let candidate = &a_payload["candidates"][0];
    let finish_reason = candidate["finishReason"].as_str().unwrap_or("STOP");
    if REFUSAL_REASONS.contains(&finish_reason)
    {
        return Err(ReadError::Refused);
    }
    if finish_reason != "STOP"
    {
        tracing::warn!("gemini output finished with {finish_reason}");
        return Err(ReadError::Unreadable);
    }

    let text: String = candidate["content"]["parts"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|part| part["thought"] != true)
        .filter_map(|part| part["text"].as_str())
        .collect();
    if text.is_empty()
    {
        return Err(ReadError::Unreadable);
    }

    let metadata = &a_payload["usageMetadata"];
    let usage = Usage {
        input_tokens: metadata["promptTokenCount"].as_i64().unwrap_or_default(),
        output_tokens: metadata["candidatesTokenCount"].as_i64().unwrap_or_default()
            + metadata["thoughtsTokenCount"].as_i64().unwrap_or_default(),
    };

    Ok((text, usage))
}

pub fn parse_models(a_payload: &Value) -> Vec<AiModelDto>
{
    let mut models: Vec<AiModelDto> = a_payload["models"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|model| {
            let id = model["name"].as_str()?.strip_prefix(MODEL_PREFIX)?;
            let is_generative = model["supportedGenerationMethods"]
                .as_array()
                .is_some_and(|methods| methods.iter().any(|method| method == GENERATE_METHOD));
            let is_suitable = id.starts_with(FAMILY_PREFIX) && !UNSUITABLE_PARTS.iter().any(|part| id.contains(part));

            (is_generative && is_suitable).then(|| AiModelDto {
                id: id.to_string(),
                name: model["displayName"].as_str().unwrap_or(id).to_string(),
            })
        })
        .collect();
    models.sort_by(|left, right| right.id.cmp(&left.id));
    models
}

pub fn is_key_error(a_payload: &Value) -> bool
{
    a_payload["error"]["details"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|detail| detail["reason"].as_str())
        .any(|reason| KEY_ERROR_REASONS.contains(&reason))
}

pub fn is_stable_pro(a_model: &str) -> bool
{
    is_stable_tier(a_model, "-pro")
}

pub fn is_stable_flash(a_model: &str) -> bool
{
    is_stable_tier(a_model, "-flash")
}

fn is_stable_tier(a_model: &str, a_tier: &str) -> bool
{
    a_model
        .strip_prefix(FAMILY_PREFIX)
        .and_then(|rest| rest.strip_suffix(a_tier))
        .is_some_and(is_version)
}

fn request_body(a_image: &ReceiptImage, a_task: &VisionTask) -> Value
{
    json!({
        "systemInstruction": { "parts": [{ "text": a_task.system }] },
        "contents": [{
            "role": "user",
            "parts": [
                { "inlineData": { "mimeType": a_image.media_type, "data": a_image.data_base64 } },
                { "text": a_task.prompt }
            ]
        }],
        "generationConfig": {
            "responseMimeType": "application/json",
            "responseSchema": to_gemini_schema(&(a_task.schema)()),
            "maxOutputTokens": MAX_OUTPUT_TOKENS
        }
    })
}

fn to_gemini_schema(a_schema: &Value) -> Value
{
    let Some(fields) = a_schema.as_object()
    else
    {
        return a_schema.clone();
    };

    if let Some(variants) = fields.get("anyOf").and_then(Value::as_array)
    {
        let inner = variants
            .iter()
            .find(|variant| variant["type"] != "null")
            .cloned()
            .unwrap_or(Value::Null);
        let mut converted = to_gemini_schema(&inner);
        converted["nullable"] = json!(true);
        return converted;
    }

    let mut converted = Map::new();
    for (name, value) in fields
    {
        match name.as_str()
        {
            "additionalProperties" =>
            {}
            "type" =>
            {
                converted.insert(name.clone(), json!(value.as_str().unwrap_or_default().to_uppercase()));
            }
            "properties" =>
            {
                let properties = value
                    .as_object()
                    .into_iter()
                    .flatten()
                    .map(|(key, property)| (key.clone(), to_gemini_schema(property)))
                    .collect();
                converted.insert(name.clone(), Value::Object(properties));
            }
            "items" =>
            {
                converted.insert(name.clone(), to_gemini_schema(value));
            }
            _ =>
            {
                converted.insert(name.clone(), value.clone());
            }
        }
    }
    if let Some(required) = fields.get("required")
    {
        converted.insert("propertyOrdering".into(), required.clone());
    }
    if fields.contains_key("enum")
    {
        converted.insert("format".into(), json!("enum"));
    }

    Value::Object(converted)
}

#[cfg(test)]
mod tests
{
    use super::*;
    use crate::receipt_ai::{label_schema, receipt_schema};

    #[test]
    fn schema_is_converted_to_the_openapi_subset()
    {
        let schema = to_gemini_schema(&receipt_schema());
        let line = &schema["properties"]["lines"]["items"];

        assert_eq!(schema["type"], "OBJECT");
        assert!(schema.get("additionalProperties").is_none());
        assert_eq!(
            schema["properties"]["store_name"],
            json!({ "type": "STRING", "nullable": true })
        );
        assert_eq!(schema["propertyOrdering"][0], "is_receipt");
        assert_eq!(line["properties"]["kind"]["format"], "enum");
        assert_eq!(line["properties"]["unit_price"]["type"], "NUMBER");
        assert_eq!(line["properties"]["unit_price"]["nullable"], true);
        assert!(!schema.to_string().contains("anyOf"));
    }

    #[test]
    fn label_schema_keeps_nullable_enums()
    {
        let schema = to_gemini_schema(&label_schema());

        assert_eq!(schema["properties"]["kind"]["format"], "enum");
        assert_eq!(schema["properties"]["kind"]["nullable"], true);
        assert_eq!(schema["properties"]["kcal"]["type"], "NUMBER");
        assert!(!schema.to_string().contains("anyOf"));
    }

    #[test]
    fn text_skips_thoughts_and_reports_blocks()
    {
        let payload = json!({
            "candidates": [{
                "finishReason": "STOP",
                "content": { "parts": [{ "text": "thinking", "thought": true }, { "text": "{\"a\":" }, { "text": "1}" }] }
            }],
            "usageMetadata": { "promptTokenCount": 1200, "candidatesTokenCount": 300, "thoughtsTokenCount": 200 }
        });
        let (text, usage) = parse_reply(&payload).unwrap();
        assert_eq!(text, "{\"a\":1}");
        assert_eq!(
            usage,
            Usage {
                input_tokens: 1200,
                output_tokens: 500
            }
        );

        let blocked = json!({ "promptFeedback": { "blockReason": "SAFETY" } });
        assert_eq!(parse_reply(&blocked).unwrap_err(), ReadError::Refused);
        let truncated = json!({ "candidates": [{ "finishReason": "MAX_TOKENS", "content": { "parts": [] } }] });
        assert_eq!(parse_reply(&truncated).unwrap_err(), ReadError::Unreadable);
    }

    #[test]
    fn model_list_keeps_generative_gemini_models()
    {
        let payload = json!({ "models": [
            { "name": "models/gemini-2.5-flash", "displayName": "Gemini 2.5 Flash", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-3.8-flash", "displayName": "Gemini 3.8 Flash", "supportedGenerationMethods": ["generateContent", "countTokens"] },
            { "name": "models/gemini-embedding-001", "supportedGenerationMethods": ["embedContent"] },
            { "name": "models/gemini-3.1-pro-preview", "displayName": "Gemini 3.1 Pro Preview", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemini-2.5-flash-preview-tts", "supportedGenerationMethods": ["generateContent"] },
            { "name": "models/gemma-3-27b-it", "supportedGenerationMethods": ["generateContent"] }
        ]});

        let ids: Vec<_> = parse_models(&payload).into_iter().map(|model| model.id).collect();
        assert_eq!(ids, ["gemini-3.8-flash", "gemini-3.1-pro-preview", "gemini-2.5-flash"]);
        assert!(is_stable_flash("gemini-3.8-flash") && !is_stable_pro("gemini-3.1-pro-preview"));
    }

    #[test]
    fn invalid_key_is_recognised_from_error_details()
    {
        let payload = json!({ "error": { "code": 400, "status": "INVALID_ARGUMENT", "details": [{ "reason": "API_KEY_INVALID" }] } });
        assert!(is_key_error(&payload));
        assert!(!is_key_error(
            &json!({ "error": { "code": 400, "status": "INVALID_ARGUMENT" } })
        ));
    }
}
