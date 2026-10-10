use std::collections::{HashMap, HashSet};

use sqlx::PgPool;
use uuid::Uuid;

use crate::domain::errors::ApiError;

const FX_TOLERANCE: f64 = 0.03;
const MATCH_TIERS: [i32; 4] = [1, 2, 3, 4];

struct Candidate
{
    out_id: Uuid,
    in_id: Uuid,
    tier: i32,
}

pub async fn match_transfers(a_db: &PgPool, a_user_id: Uuid) -> Result<u64, ApiError>
{
    let mut tx = a_db.begin().await?;

    sqlx::query!(
        "SELECT pg_advisory_xact_lock(hashtext($1::text))",
        a_user_id.to_string()
    )
    .execute(&mut *tx)
    .await?;

    let candidates = sqlx::query_as!(
        Candidate,
        r#"
        WITH cand AS MATERIALIZED (
            SELECT t.id, t.account_id, t.amount, t.curr_id, t.op_amount, t.op_curr_id, t.tx_ts,
                   t.category IN ('transfer', 'cash') OR t.source = 'manual' AS is_transfer_like,
                   t.category IS NULL OR t.category IN ('transfer', 'cash', 'income', 'other') AS is_neutral
            FROM transactions t
            JOIN accounts a ON a.id = t.account_id
            WHERE a.user_id = $1
              AND t.transfer_id IS NULL
              AND t.receipt_id IS NULL
              AND NOT t.is_match_blocked
              AND NOT t.is_pending
              AND t.source <> 'receipt_cash'
        ),
        pairs AS (
            SELECT
                o.id AS out_id,
                i.id AS in_id,
                CASE
                    WHEN i.curr_id <> o.curr_id
                     AND ((o.op_curr_id = i.curr_id AND o.op_amount = -i.amount)
                       OR (i.op_curr_id = o.curr_id AND i.op_amount = -o.amount))
                        THEN 1
                    WHEN i.curr_id = o.curr_id AND i.amount = -o.amount AND o.is_transfer_like AND i.is_transfer_like
                        THEN 2
                    WHEN i.curr_id = o.curr_id AND i.amount = -o.amount AND (o.is_transfer_like OR i.is_transfer_like)
                        THEN 3
                    WHEN i.curr_id <> o.curr_id
                     AND o.is_transfer_like AND i.is_transfer_like
                     AND i.tx_ts <= o.tx_ts + INTERVAL '2 days'
                     AND ABS(-o.amount * uah_rate(o.curr_id, o.tx_ts::date) - i.amount * uah_rate(i.curr_id, o.tx_ts::date))
                         <= $2::float8::numeric * i.amount * uah_rate(i.curr_id, o.tx_ts::date)
                        THEN 4
                END AS tier
            FROM cand o
            JOIN cand i
              ON i.account_id <> o.account_id
             AND o.amount < 0
             AND i.amount > 0
             AND o.is_neutral
             AND i.is_neutral
             AND i.tx_ts BETWEEN o.tx_ts - INTERVAL '1 day' AND o.tx_ts + INTERVAL '5 days'
        )
        SELECT out_id AS "out_id!", in_id AS "in_id!", tier AS "tier!"
        FROM pairs
        WHERE tier IS NOT NULL
        "#,
        a_user_id,
        FX_TOLERANCE
    )
    .fetch_all(&mut *tx)
    .await?;

    let (out_ids, in_ids): (Vec<Uuid>, Vec<Uuid>) = choose_pairs(&candidates).into_iter().unzip();

    if out_ids.is_empty()
    {
        tx.commit().await?;
        return Ok(0);
    }

    sqlx::query!(
        r#"
        WITH chosen AS MATERIALIZED (
            SELECT out_id, in_id, uuid_generate_v4() AS transfer_id
            FROM UNNEST($1::uuid[], $2::uuid[]) AS c(out_id, in_id)
        ),
        legs AS (
            SELECT out_id AS id, transfer_id FROM chosen
            UNION ALL
            SELECT in_id AS id, transfer_id FROM chosen
        )
        UPDATE transactions t
        SET transfer_id = legs.transfer_id, tx_type = 'transfer', is_auto_transfer = TRUE
        FROM legs
        WHERE t.id = legs.id
        "#,
        &out_ids,
        &in_ids
    )
    .execute(&mut *tx)
    .await?;

    tx.commit().await?;
    Ok(out_ids.len() as u64)
}

pub async fn match_all(a_db: &PgPool) -> Result<u64, ApiError>
{
    let users = sqlx::query_scalar!(
        r#"
        SELECT a.user_id AS "user_id!"
        FROM accounts a
        WHERE a.user_id IS NOT NULL
        GROUP BY a.user_id
        HAVING COUNT(*) > 1
        "#
    )
    .fetch_all(a_db)
    .await?;

    let mut total = 0;
    for user_id in users
    {
        total += match_transfers(a_db, user_id).await?;
    }

    Ok(total)
}

fn choose_pairs(a_candidates: &[Candidate]) -> Vec<(Uuid, Uuid)>
{
    let mut used: HashSet<Uuid> = HashSet::new();
    let mut chosen = Vec::new();

    for tier in MATCH_TIERS
    {
        let open: Vec<&Candidate> = a_candidates
            .iter()
            .filter(|pair| pair.tier == tier && !used.contains(&pair.out_id) && !used.contains(&pair.in_id))
            .collect();

        let mut out_counts: HashMap<Uuid, usize> = HashMap::new();
        let mut in_counts: HashMap<Uuid, usize> = HashMap::new();
        for pair in &open
        {
            *out_counts.entry(pair.out_id).or_default() += 1;
            *in_counts.entry(pair.in_id).or_default() += 1;
        }

        for pair in open
        {
            if out_counts[&pair.out_id] == 1 && in_counts[&pair.in_id] == 1
            {
                used.insert(pair.out_id);
                used.insert(pair.in_id);
                chosen.push((pair.out_id, pair.in_id));
            }
        }
    }

    chosen
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn pair(a_out: u128, a_in: u128, a_tier: i32) -> Candidate
    {
        Candidate {
            out_id: Uuid::from_u128(a_out),
            in_id: Uuid::from_u128(a_in),
            tier: a_tier,
        }
    }

    #[test]
    fn stronger_tiers_win_and_ambiguity_is_skipped()
    {
        let chosen = choose_pairs(&[
            pair(1, 10, 1),
            pair(1, 11, 2),
            pair(2, 11, 2),
            pair(3, 12, 3),
            pair(3, 13, 3),
            pair(4, 14, 4),
        ]);

        assert_eq!(
            chosen,
            vec![
                (Uuid::from_u128(1), Uuid::from_u128(10)),
                (Uuid::from_u128(2), Uuid::from_u128(11)),
                (Uuid::from_u128(4), Uuid::from_u128(14)),
            ]
        );
    }
}
