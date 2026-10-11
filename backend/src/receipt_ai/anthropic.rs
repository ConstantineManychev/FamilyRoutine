use reqwest::RequestBuilder;
use serde_json::{json, Value};
use shared_schema::AiModelDto;

use super::{receipt_schema, AiTarget, ReadError, ReceiptImage, Usage, MAX_OUTPUT_TOKENS, SYSTEM_PROMPT, USER_PROMPT};

const API_VERSION: &str = "2023-06-01";
const FALLBACK_BETA: &str = "server-side-fallback-2026-07-01";
const EFFORT: &str = "medium";
const PREFERRED_MODEL: &str = "claude-opus-5-5";
const MODELS_PAGE_SIZE: u32 = 100;
const CURRENT_FAMILIES: [&str; 4] = ["claude-opus-5", "claude-sonnet-5", "claude-haiku-5", "claude-fable-5"];
const LEGACY_PREFIXES: [&str; 3] = ["claude-2", "claude-instant", "claude-3"];

pub fn read_request(
    a_http: &reqwest::Client,
    a_base: &str,
    a_target: &AiTarget,
    a_image: &ReceiptImage,
) -> RequestBuilder
{
    let mut request = a_http
        .post(format!("{}/v1/messages", a_base.trim_end_matches('/')))
        .header("x-api-key", &a_target.api_key)
        .header("anthropic-version", API_VERSION)
        .json(&request_body(&a_target.model, a_image));
    if is_fallback_supported(&a_target.model)
    {
        request = request.header("anthropic-beta", FALLBACK_BETA);
    }
    request
}

pub fn models_request(a_http: &reqwest::Client, a_base: &str, a_api_key: &str) -> RequestBuilder
{
    a_http
        .get(format!(
            "{}/v1/models?limit={MODELS_PAGE_SIZE}",
            a_base.trim_end_matches('/')
        ))
        .header("x-api-key", a_api_key)
        .header("anthropic-version", API_VERSION)
}

pub fn parse_reply(a_payload: &Value) -> Result<(String, Usage), ReadError>
{
    match a_payload["stop_reason"].as_str()
    {
        Some("refusal") => return Err(ReadError::Refused),
        Some("max_tokens") =>
        {
            tracing::warn!("anthropic output hit max_tokens");
            return Err(ReadError::Unreadable);
        }
        _ =>
        {}
    }

    let text = a_payload["content"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|block| block["type"] == "text")
        .and_then(|block| block["text"].as_str())
        .ok_or(ReadError::Unreadable)?;
    let usage = Usage {
        input_tokens: a_payload["usage"]["input_tokens"].as_i64().unwrap_or_default(),
        output_tokens: a_payload["usage"]["output_tokens"].as_i64().unwrap_or_default(),
    };

    Ok((text.to_string(), usage))
}

pub fn parse_models(a_payload: &Value) -> Vec<AiModelDto>
{
    a_payload["data"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|model| {
            let id = model["id"].as_str()?;
            let is_legacy = LEGACY_PREFIXES.iter().any(|prefix| id.starts_with(prefix));
            (!is_legacy).then(|| AiModelDto {
                id: id.to_string(),
                name: model["display_name"].as_str().unwrap_or(id).to_string(),
            })
        })
        .collect()
}

pub fn is_preferred(a_model: &str) -> bool
{
    a_model == PREFERRED_MODEL
}

fn is_current_generation(a_model: &str) -> bool
{
    CURRENT_FAMILIES.iter().any(|family| a_model.starts_with(family))
}

fn is_fallback_supported(a_model: &str) -> bool
{
    is_current_generation(a_model) && !a_model.starts_with("claude-haiku")
}

fn request_body(a_model: &str, a_image: &ReceiptImage) -> Value
{
    let mut output_config = json!({ "format": { "type": "json_schema", "schema": receipt_schema() } });
    if is_current_generation(a_model)
    {
        output_config["effort"] = json!(EFFORT);
    }

    let mut body = json!({
        "model": a_model,
        "max_tokens": MAX_OUTPUT_TOKENS,
        "system": SYSTEM_PROMPT,
        "output_config": output_config,
        "messages": [{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": { "type": "base64", "media_type": a_image.media_type, "data": a_image.data_base64 }
                },
                { "type": "text", "text": USER_PROMPT }
            ]
        }]
    });
    if is_fallback_supported(a_model)
    {
        body["fallbacks"] = json!("default");
    }
    body
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn image() -> ReceiptImage
    {
        ReceiptImage {
            media_type: "image/jpeg",
            data_base64: "AAAA".into(),
        }
    }

    #[test]
    fn refusals_and_truncated_outputs_are_reported()
    {
        assert_eq!(
            parse_reply(&json!({ "stop_reason": "refusal", "content": [] })).unwrap_err(),
            ReadError::Refused
        );
        assert_eq!(
            parse_reply(&json!({ "stop_reason": "max_tokens", "content": [] })).unwrap_err(),
            ReadError::Unreadable
        );
    }

    #[test]
    fn text_block_after_thinking_is_returned_with_usage()
    {
        let payload = json!({
            "stop_reason": "end_turn",
            "content": [{ "type": "thinking", "thinking": "" }, { "type": "text", "text": "{}" }],
            "usage": { "input_tokens": 1500, "output_tokens": 400 }
        });

        let (text, usage) = parse_reply(&payload).unwrap();
        assert_eq!(text, "{}");
        assert_eq!(usage.input_tokens, 1500);
        assert_eq!(usage.output_tokens, 400);
    }

    #[test]
    fn current_models_get_effort_and_fallbacks_older_ones_do_not()
    {
        let opus = request_body("claude-opus-5-5", &image());
        assert_eq!(opus["fallbacks"], "default");
        assert_eq!(opus["output_config"]["effort"], "medium");
        assert_eq!(opus["messages"][0]["content"][0]["source"]["media_type"], "image/jpeg");

        let haiku = request_body("claude-haiku-5-5", &image());
        assert!(haiku.get("fallbacks").is_none());
        assert_eq!(haiku["output_config"]["effort"], "medium");

        let sonnet_four = request_body("claude-sonnet-4-5", &image());
        assert!(sonnet_four.get("fallbacks").is_none());
        assert!(sonnet_four["output_config"].get("effort").is_none());
        assert_eq!(sonnet_four["output_config"]["format"]["type"], "json_schema");
    }

    #[test]
    fn model_list_hides_legacy_models()
    {
        let payload = json!({ "data": [
            { "id": "claude-opus-5-5", "display_name": "Claude Opus 5.5" },
            { "id": "claude-sonnet-4-5-20250929", "display_name": "Claude Sonnet 4.5" },
            { "id": "claude-3-5-haiku-latest", "display_name": "Claude Haiku 3.5" },
            { "id": "claude-haiku-5-5", "display_name": "Claude Haiku 5.5" }
        ]});

        let ids: Vec<_> = parse_models(&payload).into_iter().map(|model| model.id).collect();
        assert_eq!(
            ids,
            ["claude-opus-5-5", "claude-sonnet-4-5-20250929", "claude-haiku-5-5"]
        );
    }
}
