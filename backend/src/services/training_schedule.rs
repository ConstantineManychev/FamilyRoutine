use chrono::{Datelike, Duration, NaiveDate};
use shared_schema::ScheduleMode;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ScheduleDay
{
    pub rest_days_after: i32,
    pub weekday_mask: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reference
{
    Done
    {
        day_index: usize, date: NaiveDate
    },
    Chosen
    {
        day_index: usize, date: NaiveDate
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Planned
{
    pub day_index: usize,
    pub date: Option<NaiveDate>,
    pub is_overdue: bool,
}

pub fn weekday_bit(a_date: NaiveDate) -> i32
{
    1 << a_date.weekday().num_days_from_monday()
}

pub fn plan(
    a_mode: ScheduleMode,
    a_days: &[ScheduleDay],
    a_reference: Option<Reference>,
    a_today: NaiveDate,
    a_horizon_days: i64,
) -> Vec<Planned>
{
    if a_days.is_empty()
    {
        return Vec::new();
    }

    match a_mode
    {
        ScheduleMode::Queue => plan_queue(a_days, a_reference),
        ScheduleMode::Intervals => plan_intervals(a_days, a_reference, a_today, a_horizon_days),
        ScheduleMode::Weekdays => plan_weekdays(a_days, a_reference, a_today, a_horizon_days),
    }
}

fn next_index(a_days: &[ScheduleDay], a_index: usize) -> usize
{
    (a_index + 1) % a_days.len()
}

fn first_due(a_days: &[ScheduleDay], a_reference: Option<Reference>, a_today: NaiveDate) -> (usize, NaiveDate)
{
    match a_reference
    {
        None => (0, a_today),
        Some(Reference::Chosen { day_index, date }) => (day_index % a_days.len(), date),
        Some(Reference::Done { day_index, date }) =>
        {
            let index = day_index % a_days.len();
            let rest = i64::from(a_days[index].rest_days_after.max(0));
            (next_index(a_days, index), date + Duration::days(rest + 1))
        }
    }
}

fn plan_queue(a_days: &[ScheduleDay], a_reference: Option<Reference>) -> Vec<Planned>
{
    let start = match a_reference
    {
        None => 0,
        Some(Reference::Chosen { day_index, .. }) => day_index % a_days.len(),
        Some(Reference::Done { day_index, .. }) => next_index(a_days, day_index % a_days.len()),
    };

    (0..a_days.len())
        .map(|offset| Planned {
            day_index: (start + offset) % a_days.len(),
            date: None,
            is_overdue: false,
        })
        .collect()
}

fn plan_intervals(
    a_days: &[ScheduleDay],
    a_reference: Option<Reference>,
    a_today: NaiveDate,
    a_horizon_days: i64,
) -> Vec<Planned>
{
    let (mut index, due) = first_due(a_days, a_reference, a_today);
    let is_overdue = due < a_today;
    let mut date = due.max(a_today);
    let last_date = a_today + Duration::days(a_horizon_days);
    let mut planned = vec![Planned {
        day_index: index,
        date: Some(date),
        is_overdue,
    }];

    loop
    {
        date += Duration::days(i64::from(a_days[index].rest_days_after.max(0)) + 1);
        index = next_index(a_days, index);
        if date > last_date
        {
            break;
        }
        planned.push(Planned {
            day_index: index,
            date: Some(date),
            is_overdue: false,
        });
    }

    planned
}

fn plan_weekdays(
    a_days: &[ScheduleDay],
    a_reference: Option<Reference>,
    a_today: NaiveDate,
    a_horizon_days: i64,
) -> Vec<Planned>
{
    let mut planned = Vec::new();
    let mut start = a_today;

    match a_reference
    {
        Some(Reference::Chosen { day_index, date }) if date == a_today =>
        {
            planned.push(Planned {
                day_index: day_index % a_days.len(),
                date: Some(a_today),
                is_overdue: false,
            });
            start = a_today + Duration::days(1);
        }
        Some(Reference::Done { date, .. }) if date >= a_today =>
        {
            start = date + Duration::days(1);
        }
        _ =>
        {}
    }

    let mut date = start;
    while date <= a_today + Duration::days(a_horizon_days)
    {
        let bit = weekday_bit(date);
        if let Some(index) = a_days.iter().position(|day| day.weekday_mask & bit != 0)
        {
            planned.push(Planned {
                day_index: index,
                date: Some(date),
                is_overdue: false,
            });
        }
        date += Duration::days(1);
    }

    planned
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn date(a_day: u32) -> NaiveDate
    {
        NaiveDate::from_ymd_opt(2026, 10, a_day).unwrap()
    }

    fn intervals(a_rests: &[i32]) -> Vec<ScheduleDay>
    {
        a_rests
            .iter()
            .map(|rest| ScheduleDay {
                rest_days_after: *rest,
                weekday_mask: 0,
            })
            .collect()
    }

    fn dates(a_plan: &[Planned]) -> Vec<(usize, u32)>
    {
        a_plan
            .iter()
            .map(|item| (item.day_index, item.date.unwrap().day()))
            .collect()
    }

    #[test]
    fn intervals_follow_rest_days_in_a_cycle()
    {
        let days = intervals(&[1, 2, 1, 2]);
        let done = Reference::Done {
            day_index: 0,
            date: date(12),
        };
        let plan = plan(ScheduleMode::Intervals, &days, Some(done), date(13), 12);

        assert_eq!(dates(&plan), [(1, 14), (2, 17), (3, 19), (0, 22), (1, 24)]);
        assert!(!plan[0].is_overdue);
    }

    #[test]
    fn missed_interval_workout_moves_to_today_and_shifts_the_rest()
    {
        let days = intervals(&[1, 2, 1, 2]);
        let done = Reference::Done {
            day_index: 0,
            date: date(5),
        };
        let plan = plan(ScheduleMode::Intervals, &days, Some(done), date(13), 8);

        assert_eq!(dates(&plan), [(1, 13), (2, 16), (3, 18), (0, 21)]);
        assert!(plan[0].is_overdue);
    }

    #[test]
    fn chosen_day_restarts_the_sequence_from_it()
    {
        let days = intervals(&[1, 2, 1, 2]);
        let chosen = Reference::Chosen {
            day_index: 2,
            date: date(13),
        };
        let plan = plan(ScheduleMode::Intervals, &days, Some(chosen), date(13), 5);
        assert_eq!(dates(&plan), [(2, 13), (3, 15), (0, 18)]);

        let queue = super::plan(ScheduleMode::Queue, &days, Some(chosen), date(13), 5);
        let order: Vec<usize> = queue.iter().map(|item| item.day_index).collect();
        assert_eq!(order, [2, 3, 0, 1]);
        assert!(queue.iter().all(|item| item.date.is_none()));
    }

    #[test]
    fn new_program_starts_with_the_first_day_today()
    {
        let days = intervals(&[0, 0]);
        let plan = plan(ScheduleMode::Intervals, &days, None, date(13), 2);
        assert_eq!(dates(&plan), [(0, 13), (1, 14), (0, 15)]);
        assert!(super::plan(ScheduleMode::Intervals, &[], None, date(13), 2).is_empty());
    }

    #[test]
    fn weekdays_follow_the_calendar()
    {
        let monday = 1 << 0;
        let wednesday = 1 << 2;
        let friday = 1 << 4;
        let days = vec![
            ScheduleDay {
                rest_days_after: 0,
                weekday_mask: monday | friday,
            },
            ScheduleDay {
                rest_days_after: 0,
                weekday_mask: wednesday,
            },
        ];

        assert_eq!(date(12).weekday(), chrono::Weekday::Mon);
        let plan = super::plan(ScheduleMode::Weekdays, &days, None, date(12), 7);
        assert_eq!(dates(&plan), [(0, 12), (1, 14), (0, 16), (0, 19)]);

        let done_today = Reference::Done {
            day_index: 0,
            date: date(12),
        };
        let plan = super::plan(ScheduleMode::Weekdays, &days, Some(done_today), date(12), 4);
        assert_eq!(dates(&plan), [(1, 14), (0, 16)]);

        let chosen_today = Reference::Chosen {
            day_index: 1,
            date: date(13),
        };
        let plan = super::plan(ScheduleMode::Weekdays, &days, Some(chosen_today), date(13), 3);
        assert_eq!(dates(&plan), [(1, 13), (1, 14), (0, 16)]);
    }
}
