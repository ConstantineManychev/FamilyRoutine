use rust_decimal::{Decimal, RoundingStrategy};
use shared_schema::{ItemKind, ItemUnit, NetMeasure, StockMeasure};
use uuid::Uuid;

pub const QTY_SCALE: u32 = 1;
pub const COST_SCALE: u32 = 2;
pub const MAX_LOT_QTY: i64 = 1_000_000;
const THOUSAND: i64 = 1000;

#[derive(Debug, Clone, Copy)]
pub struct ItemShape
{
    pub kind: ItemKind,
    pub unit: ItemUnit,
    pub net_qty: Option<Decimal>,
    pub net_measure: Option<NetMeasure>,
    pub piece_g: Option<Decimal>,
}

#[derive(Debug, Clone, Copy)]
pub struct LotLeft
{
    pub id: Uuid,
    pub qty: Decimal,
    pub left: Decimal,
    pub grams_per_unit: Option<Decimal>,
    pub cost: Option<Decimal>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Take
{
    pub lot_id: Uuid,
    pub qty: Decimal,
    pub cost: Option<Decimal>,
}

fn net_measure(a_measure: NetMeasure) -> StockMeasure
{
    match a_measure
    {
        NetMeasure::G => StockMeasure::G,
        NetMeasure::Ml => StockMeasure::Ml,
    }
}

pub fn qty(a_value: Decimal) -> Decimal
{
    a_value
        .round_dp_with_strategy(QTY_SCALE, RoundingStrategy::MidpointAwayFromZero)
        .normalize()
}

fn in_range(a_value: Decimal) -> Option<Decimal>
{
    let value = qty(a_value);
    (value > Decimal::ZERO && value <= Decimal::from(MAX_LOT_QTY)).then_some(value)
}

pub fn is_stockable(a_kind: ItemKind) -> bool
{
    matches!(a_kind, ItemKind::Food | ItemKind::Product)
}

pub fn measure_of(a_shape: &ItemShape) -> Option<StockMeasure>
{
    if !is_stockable(a_shape.kind)
    {
        return None;
    }
    match a_shape.unit
    {
        ItemUnit::Kilogram => Some(StockMeasure::G),
        ItemUnit::Liter => Some(StockMeasure::Ml),
        ItemUnit::Piece => Some(match (a_shape.net_qty, a_shape.net_measure, a_shape.piece_g)
        {
            (Some(_), Some(measure), _) => net_measure(measure),
            (_, _, Some(_)) => StockMeasure::G,
            _ => StockMeasure::Pcs,
        }),
        ItemUnit::Meter | ItemUnit::SquareMeter | ItemUnit::Hour => None,
    }
}

fn piece_amount(a_shape: &ItemShape, a_measure: StockMeasure) -> Option<Decimal>
{
    match (a_measure, a_shape.net_qty, a_shape.net_measure)
    {
        (StockMeasure::Pcs, _, _) => Some(Decimal::ONE),
        (_, Some(net_qty), Some(measure)) if net_measure(measure) == a_measure => Some(net_qty),
        (StockMeasure::G, _, _) => a_shape.piece_g,
        _ => None,
    }
}

pub fn intake_qty(a_shape: &ItemShape, a_receipt_qty: Decimal) -> Option<(StockMeasure, Decimal)>
{
    let measure = measure_of(a_shape)?;
    let amount = match a_shape.unit
    {
        ItemUnit::Kilogram | ItemUnit::Liter => a_receipt_qty * Decimal::from(THOUSAND),
        _ => a_receipt_qty * piece_amount(a_shape, measure)?,
    };
    Some((measure, in_range(amount)?))
}

pub fn manual_qty(a_shape: &ItemShape, a_qty: Decimal, a_unit: StockMeasure) -> Option<(StockMeasure, Decimal)>
{
    let measure = measure_of(a_shape)?;
    let amount = if a_unit == measure
    {
        a_qty
    }
    else if a_unit == StockMeasure::Pcs
    {
        a_qty * piece_amount(a_shape, measure)?
    }
    else
    {
        return None;
    };
    Some((measure, in_range(amount)?))
}

pub fn grams_per_unit(a_measure: StockMeasure, a_piece_g: Option<Decimal>) -> Option<Decimal>
{
    match a_measure
    {
        StockMeasure::G | StockMeasure::Ml => Some(Decimal::ONE),
        StockMeasure::Pcs => a_piece_g.filter(|grams| *grams > Decimal::ZERO),
    }
}

pub fn cost_share(a_cost: Option<Decimal>, a_lot_qty: Decimal, a_take: Decimal) -> Option<Decimal>
{
    let cost = a_cost?;
    if a_lot_qty <= Decimal::ZERO
    {
        return None;
    }
    Some(
        (cost * a_take / a_lot_qty)
            .round_dp_with_strategy(COST_SCALE, RoundingStrategy::MidpointAwayFromZero)
            .min(cost),
    )
}

pub fn plan_fifo(a_lots: &[LotLeft], a_grams: Decimal) -> (Vec<Take>, Decimal)
{
    let mut need = qty(a_grams);
    let mut takes = Vec::new();
    for lot in a_lots
    {
        if need <= Decimal::ZERO
        {
            break;
        }
        let Some(per_unit) = lot.grams_per_unit
        else
        {
            continue;
        };
        if lot.left <= Decimal::ZERO
        {
            continue;
        }
        let wanted = (need / per_unit).round_dp_with_strategy(QTY_SCALE, RoundingStrategy::AwayFromZero);
        let take = wanted.min(lot.left);
        if take <= Decimal::ZERO
        {
            continue;
        }
        need = (need - take * per_unit).max(Decimal::ZERO);
        takes.push(Take {
            lot_id: lot.id,
            qty: take.normalize(),
            cost: cost_share(lot.cost, lot.qty, take),
        });
    }
    (takes, qty(need))
}

#[cfg(test)]
mod tests
{
    use std::str::FromStr;

    use super::*;

    fn dec(a_value: &str) -> Decimal
    {
        Decimal::from_str(a_value).unwrap()
    }

    fn shape(a_unit: ItemUnit, a_net: Option<(&str, NetMeasure)>, a_piece_g: Option<&str>) -> ItemShape
    {
        ItemShape {
            kind: ItemKind::Food,
            unit: a_unit,
            net_qty: a_net.map(|(value, _)| dec(value)),
            net_measure: a_net.map(|(_, measure)| measure),
            piece_g: a_piece_g.map(dec),
        }
    }

    fn lot(a_id: u128, a_qty: &str, a_left: &str, a_per_unit: Option<&str>, a_cost: Option<&str>) -> LotLeft
    {
        LotLeft {
            id: Uuid::from_u128(a_id),
            qty: dec(a_qty),
            left: dec(a_left),
            grams_per_unit: a_per_unit.map(dec),
            cost: a_cost.map(dec),
        }
    }

    #[test]
    fn receipt_quantity_becomes_mass_from_the_item_card()
    {
        let milk = shape(ItemUnit::Piece, Some(("930", NetMeasure::Ml)), None);
        assert_eq!(intake_qty(&milk, dec("2")), Some((StockMeasure::Ml, dec("1860"))));
        let apples = shape(ItemUnit::Kilogram, None, None);
        assert_eq!(intake_qty(&apples, dec("1.255")), Some((StockMeasure::G, dec("1255"))));
        let eggs = shape(ItemUnit::Piece, None, Some("60"));
        assert_eq!(intake_qty(&eggs, dec("10")), Some((StockMeasure::G, dec("600"))));
        let candle = ItemShape {
            kind: ItemKind::Product,
            ..shape(ItemUnit::Piece, None, None)
        };
        assert_eq!(intake_qty(&candle, dec("3")), Some((StockMeasure::Pcs, dec("3"))));
        let haircut = ItemShape {
            kind: ItemKind::Service,
            ..shape(ItemUnit::Piece, None, None)
        };
        assert_eq!(intake_qty(&haircut, dec("1")), None);
        assert_eq!(intake_qty(&shape(ItemUnit::Hour, None, None), dec("1")), None);
    }

    #[test]
    fn manual_pieces_convert_through_net_mass_or_piece_weight()
    {
        let yogurt = shape(ItemUnit::Piece, Some(("150", NetMeasure::G)), None);
        assert_eq!(
            manual_qty(&yogurt, dec("4"), StockMeasure::Pcs),
            Some((StockMeasure::G, dec("600")))
        );
        assert_eq!(
            manual_qty(&yogurt, dec("320"), StockMeasure::G),
            Some((StockMeasure::G, dec("320")))
        );
        assert_eq!(manual_qty(&yogurt, dec("320"), StockMeasure::Ml), None);
        let flour = shape(ItemUnit::Kilogram, None, None);
        assert_eq!(manual_qty(&flour, dec("2"), StockMeasure::Pcs), None);
        assert_eq!(manual_qty(&flour, dec("0"), StockMeasure::G), None);
    }

    #[test]
    fn fifo_takes_oldest_lots_first_and_reports_shortage()
    {
        let lots = [
            lot(1, "500", "120", Some("1"), Some("50.00")),
            lot(2, "500", "500", Some("1"), Some("60.00")),
        ];
        let (takes, short) = plan_fifo(&lots, dec("300"));
        assert_eq!(
            takes,
            vec![
                Take {
                    lot_id: Uuid::from_u128(1),
                    qty: dec("120"),
                    cost: Some(dec("12.00")),
                },
                Take {
                    lot_id: Uuid::from_u128(2),
                    qty: dec("180"),
                    cost: Some(dec("21.60")),
                },
            ]
        );
        assert_eq!(short, Decimal::ZERO);

        let (all, missing) = plan_fifo(&lots, dec("700"));
        assert_eq!(all.iter().map(|take| take.qty).sum::<Decimal>(), dec("620"));
        assert_eq!(missing, dec("80"));
    }

    #[test]
    fn piece_lots_convert_grams_and_unknown_pieces_are_skipped()
    {
        let lots = [
            lot(1, "6", "6", None, None),
            lot(2, "10", "2", Some("60"), Some("30.00")),
        ];
        let (takes, short) = plan_fifo(&lots, dec("150"));
        assert_eq!(takes.len(), 1);
        assert_eq!(takes[0].qty, dec("2"));
        assert_eq!(takes[0].cost, Some(dec("6.00")));
        assert_eq!(short, dec("30"));

        let (partial, rest) = plan_fifo(&[lot(3, "10", "10", Some("60"), None)], dec("150"));
        assert_eq!(partial[0].qty, dec("2.5"));
        assert_eq!(rest, Decimal::ZERO);
    }

    #[test]
    fn empty_stock_leaves_the_whole_amount_short()
    {
        let (takes, short) = plan_fifo(&[lot(1, "100", "0", Some("1"), None)], dec("80"));
        assert!(takes.is_empty());
        assert_eq!(short, dec("80"));
    }
}
