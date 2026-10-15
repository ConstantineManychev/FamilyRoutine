pub mod api;
pub mod banking;
pub mod catalog;
pub mod config;
pub mod domain;
pub mod infrastructure;
pub mod receipt_ai;
pub mod security;
pub mod services;
pub mod state;

pub use api::router::build_router;
pub use state::AppState;
