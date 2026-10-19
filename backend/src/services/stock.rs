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
pub struct Intake
{
    pub measure: StockMeasure,
    pub amount: Decimal,
    pub pack: Option<Decimal>,
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
    a_kind == ItemKind::Food
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

pub fn piece_amount(a_shape: &ItemShape, a_measure: StockMeasure) -> Option<Decimal>
{
    match (a_measure, a_shape.net_qty, a_shape.net_measure)
    {
        (StockMeasure::Pcs, _, _) => Some(Decimal::ONE),
        (_, Some(net_qty), Some(measure)) if net_measure(measure) == a_measure => Some(net_qty),
        (StockMeasure::G, _, _) => a_shape.piece_g,
        _ => None,
    }
}

fn pack_of(a_shape: &ItemShape, a_measure: StockMeasure) -> Option<Decimal>
{
    if a_shape.unit != ItemUnit::Piece || a_measure == StockMeasure::Pcs
    {
        return None;
    }
    piece_amount(a_shape, a_measure).filter(|value| *value > Decimal::ZERO)
}

pub fn intake_qty(a_shape: &ItemShape, a_receipt_qty: Decimal) -> Option<Intake>
{
    let measure = measure_of(a_shape)?;
    let amount = match a_shape.unit
    {
        ItemUnit::Kilogram | ItemUnit::Liter => a_receipt_qty * Decimal::from(THOUSAND),
        _ => a_receipt_qty * piece_amount(a_shape, measure)?,
    };
    Some(Intake {
        measure,
        amount: in_range(amount)?,
        pack: pack_of(a_shape, measure),
    })
}

pub fn manual_qty(a_shape: &ItemShape, a_qty: Decimal, a_unit: StockMeasure) -> Option<Intake>
{
    let measure = measure_of(a_shape)?;
    let (amount, pack) = if a_unit == measure
    {
        (a_qty, None)
    }
    else if a_unit == StockMeasure::Pcs
    {
        (a_qty * piece_amount(a_shape, measure)?, pack_of(a_shape, measure))
    }
    else
    {
        return None;
    };
    Some(Intake {
        measure,
        amount: in_range(amount)?,
        pack,
    })
}

pub fn display_pack(a_shape: &ItemShape, a_measure: StockMeasure, a_lot_pack: Option<Decimal>) -> Option<Decimal>
{
    a_lot_pack.or_else(|| pack_of(a_shape, a_measure))
}

pub fn write_off_amount(
    a_measure: StockMeasure,
    a_unit: Option<StockMeasure>,
    a_qty: Decimal,
    a_pack: Option<Decimal>,
) -> Option<Decimal>
{
    let amount = match a_unit
    {
        None => a_qty,
        Some(unit) if unit == a_measure => a_qty,
        Some(StockMeasure::Pcs) if a_measure != StockMeasure::Pcs =>
        {
            a_qty * a_pack.filter(|pack| *pack > Decimal::ZERO)?
        }
        Some(_) => return None,
    };
    let amount = qty(amount);
    (amount > Decimal::ZERO).then_some(amount)
}

pub fn rescaled_qty(a_qty: Decimal, a_from: Decimal, a_to: Decimal) -> Decimal
{
    if a_from <= Decimal::ZERO
    {
        return a_qty;
    }
    qty(a_qty * a_to / a_from).clamp(Decimal::new(1, QTY_SCALE), Decimal::from(MAX_LOT_QTY))
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

pub fn plan_takes(a_lots: &[LotLeft], a_grams: Decimal) -> (Vec<Take>, Decimal)
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
        assert_eq!(
            intake_qty(&milk, dec("2")),
            Some(Intake {
                measure: StockMeasure::Ml,
                amount: dec("1860"),
                pack: Some(dec("930")),
            })
        );
        let apples = shape(ItemUnit::Kilogram, None, None);
        assert_eq!(
            intake_qty(&apples, dec("1.255")),
            Some(Intake {
                measure: StockMeasure::G,
                amount: dec("1255"),
                pack: None,
            })
        );
        let eggs = shape(ItemUnit::Piece, None, Some("60"));
        assert_eq!(
            intake_qty(&eggs, dec("10")).map(|intake| intake.amount),
            Some(dec("600"))
        );
        let cheese = shape(ItemUnit::Piece, None, None);
        assert_eq!(
            intake_qty(&cheese, dec("1")),
            Some(Intake {
                measure: StockMeasure::Pcs,
                amount: dec("1"),
                pack: None,
            })
        );
        let candle = ItemShape {
            kind: ItemKind::Product,
            ..shape(ItemUnit::Piece, None, None)
        };
        assert_eq!(intake_qty(&candle, dec("3")), None);
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
            Some(Intake {
                measure: StockMeasure::G,
                amount: dec("600"),
                pack: Some(dec("150")),
            })
        );
        assert_eq!(
            manual_qty(&yogurt, dec("320"), StockMeasure::G),
            Some(Intake {
                measure: StockMeasure::G,
                amount: dec("320"),
                pack: None,
            })
        );
        assert_eq!(manual_qty(&yogurt, dec("320"), StockMeasure::Ml), None);
        let flour = shape(ItemUnit::Kilogram, None, None);
        assert_eq!(manual_qty(&flour, dec("2"), StockMeasure::Pcs), None);
        assert_eq!(manual_qty(&flour, dec("0"), StockMeasure::G), None);
    }

    #[test]
    fn takes_follow_lot_order_and_report_shortage()
    {
        let lots = [
            lot(1, "500", "120", Some("1"), Some("50.00")),
            lot(2, "500", "500", Some("1"), Some("60.00")),
        ];
        let (takes, short) = plan_takes(&lots, dec("300"));
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

        let (all, missing) = plan_takes(&lots, dec("700"));
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
        let (takes, short) = plan_takes(&lots, dec("150"));
        assert_eq!(takes.len(), 1);
        assert_eq!(takes[0].qty, dec("2"));
        assert_eq!(takes[0].cost, Some(dec("6.00")));
        assert_eq!(short, dec("30"));

        let (partial, rest) = plan_takes(&[lot(3, "10", "10", Some("60"), None)], dec("150"));
        assert_eq!(partial[0].qty, dec("2.5"));
        assert_eq!(rest, Decimal::ZERO);
    }

    #[test]
    fn write_off_converts_pieces_through_the_pack()
    {
        assert_eq!(
            write_off_amount(StockMeasure::G, Some(StockMeasure::Pcs), dec("0.5"), Some(dec("290"))),
            Some(dec("145"))
        );
        assert_eq!(
            write_off_amount(StockMeasure::G, Some(StockMeasure::G), dec("250"), None),
            Some(dec("250"))
        );
        assert_eq!(
            write_off_amount(StockMeasure::G, None, dec("40"), None),
            Some(dec("40"))
        );
        assert_eq!(
            write_off_amount(StockMeasure::G, Some(StockMeasure::Pcs), dec("1"), None),
            None
        );
        assert_eq!(
            write_off_amount(StockMeasure::Pcs, Some(StockMeasure::G), dec("250"), Some(dec("290"))),
            None
        );
        assert_eq!(
            write_off_amount(StockMeasure::Ml, Some(StockMeasure::G), dec("250"), None),
            None
        );
        assert_eq!(write_off_amount(StockMeasure::G, None, dec("0"), None), None);
    }

    #[test]
    fn pack_changes_rescale_the_lot()
    {
        assert_eq!(rescaled_qty(dec("580"), dec("290"), dec("300")), dec("600"));
        assert_eq!(rescaled_qty(dec("290"), dec("290"), dec("250")), dec("250"));
        assert_eq!(rescaled_qty(dec("100"), dec("0"), dec("250")), dec("100"));
        let packed = shape(ItemUnit::Piece, Some(("290", NetMeasure::G)), None);
        assert_eq!(display_pack(&packed, StockMeasure::G, None), Some(dec("290")));
        assert_eq!(
            display_pack(&packed, StockMeasure::G, Some(dec("300"))),
            Some(dec("300"))
        );
        assert_eq!(display_pack(&packed, StockMeasure::Ml, None), None);
        let flour = shape(ItemUnit::Kilogram, None, None);
        assert_eq!(display_pack(&flour, StockMeasure::G, None), None);
    }

    #[test]
    fn empty_stock_leaves_the_whole_amount_short()
    {
        let (takes, short) = plan_takes(&[lot(1, "100", "0", Some("1"), None)], dec("80"));
        assert!(takes.is_empty());
        assert_eq!(short, dec("80"));
    }
}
