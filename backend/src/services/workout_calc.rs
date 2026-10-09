use shared_schema::{DictExDto, WeightType};

const SECONDS_PER_REP: f64 = 3.0;
const DEFAULT_SET_SECONDS: f64 = 60.0;
const KCAL_PER_KG_REP: f64 = 0.015;
const SYSTEMIC_FACTOR_PER_MUSCLE: f64 = 0.05;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CalcMode
{
    Met,
    Tonnage,
}

#[derive(Debug, Clone, Copy, Default)]
pub struct SetInput
{
    pub duration_sec: Option<i32>,
    pub reps: Option<i32>,
    pub weight_kg: Option<f64>,
}

pub fn calculate_set_kcal(a_mode: CalcMode, a_ex: &DictExDto, a_user_weight_kg: f64, a_set: SetInput) -> f64
{
    if a_mode == CalcMode::Tonnage
    {
        if let (Some(reps), Some(external_kg)) = (a_set.reps, a_set.weight_kg)
        {
            let bodyweight_kg = match a_ex.weight_type
            {
                WeightType::Hybrid | WeightType::Bodyweight => a_user_weight_kg * (a_ex.bw_pct / 100.0),
                WeightType::External => 0.0,
            };

            let tonnage = (external_kg + bodyweight_kg) * f64::from(reps.max(0));
            let systemic_multiplier = 1.0 + (a_ex.musc_grps.len() as f64 * SYSTEMIC_FACTOR_PER_MUSCLE);

            return tonnage * KCAL_PER_KG_REP * systemic_multiplier;
        }
    }

    let effective_seconds = match (a_set.duration_sec, a_set.reps)
    {
        (Some(duration), _) => f64::from(duration.max(0)),
        (None, Some(reps)) => f64::from(reps.max(0)) * SECONDS_PER_REP,
        (None, None) => DEFAULT_SET_SECONDS,
    };

    a_ex.met_val * a_user_weight_kg * (effective_seconds / 3600.0)
}

#[cfg(test)]
mod tests
{
    use super::*;
    use shared_schema::{ExMuscGrpDto, ExType, MuscGrpType};
    use uuid::Uuid;

    fn exercise(a_weight_type: WeightType, a_bw_pct: f64) -> DictExDto
    {
        DictExDto {
            id: Uuid::nil(),
            name: "test".into(),
            ex_type: ExType::Strength,
            met_val: 6.0,
            weight_type: a_weight_type,
            bw_pct: a_bw_pct,
            is_custom: true,
            musc_grps: vec![
                ExMuscGrpDto {
                    grp: MuscGrpType::Chest,
                    pct: 60.0,
                },
                ExMuscGrpDto {
                    grp: MuscGrpType::Arms,
                    pct: 40.0,
                },
            ],
        }
    }

    #[test]
    fn met_mode_uses_duration()
    {
        let kcal = calculate_set_kcal(
            CalcMode::Met,
            &exercise(WeightType::External, 0.0),
            80.0,
            SetInput {
                duration_sec: Some(1800),
                ..SetInput::default()
            },
        );

        assert!((kcal - 240.0).abs() < 1e-9);
    }

    #[test]
    fn tonnage_mode_adds_bodyweight_share()
    {
        let kcal = calculate_set_kcal(
            CalcMode::Tonnage,
            &exercise(WeightType::Hybrid, 50.0),
            80.0,
            SetInput {
                reps: Some(10),
                weight_kg: Some(20.0),
                ..SetInput::default()
            },
        );

        assert!((kcal - 600.0 * KCAL_PER_KG_REP * 1.1).abs() < 1e-9);
    }

    #[test]
    fn tonnage_without_weight_falls_back_to_met()
    {
        let kcal = calculate_set_kcal(
            CalcMode::Tonnage,
            &exercise(WeightType::External, 0.0),
            60.0,
            SetInput {
                reps: Some(20),
                ..SetInput::default()
            },
        );

        assert!((kcal - 6.0).abs() < 1e-9);
    }
}
