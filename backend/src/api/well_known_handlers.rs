use axum::extract::State;
use axum::Json;
use serde::Serialize;

use crate::domain::errors::ApiError;
use crate::state::AppState;

const HANDLE_ALL_URLS: &str = "delegate_permission/common.handle_all_urls";
const ANDROID_NAMESPACE: &str = "android_app";

#[derive(Serialize)]
pub struct AssetLinkDto
{
    relation: [&'static str; 1],
    target: AssetTargetDto,
}

#[derive(Serialize)]
pub struct AssetTargetDto
{
    namespace: &'static str,
    package_name: String,
    sha256_cert_fingerprints: Vec<String>,
}

pub async fn asset_links(State(a_state): State<AppState>) -> Result<Json<[AssetLinkDto; 1]>, ApiError>
{
    let links = a_state.cfg.android_links.as_ref().ok_or(ApiError::NotFound)?;
    Ok(Json([AssetLinkDto {
        relation: [HANDLE_ALL_URLS],
        target: AssetTargetDto {
            namespace: ANDROID_NAMESPACE,
            package_name: links.package_name.clone(),
            sha256_cert_fingerprints: links.cert_fingerprints.clone(),
        },
    }]))
}
