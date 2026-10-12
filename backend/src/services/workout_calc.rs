const RESTING_MET: f64 = 1.0;
const DEFAULT_MET: f64 = 5.0;
const BASE_INTENSITY_FACTOR: f64 = 0.6;
const INTENSITY_STEP: f64 = 0.08;
const MAX_SESSION_HOURS: f64 = 6.0;

pub struct ExerciseLoad
{
    pub met: f64,
    pub done_sets: u32,
}

pub fn average_met(a_loads: &[ExerciseLoad]) -> f64
{
    let weighted: f64 = a_loads.iter().map(|load| load.met * f64::from(load.done_sets)).sum();
    let sets: u32 = a_loads.iter().map(|load| load.done_sets).sum();
    if sets > 0
    {
        return weighted / f64::from(sets);
    }
    if a_loads.is_empty()
    {
        return DEFAULT_MET;
    }
    a_loads.iter().map(|load| load.met).sum::<f64>() / a_loads.len() as f64
}

pub fn intensity_factor(a_intensity: i32) -> f64
{
    BASE_INTENSITY_FACTOR + INTENSITY_STEP * f64::from(a_intensity.clamp(1, 10))
}

pub fn session_kcal(a_average_met: f64, a_intensity: i32, a_weight_kg: f64, a_hours: f64) -> f64
{
    let net_met = (a_average_met * intensity_factor(a_intensity) - RESTING_MET).max(0.0);
    let hours = a_hours.clamp(0.0, MAX_SESSION_HOURS);
    (net_met * a_weight_kg * hours * 10.0).round() / 10.0
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn average_met_is_weighted_by_completed_sets()
    {
        let loads = [
            ExerciseLoad { met: 6.0, done_sets: 3 },
            ExerciseLoad { met: 3.5, done_sets: 1 },
        ];
        assert!((average_met(&loads) - 5.375).abs() < 1e-9);
        assert_eq!(average_met(&[]), DEFAULT_MET);
        let planned = [
            ExerciseLoad { met: 4.0, done_sets: 0 },
            ExerciseLoad { met: 6.0, done_sets: 0 },
        ];
        assert_eq!(average_met(&planned), 5.0);
    }

    #[test]
    fn energy_excludes_resting_metabolism_and_scales_with_intensity()
    {
        let moderate = session_kcal(5.0, 5, 80.0, 1.0);
        assert_eq!(moderate, 320.0);
        assert!(session_kcal(5.0, 9, 80.0, 1.0) > moderate);
        assert!(session_kcal(5.0, 2, 80.0, 1.0) < moderate);
        assert_eq!(session_kcal(1.0, 1, 80.0, 1.0), 0.0);
        assert_eq!(
            session_kcal(5.0, 5, 80.0, 10.0),
            session_kcal(5.0, 5, 80.0, MAX_SESSION_HOURS)
        );
    }
}
