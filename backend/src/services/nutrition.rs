use rust_decimal::prelude::{FromPrimitive, ToPrimitive};
use rust_decimal::{Decimal, RoundingStrategy};
use shared_schema::{ActivityLevel, MacrosDto, MealSlot, NormGap, NutritionNormDto, Sex};

const PER_HUNDRED: Decimal = Decimal::ONE_HUNDRED;
const PER_100_SCALE: u32 = 2;
const AMOUNT_SCALE: u32 = 1;
const ADULT_AGE: i32 = 18;
const MALE_BMR_CONST: f64 = 5.0;
const FEMALE_BMR_CONST: f64 = -161.0;
const PROTEIN_G_PER_KG: f64 = 1.6;
const PROTEIN_MAX_SHARE: f64 = 0.3;
const FAT_SHARE: f64 = 0.3;
const KCAL_PER_G_PROTEIN: f64 = 4.0;
const KCAL_PER_G_FAT: f64 = 9.0;
const KCAL_PER_G_CARB: f64 = 4.0;

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
    pub age: i32,
    pub weight_kg: Option<Decimal>,
    pub height_cm: Option<Decimal>,
    pub activity: Option<ActivityLevel>,
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

pub fn maintenance_norm(a_profile: &BodyProfile) -> Result<NutritionNormDto, Vec<NormGap>>
{
    let mut gaps = Vec::new();
    if a_profile.age < ADULT_AGE
    {
        gaps.push(NormGap::Child);
    }
    if a_profile.weight_kg.is_none()
    {
        gaps.push(NormGap::Weight);
    }
    if a_profile.height_cm.is_none()
    {
        gaps.push(NormGap::Height);
    }
    if a_profile.sex.is_none()
    {
        gaps.push(NormGap::Sex);
    }
    if a_profile.activity.is_none()
    {
        gaps.push(NormGap::Activity);
    }
    let (Some(sex), Some(weight), Some(height), Some(activity), true) = (
        a_profile.sex,
        a_profile.weight_kg,
        a_profile.height_cm,
        a_profile.activity,
        gaps.is_empty(),
    )
    else
    {
        return Err(gaps);
    };

    let weight_kg = weight.to_f64().unwrap_or_default();
    let base = bmr(
        sex == Sex::Male,
        weight_kg,
        height.to_f64().unwrap_or_default(),
        f64::from(a_profile.age),
    );
    let kcal = (base * activity_factor(activity)).round();
    let prot = (PROTEIN_G_PER_KG * weight_kg)
        .min(PROTEIN_MAX_SHARE * kcal / KCAL_PER_G_PROTEIN)
        .round();
    let fat = (FAT_SHARE * kcal / KCAL_PER_G_FAT).round();
    let carb = ((kcal - prot * KCAL_PER_G_PROTEIN - fat * KCAL_PER_G_FAT) / KCAL_PER_G_CARB)
        .max(0.0)
        .round();
    let whole = |a_value: f64| Decimal::from_f64(a_value).unwrap_or_default().round_dp(0);

    Ok(NutritionNormDto {
        target: MacrosDto {
            kcal: whole(kcal),
            prot: whole(prot),
            fat: whole(fat),
            carb: whole(carb),
        },
        bmr: whole(base),
        activity,
        weight_kg: weight.normalize(),
    })
}

pub fn slot_hour(a_meal: MealSlot) -> i64
{
    match a_meal
    {
        MealSlot::Breakfast => 8,
        MealSlot::Lunch => 13,
        MealSlot::Snack => 16,
        MealSlot::Dinner => 19,
    }
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

    #[test]
    fn maintenance_follows_mifflin_and_activity()
    {
        let profile = BodyProfile {
            sex: Some(Sex::Male),
            age: 30,
            weight_kg: Some(dec("80")),
            height_cm: Some(dec("180")),
            activity: Some(ActivityLevel::Moderate),
        };
        let norm = maintenance_norm(&profile).unwrap();
        assert_eq!(norm.bmr, dec("1780"));
        assert_eq!(norm.target.kcal, dec("2759"));
        assert_eq!(norm.target.prot, dec("128"));
        assert_eq!(norm.target.fat, dec("92"));
        assert_eq!(norm.target.carb, dec("355"));

        let female = BodyProfile {
            sex: Some(Sex::Female),
            age: 40,
            weight_kg: Some(dec("60")),
            height_cm: Some(dec("165")),
            activity: Some(ActivityLevel::Sedentary),
        };
        assert_eq!(maintenance_norm(&female).unwrap().bmr, dec("1270"));
    }

    #[test]
    fn missing_profile_data_and_children_have_no_norm()
    {
        let child = BodyProfile {
            sex: Some(Sex::Female),
            age: 12,
            weight_kg: Some(dec("40")),
            height_cm: None,
            activity: Some(ActivityLevel::Active),
        };
        assert_eq!(
            maintenance_norm(&child).unwrap_err(),
            vec![NormGap::Child, NormGap::Height]
        );
    }
}
