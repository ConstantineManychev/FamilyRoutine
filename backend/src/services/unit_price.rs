use std::collections::{BTreeMap, BTreeSet};

use chrono::{DateTime, Utc};
use rust_decimal::{Decimal, RoundingStrategy};
use shared_schema::{CatItemRefDto, CatPriceRowDto, ItemUnit, NetMeasure};
use uuid::Uuid;

const PRICE_SCALE: u32 = 2;
const BULK_UNITS_PER_100: i64 = 10;

pub struct PriceObservation
{
    pub item_id: Uuid,
    pub item_name: String,
    pub cat_id: Option<Uuid>,
    pub unit: ItemUnit,
    pub net_qty: Option<Decimal>,
    pub net_measure: Option<NetMeasure>,
    pub curr_code: String,
    pub unit_price: Decimal,
    pub store: Option<String>,
    pub branch: Option<String>,
    pub ts: DateTime<Utc>,
}

pub fn per_100(
    a_unit: ItemUnit,
    a_net_qty: Option<Decimal>,
    a_net_measure: Option<NetMeasure>,
    a_unit_price: Decimal,
) -> Option<(NetMeasure, Decimal)>
{
    let (measure, price) = match a_unit
    {
        ItemUnit::Kilogram => (NetMeasure::G, a_unit_price / Decimal::from(BULK_UNITS_PER_100)),
        ItemUnit::Liter => (NetMeasure::Ml, a_unit_price / Decimal::from(BULK_UNITS_PER_100)),
        ItemUnit::Piece =>
        {
            let net = a_net_qty.filter(|net| *net > Decimal::ZERO)?;
            (a_net_measure?, a_unit_price * Decimal::ONE_HUNDRED / net)
        }
        _ => return None,
    };
    Some((
        measure,
        price
            .round_dp_with_strategy(PRICE_SCALE, RoundingStrategy::MidpointAwayFromZero)
            .normalize(),
    ))
}

pub fn rank_prices(a_observations: Vec<PriceObservation>) -> (Vec<CatPriceRowDto>, Vec<CatItemRefDto>)
{
    let mut rows: BTreeMap<(Uuid, String), CatPriceRowDto> = BTreeMap::new();
    let mut unmeasured: BTreeMap<Uuid, String> = BTreeMap::new();

    for observation in a_observations
    {
        let Some((measure, price)) = per_100(
            observation.unit,
            observation.net_qty,
            observation.net_measure,
            observation.unit_price,
        )
        else
        {
            unmeasured.insert(observation.item_id, observation.item_name);
            continue;
        };

        let key = (observation.item_id, observation.curr_code.clone());
        let row = rows.entry(key).or_insert_with(|| CatPriceRowDto {
            item_id: observation.item_id,
            item_name: observation.item_name.clone(),
            cat_id: observation.cat_id,
            measure,
            curr_code: observation.curr_code.clone(),
            best_100: price,
            best_store: observation.store.clone(),
            best_branch: observation.branch.clone(),
            best_ts: observation.ts,
            last_100: price,
            last_store: observation.store.clone(),
            last_ts: observation.ts,
            count: 0,
        });
        row.count += 1;
        if price < row.best_100 || (price == row.best_100 && observation.ts > row.best_ts)
        {
            row.best_100 = price;
            row.best_store = observation.store.clone();
            row.best_branch = observation.branch.clone();
            row.best_ts = observation.ts;
        }
        if observation.ts > row.last_ts
        {
            row.last_100 = price;
            row.last_store = observation.store;
            row.last_ts = observation.ts;
        }
    }

    let measured: BTreeSet<Uuid> = rows.keys().map(|(item_id, _)| *item_id).collect();
    let mut ranked: Vec<CatPriceRowDto> = rows.into_values().collect();
    ranked.sort_by(|left, right| {
        (left.measure, &left.curr_code, left.best_100, &left.item_name).cmp(&(
            right.measure,
            &right.curr_code,
            right.best_100,
            &right.item_name,
        ))
    });
    let missing = unmeasured
        .into_iter()
        .filter(|(id, _)| !measured.contains(id))
        .map(|(id, name)| CatItemRefDto { id, name })
        .collect();
    (ranked, missing)
}

#[cfg(test)]
mod tests
{
    use std::str::FromStr;

    use chrono::Duration;

    use super::*;

    fn dec(a_value: &str) -> Decimal
    {
        Decimal::from_str(a_value).unwrap()
    }

    fn observation(
        a_item: u128,
        a_unit: ItemUnit,
        a_net: Option<(&str, NetMeasure)>,
        a_price: &str,
        a_days_ago: i64,
    ) -> PriceObservation
    {
        PriceObservation {
            item_id: Uuid::from_u128(a_item),
            item_name: format!("item {a_item}"),
            cat_id: None,
            unit: a_unit,
            net_qty: a_net.map(|(net, _)| dec(net)),
            net_measure: a_net.map(|(_, measure)| measure),
            curr_code: "UAH".into(),
            unit_price: dec(a_price),
            store: Some(format!("store {a_days_ago}")),
            branch: None,
            ts: Utc::now() - Duration::days(a_days_ago),
        }
    }

    #[test]
    fn prices_per_100_cover_packs_and_bulk_goods()
    {
        assert_eq!(
            per_100(ItemUnit::Piece, Some(dec("200")), Some(NetMeasure::G), dec("89.90")),
            Some((NetMeasure::G, dec("44.95")))
        );
        assert_eq!(
            per_100(ItemUnit::Piece, Some(dec("250")), Some(NetMeasure::Ml), dec("45")),
            Some((NetMeasure::Ml, dec("18")))
        );
        assert_eq!(
            per_100(ItemUnit::Kilogram, None, None, dec("399")),
            Some((NetMeasure::G, dec("39.9")))
        );
        assert_eq!(
            per_100(ItemUnit::Liter, None, None, dec("42")),
            Some((NetMeasure::Ml, dec("4.2")))
        );
        assert_eq!(per_100(ItemUnit::Piece, None, None, dec("10")), None);
        assert_eq!(per_100(ItemUnit::Hour, None, None, dec("10")), None);
    }

    #[test]
    fn ranking_keeps_the_best_and_the_latest_price_per_item()
    {
        let maasdam_small = Some(("200", NetMeasure::G));
        let maasdam_big = Some(("450", NetMeasure::G));
        let (rows, unmeasured) = rank_prices(vec![
            observation(1, ItemUnit::Piece, maasdam_small, "99", 10),
            observation(1, ItemUnit::Piece, maasdam_small, "89.90", 40),
            observation(2, ItemUnit::Piece, maasdam_big, "189", 3),
            observation(3, ItemUnit::Kilogram, None, "420", 5),
            observation(4, ItemUnit::Piece, None, "50", 1),
            observation(5, ItemUnit::Piece, Some(("250", NetMeasure::Ml)), "45", 2),
        ]);

        let order: Vec<u128> = rows.iter().map(|row| row.item_id.as_u128()).collect();
        assert_eq!(order, vec![2, 3, 1, 5]);
        assert_eq!(rows[0].best_100, dec("42"));
        assert_eq!(rows[1].best_100, dec("42"));
        assert_eq!(rows[2].best_100, dec("44.95"));
        assert_eq!(rows[2].best_store.as_deref(), Some("store 40"));
        assert_eq!(rows[2].last_100, dec("49.5"));
        assert_eq!(rows[2].count, 2);
        assert_eq!(rows[3].measure, NetMeasure::Ml);
        assert_eq!(unmeasured.len(), 1);
        assert_eq!(unmeasured[0].id, Uuid::from_u128(4));
    }
}
