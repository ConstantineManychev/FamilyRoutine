use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "ai_provider_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum AiProvider
{
    Anthropic,
    Openai,
    Gemini,
}

impl AiProvider
{
    pub const ALL: [AiProvider; 3] = [AiProvider::Anthropic, AiProvider::Openai, AiProvider::Gemini];

    pub fn as_str(self) -> &'static str
    {
        match self
        {
            AiProvider::Anthropic => "anthropic",
            AiProvider::Openai => "openai",
            AiProvider::Gemini => "gemini",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, sqlx::Type)]
#[sqlx(type_name = "ai_source_t", rename_all = "snake_case")]
#[serde(rename_all = "snake_case")]
pub enum AiSource
{
    Off,
    Server,
    Anthropic,
    Openai,
    Gemini,
}

impl AiSource
{
    pub fn own_provider(self) -> Option<AiProvider>
    {
        match self
        {
            AiSource::Anthropic => Some(AiProvider::Anthropic),
            AiSource::Openai => Some(AiProvider::Openai),
            AiSource::Gemini => Some(AiProvider::Gemini),
            AiSource::Off | AiSource::Server => None,
        }
    }
}

impl From<AiProvider> for AiSource
{
    fn from(a_provider: AiProvider) -> Self
    {
        match a_provider
        {
            AiProvider::Anthropic => AiSource::Anthropic,
            AiProvider::Openai => AiSource::Openai,
            AiProvider::Gemini => AiSource::Gemini,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct AiKeyDto
{
    pub provider: AiProvider,
    pub key_hint: String,
    pub model: String,
    pub updated_ts: DateTime<Utc>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AiModelDto
{
    pub id: String,
    pub name: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct AiKeySavedDto
{
    pub key: AiKeyDto,
    pub models: Vec<AiModelDto>,
}

#[derive(Debug, Clone, Serialize)]
pub struct AiServerDto
{
    pub provider: AiProvider,
    pub model: String,
    pub daily_limit: i32,
    pub monthly_limit: i32,
}

#[derive(Debug, Clone, Serialize)]
pub struct AiUsageDto
{
    pub is_own_key: bool,
    pub today_count: i64,
    pub month_count: i64,
    pub month_input_tokens: i64,
    pub month_output_tokens: i64,
}

#[derive(Debug, Clone, Serialize)]
pub struct AiSettingsDto
{
    pub source: AiSource,
    pub daily_limit: Option<i32>,
    pub monthly_limit: Option<i32>,
    pub effective_daily_limit: i32,
    pub effective_monthly_limit: i32,
    pub server: Option<AiServerDto>,
    pub is_own_keys_allowed: bool,
    pub keys: Vec<AiKeyDto>,
    pub usage: Vec<AiUsageDto>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveAiSettingsRequest
{
    pub source: AiSource,
    #[serde(default)]
    pub daily_limit: Option<i32>,
    #[serde(default)]
    pub monthly_limit: Option<i32>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SaveAiKeyRequest
{
    pub api_key: String,
    #[serde(default)]
    pub model: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct SetAiModelRequest
{
    pub model: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct FeaturesDto
{
    pub is_receipt_recognition: bool,
    pub recognition_provider: Option<AiProvider>,
}
