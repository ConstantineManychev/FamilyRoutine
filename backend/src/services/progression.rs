use chrono::{DateTime, Utc};
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use shared_schema::{ExType, ProgressPointDto, ProgressionAdviceDto, ProgressionKind, SessionSetDto};
use uuid::Uuid;

const UPPER_BODY_STEP: Decimal = Decimal::from_parts(25, 0, 0, false, 1);
const LOWER_BODY_STEP: Decimal = Decimal::from_parts(5, 0, 0, false, 0);
const LIGHT_UPPER_STEP: Decimal = Decimal::from_parts(1, 0, 0, false, 0);
const LIGHT_LOWER_STEP: Decimal = Decimal::from_parts(25, 0, 0, false, 1);
const LIGHT_WEIGHT_LIMIT: Decimal = Decimal::from_parts(20, 0, 0, false, 0);
const DELOAD_FACTOR: Decimal = Decimal::from_parts(9, 0, 0, false, 1);
const SHORT_HOLD_LIMIT_SEC: i32 = 600;
const SHORT_HOLD_GROWTH_PCT: i32 = 10;
const LONG_HOLD_GROWTH_PCT: i32 = 5;
const TIME_GRANULARITY_SEC: i32 = 5;
const MAX_DURATION_SEC: i32 = 7200;
const MAX_REPS: i32 = 200;
const MAX_WEIGHT: Decimal = Decimal::from_parts(1000, 0, 0, false, 0);
const E1RM_MAX_REPS: i32 = 12;
const EPLEY_DIVISOR: f64 = 30.0;

pub struct ExerciseTraits
{
    pub ex_type: ExType,
    pub is_lower_body: bool,
}

pub struct PlannedExercise
{
    pub sets: usize,
    pub reps_min: Option<i32>,
    pub reps_max: Option<i32>,
    pub duration_sec: Option<i32>,
    pub weight_kg: Option<Decimal>,
    pub weight_step: Option<Decimal>,
}

pub struct Suggestion
{
    pub sets: Vec<SessionSetDto>,
    pub advice: Option<ProgressionAdviceDto>,
}

pub fn suggest(a_plan: &PlannedExercise, a_traits: &ExerciseTraits, a_history: &[Vec<SessionSetDto>]) -> Suggestion
{
    let Some(last) = a_history.first().filter(|sets| !sets.is_empty())
    else
    {
        return from_plan(a_plan);
    };

    if a_traits.ex_type == ExType::Flexibility
    {
        return repeat(a_plan, last);
    }
    if is_timed(a_plan, a_traits, last)
    {
        return progress_time(a_plan, last);
    }
    if top_weight(last).is_some_and(|weight| weight > Decimal::ZERO)
    {
        return progress_weight(a_plan, a_traits, a_history);
    }
    progress_bodyweight(a_plan, last)
}

fn is_timed(a_plan: &PlannedExercise, a_traits: &ExerciseTraits, a_last: &[SessionSetDto]) -> bool
{
    let has_reps =
        a_plan.reps_min.is_some() || a_plan.reps_max.is_some() || a_last.iter().any(|set| set.reps.is_some());
    !has_reps && (a_plan.duration_sec.is_some() || a_traits.ex_type == ExType::Cardio)
}

fn from_plan(a_plan: &PlannedExercise) -> Suggestion
{
    let set = SessionSetDto {
        reps: a_plan.reps_max.or(a_plan.reps_min),
        weight_kg: a_plan.weight_kg,
        duration_sec: a_plan.duration_sec,
        is_done: false,
    };
    Suggestion {
        sets: vec![set; a_plan.sets],
        advice: None,
    }
}

fn repeat(a_plan: &PlannedExercise, a_last: &[SessionSetDto]) -> Suggestion
{
    Suggestion {
        sets: (0..a_plan.sets)
            .map(|index| fresh(nth(a_last, index), a_plan))
            .collect(),
        advice: None,
    }
}

fn nth(a_sets: &[SessionSetDto], a_index: usize) -> &SessionSetDto
{
    a_sets.get(a_index).unwrap_or_else(|| &a_sets[a_sets.len() - 1])
}

fn fresh(a_set: &SessionSetDto, a_plan: &PlannedExercise) -> SessionSetDto
{
    SessionSetDto {
        reps: a_set.reps.or(a_plan.reps_max).or(a_plan.reps_min),
        weight_kg: a_set.weight_kg.or(a_plan.weight_kg),
        duration_sec: a_set.duration_sec.or(a_plan.duration_sec),
        is_done: false,
    }
}

fn reps_range(a_plan: &PlannedExercise) -> (Option<i32>, Option<i32>)
{
    (a_plan.reps_min.or(a_plan.reps_max), a_plan.reps_max.or(a_plan.reps_min))
}

fn top_weight(a_sets: &[SessionSetDto]) -> Option<Decimal>
{
    a_sets.iter().filter_map(|set| set.weight_kg).max()
}

fn is_complete(a_plan: &PlannedExercise, a_sets: &[SessionSetDto]) -> bool
{
    a_sets.len() >= a_plan.sets
}

fn progress_time(a_plan: &PlannedExercise, a_last: &[SessionSetDto]) -> Suggestion
{
    let achieved = a_last.iter().filter_map(|set| set.duration_sec).min();
    let target = a_plan.duration_sec.or(achieved);
    let (Some(achieved), Some(target)) = (achieved, target)
    else
    {
        return repeat(a_plan, a_last);
    };

    if !is_complete(a_plan, a_last) || achieved < target
    {
        let mut suggestion = repeat(a_plan, a_last);
        for set in &mut suggestion.sets
        {
            set.duration_sec = Some(target.max(set.duration_sec.unwrap_or(0)));
        }
        suggestion.advice = Some(advice(ProgressionKind::Hold, Some(target.into()), Some(target.into())));
        return suggestion;
    }

    let next = (achieved + time_growth(achieved)).min(MAX_DURATION_SEC);
    let mut suggestion = repeat(a_plan, a_last);
    for set in &mut suggestion.sets
    {
        set.duration_sec = Some(next);
    }
    suggestion.advice = Some(advice(
        ProgressionKind::AddTime,
        Some(achieved.into()),
        Some(next.into()),
    ));
    suggestion
}

fn time_growth(a_duration_sec: i32) -> i32
{
    let pct = if a_duration_sec < SHORT_HOLD_LIMIT_SEC
    {
        SHORT_HOLD_GROWTH_PCT
    }
    else
    {
        LONG_HOLD_GROWTH_PCT
    };
    let raw = a_duration_sec * pct;
    let rounded = (raw + 100 * TIME_GRANULARITY_SEC - 1) / (100 * TIME_GRANULARITY_SEC) * TIME_GRANULARITY_SEC;
    rounded.max(TIME_GRANULARITY_SEC)
}

fn progress_weight(a_plan: &PlannedExercise, a_traits: &ExerciseTraits, a_history: &[Vec<SessionSetDto>])
    -> Suggestion
{
    let last = &a_history[0];
    let weight = top_weight(last).unwrap_or_default();
    let (low, high) = reps_range(a_plan);

    if let Some(low) = low
    {
        let is_stalled = a_history.len() >= 2
            && a_history[..2]
                .iter()
                .all(|sets| is_below_range(sets, low) && top_weight(sets) == Some(weight));
        if is_stalled
        {
            let lighter = deload(weight);
            return uniform(
                a_plan,
                Some(low),
                Some(lighter),
                advice(ProgressionKind::Deload, Some(weight), Some(lighter)),
            );
        }
    }

    if let Some(high) = high
    {
        let is_topped = is_complete(a_plan, last)
            && last
                .iter()
                .all(|set| set.reps.unwrap_or(0) >= high && set.weight_kg == Some(weight));
        if is_topped
        {
            let heavier = (weight + weight_step(a_plan, a_traits, weight)).min(MAX_WEIGHT);
            return uniform(
                a_plan,
                low,
                Some(heavier),
                advice(ProgressionKind::IncreaseWeight, Some(weight), Some(heavier)),
            );
        }
    }

    let sets = (0..a_plan.sets)
        .map(|index| {
            let before = last.get(index);
            SessionSetDto {
                reps: Some(next_reps(before.and_then(|set| set.reps), low, high)),
                weight_kg: before.and_then(|set| set.weight_kg).or(Some(weight)),
                duration_sec: before.and_then(|set| set.duration_sec),
                is_done: false,
            }
        })
        .collect();
    Suggestion {
        sets,
        advice: Some(advice(ProgressionKind::AddReps, Some(weight), Some(weight))),
    }
}

fn is_below_range(a_sets: &[SessionSetDto], a_low: i32) -> bool
{
    a_sets.iter().any(|set| set.reps.unwrap_or(0) < a_low)
}

fn next_reps(a_previous: Option<i32>, a_low: Option<i32>, a_high: Option<i32>) -> i32
{
    let base = a_previous.or(a_low).unwrap_or(1);
    let next = (base + 1).min(MAX_REPS);
    match a_high
    {
        Some(high) => next.min(high.max(base)),
        None => next,
    }
}

fn uniform(
    a_plan: &PlannedExercise,
    a_reps: Option<i32>,
    a_weight: Option<Decimal>,
    a_advice: ProgressionAdviceDto,
) -> Suggestion
{
    let set = SessionSetDto {
        reps: a_reps.or(a_plan.reps_max),
        weight_kg: a_weight,
        duration_sec: None,
        is_done: false,
    };
    Suggestion {
        sets: vec![set; a_plan.sets],
        advice: Some(a_advice),
    }
}

fn weight_step(a_plan: &PlannedExercise, a_traits: &ExerciseTraits, a_weight: Decimal) -> Decimal
{
    if let Some(step) = a_plan.weight_step
    {
        return step;
    }
    match (a_traits.is_lower_body, a_weight < LIGHT_WEIGHT_LIMIT)
    {
        (true, true) => LIGHT_LOWER_STEP,
        (true, false) => LOWER_BODY_STEP,
        (false, true) => LIGHT_UPPER_STEP,
        (false, false) => UPPER_BODY_STEP,
    }
}

fn deload(a_weight: Decimal) -> Decimal
{
    let two = Decimal::TWO;
    ((a_weight * DELOAD_FACTOR * two).floor() / two).normalize()
}

fn progress_bodyweight(a_plan: &PlannedExercise, a_last: &[SessionSetDto]) -> Suggestion
{
    let (low, high) = reps_range(a_plan);
    if let Some(high) = high
    {
        let is_topped = is_complete(a_plan, a_last) && a_last.iter().all(|set| set.reps.unwrap_or(0) >= high);
        if is_topped
        {
            return uniform(
                a_plan,
                Some(high),
                None,
                advice(ProgressionKind::BodyweightTop, Some(high.into()), Some(high.into())),
            );
        }
    }

    let sets = (0..a_plan.sets)
        .map(|index| SessionSetDto {
            reps: Some(next_reps(a_last.get(index).and_then(|set| set.reps), low, high)),
            weight_kg: None,
            duration_sec: None,
            is_done: false,
        })
        .collect();
    Suggestion {
        sets,
        advice: Some(advice(ProgressionKind::AddReps, None, None)),
    }
}

fn advice(a_kind: ProgressionKind, a_from: Option<Decimal>, a_to: Option<Decimal>) -> ProgressionAdviceDto
{
    ProgressionAdviceDto {
        kind: a_kind,
        from: a_from,
        to: a_to,
    }
}

pub fn estimated_max(a_weight: Decimal, a_reps: i32) -> Option<Decimal>
{
    if a_weight <= Decimal::ZERO || !(1..=E1RM_MAX_REPS).contains(&a_reps)
    {
        return None;
    }
    let mut value = if a_reps == 1
    {
        a_weight
    }
    else
    {
        let estimate = a_weight.to_f64()? * (1.0 + f64::from(a_reps) / EPLEY_DIVISOR);
        Decimal::from_f64_retain(estimate)?.round_dp(1)
    };
    value.rescale(1);
    Some(value)
}

pub fn progress_point(
    a_session_id: Uuid,
    a_started_ts: DateTime<Utc>,
    a_day_name: Option<String>,
    a_sets: &[SessionSetDto],
) -> ProgressPointDto
{
    let weighted = a_sets.iter().filter_map(|set| {
        set.weight_kg
            .filter(|weight| *weight > Decimal::ZERO)
            .map(|weight| (weight, set.reps.unwrap_or(0)))
    });
    let top = weighted
        .clone()
        .max_by(|left, right| left.0.cmp(&right.0).then(left.1.cmp(&right.1)));
    let e1rm = weighted.filter_map(|(weight, reps)| estimated_max(weight, reps)).max();
    let reps_only = a_sets.iter().filter_map(|set| set.reps).max();

    ProgressPointDto {
        session_id: a_session_id,
        started_ts: a_started_ts,
        day_name: a_day_name,
        e1rm_kg: e1rm,
        top_weight_kg: top.map(|(weight, _)| weight),
        top_reps: top.map(|(_, reps)| reps).or(reps_only),
        best_duration_sec: a_sets.iter().filter_map(|set| set.duration_sec).max(),
        total_reps: a_sets.iter().filter_map(|set| set.reps).sum(),
        volume_kg: a_sets
            .iter()
            .map(|set| set.weight_kg.unwrap_or_default() * Decimal::from(set.reps.unwrap_or(0)))
            .sum(),
    }
}

#[cfg(test)]
mod tests
{
    use super::*;

    fn set(a_reps: i32, a_weight: f64) -> SessionSetDto
    {
        SessionSetDto {
            reps: Some(a_reps),
            weight_kg: Decimal::from_f64_retain(a_weight).map(|value| value.round_dp(2)),
            duration_sec: None,
            is_done: true,
        }
    }

    fn reps_only(a_reps: i32) -> SessionSetDto
    {
        SessionSetDto {
            reps: Some(a_reps),
            weight_kg: None,
            duration_sec: None,
            is_done: true,
        }
    }

    fn timed(a_seconds: i32) -> SessionSetDto
    {
        SessionSetDto {
            reps: None,
            weight_kg: None,
            duration_sec: Some(a_seconds),
            is_done: true,
        }
    }

    fn plan(a_sets: usize, a_low: Option<i32>, a_high: Option<i32>) -> PlannedExercise
    {
        PlannedExercise {
            sets: a_sets,
            reps_min: a_low,
            reps_max: a_high,
            duration_sec: None,
            weight_kg: Some(Decimal::from(60)),
            weight_step: None,
        }
    }

    fn traits(a_is_lower: bool) -> ExerciseTraits
    {
        ExerciseTraits {
            ex_type: ExType::Strength,
            is_lower_body: a_is_lower,
        }
    }

    fn kg(a_value: &str) -> Decimal
    {
        a_value.parse().unwrap()
    }

    #[test]
    fn first_session_follows_the_program()
    {
        let result = suggest(&plan(3, Some(8), Some(10)), &traits(false), &[]);
        assert!(result.advice.is_none());
        assert_eq!(result.sets.len(), 3);
        assert!(result
            .sets
            .iter()
            .all(|set| set.reps == Some(10) && set.weight_kg == Some(kg("60"))));
    }

    #[test]
    fn top_of_range_adds_weight_and_restarts_reps()
    {
        let history = vec![vec![set(10, 60.0), set(10, 60.0), set(11, 60.0)]];
        let upper = suggest(&plan(3, Some(8), Some(10)), &traits(false), &history);
        let advice = upper.advice.unwrap();
        assert_eq!(advice.kind, ProgressionKind::IncreaseWeight);
        assert_eq!((advice.from, advice.to), (Some(kg("60")), Some(kg("62.5"))));
        assert!(upper
            .sets
            .iter()
            .all(|set| set.reps == Some(8) && set.weight_kg == Some(kg("62.5"))));

        let legs = suggest(&plan(3, Some(8), Some(10)), &traits(true), &history);
        assert_eq!(legs.advice.unwrap().to, Some(kg("65")));

        let mut stepped = plan(3, Some(8), Some(10));
        stepped.weight_step = Some(kg("1.25"));
        assert_eq!(
            suggest(&stepped, &traits(true), &history).advice.unwrap().to,
            Some(kg("61.25"))
        );

        let light = vec![vec![set(12, 8.0), set(12, 8.0), set(12, 8.0)]];
        assert_eq!(
            suggest(&plan(3, Some(10), Some(12)), &traits(false), &light)
                .advice
                .unwrap()
                .to,
            Some(kg("9"))
        );
    }

    #[test]
    fn missing_reps_keep_the_weight_and_add_one_rep_per_set()
    {
        let history = vec![vec![set(10, 60.0), set(9, 60.0), set(8, 60.0)]];
        let result = suggest(&plan(3, Some(8), Some(10)), &traits(false), &history);
        assert_eq!(result.advice.unwrap().kind, ProgressionKind::AddReps);
        let reps: Vec<_> = result.sets.iter().map(|set| set.reps.unwrap()).collect();
        assert_eq!(reps, [10, 10, 9]);
        assert!(result.sets.iter().all(|set| set.weight_kg == Some(kg("60"))));

        let short = vec![vec![set(10, 60.0), set(10, 60.0)]];
        let unfinished = suggest(&plan(3, Some(8), Some(10)), &traits(false), &short);
        assert_eq!(unfinished.advice.unwrap().kind, ProgressionKind::AddReps);
        assert_eq!(unfinished.sets[2].reps, Some(9));
    }

    #[test]
    fn two_sessions_below_range_at_the_same_weight_deload_by_ten_percent()
    {
        let history = vec![
            vec![set(7, 62.5), set(6, 62.5), set(6, 62.5)],
            vec![set(8, 62.5), set(7, 62.5), set(6, 62.5)],
        ];
        let result = suggest(&plan(3, Some(8), Some(10)), &traits(false), &history);
        let advice = result.advice.unwrap();
        assert_eq!(advice.kind, ProgressionKind::Deload);
        assert_eq!((advice.from, advice.to), (Some(kg("62.5")), Some(kg("56"))));
        assert!(result
            .sets
            .iter()
            .all(|set| set.reps == Some(8) && set.weight_kg == Some(kg("56"))));

        let changed = vec![
            vec![set(7, 62.5), set(6, 62.5), set(6, 62.5)],
            vec![set(7, 60.0), set(6, 60.0), set(6, 60.0)],
        ];
        assert_eq!(
            suggest(&plan(3, Some(8), Some(10)), &traits(false), &changed)
                .advice
                .unwrap()
                .kind,
            ProgressionKind::AddReps
        );
    }

    #[test]
    fn bodyweight_exercises_add_reps_until_the_top()
    {
        let mut pull_ups = plan(3, Some(6), Some(10));
        pull_ups.weight_kg = None;
        let body = ExerciseTraits {
            ex_type: ExType::Strength,
            is_lower_body: false,
        };
        let growing = suggest(&pull_ups, &body, &[vec![reps_only(8), reps_only(7), reps_only(6)]]);
        assert_eq!(growing.advice.unwrap().kind, ProgressionKind::AddReps);
        assert_eq!(
            growing.sets.iter().map(|set| set.reps.unwrap()).collect::<Vec<_>>(),
            [9, 8, 7]
        );

        let topped = suggest(&pull_ups, &body, &[vec![reps_only(10), reps_only(10), reps_only(12)]]);
        assert_eq!(topped.advice.unwrap().kind, ProgressionKind::BodyweightTop);
        assert!(topped.sets.iter().all(|set| set.reps == Some(10)));

        let weighted = suggest(&pull_ups, &body, &[vec![set(10, 5.0), set(10, 5.0), set(10, 5.0)]]);
        assert_eq!(weighted.advice.unwrap().kind, ProgressionKind::IncreaseWeight);
    }

    #[test]
    fn timed_exercises_grow_by_time_once_every_set_holds_the_target()
    {
        let plank = PlannedExercise {
            sets: 3,
            reps_min: None,
            reps_max: None,
            duration_sec: Some(60),
            weight_kg: None,
            weight_step: None,
        };
        let held = suggest(&plank, &traits(false), &[vec![timed(60), timed(65), timed(62)]]);
        let advice = held.advice.unwrap();
        assert_eq!(advice.kind, ProgressionKind::AddTime);
        assert_eq!(
            (advice.from, advice.to),
            (Some(Decimal::from(60)), Some(Decimal::from(70)))
        );
        assert!(held.sets.iter().all(|set| set.duration_sec == Some(70)));

        let short = suggest(&plank, &traits(false), &[vec![timed(60), timed(45), timed(40)]]);
        assert_eq!(short.advice.unwrap().kind, ProgressionKind::Hold);
        assert!(short.sets.iter().all(|set| set.duration_sec == Some(60)));

        let run = PlannedExercise {
            sets: 1,
            reps_min: None,
            reps_max: None,
            duration_sec: Some(1800),
            weight_kg: None,
            weight_step: None,
        };
        let cardio = ExerciseTraits {
            ex_type: ExType::Cardio,
            is_lower_body: false,
        };
        assert_eq!(
            suggest(&run, &cardio, &[vec![timed(1800)]]).sets[0].duration_sec,
            Some(1890)
        );
    }

    #[test]
    fn flexibility_repeats_the_last_session_without_advice()
    {
        let stretch = ExerciseTraits {
            ex_type: ExType::Flexibility,
            is_lower_body: false,
        };
        let mut yoga = plan(1, None, None);
        yoga.weight_kg = None;
        yoga.duration_sec = Some(900);
        let result = suggest(&yoga, &stretch, &[vec![timed(1200)]]);
        assert!(result.advice.is_none());
        assert_eq!(result.sets[0].duration_sec, Some(1200));
    }

    #[test]
    fn progress_point_summarises_the_best_set_and_volume()
    {
        let sets = [set(5, 100.0), set(8, 90.0), set(5, 100.0), set(15, 50.0)];
        let point = progress_point(Uuid::nil(), Utc::now(), None, &sets);
        assert_eq!(point.top_weight_kg, Some(kg("100")));
        assert_eq!(point.top_reps, Some(5));
        assert_eq!(point.e1rm_kg, Some(kg("116.7")));
        assert_eq!(point.total_reps, 33);
        assert_eq!(point.volume_kg, kg("2470"));

        let body = progress_point(Uuid::nil(), Utc::now(), None, &[reps_only(12), reps_only(9)]);
        assert_eq!(
            (body.top_weight_kg, body.top_reps, body.e1rm_kg),
            (None, Some(12), None)
        );
        let plank = progress_point(Uuid::nil(), Utc::now(), None, &[timed(45), timed(60)]);
        assert_eq!(plank.best_duration_sec, Some(60));
    }

    #[test]
    fn estimated_max_uses_epley_up_to_twelve_reps()
    {
        assert_eq!(estimated_max(kg("100"), 1), Some(kg("100")));
        assert_eq!(estimated_max(kg("100"), 10), Some(kg("133.3")));
        assert_eq!(estimated_max(kg("100"), 13), None);
        assert_eq!(estimated_max(Decimal::ZERO, 5), None);
    }
}
