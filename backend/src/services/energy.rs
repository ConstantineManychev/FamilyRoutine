use chrono::{DateTime, Utc};

const POINT_SCALE: f64 = 10.0;
const DAY_SECONDS: f64 = 86_400.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FoodEvent
{
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub kcal: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WorkoutSpan
{
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub kcal: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EnergyReset
{
    pub ts: DateTime<Utc>,
    pub kcal: f64,
}

#[derive(Debug, Clone, Copy)]
pub struct CurveInput<'a>
{
    pub from: DateTime<Utc>,
    pub until: DateTime<Utc>,
    pub start_value: f64,
    pub daily_burn: Option<f64>,
    pub foods: &'a [FoodEvent],
    pub workouts: &'a [WorkoutSpan],
    pub resets: &'a [EnergyReset],
}

#[derive(Debug, Clone, PartialEq)]
pub struct EnergyCurve
{
    pub points: Vec<(DateTime<Utc>, f64)>,
    pub eaten: f64,
    pub burned_base: f64,
    pub burned_workouts: f64,
    pub value: f64,
}

struct Flow
{
    start: DateTime<Utc>,
    end: DateTime<Utc>,
    rate: f64,
}

impl FoodEvent
{
    pub fn instant(a_ts: DateTime<Utc>, a_kcal: f64) -> Self
    {
        Self {
            start: a_ts,
            end: a_ts,
            kcal: a_kcal,
        }
    }

    fn is_instant(&self) -> bool
    {
        self.end <= self.start
    }
}

fn seconds(a_from: DateTime<Utc>, a_to: DateTime<Utc>) -> f64
{
    (a_to - a_from).num_milliseconds().max(0) as f64 / 1000.0
}

fn rounded(a_value: f64) -> f64
{
    (a_value * POINT_SCALE).round() / POINT_SCALE
}

pub fn base_rate(a_daily_burn: Option<f64>) -> f64
{
    a_daily_burn.unwrap_or(0.0).max(0.0) / DAY_SECONDS
}

pub fn workout_share(a_span: &WorkoutSpan, a_from: DateTime<Utc>, a_to: DateTime<Utc>) -> f64
{
    let total = seconds(a_span.start, a_span.end);
    if total <= 0.0 || a_span.kcal <= 0.0
    {
        return 0.0;
    }
    let start = a_span.start.max(a_from);
    let end = a_span.end.min(a_to);
    a_span.kcal * seconds(start, end) / total
}

pub fn carried_value(
    a_base: f64,
    a_since: DateTime<Utc>,
    a_until: DateTime<Utc>,
    a_daily_burn: Option<f64>,
    a_eaten: f64,
    a_workouts: &[WorkoutSpan],
) -> f64
{
    let burned: f64 = a_workouts
        .iter()
        .map(|span| workout_share(span, a_since, a_until))
        .sum();
    a_base + a_eaten - burned - base_rate(a_daily_burn) * seconds(a_since, a_until)
}

fn flows_of<I>(a_spans: I, a_from: DateTime<Utc>, a_until: DateTime<Utc>) -> Vec<Flow>
where
    I: Iterator<Item = (DateTime<Utc>, DateTime<Utc>, f64)>,
{
    a_spans
        .filter(|(start, end, kcal)| end > start && *end > a_from && *start < a_until && *kcal > 0.0)
        .map(|(start, end, kcal)| Flow {
            start: start.clamp(a_from, a_until),
            end: end.clamp(a_from, a_until),
            rate: kcal / seconds(start, end),
        })
        .collect()
}

fn rate_between(a_flows: &[Flow], a_moment: DateTime<Utc>, a_next: DateTime<Utc>) -> f64
{
    a_flows
        .iter()
        .filter(|flow| flow.start <= a_moment && flow.end >= a_next)
        .map(|flow| flow.rate)
        .sum()
}

pub fn energy_curve(a_input: CurveInput<'_>) -> EnergyCurve
{
    let from = a_input.from;
    let until = a_input.until;
    if until <= from
    {
        return EnergyCurve {
            points: Vec::new(),
            eaten: 0.0,
            burned_base: 0.0,
            burned_workouts: 0.0,
            value: a_input.start_value,
        };
    }

    let rate = base_rate(a_input.daily_burn);
    let workouts = flows_of(
        a_input.workouts.iter().map(|span| (span.start, span.end, span.kcal)),
        from,
        until,
    );
    let intakes = flows_of(
        a_input
            .foods
            .iter()
            .filter(|food| !food.is_instant())
            .map(|food| (food.start, food.end, food.kcal)),
        from,
        until,
    );
    let jumps: Vec<(DateTime<Utc>, f64)> = a_input
        .foods
        .iter()
        .filter(|food| food.is_instant() && food.kcal > 0.0 && food.start >= from && food.start <= until)
        .map(|food| (food.start, food.kcal))
        .collect();
    let resets: Vec<(DateTime<Utc>, f64)> = a_input
        .resets
        .iter()
        .filter(|reset| reset.ts > from && reset.ts <= until)
        .map(|reset| (reset.ts, reset.kcal))
        .collect();

    let mut moments: Vec<DateTime<Utc>> = vec![from, until];
    moments.extend(jumps.iter().map(|(ts, _)| *ts));
    moments.extend(resets.iter().map(|(ts, _)| *ts));
    moments.extend(workouts.iter().chain(&intakes).flat_map(|flow| [flow.start, flow.end]));
    moments.sort();
    moments.dedup();

    let mut value = a_input.start_value;
    let mut eaten = 0.0;
    let mut burned_workouts = 0.0;
    let mut points = Vec::with_capacity(moments.len() * 2);
    for (index, moment) in moments.iter().enumerate()
    {
        points.push((*moment, rounded(value)));
        let jump: f64 = jumps.iter().filter(|(ts, _)| ts == moment).map(|(_, kcal)| kcal).sum();
        if jump > 0.0
        {
            value += jump;
            eaten += jump;
            points.push((*moment, rounded(value)));
        }
        if let Some((_, kcal)) = resets.iter().find(|(ts, _)| ts == moment)
        {
            value = *kcal;
            points.push((*moment, rounded(value)));
        }
        let Some(next) = moments.get(index + 1)
        else
        {
            break;
        };
        let interval = seconds(*moment, *next);
        let workout_rate = rate_between(&workouts, *moment, *next);
        let intake_rate = rate_between(&intakes, *moment, *next);
        burned_workouts += workout_rate * interval;
        eaten += intake_rate * interval;
        value += (intake_rate - rate - workout_rate) * interval;
    }
    points.dedup();

    EnergyCurve {
        points,
        eaten,
        burned_base: rate * seconds(from, until),
        burned_workouts,
        value,
    }
}

#[cfg(test)]
mod tests
{
    use chrono::{Duration, TimeZone};

    use super::*;

    fn at(a_hour: i64) -> DateTime<Utc>
    {
        Utc.with_ymd_and_hms(2026, 10, 17, 0, 0, 0).unwrap() + Duration::hours(a_hour)
    }

    fn curve(
        a_from: i64,
        a_until: i64,
        a_start: f64,
        a_burn: Option<f64>,
        a_foods: &[FoodEvent],
        a_workouts: &[WorkoutSpan],
        a_resets: &[EnergyReset],
    ) -> EnergyCurve
    {
        energy_curve(CurveInput {
            from: at(a_from),
            until: at(a_until),
            start_value: a_start,
            daily_burn: a_burn,
            foods: a_foods,
            workouts: a_workouts,
            resets: a_resets,
        })
    }

    #[test]
    fn food_jumps_and_the_day_burns_evenly()
    {
        let result = curve(
            0,
            24,
            0.0,
            Some(2400.0),
            &[FoodEvent::instant(at(8), 600.0), FoodEvent::instant(at(13), 900.0)],
            &[],
            &[],
        );
        assert_eq!(
            result.points,
            vec![
                (at(0), 0.0),
                (at(8), -800.0),
                (at(8), -200.0),
                (at(13), -700.0),
                (at(13), 200.0),
                (at(24), -900.0),
            ]
        );
        assert_eq!(result.eaten, 1500.0);
        assert!((result.burned_base - 2400.0).abs() < 1e-6);
        assert!((result.value + 900.0).abs() < 1e-6);
    }

    #[test]
    fn a_meal_block_raises_the_balance_gradually_while_the_day_burns()
    {
        let lunch = FoodEvent {
            start: at(13),
            end: at(13) + Duration::minutes(30),
            kcal: 500.0,
        };
        let result = curve(12, 14, 0.0, Some(2400.0), &[lunch], &[], &[]);
        assert_eq!(
            result.points,
            vec![
                (at(12), 0.0),
                (at(13), -100.0),
                (at(13) + Duration::minutes(30), 350.0),
                (at(14), 300.0),
            ]
        );
        assert!((result.eaten - 500.0).abs() < 1e-6);

        let halfway = curve(12, 13, 0.0, Some(2400.0), &[lunch], &[], &[]);
        assert_eq!(halfway.eaten, 0.0);
        let during = energy_curve(CurveInput {
            from: at(13),
            until: at(13) + Duration::minutes(15),
            start_value: 0.0,
            daily_burn: None,
            foods: &[lunch],
            workouts: &[],
            resets: &[],
        });
        assert!((during.eaten - 250.0).abs() < 1e-6);
        assert!((during.value - 250.0).abs() < 1e-6);
    }

    #[test]
    fn the_next_day_continues_from_the_carried_value()
    {
        let result = curve(24, 30, 200.0, Some(2400.0), &[], &[], &[]);
        assert_eq!(result.points, vec![(at(24), 200.0), (at(30), -400.0)]);
        assert!((result.value + 400.0).abs() < 1e-6);
    }

    #[test]
    fn workouts_burn_extra_over_their_span_and_today_stops_now()
    {
        let result = curve(
            0,
            12,
            0.0,
            Some(2400.0),
            &[FoodEvent::instant(at(20), 500.0)],
            &[WorkoutSpan {
                start: at(9),
                end: at(11),
                kcal: 400.0,
            }],
            &[],
        );
        assert_eq!(
            result.points,
            vec![(at(0), 0.0), (at(9), -900.0), (at(11), -1500.0), (at(12), -1600.0)]
        );
        assert_eq!(result.eaten, 0.0);
        assert!((result.burned_workouts - 400.0).abs() < 1e-6);
        assert!((result.burned_base - 1200.0).abs() < 1e-6);
    }

    #[test]
    fn a_reset_sets_the_value_at_its_moment()
    {
        let result = curve(
            0,
            12,
            -500.0,
            Some(2400.0),
            &[FoodEvent::instant(at(6), 300.0)],
            &[],
            &[EnergyReset {
                ts: at(6),
                kcal: 1000.0,
            }],
        );
        assert_eq!(
            result.points,
            vec![
                (at(0), -500.0),
                (at(6), -1100.0),
                (at(6), -800.0),
                (at(6), 1000.0),
                (at(12), 400.0),
            ]
        );
        assert!((result.value - 400.0).abs() < 1e-6);
    }

    #[test]
    fn carried_value_counts_food_workouts_and_burn_since_the_anchor()
    {
        let span = WorkoutSpan {
            start: at(-1),
            end: at(1),
            kcal: 300.0,
        };
        let value = carried_value(100.0, at(0), at(12), Some(2400.0), 700.0, &[span]);
        assert!((value - (100.0 + 700.0 - 150.0 - 1200.0)).abs() < 1e-6);
        assert_eq!(workout_share(&span, at(2), at(5)), 0.0);
    }

    #[test]
    fn future_windows_are_empty()
    {
        let result = curve(24, 12, 50.0, Some(2000.0), &[], &[], &[]);
        assert!(result.points.is_empty());
        assert_eq!(result.value, 50.0);
    }
}
