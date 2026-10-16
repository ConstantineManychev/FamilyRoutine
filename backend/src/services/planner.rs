use chrono::{DateTime, Datelike, Duration, LocalResult, NaiveDate, NaiveTime, Offset, TimeZone, Utc};
use chrono_tz::Tz;
use shared_schema::{PlanRepeat, PlanState, PlanTiming};

const GAP_PROBE_HOURS: i64 = 3;
const MONTHS_IN_YEAR: i64 = 12;
const DAYS_IN_WEEK: i64 = 7;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Rule
{
    pub start_date: NaiveDate,
    pub repeat: PlanRepeat,
    pub every: i32,
    pub weekday_mask: i32,
    pub until: Option<NaiveDate>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slot
{
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub timing: PlanTiming,
    pub duration_min: i32,
    pub state: PlanState,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Issues
{
    pub conflicts: Vec<usize>,
    pub overload: Option<Overload>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Overload
{
    pub window_min: i32,
    pub busy_min: i32,
}

impl Rule
{
    pub fn occurs_on(&self, a_date: NaiveDate) -> bool
    {
        if a_date < self.start_date || self.until.is_some_and(|until| a_date > until)
        {
            return false;
        }

        let every = i64::from(self.every.max(1));
        match self.repeat
        {
            PlanRepeat::Once => a_date == self.start_date,
            PlanRepeat::Daily => (a_date - self.start_date).num_days() % every == 0,
            PlanRepeat::Weekly =>
            {
                let week = (a_date - monday_of(self.start_date)).num_days() / DAYS_IN_WEEK;
                self.weekday_mask & weekday_bit(a_date) != 0 && week % every == 0
            }
            PlanRepeat::Monthly =>
            {
                let months = month_index(a_date) - month_index(self.start_date);
                months % every == 0 && a_date.day() == clamp_day(self.start_date.day(), a_date)
            }
        }
    }

    pub fn dates_between(&self, a_from: NaiveDate, a_to: NaiveDate) -> Vec<NaiveDate>
    {
        let first = a_from.max(self.start_date);
        let last = self.until.map_or(a_to, |until| a_to.min(until));
        first
            .iter_days()
            .take_while(|date| *date <= last)
            .filter(|date| self.occurs_on(*date))
            .collect()
    }
}

pub fn weekday_bit(a_date: NaiveDate) -> i32
{
    1 << a_date.weekday().num_days_from_monday()
}

pub fn parse_zone(a_name: &str) -> Option<Tz>
{
    a_name.parse::<Tz>().ok()
}

pub fn resolve_local(a_tz: Tz, a_date: NaiveDate, a_time: NaiveTime) -> DateTime<Utc>
{
    let naive = a_date.and_time(a_time);
    match a_tz.from_local_datetime(&naive)
    {
        LocalResult::Single(moment) => moment.with_timezone(&Utc),
        LocalResult::Ambiguous(earliest, _) => earliest.with_timezone(&Utc),
        LocalResult::None =>
        {
            let probe = (naive - Duration::hours(GAP_PROBE_HOURS)).and_utc();
            let before = a_tz.offset_from_utc_datetime(&probe.naive_utc()).fix();
            (naive - Duration::seconds(i64::from(before.local_minus_utc()))).and_utc()
        }
    }
}

pub fn local_date(a_tz: Tz, a_moment: DateTime<Utc>) -> NaiveDate
{
    a_moment.with_timezone(&a_tz).date_naive()
}

pub fn analyze(a_slots: &[Slot]) -> Vec<Issues>
{
    let mut issues = vec![Issues::default(); a_slots.len()];
    let is_fixed = |slot: &Slot| slot.timing == PlanTiming::Fixed && slot.state != PlanState::Skipped;
    let is_open_window = |slot: &Slot| slot.timing == PlanTiming::Window && slot.state == PlanState::Planned;

    let mut fixed: Vec<usize> = (0..a_slots.len()).filter(|index| is_fixed(&a_slots[*index])).collect();
    fixed.sort_by_key(|index| (a_slots[*index].start, a_slots[*index].end));
    for (position, &left) in fixed.iter().enumerate()
    {
        for &right in &fixed[position + 1..]
        {
            if a_slots[right].start >= a_slots[left].end
            {
                break;
            }
            if a_slots[right].end > a_slots[left].start
            {
                issues[left].conflicts.push(right);
                issues[right].conflicts.push(left);
            }
        }
    }

    for (index, window) in a_slots.iter().enumerate()
    {
        if !is_open_window(window)
        {
            continue;
        }

        let window_min = minutes(window.end - window.start);
        let fixed_min = busy_minutes(
            fixed
                .iter()
                .map(|other| &a_slots[*other])
                .filter_map(|other| clip(other, window)),
        );
        let nested_min: i32 = a_slots
            .iter()
            .enumerate()
            .filter(|(other_index, other)| {
                *other_index != index && is_open_window(other) && other.start >= window.start && other.end <= window.end
            })
            .map(|(_, other)| other.duration_min)
            .sum();

        let busy_min = fixed_min + window.duration_min + nested_min;
        if busy_min > window_min
        {
            issues[index].overload = Some(Overload { window_min, busy_min });
        }
    }

    issues
}

fn clip(a_slot: &Slot, a_window: &Slot) -> Option<(DateTime<Utc>, DateTime<Utc>)>
{
    let start = a_slot.start.max(a_window.start);
    let end = a_slot.end.min(a_window.end);
    (start < end).then_some((start, end))
}

fn busy_minutes(a_intervals: impl Iterator<Item = (DateTime<Utc>, DateTime<Utc>)>) -> i32
{
    let mut intervals: Vec<_> = a_intervals.collect();
    intervals.sort();
    let mut total = Duration::zero();
    let mut current: Option<(DateTime<Utc>, DateTime<Utc>)> = None;
    for (start, end) in intervals
    {
        current = match current
        {
            Some((open_start, open_end)) if start <= open_end => Some((open_start, open_end.max(end))),
            Some((open_start, open_end)) =>
            {
                total += open_end - open_start;
                Some((start, end))
            }
            None => Some((start, end)),
        };
    }
    if let Some((start, end)) = current
    {
        total += end - start;
    }
    minutes(total)
}

fn minutes(a_duration: Duration) -> i32
{
    i32::try_from(a_duration.num_minutes()).unwrap_or(i32::MAX)
}

fn monday_of(a_date: NaiveDate) -> NaiveDate
{
    a_date - Duration::days(i64::from(a_date.weekday().num_days_from_monday()))
}

fn month_index(a_date: NaiveDate) -> i64
{
    i64::from(a_date.year()) * MONTHS_IN_YEAR + i64::from(a_date.month0())
}

fn clamp_day(a_day: u32, a_date: NaiveDate) -> u32
{
    let first = NaiveDate::from_ymd_opt(a_date.year(), a_date.month(), 1).unwrap_or(a_date);
    let next_month = first + Duration::days(32);
    let last = NaiveDate::from_ymd_opt(next_month.year(), next_month.month(), 1)
        .and_then(|date| date.pred_opt())
        .map_or(28, |date| date.day());
    a_day.min(last)
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn date(a_value: &str) -> NaiveDate
    {
        a_value.parse().unwrap()
    }

    fn time(a_value: &str) -> NaiveTime
    {
        a_value.parse().unwrap()
    }

    fn utc(a_value: &str) -> DateTime<Utc>
    {
        a_value.parse().unwrap()
    }

    fn rule(a_repeat: PlanRepeat, a_every: i32, a_mask: i32) -> Rule
    {
        Rule {
            start_date: date("2026-10-14"),
            repeat: a_repeat,
            every: a_every,
            weekday_mask: a_mask,
            until: None,
        }
    }

    fn slot(a_start: &str, a_end: &str, a_timing: PlanTiming, a_duration: i32) -> Slot
    {
        Slot {
            start: utc(a_start),
            end: utc(a_end),
            timing: a_timing,
            duration_min: a_duration,
            state: PlanState::Planned,
        }
    }

    #[test]
    fn recurrence_rules_are_expanded_only_inside_the_range()
    {
        let once = rule(PlanRepeat::Once, 1, 0);
        assert_eq!(
            once.dates_between(date("2026-10-01"), date("2026-10-31")),
            vec![date("2026-10-14")]
        );

        let every_other_day = rule(PlanRepeat::Daily, 2, 0);
        assert_eq!(
            every_other_day.dates_between(date("2026-10-13"), date("2026-10-19")),
            vec![date("2026-10-14"), date("2026-10-16"), date("2026-10-18")]
        );

        let monday_and_wednesday_biweekly = rule(PlanRepeat::Weekly, 2, 0b0000101);
        assert_eq!(
            monday_and_wednesday_biweekly.dates_between(date("2026-10-12"), date("2026-11-01")),
            vec![date("2026-10-14"), date("2026-10-26"), date("2026-10-28")]
        );

        let limited = Rule {
            until: Some(date("2026-10-16")),
            ..rule(PlanRepeat::Daily, 1, 0)
        };
        assert_eq!(limited.dates_between(date("2026-10-01"), date("2026-12-31")).len(), 3);
    }

    #[test]
    fn monthly_repeats_clamp_to_short_months()
    {
        let rule = Rule {
            start_date: date("2026-01-31"),
            ..rule(PlanRepeat::Monthly, 1, 0)
        };
        assert_eq!(
            rule.dates_between(date("2026-01-01"), date("2026-04-30")),
            vec![
                date("2026-01-31"),
                date("2026-02-28"),
                date("2026-03-31"),
                date("2026-04-30")
            ]
        );
        let quarterly = Rule { every: 3, ..rule };
        assert_eq!(
            quarterly.dates_between(date("2026-01-01"), date("2026-12-31")),
            vec![
                date("2026-01-31"),
                date("2026-04-30"),
                date("2026-07-31"),
                date("2026-10-31")
            ]
        );
    }

    #[test]
    fn local_time_survives_daylight_saving_changes()
    {
        let dublin: Tz = "Europe/Dublin".parse().unwrap();
        assert_eq!(
            resolve_local(dublin, date("2026-10-19"), time("09:00")),
            utc("2026-10-19T08:00:00Z")
        );
        assert_eq!(
            resolve_local(dublin, date("2026-10-26"), time("09:00")),
            utc("2026-10-26T09:00:00Z")
        );

        let kyiv: Tz = "Europe/Kyiv".parse().unwrap();
        assert_eq!(
            resolve_local(kyiv, date("2026-03-28"), time("07:30")),
            utc("2026-03-28T05:30:00Z")
        );
        assert_eq!(
            resolve_local(kyiv, date("2026-03-30"), time("07:30")),
            utc("2026-03-30T04:30:00Z")
        );
    }

    #[test]
    fn skipped_and_repeated_local_times_are_resolved_predictably()
    {
        let dublin: Tz = "Europe/Dublin".parse().unwrap();
        assert_eq!(
            resolve_local(dublin, date("2026-03-29"), time("01:30")),
            utc("2026-03-29T01:30:00Z")
        );
        assert_eq!(
            resolve_local(dublin, date("2026-10-25"), time("01:30")),
            utc("2026-10-25T00:30:00Z")
        );
        assert_eq!(local_date(dublin, utc("2026-10-25T23:30:00Z")), date("2026-10-25"));
    }

    #[test]
    fn overlapping_fixed_events_are_reported_both_ways()
    {
        let slots = [
            slot("2026-10-14T13:00:00Z", "2026-10-14T14:00:00Z", PlanTiming::Fixed, 60),
            slot("2026-10-14T13:30:00Z", "2026-10-14T15:00:00Z", PlanTiming::Fixed, 90),
            slot("2026-10-14T15:00:00Z", "2026-10-14T16:00:00Z", PlanTiming::Fixed, 60),
            Slot {
                state: PlanState::Skipped,
                ..slot("2026-10-14T13:15:00Z", "2026-10-14T13:45:00Z", PlanTiming::Fixed, 30)
            },
        ];
        let issues = analyze(&slots);
        assert_eq!(issues[0].conflicts, vec![1]);
        assert_eq!(issues[1].conflicts, vec![0]);
        assert!(issues[2].conflicts.is_empty());
        assert!(issues[3].conflicts.is_empty());
    }

    #[test]
    fn window_is_overloaded_when_fixed_events_and_tasks_do_not_fit()
    {
        let window = slot("2026-10-14T12:00:00Z", "2026-10-14T14:00:00Z", PlanTiming::Window, 40);
        let lunch = slot("2026-10-14T12:30:00Z", "2026-10-14T13:30:00Z", PlanTiming::Fixed, 60);
        let meeting = slot("2026-10-14T13:00:00Z", "2026-10-14T13:45:00Z", PlanTiming::Fixed, 45);
        assert_eq!(analyze(&[window, lunch])[0].overload, None);

        let issues = analyze(&[window, lunch, meeting]);
        assert_eq!(issues[0].overload, None);
        assert_eq!(issues[1].conflicts, vec![2]);

        let errand = slot("2026-10-14T12:15:00Z", "2026-10-14T13:15:00Z", PlanTiming::Window, 30);
        let issues = analyze(&[window, lunch, meeting, errand]);
        assert_eq!(
            issues[0].overload,
            Some(Overload {
                window_min: 120,
                busy_min: 145
            })
        );
        assert!(issues[3].overload.is_some());

        let done = Slot {
            state: PlanState::Done,
            ..errand
        };
        assert_eq!(analyze(&[window, lunch, meeting, done])[0].overload, None);
    }
}
