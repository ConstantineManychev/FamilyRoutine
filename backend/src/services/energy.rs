use chrono::{DateTime, Utc};

const POINT_SCALE: f64 = 10.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct FoodEvent
{
    pub ts: DateTime<Utc>,
    pub kcal: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WorkoutSpan
{
    pub start: DateTime<Utc>,
    pub end: DateTime<Utc>,
    pub kcal: f64,
}

#[derive(Debug, Clone, PartialEq)]
pub struct EnergyCurve
{
    pub points: Vec<(DateTime<Utc>, f64)>,
    pub eaten: f64,
    pub burned_base: f64,
    pub burned_workouts: f64,
}

impl EnergyCurve
{
    pub fn balance(&self) -> f64
    {
        self.eaten - self.burned_base - self.burned_workouts
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

pub fn energy_curve(
    a_day_start: DateTime<Utc>,
    a_day_end: DateTime<Utc>,
    a_until: DateTime<Utc>,
    a_daily_burn: Option<f64>,
    a_foods: &[FoodEvent],
    a_workouts: &[WorkoutSpan],
) -> EnergyCurve
{
    let until = a_until.min(a_day_end);
    if until <= a_day_start
    {
        return EnergyCurve {
            points: Vec::new(),
            eaten: 0.0,
            burned_base: 0.0,
            burned_workouts: 0.0,
        };
    }

    let day_seconds = seconds(a_day_start, a_day_end).max(1.0);
    let base_rate = a_daily_burn.unwrap_or(0.0).max(0.0) / day_seconds;
    let clamp = |a_ts: DateTime<Utc>| a_ts.clamp(a_day_start, until);
    let spans: Vec<(DateTime<Utc>, DateTime<Utc>, f64)> = a_workouts
        .iter()
        .filter(|span| span.end > span.start && span.end > a_day_start && span.start < until && span.kcal > 0.0)
        .map(|span| {
            (
                clamp(span.start),
                clamp(span.end),
                span.kcal / seconds(span.start, span.end),
            )
        })
        .collect();
    let foods: Vec<(DateTime<Utc>, f64)> = a_foods
        .iter()
        .filter(|food| food.kcal > 0.0)
        .map(|food| (clamp(food.ts), food.kcal))
        .collect();

    let mut moments: Vec<DateTime<Utc>> = vec![a_day_start, until];
    moments.extend(foods.iter().map(|(ts, _)| *ts));
    moments.extend(spans.iter().flat_map(|(start, end, _)| [*start, *end]));
    moments.sort();
    moments.dedup();

    let mut value = 0.0;
    let mut eaten = 0.0;
    let mut burned_workouts = 0.0;
    let mut points = Vec::with_capacity(moments.len() * 2);
    for (index, moment) in moments.iter().enumerate()
    {
        points.push((*moment, rounded(value)));
        let jump: f64 = foods.iter().filter(|(ts, _)| ts == moment).map(|(_, kcal)| kcal).sum();
        if jump > 0.0
        {
            value += jump;
            eaten += jump;
            points.push((*moment, rounded(value)));
        }
        let Some(next) = moments.get(index + 1)
        else
        {
            break;
        };
        let interval = seconds(*moment, *next);
        let workout_rate: f64 = spans
            .iter()
            .filter(|(start, end, _)| start <= moment && end >= next)
            .map(|(_, _, rate)| rate)
            .sum();
        burned_workouts += workout_rate * interval;
        value -= (base_rate + workout_rate) * interval;
    }

    EnergyCurve {
        points,
        eaten,
        burned_base: base_rate * seconds(a_day_start, until),
        burned_workouts,
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

    #[test]
    fn food_jumps_and_the_day_burns_evenly()
    {
        let curve = energy_curve(
            at(0),
            at(24),
            at(24),
            Some(2400.0),
            &[
                FoodEvent { ts: at(8), kcal: 600.0 },
                FoodEvent {
                    ts: at(13),
                    kcal: 900.0,
                },
            ],
            &[],
        );
        assert_eq!(
            curve.points,
            vec![
                (at(0), 0.0),
                (at(8), -800.0),
                (at(8), -200.0),
                (at(13), -700.0),
                (at(13), 200.0),
                (at(24), -900.0),
            ]
        );
        assert_eq!(curve.eaten, 1500.0);
        assert!((curve.burned_base - 2400.0).abs() < 1e-6);
        assert!((curve.balance() + 900.0).abs() < 1e-6);
    }

    #[test]
    fn workouts_burn_extra_over_their_span_and_today_stops_now()
    {
        let curve = energy_curve(
            at(0),
            at(24),
            at(12),
            Some(2400.0),
            &[FoodEvent {
                ts: at(20),
                kcal: 500.0,
            }],
            &[WorkoutSpan {
                start: at(9),
                end: at(11),
                kcal: 400.0,
            }],
        );
        assert_eq!(
            curve.points,
            vec![
                (at(0), 0.0),
                (at(9), -900.0),
                (at(11), -1500.0),
                (at(12), -1600.0),
                (at(12), -1100.0),
            ]
        );
        assert!((curve.burned_workouts - 400.0).abs() < 1e-6);
        assert!((curve.burned_base - 1200.0).abs() < 1e-6);
    }

    #[test]
    fn spans_crossing_midnight_count_only_their_share_and_future_days_are_empty()
    {
        let curve = energy_curve(
            at(0),
            at(24),
            at(24),
            None,
            &[],
            &[WorkoutSpan {
                start: at(-1),
                end: at(1),
                kcal: 300.0,
            }],
        );
        assert_eq!(curve.points, vec![(at(0), 0.0), (at(1), -150.0), (at(24), -150.0)]);
        assert_eq!(curve.burned_base, 0.0);

        let future = energy_curve(at(24), at(48), at(12), Some(2000.0), &[], &[]);
        assert!(future.points.is_empty());
        assert_eq!(future.balance(), 0.0);
    }

    #[test]
    fn short_days_spread_the_burn_over_their_real_length()
    {
        let curve = energy_curve(at(0), at(23), at(23), Some(2300.0), &[], &[]);
        assert_eq!(curve.points.last(), Some(&(at(23), -2300.0)));
    }
}
