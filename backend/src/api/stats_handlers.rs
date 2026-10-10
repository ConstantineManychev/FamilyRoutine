use std::collections::BTreeMap;

use axum::extract::State;
use axum::Json;
use chrono::{Duration, DurationRound, NaiveDateTime};
use rust_decimal::Decimal;
use shared_schema::{CashflowDto, CashflowPointDto, CashflowQuery, CashflowSeriesDto, StatsBucket};

use crate::api::extract::{ApiQuery, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::money;
use crate::state::AppState;

const MAX_TZ_OFFSET_MIN: i32 = 14 * 60;
const MAX_HOUR_RANGE_DAYS: i64 = 31;
const MAX_DAY_RANGE_DAYS: i64 = 3 * 366;

pub async fn cashflow(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<CashflowQuery>,
) -> Result<Json<CashflowDto>, ApiError>
{
    if a_query.tz_offset_min.abs() > MAX_TZ_OFFSET_MIN
    {
        return Err(ApiError::Validation("tz_offset_min"));
    }

    let (step, unit, max_range) = match a_query.bucket
    {
        StatsBucket::Hour => (Duration::hours(1), "hour", Duration::days(MAX_HOUR_RANGE_DAYS)),
        StatsBucket::Day => (Duration::days(1), "day", Duration::days(MAX_DAY_RANGE_DAYS)),
    };

    if a_query.from >= a_query.to || a_query.to - a_query.from > max_range
    {
        return Err(ApiError::Validation("range"));
    }

    let offset = Duration::minutes(i64::from(a_query.tz_offset_min));

    let rows = sqlx::query!(
        r#"
        SELECT
            c.code AS curr_code,
            date_trunc($2, (t.tx_ts AT TIME ZONE 'UTC') + make_interval(mins => $3)) AS "bucket!",
            SUM(CASE WHEN t.amount > 0 THEN t.amount ELSE 0 END) AS "income!",
            SUM(CASE WHEN t.amount < 0 THEN -t.amount ELSE 0 END) AS "expense!"
        FROM transactions t
        JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $1
        JOIN currencies c ON c.id = t.curr_id
        WHERE t.tx_type <> 'transfer'
          AND t.tx_ts >= $4 AND t.tx_ts < $5
          AND ($6::uuid IS NULL OR t.account_id = $6)
        GROUP BY 1, 2
        ORDER BY 1, 2
        "#,
        a_user.user_id,
        unit,
        a_query.tz_offset_min,
        a_query.from,
        a_query.to,
        a_query.account_id
    )
    .fetch_all(&a_state.db)
    .await?;

    let mut by_currency: BTreeMap<String, BTreeMap<NaiveDateTime, (Decimal, Decimal)>> = BTreeMap::new();
    for row in rows
    {
        by_currency
            .entry(row.curr_code)
            .or_default()
            .insert(row.bucket, (row.income, row.expense));
    }

    let local_from = (a_query.from + offset).naive_utc();
    let local_to = (a_query.to + offset).naive_utc();
    let first_bucket = local_from
        .duration_trunc(step)
        .map_err(|_| ApiError::Validation("range"))?;

    let series = by_currency
        .into_iter()
        .map(|(curr_code, buckets)| {
            let mut points = Vec::new();
            let mut cursor = first_bucket;

            while cursor < local_to
            {
                let (income, expense) = buckets.get(&cursor).copied().unwrap_or_default();
                points.push(CashflowPointDto {
                    ts: (cursor - offset).and_utc(),
                    income: money(income),
                    expense: money(expense),
                });
                cursor += step;
            }

            CashflowSeriesDto {
                income_total: money(points.iter().map(|point| point.income).sum()),
                expense_total: money(points.iter().map(|point| point.expense).sum()),
                curr_code,
                points,
            }
        })
        .collect();

    Ok(Json(CashflowDto {
        bucket: a_query.bucket,
        series,
    }))
}
