use std::collections::HashMap;

use rust_decimal::prelude::{FromPrimitive, ToPrimitive};
use rust_decimal::Decimal;
use shared_schema::{StudyProgressDto, StudyUnit};
use uuid::Uuid;

use crate::services::tree::Forest;

const PERCENT_SCALE: u32 = 1;
const AMOUNT_SCALE: u32 = 1;

#[derive(Debug, Clone, Copy)]
pub struct TopicGoal
{
    pub unit: StudyUnit,
    pub target: Decimal,
    pub done: Decimal,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct Progress
{
    ratio: f64,
    amount: Option<(f64, f64, StudyUnit)>,
    is_aggregated: bool,
}

fn as_f64(a_value: Decimal) -> f64
{
    a_value.to_f64().unwrap_or_default()
}

fn to_decimal(a_value: f64, a_scale: u32) -> Decimal
{
    Decimal::from_f64(a_value)
        .unwrap_or_default()
        .round_dp(a_scale)
        .normalize()
}

fn own_progress(a_goal: TopicGoal) -> Progress
{
    let target = as_f64(a_goal.target);
    let done = as_f64(a_goal.done);
    let ratio = if target > 0.0
    {
        (done / target).clamp(0.0, 1.0)
    }
    else
    {
        0.0
    };
    Progress {
        ratio,
        amount: Some((done, target, a_goal.unit)),
        is_aggregated: false,
    }
}

fn combine(a_children: &[Progress]) -> Progress
{
    let units: Vec<Option<StudyUnit>> = a_children
        .iter()
        .map(|child| child.amount.map(|(_, _, unit)| unit))
        .collect();
    let shared_unit = units
        .first()
        .copied()
        .flatten()
        .filter(|unit| *unit != StudyUnit::Percent && units.iter().all(|other| *other == Some(*unit)));

    if let Some(unit) = shared_unit
    {
        let (done, target) = a_children.iter().filter_map(|child| child.amount).fold(
            (0.0, 0.0),
            |(done, target), (child_done, child_target, _)| {
                (done + child_done.min(child_target), target + child_target)
            },
        );
        let ratio = if target > 0.0
        {
            (done / target).clamp(0.0, 1.0)
        }
        else
        {
            0.0
        };
        return Progress {
            ratio,
            amount: Some((done, target, unit)),
            is_aggregated: true,
        };
    }

    let ratio = a_children.iter().map(|child| child.ratio).sum::<f64>() / a_children.len() as f64;
    Progress {
        ratio,
        amount: None,
        is_aggregated: true,
    }
}

fn progress_of(
    a_id: Uuid,
    a_forest: &Forest,
    a_goals: &HashMap<Uuid, TopicGoal>,
    a_done: &mut HashMap<Uuid, Progress>,
    a_path: &mut Vec<Uuid>,
) -> Progress
{
    if let Some(progress) = a_done.get(&a_id)
    {
        return *progress;
    }
    let own = a_goals.get(&a_id).copied().map(own_progress).unwrap_or(Progress {
        ratio: 0.0,
        amount: None,
        is_aggregated: false,
    });
    if a_path.contains(&a_id)
    {
        return own;
    }
    a_path.push(a_id);
    let children: Vec<Progress> = a_forest
        .children(a_id)
        .iter()
        .map(|child| progress_of(*child, a_forest, a_goals, a_done, a_path))
        .collect();
    a_path.pop();
    let progress = if children.is_empty() { own } else { combine(&children) };
    a_done.insert(a_id, progress);
    progress
}

pub fn aggregate(a_forest: &Forest, a_goals: &HashMap<Uuid, TopicGoal>) -> HashMap<Uuid, StudyProgressDto>
{
    let mut done = HashMap::new();
    let mut path = Vec::new();
    for id in a_goals.keys()
    {
        progress_of(*id, a_forest, a_goals, &mut done, &mut path);
    }
    done.into_iter()
        .map(|(id, progress)| {
            (
                id,
                StudyProgressDto {
                    percent: to_decimal(progress.ratio * 100.0, PERCENT_SCALE),
                    done: progress.amount.map(|(value, _, _)| to_decimal(value, AMOUNT_SCALE)),
                    target: progress.amount.map(|(_, value, _)| to_decimal(value, AMOUNT_SCALE)),
                    unit: progress.amount.map(|(_, _, unit)| unit),
                    is_aggregated: progress.is_aggregated,
                },
            )
        })
        .collect()
}

#[cfg(test)]
mod tests
{
    use std::str::FromStr;

    use super::*;

    fn id(a_value: u128) -> Uuid
    {
        Uuid::from_u128(a_value)
    }

    fn goal(a_unit: StudyUnit, a_target: &str, a_done: &str) -> TopicGoal
    {
        TopicGoal {
            unit: a_unit,
            target: Decimal::from_str(a_target).unwrap(),
            done: Decimal::from_str(a_done).unwrap(),
        }
    }

    fn dec(a_value: &str) -> Decimal
    {
        Decimal::from_str(a_value).unwrap()
    }

    #[test]
    fn leaves_use_their_own_goal_and_cap_at_full()
    {
        let forest = Forest::new([(id(1), None), (id(2), None)]);
        let goals = HashMap::from([
            (id(1), goal(StudyUnit::Pages, "120", "45")),
            (id(2), goal(StudyUnit::Tasks, "10", "14")),
        ]);
        let progress = aggregate(&forest, &goals);
        assert_eq!(progress[&id(1)].percent, dec("37.5"));
        assert_eq!(progress[&id(1)].done, Some(dec("45")));
        assert!(!progress[&id(1)].is_aggregated);
        assert_eq!(progress[&id(2)].percent, dec("100"));
    }

    #[test]
    fn same_unit_children_add_up_by_volume()
    {
        let forest = Forest::new([(id(1), None), (id(2), Some(id(1))), (id(3), Some(id(1)))]);
        let goals = HashMap::from([
            (id(1), goal(StudyUnit::Percent, "100", "90")),
            (id(2), goal(StudyUnit::Pages, "100", "100")),
            (id(3), goal(StudyUnit::Pages, "300", "60")),
        ]);
        let progress = aggregate(&forest, &goals);
        let parent = &progress[&id(1)];
        assert!(parent.is_aggregated);
        assert_eq!(parent.done, Some(dec("160")));
        assert_eq!(parent.target, Some(dec("400")));
        assert_eq!(parent.unit, Some(StudyUnit::Pages));
        assert_eq!(parent.percent, dec("40"));
    }

    #[test]
    fn mixed_units_average_child_percentages_through_levels()
    {
        let forest = Forest::new([
            (id(1), None),
            (id(2), Some(id(1))),
            (id(3), Some(id(1))),
            (id(4), Some(id(3))),
            (id(5), Some(id(3))),
        ]);
        let goals = HashMap::from([
            (id(1), goal(StudyUnit::Percent, "100", "0")),
            (id(2), goal(StudyUnit::Percent, "100", "80")),
            (id(3), goal(StudyUnit::Percent, "100", "0")),
            (id(4), goal(StudyUnit::Tasks, "10", "5")),
            (id(5), goal(StudyUnit::Lessons, "4", "4")),
        ]);
        let progress = aggregate(&forest, &goals);
        assert_eq!(progress[&id(3)].percent, dec("75"));
        assert_eq!(progress[&id(3)].unit, None);
        assert_eq!(progress[&id(1)].percent, dec("77.5"));
    }

    #[test]
    fn broken_cycles_do_not_hang()
    {
        let forest = Forest::new([(id(1), Some(id(2))), (id(2), Some(id(1)))]);
        let goals = HashMap::from([
            (id(1), goal(StudyUnit::Pages, "10", "5")),
            (id(2), goal(StudyUnit::Pages, "10", "10")),
        ]);
        assert_eq!(aggregate(&forest, &goals).len(), 2);
    }
}
