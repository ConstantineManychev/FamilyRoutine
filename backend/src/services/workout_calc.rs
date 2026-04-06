pub fn calculate_set_kcal(
    calc_mode: &str,
    ex: &ExDto,
    user_weight_kg: f64,
    duration_sec: Option<i32>,
    reps: Option<i32>,
    weight_kg: Option<f64>,
) -> f64 {
    let effective_duration = match duration_sec {
        Some(d) => d as f64,
        None => match reps {
            Some(r) => (r * 3) as f64,
            None => 60.0,
        },
    };

    if calc_mode == "tonnage" && reps.is_some() && weight_kg.is_some() {
        let external_w = weight_kg.unwrap();
        let r = reps.unwrap() as f64;
        
        let bw_component = if ex.weight_type == "hybrid" || ex.weight_type == "bodyweight" {
            user_weight_kg * (ex.bw_pct / 100.0)
        } else {
            0.0
        };

        let effective_weight = external_w + bw_component;
        let tonnage = effective_weight * r;
        
        let muscle_count = ex.muscles.len() as f64;
        let systemic_multiplier = 1.0 + (muscle_count * 0.05);
        let base_kcal_per_kg_rep = 0.015;

        return tonnage * base_kcal_per_kg_rep * systemic_multiplier;
    }

    let hours = effective_duration / 3600.0;
    ex.met_val * user_weight_kg * hours
}