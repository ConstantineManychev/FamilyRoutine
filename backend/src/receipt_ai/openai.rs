use reqwest::RequestBuilder;
use serde_json::{json, Value};
use shared_schema::AiModelDto;

use super::{has_date_suffix, is_version, AiTarget, ReadError, ReceiptImage, Usage, VisionTask, MAX_OUTPUT_TOKENS};

const IMAGE_DETAIL: &str = "high";
const CHAT_PREFIX: &str = "gpt-";
const UNSUITABLE_PARTS: [&str; 14] = [
    "audio",
    "realtime",
    "tts",
    "transcribe",
    "search",
    "image",
    "instruct",
    "codex",
    "embedding",
    "moderation",
    "deep-research",
    "computer-use",
    "oss",
    "chat-latest",
];
const LEGACY_PREFIXES: [&str; 2] = ["gpt-3.5", "gpt-4-"];

pub fn read_request(
    a_http: &reqwest::Client,
    a_base: &str,
    a_target: &AiTarget,
    a_image: &ReceiptImage,
    a_task: &VisionTask,
    a_prompt: &str,
) -> RequestBuilder
{
    a_http
        .post(format!("{}/v1/responses", a_base.trim_end_matches('/')))
        .bearer_auth(&a_target.api_key)
        .json(&request_body(&a_target.model, a_image, a_task, a_prompt))
}

pub fn models_request(a_http: &reqwest::Client, a_base: &str, a_api_key: &str) -> RequestBuilder
{
    a_http
        .get(format!("{}/v1/models", a_base.trim_end_matches('/')))
        .bearer_auth(a_api_key)
}

pub fn parse_reply(a_payload: &Value) -> Result<(String, Usage), ReadError>
{
    if a_payload["status"] == "incomplete"
    {
        let reason = a_payload["incomplete_details"]["reason"].as_str().unwrap_or("unknown");
        tracing::warn!("openai response is incomplete: {reason}");
        return Err(
            if reason == "content_filter"
            {
                ReadError::Refused
            }
            else
            {
                ReadError::Unreadable
            },
        );
    }

    let parts: Vec<&Value> = a_payload["output"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|item| item["type"] == "message")
        .flat_map(|item| item["content"].as_array().into_iter().flatten())
        .collect();
    if parts.iter().any(|part| part["type"] == "refusal")
    {
        return Err(ReadError::Refused);
    }

    let text = parts
        .iter()
        .find(|part| part["type"] == "output_text")
        .and_then(|part| part["text"].as_str())
        .ok_or(ReadError::Unreadable)?;
    let usage = Usage {
        input_tokens: a_payload["usage"]["input_tokens"].as_i64().unwrap_or_default(),
        output_tokens: a_payload["usage"]["output_tokens"].as_i64().unwrap_or_default(),
    };

    Ok((text.to_string(), usage))
}

pub fn parse_models(a_payload: &Value) -> Vec<AiModelDto>
{
    let mut models: Vec<(i64, String)> = a_payload["data"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|model| {
            let id = model["id"].as_str()?;
            is_suitable(id).then(|| (model["created"].as_i64().unwrap_or_default(), id.to_string()))
        })
        .collect();
    models.sort_by(|left, right| right.0.cmp(&left.0).then_with(|| right.1.cmp(&left.1)));

    models
        .into_iter()
        .map(|(_, id)| AiModelDto { name: id.clone(), id })
        .collect()
}

pub fn is_flagship(a_model: &str) -> bool
{
    a_model.strip_prefix(CHAT_PREFIX).is_some_and(is_version)
}

pub fn is_flagship_mini(a_model: &str) -> bool
{
    a_model
        .strip_prefix(CHAT_PREFIX)
        .and_then(|rest| rest.strip_suffix("-mini"))
        .is_some_and(is_version)
}

fn is_suitable(a_model: &str) -> bool
{
    let is_chat_family = a_model.starts_with(CHAT_PREFIX)
        || (a_model.starts_with('o') && a_model[1..].starts_with(|chr: char| chr.is_ascii_digit()));

    is_chat_family
        && a_model != "gpt-4"
        && !LEGACY_PREFIXES.iter().any(|prefix| a_model.starts_with(prefix))
        && !UNSUITABLE_PARTS.iter().any(|part| a_model.contains(part))
        && !has_date_suffix(a_model)
}

fn request_body(a_model: &str, a_image: &ReceiptImage, a_task: &VisionTask, a_prompt: &str) -> Value
{
    json!({
        "model": a_model,
        "instructions": a_task.system,
        "input": [{
            "role": "user",
            "content": [
                {
                    "type": "input_image",
                    "image_url": format!("data:{};base64,{}", a_image.media_type, a_image.data_base64),
                    "detail": IMAGE_DETAIL
                },
                { "type": "input_text", "text": a_prompt }
            ]
        }],
        "text": { "format": { "type": "json_schema", "name": a_task.name, "strict": true, "schema": (a_task.schema)() } },
        "max_output_tokens": MAX_OUTPUT_TOKENS,
        "store": false
    })
}

#[cfg(test)]
mod tests
{
    use super::*;
    use crate::receipt_ai::LABEL_TASK;

    #[test]
    fn request_is_stateless_and_strict()
    {
        let image = ReceiptImage {
            media_type: "image/png",
            data_base64: "AAAA".into(),
        };
        let body = request_body("gpt-5.5", &image, &LABEL_TASK, LABEL_TASK.prompt);

        assert_eq!(body["store"], false);
        assert_eq!(body["text"]["format"]["strict"], true);
        assert_eq!(body["text"]["format"]["name"], "label");
        assert_eq!(
            body["input"][0]["content"][0]["image_url"],
            "data:image/png;base64,AAAA"
        );
    }

    #[test]
    fn output_text_is_returned_and_refusals_are_reported()
    {
        let payload = json!({
            "status": "completed",
            "output": [
                { "type": "reasoning", "summary": [] },
                { "type": "message", "content": [{ "type": "output_text", "text": "{}" }] }
            ],
            "usage": { "input_tokens": 900, "output_tokens": 300 }
        });
        let (text, usage) = parse_reply(&payload).unwrap();
        assert_eq!(text, "{}");
        assert_eq!(
            usage,
            Usage {
                input_tokens: 900,
                output_tokens: 300
            }
        );

        let refusal = json!({ "status": "completed", "output": [{ "type": "message", "content": [{ "type": "refusal", "refusal": "no" }] }] });
        assert_eq!(parse_reply(&refusal).unwrap_err(), ReadError::Refused);

        let truncated = json!({ "status": "incomplete", "incomplete_details": { "reason": "max_output_tokens" } });
        assert_eq!(parse_reply(&truncated).unwrap_err(), ReadError::Unreadable);
    }

    #[test]
    fn model_list_keeps_chat_models_newest_first()
    {
        let payload = json!({ "data": [
            { "id": "gpt-4o", "created": 100 },
            { "id": "gpt-5.5-mini", "created": 300 },
            { "id": "gpt-5.5", "created": 300 },
            { "id": "gpt-4o-2024-08-06", "created": 90 },
            { "id": "gpt-realtime", "created": 400 },
            { "id": "text-embedding-3-small", "created": 50 },
            { "id": "o4-mini", "created": 200 },
            { "id": "gpt-3.5-turbo", "created": 10 },
            { "id": "gpt-4", "created": 5 }
        ]});

        let ids: Vec<_> = parse_models(&payload).into_iter().map(|model| model.id).collect();
        assert_eq!(ids, ["gpt-5.5-mini", "gpt-5.5", "o4-mini", "gpt-4o"]);
        assert!(is_flagship("gpt-5.5") && !is_flagship("gpt-5.5-mini") && is_flagship_mini("gpt-5.5-mini"));
    }
}
