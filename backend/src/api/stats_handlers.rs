use std::collections::{BTreeMap, BTreeSet, HashMap};

use axum::extract::State;
use axum::Json;
use chrono::{DateTime, Duration, DurationRound, NaiveDate, NaiveDateTime, Utc};
use rust_decimal::Decimal;
use shared_schema::{
    CashflowDto, CashflowPointDto, CashflowQuery, CashflowSeriesDto, CategoryAmountDto, CategoryQuery,
    CategorySeriesDto, CategoryStatsDto, FlowMode, StatsBucket, TxCategory,
};
use uuid::Uuid;

use crate::api::extract::{ApiQuery, AuthUser};
use crate::domain::errors::ApiError;
use crate::domain::validation::money;
use crate::state::AppState;

const MAX_TZ_OFFSET_MIN: i32 = 14 * 60;
const MAX_HOUR_RANGE_DAYS: i64 = 31;
const MAX_DAY_RANGE_DAYS: i64 = 3 * 366;

struct Target
{
    id: Uuid,
    code: String,
}

struct Converter
{
    target: Option<Target>,
    missing: BTreeSet<String>,
}

impl Converter
{
    fn output_code(&self, a_curr_code: &str) -> String
    {
        self.target
            .as_ref()
            .map_or_else(|| a_curr_code.to_string(), |target| target.code.clone())
    }

    fn convert(
        &mut self,
        a_amount: Decimal,
        a_curr_code: &str,
        a_src_rate: Option<Decimal>,
        a_dst_rate: Option<Decimal>,
    ) -> Option<Decimal>
    {
        let Some(target) = &self.target
        else
        {
            return Some(a_amount);
        };

        if a_curr_code == target.code
        {
            return Some(a_amount);
        }

        match (a_src_rate, a_dst_rate)
        {
            (Some(src), Some(dst)) if !dst.is_zero() => Some(a_amount * src / dst),
            _ =>
            {
                self.missing.insert(a_curr_code.to_string());
                None
            }
        }
    }
}

pub async fn cashflow(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<CashflowQuery>,
) -> Result<Json<CashflowDto>, ApiError>
{
    check_tz(a_query.tz_offset_min)?;

    let (step, unit, max_range) = match a_query.bucket
    {
        StatsBucket::Hour => (Duration::hours(1), "hour", Duration::days(MAX_HOUR_RANGE_DAYS)),
        StatsBucket::Day => (Duration::days(1), "day", Duration::days(MAX_DAY_RANGE_DAYS)),
    };
    check_range(a_query.from, a_query.to, max_range)?;

    let mut converter = converter(&a_state, a_query.convert_to.as_deref()).await?;
    let target_id = converter.target.as_ref().map(|target| target.id);
    let offset = Duration::minutes(i64::from(a_query.tz_offset_min));

    let rows = sqlx::query!(
        r#"
        WITH flows AS (
            SELECT
                t.curr_id,
                date_trunc($2, (t.tx_ts AT TIME ZONE 'UTC') + make_interval(mins => $3)) AS bucket,
                SUM(CASE WHEN t.amount > 0 THEN t.amount ELSE 0 END) AS income,
                SUM(CASE WHEN t.amount < 0 THEN -t.amount ELSE 0 END) AS expense
            FROM transactions t
            JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $1
            WHERE t.tx_ts >= $4 AND t.tx_ts < $5
              AND ($6::uuid IS NULL OR t.account_id = $6)
              AND ($7 OR (t.tx_type <> 'transfer' AND NOT (t.source = 'bank' AND t.category = 'cash')))
            GROUP BY 1, 2
        )
        SELECT
            c.code AS curr_code,
            f.bucket AS "bucket!",
            f.income AS "income!",
            f.expense AS "expense!",
            uah_rate(f.curr_id, f.bucket::date) AS src_rate,
            uah_rate($8, f.bucket::date) AS dst_rate
        FROM flows f
        JOIN currencies c ON c.id = f.curr_id
        ORDER BY 1, 2
        "#,
        a_user.user_id,
        unit,
        a_query.tz_offset_min,
        a_query.from,
        a_query.to,
        a_query.account_id,
        a_query.mode == FlowMode::Turnover,
        target_id
    )
    .fetch_all(&a_state.db)
    .await?;

    let mut by_currency: BTreeMap<String, BTreeMap<NaiveDateTime, (Decimal, Decimal)>> = BTreeMap::new();
    for row in rows
    {
        let income = converter.convert(row.income, &row.curr_code, row.src_rate, row.dst_rate);
        let expense = converter.convert(row.expense, &row.curr_code, row.src_rate, row.dst_rate);
        let (Some(income), Some(expense)) = (income, expense)
        else
        {
            continue;
        };

        let slot = by_currency
            .entry(converter.output_code(&row.curr_code))
            .or_default()
            .entry(row.bucket)
            .or_default();
        slot.0 += income;
        slot.1 += expense;
    }

    if let Some(target) = &converter.target
    {
        by_currency.entry(target.code.clone()).or_default();
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
        missing_rates: converter.missing.into_iter().collect(),
    }))
}

pub async fn categories(
    State(a_state): State<AppState>,
    a_user: AuthUser,
    ApiQuery(a_query): ApiQuery<CategoryQuery>,
) -> Result<Json<CategoryStatsDto>, ApiError>
{
    check_tz(a_query.tz_offset_min)?;
    check_range(a_query.from, a_query.to, Duration::days(MAX_DAY_RANGE_DAYS))?;

    let mut converter = converter(&a_state, a_query.convert_to.as_deref()).await?;
    let target_id = converter.target.as_ref().map(|target| target.id);

    let rows = sqlx::query!(
        r#"
        WITH flows AS (
            SELECT
                t.curr_id,
                t.category,
                ((t.tx_ts AT TIME ZONE 'UTC') + make_interval(mins => $2))::date AS day,
                SUM(CASE WHEN t.amount > 0 THEN t.amount ELSE 0 END) AS income,
                SUM(CASE WHEN t.amount < 0 THEN -t.amount ELSE 0 END) AS expense,
                COUNT(*) AS tx_count
            FROM transactions t
            JOIN account_viewers v ON v.account_id = t.account_id AND v.viewer_id = $1
            WHERE t.tx_ts >= $3 AND t.tx_ts < $4
              AND ($5::uuid IS NULL OR t.account_id = $5)
              AND ($6 OR (t.tx_type <> 'transfer' AND NOT (t.source = 'bank' AND t.category = 'cash')))
            GROUP BY 1, 2, 3
        )
        SELECT
            c.code AS curr_code,
            f.category AS "category: TxCategory",
            f.day AS "day!: NaiveDate",
            f.income AS "income!",
            f.expense AS "expense!",
            f.tx_count AS "tx_count!",
            uah_rate(f.curr_id, f.day) AS src_rate,
            uah_rate($7, f.day) AS dst_rate
        FROM flows f
        JOIN currencies c ON c.id = f.curr_id
        "#,
        a_user.user_id,
        a_query.tz_offset_min,
        a_query.from,
        a_query.to,
        a_query.account_id,
        a_query.mode == FlowMode::Turnover,
        target_id
    )
    .fetch_all(&a_state.db)
    .await?;

    let mut by_currency: BTreeMap<String, HashMap<Option<TxCategory>, CategoryAmountDto>> = BTreeMap::new();
    for row in rows
    {
        let income = converter.convert(row.income, &row.curr_code, row.src_rate, row.dst_rate);
        let expense = converter.convert(row.expense, &row.curr_code, row.src_rate, row.dst_rate);
        let (Some(income), Some(expense)) = (income, expense)
        else
        {
            continue;
        };

        let item = by_currency
            .entry(converter.output_code(&row.curr_code))
            .or_default()
            .entry(row.category)
            .or_insert_with(|| CategoryAmountDto {
                category: row.category,
                income: Decimal::ZERO,
                expense: Decimal::ZERO,
                tx_count: 0,
            });
        item.income += income;
        item.expense += expense;
        item.tx_count += row.tx_count;
    }

    let series = by_currency
        .into_iter()
        .map(|(curr_code, items)| {
            let mut items: Vec<CategoryAmountDto> = items
                .into_values()
                .map(|item| CategoryAmountDto {
                    income: money(item.income),
                    expense: money(item.expense),
                    ..item
                })
                .collect();
            items.sort_by(|left, right| {
                right
                    .expense
                    .cmp(&left.expense)
                    .then(right.income.cmp(&left.income))
                    .then_with(|| format!("{:?}", left.category).cmp(&format!("{:?}", right.category)))
            });

            CategorySeriesDto {
                income_total: money(items.iter().map(|item| item.income).sum()),
                expense_total: money(items.iter().map(|item| item.expense).sum()),
                curr_code,
                items,
            }
        })
        .collect();

    Ok(Json(CategoryStatsDto {
        series,
        missing_rates: converter.missing.into_iter().collect(),
    }))
}

async fn converter(a_state: &AppState, a_convert_to: Option<&str>) -> Result<Converter, ApiError>
{
    let target = match a_convert_to.map(str::trim).filter(|code| !code.is_empty())
    {
        Some(code) =>
        {
            let code = code.to_ascii_uppercase();
            let id = sqlx::query_scalar!("SELECT id FROM currencies WHERE code = $1", code)
                .fetch_optional(&a_state.db)
                .await?
                .ok_or(ApiError::Validation("convert_to"))?;
            Some(Target { id, code })
        }
        None => None,
    };

    Ok(Converter {
        target,
        missing: BTreeSet::new(),
    })
}

fn check_tz(a_tz_offset_min: i32) -> Result<(), ApiError>
{
    if a_tz_offset_min.abs() > MAX_TZ_OFFSET_MIN
    {
        return Err(ApiError::Validation("tz_offset_min"));
    }
    Ok(())
}

fn check_range(a_from: DateTime<Utc>, a_to: DateTime<Utc>, a_max: Duration) -> Result<(), ApiError>
{
    if a_from >= a_to || a_to - a_from > a_max
    {
        return Err(ApiError::Validation("range"));
    }
    Ok(())
}
