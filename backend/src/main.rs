use axum::{
    extract::State,
    http::StatusCode,
    routing::{post, get},
    Json, Router,
};
use sqlx::PgPool;
use argon2::{
    password_hash::{rand_core::OsRng, PasswordHasher, PasswordVerifier, SaltString},
    Argon2, PasswordHash,
};
use serde_json::{json, Value};
use std::net::SocketAddr;
use tower_http::cors::{Any, CorsLayer};

use shared_schema::{UserResponse, CreateUserRequest}; 

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt::init();

    let database_url = std::env::var("DATABASE_URL")
        .expect("DATABASE_URL must be set");

    let pool = PgPool::connect(&database_url)
        .await
        .expect("Failed to connect to Postgres");

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("Failed to run migrations");

    let cors = CorsLayer::new()
        .allow_origin(Any)
        .allow_methods(Any)
        .allow_headers(Any);

    let app = Router::new()
        .route("/api/auth/register", post(register_user))
        .route("/api/auth/login", post(login_user))
        .layer(cors)
        .with_state(pool);

    let addr = SocketAddr::from(([0, 0, 0, 0], 3000));
    tracing::info!("Server listening on {}", addr);
    
    axum::Server::bind(&addr)
        .serve(app.into_make_service())
        .await
        .unwrap();
}

async fn register_user(
    State(pool): State<PgPool>,
    Json(payload): Json<CreateUserRequest>,
) -> Result<(StatusCode, Json<Value>), (StatusCode, Json<Value>)> {
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    let password_hash = argon2
        .hash_password(payload.password.as_bytes(), &salt)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Failed to hash password"}))))?
        .to_string();

    let result = sqlx::query!(
        r#"
        INSERT INTO users (first_name, last_name, email, password_hash, birth_date, username, is_verified)
        VALUES ($1, $2, $3, $4, $5, $3, FALSE)
        RETURNING id, created_at
        "#,
        payload.first_name,
        payload.last_name,
        payload.email,
        password_hash,
        payload.birth_date,
    )
    .fetch_one(&pool)
    .await;

    match result {
        Ok(record) => Ok((StatusCode::CREATED, Json(json!({
            "id": record.id,
            "message": "User registered successfully. Please verify your email."
        })))),
        Err(e) => {
            tracing::error!("Database error: {:?}", e);
            Err((StatusCode::BAD_REQUEST, Json(json!({"error": "User with this email already exists"}))))
        }
    }
}

async fn login_user(
    State(pool): State<PgPool>,
    Json(payload): Json<shared_schema::LoginRequest>,
) -> Result<Json<UserResponse>, (StatusCode, Json<Value>)> {
    let user = sqlx::query!(
        "SELECT id, email, password_hash, first_name, last_name, birth_date, created_at FROM users WHERE email = $1",
        payload.email
    )
    .fetch_optional(&pool)
    .await
    .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Database error"}))))?
    .ok_or((StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))))?;

    let parsed_hash = PasswordHash::new(&user.password_hash)
        .map_err(|_| (StatusCode::INTERNAL_SERVER_ERROR, Json(json!({"error": "Invalid hash format"}))))?;

    Argon2::default()
        .verify_password(payload.password.as_bytes(), &parsed_hash)
        .map_err(|_| (StatusCode::UNAUTHORIZED, Json(json!({"error": "Invalid credentials"}))))?;

    Ok(Json(UserResponse {
        id: user.id,
        username: user.email.clone(),
        email: user.email,
        first_name: user.first_name,
        last_name: user.last_name,
        birth_date: user.birth_date,
        created_at: user.created_at,
    }))
}