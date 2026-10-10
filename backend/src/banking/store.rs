use std::collections::hash_map::Entry;
use std::collections::HashMap;

use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use shared_schema::{AccountType, BankType, TxCategory, TxType};
use sqlx::{PgConnection, PgPool};
use uuid::Uuid;

use crate::banking::{categories, clean_text, BankAccount, BankTx};
use crate::domain::errors::ApiError;

const MERCHANT_PREFIXES: &[&str] = &["VDP-", "VDC-", "VDA-", "POS ", "POS-", "D/D ", "BOI-"];
const RECATEGORIZE_BATCH: i64 = 500;
const NO_RULE_KEY: &str = "";

pub struct LinkedAccount
{
    pub id: Uuid,
    pub ext_id: String,
    pub curr_id: Uuid,
    pub curr_code: String,
    pub history_from_ts: Option<DateTime<Utc>>,
    pub is_history_done: bool,
    pub latest_tx_ts: Option<DateTime<Utc>>,
}

pub async fn currency_id(a_conn: &mut PgConnection, a_code: &str) -> Result<Uuid, ApiError>
{
    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO currencies (code) VALUES ($1)
        ON CONFLICT (code) DO UPDATE SET code = EXCLUDED.code
        RETURNING id
        "#,
        a_code
    )
    .fetch_one(&mut *a_conn)
    .await?;

    Ok(id)
}

pub async fn upsert_accounts(
    a_db: &PgPool,
    a_conn_id: Uuid,
    a_owner_id: Uuid,
    a_bank_type: BankType,
    a_accounts: &[BankAccount],
) -> Result<(), ApiError>
{
    let mut tx = a_db.begin().await?;

    for account in a_accounts
    {
        let curr_id = currency_id(&mut tx, &account.curr_code).await?;
        let account_type = if account.is_card
        {
            AccountType::Card
        }
        else
        {
            AccountType::BankAcc
        };

        sqlx::query!(
            r#"
            INSERT INTO accounts (
                user_id, curr_id, account_type, bank_type, name, mask, conn_id, ext_acc_id, balance, balance_ts,
                created_by
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, CASE WHEN $9::numeric IS NULL THEN NULL ELSE NOW() END, $1)
            ON CONFLICT (conn_id, ext_acc_id) WHERE conn_id IS NOT NULL DO UPDATE SET
                balance = COALESCE(EXCLUDED.balance, accounts.balance),
                balance_ts = COALESCE(EXCLUDED.balance_ts, accounts.balance_ts),
                mask = COALESCE(accounts.mask, EXCLUDED.mask)
            "#,
            a_owner_id,
            curr_id,
            account_type as AccountType,
            a_bank_type as BankType,
            account.name,
            account.mask,
            a_conn_id,
            account.ext_id,
            account.balance
        )
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

pub async fn linked_accounts(a_db: &PgPool, a_conn_id: Uuid) -> Result<Vec<LinkedAccount>, ApiError>
{
    let accounts = sqlx::query_as!(
        LinkedAccount,
        r#"
        SELECT
            a.id,
            a.ext_acc_id AS "ext_id!",
            a.curr_id,
            c.code AS curr_code,
            a.history_from_ts,
            a.is_history_done,
            (SELECT MAX(t.tx_ts) FROM transactions t WHERE t.account_id = a.id AND t.source = 'bank') AS latest_tx_ts
        FROM accounts a
        JOIN currencies c ON c.id = a.curr_id
        WHERE a.conn_id = $1 AND a.is_active AND a.ext_acc_id IS NOT NULL
        ORDER BY a.created_ts
        "#,
        a_conn_id
    )
    .fetch_all(a_db)
    .await?;

    Ok(accounts)
}

pub async fn set_balance(a_db: &PgPool, a_account_id: Uuid, a_balance: Decimal) -> Result<(), ApiError>
{
    sqlx::query!(
        "UPDATE accounts SET balance = $2, balance_ts = NOW() WHERE id = $1",
        a_account_id,
        a_balance
    )
    .execute(a_db)
    .await?;

    Ok(())
}

pub async fn set_history(
    a_db: &PgPool,
    a_account_id: Uuid,
    a_from_ts: Option<DateTime<Utc>>,
    a_is_done: bool,
) -> Result<(), ApiError>
{
    sqlx::query!(
        r#"
        UPDATE accounts
        SET history_from_ts = COALESCE($2, history_from_ts), is_history_done = $3, last_sync_ts = NOW()
        WHERE id = $1
        "#,
        a_account_id,
        a_from_ts,
        a_is_done
    )
    .execute(a_db)
    .await?;

    Ok(())
}

pub async fn store_transactions(
    a_db: &PgPool,
    a_account: &LinkedAccount,
    a_owner_id: Uuid,
    a_txs: &[BankTx],
) -> Result<(), ApiError>
{
    if a_txs.is_empty()
    {
        return Ok(());
    }

    let mut tx = a_db.begin().await?;
    let rules = category_rules(&mut tx, a_owner_id).await?;

    for bank_tx in a_txs
    {
        let op_curr_id = match bank_tx.op_curr_code.as_deref()
        {
            Some(code) => Some(currency_id(&mut tx, code).await?),
            None => None,
        };

        let text = tx_text(bank_tx.description.as_deref(), bank_tx.counterparty.as_deref());
        let key = rule_key(bank_tx.counterparty.as_deref(), bank_tx.description.as_deref());
        let category = rules
            .get(&key)
            .copied()
            .unwrap_or_else(|| categories::detect(bank_tx.mcc, bank_tx.amount, &text));

        let merchant_id = if categories::is_merchant_payment(bank_tx.mcc, bank_tx.amount, &text)
        {
            let raw_name = bank_tx.counterparty.as_deref().or(bank_tx.description.as_deref());
            match raw_name.and_then(merchant_name)
            {
                Some(name) => Some(merchant_id(&mut tx, &name, bank_tx.mcc).await?),
                None => None,
            }
        }
        else
        {
            None
        };

        let tx_type = if bank_tx.amount > Decimal::ZERO
        {
            TxType::Income
        }
        else
        {
            TxType::Expense
        };

        sqlx::query!(
            r#"
            INSERT INTO transactions (
                user_id, account_id, curr_id, amount, tx_type, tx_ts, ext_id, source, description, counterparty, mcc,
                category, merchant_id, op_amount, op_curr_id, balance_after, is_pending, rule_key
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, 'bank', $8, $9, $10, $11, $12, $13, $14, $15, $16, $17)
            ON CONFLICT (account_id, ext_id) WHERE ext_id IS NOT NULL DO UPDATE SET
                amount = EXCLUDED.amount,
                tx_ts = EXCLUDED.tx_ts,
                description = EXCLUDED.description,
                counterparty = EXCLUDED.counterparty,
                mcc = EXCLUDED.mcc,
                op_amount = EXCLUDED.op_amount,
                op_curr_id = EXCLUDED.op_curr_id,
                balance_after = EXCLUDED.balance_after,
                is_pending = EXCLUDED.is_pending,
                merchant_id = COALESCE(transactions.merchant_id, EXCLUDED.merchant_id),
                rule_key = EXCLUDED.rule_key,
                category = CASE WHEN transactions.is_category_locked THEN transactions.category ELSE EXCLUDED.category END,
                tx_type = CASE WHEN transactions.transfer_id IS NULL THEN EXCLUDED.tx_type ELSE transactions.tx_type END
            "#,
            a_owner_id,
            a_account.id,
            a_account.curr_id,
            bank_tx.amount,
            tx_type as TxType,
            bank_tx.tx_ts,
            bank_tx.ext_id,
            bank_tx.description,
            bank_tx.counterparty,
            bank_tx.mcc,
            category as shared_schema::TxCategory,
            merchant_id,
            bank_tx.op_amount,
            op_curr_id,
            bank_tx.balance_after,
            bank_tx.is_pending,
            key
        )
        .execute(&mut *tx)
        .await?;
    }

    tx.commit().await?;
    Ok(())
}

pub async fn recategorize_pending(a_db: &PgPool) -> Result<u64, ApiError>
{
    let mut rules_by_owner: HashMap<Uuid, HashMap<String, TxCategory>> = HashMap::new();
    let mut processed = 0;

    loop
    {
        let rows = sqlx::query!(
            r#"
            SELECT t.id, t.amount, t.mcc, t.description, t.counterparty, t.is_category_locked,
                   COALESCE(a.user_id, t.user_id) AS "owner_id!"
            FROM transactions t
            JOIN accounts a ON a.id = t.account_id
            WHERE t.source = 'bank' AND t.rule_key IS NULL
            ORDER BY t.id
            LIMIT $1
            "#,
            RECATEGORIZE_BATCH
        )
        .fetch_all(a_db)
        .await?;

        if rows.is_empty()
        {
            return Ok(processed);
        }

        let mut tx = a_db.begin().await?;
        for row in &rows
        {
            if let Entry::Vacant(slot) = rules_by_owner.entry(row.owner_id)
            {
                slot.insert(category_rules(&mut tx, row.owner_id).await?);
            }

            let key = rule_key(row.counterparty.as_deref(), row.description.as_deref());
            let text = tx_text(row.description.as_deref(), row.counterparty.as_deref());
            let category = rules_by_owner
                .get(&row.owner_id)
                .and_then(|rules| rules.get(&key).copied())
                .unwrap_or_else(|| categories::detect(row.mcc, row.amount, &text));

            sqlx::query!(
                r#"
                UPDATE transactions
                SET rule_key = $2,
                    category = CASE WHEN is_category_locked THEN category ELSE $3 END
                WHERE id = $1
                "#,
                row.id,
                key,
                category as TxCategory
            )
            .execute(&mut *tx)
            .await?;
        }
        tx.commit().await?;

        processed += rows.len() as u64;
    }
}

pub fn rule_key(a_counterparty: Option<&str>, a_description: Option<&str>) -> String
{
    a_counterparty
        .or(a_description)
        .and_then(merchant_name)
        .map(|name| {
            merchant_key(&name)
                .split(' ')
                .filter(|word| !word.chars().all(|ch| ch.is_ascii_digit()))
                .collect::<Vec<_>>()
                .join(" ")
        })
        .unwrap_or_else(|| NO_RULE_KEY.to_string())
}

fn tx_text(a_description: Option<&str>, a_counterparty: Option<&str>) -> String
{
    [a_description, a_counterparty]
        .into_iter()
        .flatten()
        .collect::<Vec<_>>()
        .join(" ")
}

async fn category_rules(a_conn: &mut PgConnection, a_user_id: Uuid) -> Result<HashMap<String, TxCategory>, ApiError>
{
    let rows = sqlx::query!(
        r#"SELECT rule_key, category AS "category: TxCategory" FROM category_rules WHERE user_id = $1"#,
        a_user_id
    )
    .fetch_all(&mut *a_conn)
    .await?;

    Ok(rows.into_iter().map(|row| (row.rule_key, row.category)).collect())
}

pub fn merchant_name(a_raw: &str) -> Option<String>
{
    let trimmed = a_raw.trim();
    let stripped = MERCHANT_PREFIXES
        .iter()
        .find_map(|prefix| {
            trimmed
                .get(..prefix.len())
                .filter(|head| head.eq_ignore_ascii_case(prefix))
                .and_then(|_| trimmed.get(prefix.len()..))
        })
        .unwrap_or(trimmed);

    clean_text(Some(stripped), 100)
}

pub fn merchant_key(a_name: &str) -> String
{
    a_name
        .chars()
        .map(|ch| {
            if ch.is_alphanumeric()
            {
                ch.to_lowercase().next().unwrap_or(ch)
            }
            else
            {
                ' '
            }
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(100)
        .collect()
}

async fn merchant_id(a_conn: &mut PgConnection, a_name: &str, a_mcc: Option<i16>) -> Result<Uuid, ApiError>
{
    let key = merchant_key(a_name);

    let id = sqlx::query_scalar!(
        r#"
        INSERT INTO merchants (name, name_key, mcc) VALUES ($1, $2, $3)
        ON CONFLICT (name_key) DO UPDATE SET mcc = COALESCE(merchants.mcc, EXCLUDED.mcc)
        RETURNING id
        "#,
        a_name,
        key,
        a_mcc
    )
    .fetch_one(&mut *a_conn)
    .await?;

    Ok(id)
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn merchant_names_are_cleaned_and_keyed()
    {
        assert_eq!(
            merchant_name("VDP-TESCO STORES 3092").as_deref(),
            Some("TESCO STORES 3092")
        );
        assert_eq!(merchant_name("  Сільпо  ").as_deref(), Some("Сільпо"));
        assert_eq!(merchant_key("Tesco  Stores-3092"), "tesco stores 3092");
        assert_eq!(merchant_key("СІЛЬПО"), "сільпо");
        assert_eq!(merchant_name("boı-shop").as_deref(), Some("boı-shop"));
    }

    #[test]
    fn rule_keys_ignore_branch_numbers()
    {
        assert_eq!(rule_key(None, Some("VDP-TESCO STORES 3092")), "tesco stores");
        assert_eq!(rule_key(None, Some("VDP-TESCO STORES 1001")), "tesco stores");
        assert_eq!(rule_key(Some("Сільпо"), Some("ignored")), "сільпо");
        assert_eq!(rule_key(None, None), "");
    }
}
