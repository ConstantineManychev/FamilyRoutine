use chrono::{Datelike, NaiveDate};
use rust_decimal::prelude::{FromPrimitive, ToPrimitive};
use rust_decimal::{Decimal, RoundingStrategy};
use shared_schema::{ActivityLevel, GoalMode, MacrosDto, NormGap, NormKind, NormWarning, NutritionNormDto, Sex};

const PER_HUNDRED: Decimal = Decimal::ONE_HUNDRED;
const PER_100_SCALE: u32 = 2;
const AMOUNT_SCALE: u32 = 1;
const ADULT_AGE: i32 = 18;
const MALE_BMR_CONST: f64 = 5.0;
const FEMALE_BMR_CONST: f64 = -161.0;
const PROTEIN_MAX_SHARE: f64 = 0.35;
const FAT_G_PER_KG: f64 = 0.9;
const FAT_MIN_G_PER_KG: f64 = 0.8;
const FAT_MIN_SHARE: f64 = 0.25;
const FAT_MAX_SHARE: f64 = 0.3;
const KCAL_PER_KG: f64 = 7700.0;
const DAYS_PER_WEEK: f64 = 7.0;
const MAX_DEFICIT_SHARE: f64 = 0.25;
const MIN_SURPLUS_KCAL: f64 = 200.0;
const MAX_SURPLUS_KCAL: f64 = 500.0;
const FEMALE_MIN_KCAL: f64 = 1200.0;
const MALE_MIN_KCAL: f64 = 1500.0;
const MACROS_MISMATCH_SHARE: f64 = 0.1;
const TODDLER_YEARS: i32 = 3;
const CHILD_BOOST_ONE_WORKOUTS: i64 = 2;
const CHILD_BOOST_TWO_WORKOUTS: i64 = 4;
const CHILD_PA_MALE: [f64; 4] = [1.0, 1.13, 1.26, 1.42];
const CHILD_PA_FEMALE: [f64; 4] = [1.0, 1.16, 1.31, 1.56];
const KCAL_PER_G_PROTEIN: f64 = 4.0;
const KCAL_PER_G_FAT: f64 = 9.0;
const KCAL_PER_G_CARB: f64 = 4.0;

#[derive(Debug, Clone, Copy)]
pub struct Ingredient
{
    pub per_100: Option<MacrosDto>,
    pub grams: Decimal,
}

#[derive(Debug, PartialEq, Eq)]
pub struct DishMath
{
    pub raw_g: Decimal,
    pub cooked_g: Decimal,
    pub total: MacrosDto,
    pub per_100: MacrosDto,
    pub portion_g: Option<Decimal>,
    pub missing_count: usize,
}

pub struct BodyProfile
{
    pub sex: Option<Sex>,
    pub birth_date: NaiveDate,
    pub on: NaiveDate,
    pub weight_kg: Option<Decimal>,
    pub height_cm: Option<Decimal>,
    pub activity: Option<ActivityLevel>,
    pub recent_workouts: i64,
}

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GoalSettings
{
    pub mode: GoalMode,
    pub pace_kg: Option<Decimal>,
    pub target_kg: Option<Decimal>,
    pub custom: Option<MacrosDto>,
}

pub fn add(a_left: MacrosDto, a_right: MacrosDto) -> MacrosDto
{
    MacrosDto {
        kcal: a_left.kcal + a_right.kcal,
        prot: a_left.prot + a_right.prot,
        fat: a_left.fat + a_right.fat,
        carb: a_left.carb + a_right.carb,
    }
}

pub fn sum(a_items: impl IntoIterator<Item = MacrosDto>) -> MacrosDto
{
    a_items.into_iter().fold(MacrosDto::default(), add)
}

fn scale(a_macros: MacrosDto, a_factor: Decimal) -> MacrosDto
{
    MacrosDto {
        kcal: a_macros.kcal * a_factor,
        prot: a_macros.prot * a_factor,
        fat: a_macros.fat * a_factor,
        carb: a_macros.carb * a_factor,
    }
}

pub fn rounded(a_macros: MacrosDto, a_scale: u32) -> MacrosDto
{
    let round = |a_value: Decimal| half_up(a_value, a_scale);
    MacrosDto {
        kcal: round(a_macros.kcal),
        prot: round(a_macros.prot),
        fat: round(a_macros.fat),
        carb: round(a_macros.carb),
    }
}

pub fn for_grams(a_per_100: MacrosDto, a_grams: Decimal) -> MacrosDto
{
    rounded(scale(a_per_100, a_grams / PER_HUNDRED), AMOUNT_SCALE)
}

pub fn amount(a_value: Decimal) -> Decimal
{
    half_up(a_value, AMOUNT_SCALE)
}

fn half_up(a_value: Decimal, a_scale: u32) -> Decimal
{
    a_value
        .round_dp_with_strategy(a_scale, RoundingStrategy::MidpointAwayFromZero)
        .normalize()
}

pub fn portion_grams(a_portions: Decimal, a_portion_g: Decimal) -> Decimal
{
    amount(a_portions * a_portion_g)
}

pub fn dish_math(
    a_ingredients: &[Ingredient],
    a_cooked_g: Option<Decimal>,
    a_serving_g: Option<Decimal>,
    a_servings: Option<i32>,
) -> DishMath
{
    let raw_g: Decimal = a_ingredients.iter().map(|ingredient| ingredient.grams).sum();
    let cooked_g = a_cooked_g.unwrap_or(raw_g);
    let exact = sum(a_ingredients.iter().filter_map(|ingredient| {
        ingredient
            .per_100
            .map(|per_100| scale(per_100, ingredient.grams / PER_HUNDRED))
    }));
    let per_100 = if cooked_g > Decimal::ZERO
    {
        rounded(scale(exact, PER_HUNDRED / cooked_g), PER_100_SCALE)
    }
    else
    {
        MacrosDto::default()
    };
    let portion_g = a_serving_g.or_else(|| {
        a_servings
            .filter(|servings| *servings > 0)
            .map(|servings| amount(cooked_g / Decimal::from(servings)))
    });

    DishMath {
        raw_g: amount(raw_g),
        cooked_g: amount(cooked_g),
        total: rounded(exact, AMOUNT_SCALE),
        per_100,
        portion_g: portion_g.filter(|grams| *grams > Decimal::ZERO),
        missing_count: a_ingredients
            .iter()
            .filter(|ingredient| ingredient.per_100.is_none())
            .count(),
    }
}

pub fn bmr(a_is_male: bool, a_weight_kg: f64, a_height_cm: f64, a_age: f64) -> f64
{
    let base = (10.0 * a_weight_kg) + (6.25 * a_height_cm) - (5.0 * a_age);
    if a_is_male
    {
        base + MALE_BMR_CONST
    }
    else
    {
        base + FEMALE_BMR_CONST
    }
}

pub fn activity_factor(a_activity: ActivityLevel) -> f64
{
    match a_activity
    {
        ActivityLevel::Sedentary => 1.2,
        ActivityLevel::Light => 1.375,
        ActivityLevel::Moderate => 1.55,
        ActivityLevel::Active => 1.725,
        ActivityLevel::VeryActive => 1.9,
    }
}

pub fn age_months(a_birth_date: NaiveDate, a_on: NaiveDate) -> i32
{
    let mut months = (a_on.year() - a_birth_date.year()) * 12 + a_on.month() as i32 - a_birth_date.month() as i32;
    if a_on.day() < a_birth_date.day()
    {
        months -= 1;
    }
    months.max(0)
}

fn whole(a_value: f64) -> Decimal
{
    Decimal::from_f64(a_value.round()).unwrap_or_default().normalize()
}

fn as_f64(a_value: Decimal) -> f64
{
    a_value.to_f64().unwrap_or_default()
}

fn macros_of(a_kcal: f64, a_prot: f64, a_fat: f64) -> MacrosDto
{
    let prot = a_prot.round();
    let fat = a_fat.round();
    let kcal = a_kcal.round();
    let carb = ((kcal - prot * KCAL_PER_G_PROTEIN - fat * KCAL_PER_G_FAT) / KCAL_PER_G_CARB)
        .max(0.0)
        .round();
    MacrosDto {
        kcal: whole(kcal),
        prot: whole(prot),
        fat: whole(fat),
        carb: whole(carb),
    }
}

fn protein_per_kg(a_mode: GoalMode) -> f64
{
    match a_mode
    {
        GoalMode::Lose => 2.0,
        GoalMode::Maintain => 1.6,
        GoalMode::Gain => 1.8,
    }
}

pub fn adult_macros(a_kcal: f64, a_weight_kg: f64, a_mode: GoalMode) -> MacrosDto
{
    let prot = (protein_per_kg(a_mode) * a_weight_kg).min(PROTEIN_MAX_SHARE * a_kcal / KCAL_PER_G_PROTEIN);
    let fat = (FAT_G_PER_KG * a_weight_kg)
        .max(FAT_MIN_SHARE * a_kcal / KCAL_PER_G_FAT)
        .min(FAT_MAX_SHARE * a_kcal / KCAL_PER_G_FAT)
        .max(FAT_MIN_G_PER_KG * a_weight_kg);
    macros_of(a_kcal, prot, fat)
}

fn safe_minimum(a_sex: Sex) -> f64
{
    match a_sex
    {
        Sex::Female => FEMALE_MIN_KCAL,
        Sex::Male => MALE_MIN_KCAL,
    }
}

fn pace_of(a_kcal_per_day: f64) -> Decimal
{
    Decimal::from_f64((a_kcal_per_day * DAYS_PER_WEEK / KCAL_PER_KG * 100.0).round() / 100.0)
        .unwrap_or_default()
        .normalize()
}

fn weeks_to(a_weight_kg: f64, a_target_kg: f64, a_pace: f64) -> Option<i32>
{
    if a_pace <= 0.0
    {
        return None;
    }
    let weeks = ((a_weight_kg - a_target_kg).abs() / a_pace).ceil();
    i32::try_from(weeks as i64).ok()
}

fn is_target_passed(a_mode: GoalMode, a_weight_kg: f64, a_target_kg: f64) -> bool
{
    match a_mode
    {
        GoalMode::Lose => a_target_kg >= a_weight_kg,
        GoalMode::Gain => a_target_kg <= a_weight_kg,
        GoalMode::Maintain => false,
    }
}

fn custom_warnings(a_custom: MacrosDto, a_floor: Option<f64>) -> Vec<NormWarning>
{
    let mut warnings = Vec::new();
    let kcal = as_f64(a_custom.kcal);
    if a_floor.is_some_and(|floor| kcal < floor)
    {
        warnings.push(NormWarning::CustomBelowFloor);
    }
    let from_macros = as_f64(a_custom.prot) * KCAL_PER_G_PROTEIN
        + as_f64(a_custom.fat) * KCAL_PER_G_FAT
        + as_f64(a_custom.carb) * KCAL_PER_G_CARB;
    if kcal > 0.0 && ((from_macros - kcal).abs() / kcal) > MACROS_MISMATCH_SHARE
    {
        warnings.push(NormWarning::CustomMacrosMismatch);
    }
    warnings
}

pub fn daily_norm(a_profile: &BodyProfile, a_goal: &GoalSettings) -> Result<NutritionNormDto, Vec<NormGap>>
{
    let months = age_months(a_profile.birth_date, a_profile.on);
    if months < ADULT_AGE * 12
    {
        return child_norm(a_profile, months);
    }
    adult_norm(a_profile, a_goal, months / 12)
}

fn adult_gaps(a_profile: &BodyProfile) -> Vec<NormGap>
{
    [
        (a_profile.weight_kg.is_none(), NormGap::Weight),
        (a_profile.height_cm.is_none(), NormGap::Height),
        (a_profile.sex.is_none(), NormGap::Sex),
        (a_profile.activity.is_none(), NormGap::Activity),
    ]
    .into_iter()
    .filter_map(|(is_missing, gap)| is_missing.then_some(gap))
    .collect()
}

fn adult_norm(a_profile: &BodyProfile, a_goal: &GoalSettings, a_age: i32) -> Result<NutritionNormDto, Vec<NormGap>>
{
    let gaps = adult_gaps(a_profile);
    let base = NutritionNormDto {
        target: MacrosDto::default(),
        kind: NormKind::Adult,
        mode: a_goal.mode,
        age: a_age,
        maintenance_kcal: None,
        bmr: None,
        floor_kcal: a_profile.sex.map(|sex| whole(safe_minimum(sex))),
        delta_kcal: Decimal::ZERO,
        pace_kg: a_goal.pace_kg.filter(|_| a_goal.mode != GoalMode::Maintain),
        effective_pace_kg: None,
        target_kg: a_goal.target_kg.filter(|_| a_goal.mode != GoalMode::Maintain),
        weeks_to_target: None,
        activity: a_profile.activity,
        weight_kg: a_profile.weight_kg.map(|value| value.normalize()),
        recent_workouts: a_profile.recent_workouts,
        is_training_boost: false,
        warnings: Vec::new(),
    };

    let (Some(sex), Some(weight), Some(height), Some(activity), true) = (
        a_profile.sex,
        a_profile.weight_kg,
        a_profile.height_cm,
        a_profile.activity,
        gaps.is_empty(),
    )
    else
    {
        return match a_goal.custom
        {
            Some(custom) => Ok(NutritionNormDto {
                target: custom,
                kind: NormKind::Custom,
                warnings: custom_warnings(custom, a_profile.sex.map(safe_minimum)),
                ..base
            }),
            None => Err(gaps),
        };
    };

    let weight_kg = as_f64(weight);
    let basal = bmr(sex == Sex::Male, weight_kg, as_f64(height), f64::from(a_age));
    let maintenance = (basal * activity_factor(activity)).round();
    let floor = basal.max(safe_minimum(sex)).round();
    let base = NutritionNormDto {
        maintenance_kcal: Some(whole(maintenance)),
        bmr: Some(whole(basal)),
        floor_kcal: Some(whole(floor)),
        ..base
    };

    if let Some(custom) = a_goal.custom
    {
        return Ok(NutritionNormDto {
            target: custom,
            kind: NormKind::Custom,
            delta_kcal: whole(as_f64(custom.kcal) - maintenance),
            warnings: custom_warnings(custom, Some(floor)),
            ..base
        });
    }

    let requested = a_goal.pace_kg.map(as_f64).unwrap_or_default() * KCAL_PER_KG / DAYS_PER_WEEK;
    let mut warnings = Vec::new();
    let delta = match a_goal.mode
    {
        GoalMode::Maintain => 0.0,
        GoalMode::Lose =>
        {
            let cap = (MAX_DEFICIT_SHARE * maintenance).round();
            let room = (maintenance - floor).max(0.0);
            let deficit = requested.min(cap).min(room).round();
            if deficit < requested.round()
            {
                warnings.push(
                    if room < cap
                    {
                        NormWarning::FloorReached
                    }
                    else
                    {
                        NormWarning::DeficitCapped
                    },
                );
            }
            -deficit
        }
        GoalMode::Gain =>
        {
            if requested > MAX_SURPLUS_KCAL
            {
                warnings.push(NormWarning::SurplusCapped);
            }
            else if requested < MIN_SURPLUS_KCAL
            {
                warnings.push(NormWarning::SurplusRaised);
            }
            requested.clamp(MIN_SURPLUS_KCAL, MAX_SURPLUS_KCAL).round()
        }
    };
    let kcal = maintenance + delta;
    let effective_pace = (a_goal.mode != GoalMode::Maintain).then(|| pace_of(delta.abs()));
    let target_kg = base.target_kg.map(as_f64);
    let weeks_to_target = match target_kg
    {
        Some(target) if is_target_passed(a_goal.mode, weight_kg, target) =>
        {
            warnings.push(NormWarning::TargetPassed);
            None
        }
        Some(target) => weeks_to(weight_kg, target, effective_pace.map(as_f64).unwrap_or_default()),
        None => None,
    };

    Ok(NutritionNormDto {
        target: adult_macros(kcal, weight_kg, a_goal.mode),
        delta_kcal: whole(delta),
        effective_pace_kg: effective_pace,
        weeks_to_target,
        warnings,
        ..base
    })
}

fn child_level(a_activity: Option<ActivityLevel>, a_recent_workouts: i64) -> (usize, bool)
{
    let base = match a_activity
    {
        None | Some(ActivityLevel::Sedentary) => 0,
        Some(ActivityLevel::Light) => 1,
        Some(ActivityLevel::Moderate) => 2,
        Some(ActivityLevel::Active | ActivityLevel::VeryActive) => 3,
    };
    let boost = if a_recent_workouts >= CHILD_BOOST_TWO_WORKOUTS
    {
        2
    }
    else if a_recent_workouts >= CHILD_BOOST_ONE_WORKOUTS
    {
        1
    }
    else
    {
        0
    };
    let level = (base + boost).min(CHILD_PA_MALE.len() - 1);
    (level, level > base)
}

pub fn child_energy(a_profile: &BodyProfile, a_months: i32) -> Result<(f64, bool), Vec<NormGap>>
{
    let years = a_months / 12;
    let mut gaps = Vec::new();
    if a_profile.weight_kg.is_none()
    {
        gaps.push(NormGap::Weight);
    }
    if years >= TODDLER_YEARS
    {
        gaps.extend(
            [
                (a_profile.height_cm.is_none(), NormGap::Height),
                (a_profile.sex.is_none(), NormGap::Sex),
                (a_profile.activity.is_none(), NormGap::Activity),
            ]
            .into_iter()
            .filter_map(|(is_missing, gap)| is_missing.then_some(gap)),
        );
    }
    if !gaps.is_empty()
    {
        return Err(gaps);
    }
    let weight = a_profile.weight_kg.map(as_f64).unwrap_or_default();
    if years < TODDLER_YEARS
    {
        let growth = match a_months
        {
            0..=3 => 175.0,
            4..=6 => 56.0,
            7..=12 => 22.0,
            _ => 20.0,
        };
        return Ok(((89.0 * weight - 100.0 + growth).max(0.0), false));
    }

    let height_m = a_profile.height_cm.map(as_f64).unwrap_or_default() / 100.0;
    let (level, is_boost) = child_level(a_profile.activity, a_profile.recent_workouts);
    let growth = if years <= 8 { 20.0 } else { 25.0 };
    let age = f64::from(years);
    let energy = if a_profile.sex == Some(Sex::Female)
    {
        135.3 - 30.8 * age + CHILD_PA_FEMALE[level] * (10.0 * weight + 934.0 * height_m) + growth
    }
    else
    {
        88.5 - 61.9 * age + CHILD_PA_MALE[level] * (26.7 * weight + 903.0 * height_m) + growth
    };
    Ok((energy, is_boost))
}

fn child_macros(a_kcal: f64, a_weight_kg: f64, a_months: i32) -> MacrosDto
{
    let years = a_months / 12;
    let (protein_per_kg, protein_share, fat_share) = match (years, a_months)
    {
        (_, 0..=6) => (1.5, 0.0, 0.45),
        (0, _) => (1.2, 0.0, 0.40),
        (1..=3, _) => (1.05, 0.12, 0.35),
        (4..=13, _) => (0.95, 0.15, 0.30),
        _ => (0.85, 0.15, 0.30),
    };
    let prot = (protein_per_kg * a_weight_kg).max(protein_share * a_kcal / KCAL_PER_G_PROTEIN);
    macros_of(a_kcal, prot, fat_share * a_kcal / KCAL_PER_G_FAT)
}

fn child_norm(a_profile: &BodyProfile, a_months: i32) -> Result<NutritionNormDto, Vec<NormGap>>
{
    let (energy, is_boost) = child_energy(a_profile, a_months)?;
    let kcal = energy.round();
    let weight_kg = a_profile.weight_kg.map(as_f64).unwrap_or_default();
    Ok(NutritionNormDto {
        target: child_macros(kcal, weight_kg, a_months),
        kind: NormKind::Child,
        mode: GoalMode::Maintain,
        age: a_months / 12,
        maintenance_kcal: Some(whole(kcal)),
        bmr: None,
        floor_kcal: None,
        delta_kcal: Decimal::ZERO,
        pace_kg: None,
        effective_pace_kg: None,
        target_kg: None,
        weeks_to_target: None,
        activity: a_profile.activity,
        weight_kg: a_profile.weight_kg.map(|value| value.normalize()),
        recent_workouts: a_profile.recent_workouts,
        is_training_boost: is_boost,
        warnings: Vec::new(),
    })
}

pub fn is_child(a_birth_date: NaiveDate, a_on: NaiveDate) -> bool
{
    age_months(a_birth_date, a_on) < ADULT_AGE * 12
}

pub fn clean_goal(a_goal: GoalSettings, a_is_child: bool) -> Result<GoalSettings, &'static str>
{
    if a_is_child && (a_goal.mode != GoalMode::Maintain || a_goal.custom.is_some())
    {
        return Err("mode");
    }
    let pace = match a_goal.mode
    {
        GoalMode::Maintain => None,
        _ =>
        {
            let pace = a_goal.pace_kg.ok_or("pace_kg")?.round_dp(2).normalize();
            if pace < Decimal::new(5, 2) || pace > Decimal::new(15, 1)
            {
                return Err("pace_kg");
            }
            Some(pace)
        }
    };
    let target = match a_goal.target_kg
    {
        Some(target) =>
        {
            let target = target.round_dp(1).normalize();
            if target < Decimal::from(20) || target > Decimal::from(350)
            {
                return Err("target_kg");
            }
            Some(target)
        }
        None => None,
    };
    Ok(GoalSettings {
        mode: a_goal.mode,
        pace_kg: pace,
        target_kg: target,
        custom: a_goal.custom.map(clean_custom).transpose()?,
    })
}

pub fn clean_custom(a_custom: MacrosDto) -> Result<MacrosDto, &'static str>
{
    let custom = rounded(a_custom, 0);
    let limits = [
        (custom.kcal, 800, 6000, "custom.kcal"),
        (custom.prot, 0, 600, "custom.prot"),
        (custom.fat, 0, 400, "custom.fat"),
        (custom.carb, 0, 1000, "custom.carb"),
    ];
    for (value, low, high, field) in limits
    {
        if value < Decimal::from(low) || value > Decimal::from(high)
        {
            return Err(field);
        }
    }
    Ok(custom)
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

    fn macros(a_kcal: &str, a_prot: &str, a_fat: &str, a_carb: &str) -> MacrosDto
    {
        MacrosDto {
            kcal: dec(a_kcal),
            prot: dec(a_prot),
            fat: dec(a_fat),
            carb: dec(a_carb),
        }
    }

    #[test]
    fn cooked_weight_dilutes_buckwheat()
    {
        let ingredients = [Ingredient {
            per_100: Some(macros("343", "13.3", "3.4", "62.1")),
            grams: dec("200"),
        }];

        let raw = dish_math(&ingredients, None, None, None);
        assert_eq!(raw.per_100, macros("343", "13.3", "3.4", "62.1"));
        assert_eq!(raw.cooked_g, dec("200"));

        let boiled = dish_math(&ingredients, Some(dec("600")), None, Some(3));
        assert_eq!(boiled.raw_g, dec("200"));
        assert_eq!(boiled.cooked_g, dec("600"));
        assert_eq!(boiled.total, macros("686", "26.6", "6.8", "124.2"));
        assert_eq!(boiled.per_100, macros("114.33", "4.43", "1.13", "20.7"));
        assert_eq!(boiled.portion_g, Some(dec("200")));
    }

    #[test]
    fn frying_concentrates_meat_and_flags_missing_values()
    {
        let ingredients = [
            Ingredient {
                per_100: Some(macros("187", "18.6", "12.4", "0")),
                grams: dec("1000"),
            },
            Ingredient {
                per_100: None,
                grams: dec("5"),
            },
        ];

        let fried = dish_math(&ingredients, Some(dec("720")), Some(dec("180")), None);
        assert_eq!(fried.raw_g, dec("1005"));
        assert_eq!(fried.per_100, macros("259.72", "25.83", "17.22", "0"));
        assert_eq!(fried.portion_g, Some(dec("180")));
        assert_eq!(fried.missing_count, 1);
        assert_eq!(
            for_grams(fried.per_100, fried.portion_g.unwrap()),
            macros("467.5", "46.5", "31", "0")
        );
    }

    #[test]
    fn entries_scale_from_the_snapshot()
    {
        let per_100 = macros("52", "0.3", "0.2", "13.8");
        assert_eq!(for_grams(per_100, dec("150")), macros("78", "0.5", "0.3", "20.7"));
        assert_eq!(portion_grams(dec("1.5"), dec("133.3")), dec("200"));
        assert_eq!(
            sum([macros("1", "2", "3", "4"), macros("0.5", "0.5", "0.5", "0.5")]),
            macros("1.5", "2.5", "3.5", "4.5")
        );
    }

    fn adult(a_sex: Sex, a_weight: &str, a_height: &str, a_activity: ActivityLevel) -> BodyProfile
    {
        BodyProfile {
            sex: Some(a_sex),
            birth_date: NaiveDate::from_ymd_opt(1996, 1, 10).unwrap(),
            on: NaiveDate::from_ymd_opt(2026, 10, 16).unwrap(),
            weight_kg: Some(dec(a_weight)),
            height_cm: Some(dec(a_height)),
            activity: Some(a_activity),
            recent_workouts: 0,
        }
    }

    fn goal(a_mode: GoalMode, a_pace: Option<&str>) -> GoalSettings
    {
        GoalSettings {
            mode: a_mode,
            pace_kg: a_pace.map(dec),
            ..GoalSettings::default()
        }
    }

    #[test]
    fn maintenance_follows_mifflin_and_activity()
    {
        let profile = adult(Sex::Male, "80", "180", ActivityLevel::Moderate);
        let norm = daily_norm(&profile, &GoalSettings::default()).unwrap();
        assert_eq!(norm.kind, NormKind::Adult);
        assert_eq!(norm.age, 30);
        assert_eq!(norm.bmr, Some(dec("1780")));
        assert_eq!(norm.maintenance_kcal, Some(dec("2759")));
        assert_eq!(norm.floor_kcal, Some(dec("1780")));
        assert_eq!(norm.target, macros("2759", "128", "77", "389"));
        assert!(norm.warnings.is_empty());
    }

    #[test]
    fn weight_loss_keeps_safe_limits()
    {
        let profile = adult(Sex::Male, "80", "180", ActivityLevel::Moderate);
        let half = daily_norm(&profile, &goal(GoalMode::Lose, Some("0.5"))).unwrap();
        assert_eq!(half.delta_kcal, dec("-550"));
        assert_eq!(half.target.kcal, dec("2209"));
        assert_eq!(half.target.prot, dec("160"));
        assert_eq!(half.effective_pace_kg, Some(dec("0.5")));
        assert!(half.warnings.is_empty());

        let fast = daily_norm(&profile, &goal(GoalMode::Lose, Some("1"))).unwrap();
        assert_eq!(fast.delta_kcal, dec("-690"));
        assert_eq!(fast.warnings, vec![NormWarning::DeficitCapped]);
        assert_eq!(fast.effective_pace_kg, Some(dec("0.63")));

        let small = adult(Sex::Female, "50", "155", ActivityLevel::Sedentary);
        let floor = daily_norm(&small, &goal(GoalMode::Lose, Some("0.5"))).unwrap();
        assert_eq!(floor.bmr, Some(dec("1158")));
        assert_eq!(floor.floor_kcal, Some(dec("1200")));
        assert_eq!(floor.target.kcal, dec("1200"));
        assert_eq!(floor.warnings, vec![NormWarning::FloorReached]);
    }

    #[test]
    fn weight_gain_surplus_stays_in_range()
    {
        let profile = adult(Sex::Female, "60", "170", ActivityLevel::Light);
        let slow = daily_norm(&profile, &goal(GoalMode::Gain, Some("0.1"))).unwrap();
        assert_eq!(slow.delta_kcal, dec("200"));
        assert_eq!(slow.warnings, vec![NormWarning::SurplusRaised]);
        let fast = daily_norm(&profile, &goal(GoalMode::Gain, Some("1"))).unwrap();
        assert_eq!(fast.delta_kcal, dec("500"));
        assert_eq!(fast.effective_pace_kg, Some(dec("0.45")));
        assert_eq!(fast.warnings, vec![NormWarning::SurplusCapped]);
        assert_eq!(fast.target.prot, dec("108"));
    }

    #[test]
    fn target_weight_gives_weeks_or_warns()
    {
        let profile = adult(Sex::Male, "80", "180", ActivityLevel::Moderate);
        let mut settings = goal(GoalMode::Lose, Some("0.5"));
        settings.target_kg = Some(dec("75"));
        assert_eq!(daily_norm(&profile, &settings).unwrap().weeks_to_target, Some(10));
        settings.target_kg = Some(dec("85"));
        let passed = daily_norm(&profile, &settings).unwrap();
        assert_eq!(passed.weeks_to_target, None);
        assert_eq!(passed.warnings, vec![NormWarning::TargetPassed]);
    }

    #[test]
    fn custom_norm_works_without_profile_and_flags_problems()
    {
        let mut profile = adult(Sex::Female, "60", "165", ActivityLevel::Sedentary);
        let settings = GoalSettings {
            custom: Some(macros("1100", "100", "40", "50")),
            ..GoalSettings::default()
        };
        let norm = daily_norm(&profile, &settings).unwrap();
        assert_eq!(norm.kind, NormKind::Custom);
        assert_eq!(norm.target.kcal, dec("1100"));
        assert_eq!(
            norm.warnings,
            vec![NormWarning::CustomBelowFloor, NormWarning::CustomMacrosMismatch]
        );

        profile.weight_kg = None;
        assert_eq!(daily_norm(&profile, &settings).unwrap().maintenance_kcal, None);
        assert_eq!(
            daily_norm(&profile, &GoalSettings::default()).unwrap_err(),
            vec![NormGap::Weight]
        );
    }

    #[test]
    fn children_get_age_norms_without_goals()
    {
        let boy = BodyProfile {
            sex: Some(Sex::Male),
            birth_date: NaiveDate::from_ymd_opt(2016, 5, 1).unwrap(),
            on: NaiveDate::from_ymd_opt(2026, 10, 16).unwrap(),
            weight_kg: Some(dec("32")),
            height_cm: Some(dec("140")),
            activity: Some(ActivityLevel::Moderate),
            recent_workouts: 0,
        };
        let norm = daily_norm(&boy, &goal(GoalMode::Lose, Some("0.5"))).unwrap();
        assert_eq!(norm.kind, NormKind::Child);
        assert_eq!(norm.age, 10);
        assert_eq!(norm.mode, GoalMode::Maintain);
        assert_eq!(norm.target, macros("2164", "81", "72", "298"));
        assert!(!norm.is_training_boost);

        let trained = BodyProfile {
            recent_workouts: 3,
            ..boy
        };
        let boosted = daily_norm(&trained, &GoalSettings::default()).unwrap();
        assert!(boosted.is_training_boost);
        assert_eq!(boosted.target.kcal, dec("2503"));

        let toddler = BodyProfile {
            sex: None,
            birth_date: NaiveDate::from_ymd_opt(2024, 9, 20).unwrap(),
            height_cm: None,
            activity: None,
            weight_kg: Some(dec("12")),
            ..boy
        };
        let small = daily_norm(&toddler, &GoalSettings::default()).unwrap();
        assert_eq!(small.age, 2);
        assert_eq!(small.target.kcal, dec("988"));

        let missing = BodyProfile { height_cm: None, ..boy };
        assert_eq!(
            daily_norm(&missing, &GoalSettings::default()).unwrap_err(),
            vec![NormGap::Height]
        );
    }

    #[test]
    fn goals_are_validated_and_children_cannot_diet()
    {
        assert_eq!(clean_goal(goal(GoalMode::Lose, None), false), Err("pace_kg"));
        assert_eq!(clean_goal(goal(GoalMode::Lose, Some("2")), false), Err("pace_kg"));
        assert_eq!(clean_goal(goal(GoalMode::Lose, Some("0.5")), true), Err("mode"));
        assert_eq!(
            clean_goal(goal(GoalMode::Maintain, Some("0.5")), true).unwrap().pace_kg,
            None
        );
        let custom = GoalSettings {
            custom: Some(macros("500", "10", "10", "10")),
            ..GoalSettings::default()
        };
        assert_eq!(clean_goal(custom, false), Err("custom.kcal"));
        assert_eq!(
            age_months(
                NaiveDate::from_ymd_opt(2008, 10, 17).unwrap(),
                NaiveDate::from_ymd_opt(2026, 10, 16).unwrap()
            ),
            215
        );
        assert!(is_child(
            NaiveDate::from_ymd_opt(2008, 10, 17).unwrap(),
            NaiveDate::from_ymd_opt(2026, 10, 16).unwrap()
        ));
        assert!(!is_child(
            NaiveDate::from_ymd_opt(2008, 10, 16).unwrap(),
            NaiveDate::from_ymd_opt(2026, 10, 16).unwrap()
        ));
    }
}
