use shared_schema::StockMeasure;

pub const LANGS: [&str; 6] = ["en", "ru", "de", "fr", "ja", "zh"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Lang
{
    En,
    Ru,
    De,
    Fr,
    Ja,
    Zh,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExpiryDay
{
    Today,
    Tomorrow,
}

impl ExpiryDay
{
    pub fn as_str(self) -> &'static str
    {
        match self
        {
            Self::Today => "today",
            Self::Tomorrow => "tomorrow",
        }
    }
}

pub struct StockLine
{
    pub title: String,
    pub qty: String,
    pub measure: StockMeasure,
}

impl Lang
{
    pub fn parse(a_code: &str) -> Self
    {
        match a_code.split(['-', '_']).next().unwrap_or_default()
        {
            "ru" => Self::Ru,
            "de" => Self::De,
            "fr" => Self::Fr,
            "ja" => Self::Ja,
            "zh" => Self::Zh,
            _ => Self::En,
        }
    }

    pub fn workout_title(self, a_title: &str) -> String
    {
        match self
        {
            Self::En => format!("Workout: {a_title}"),
            Self::Ru => format!("Тренировка: {a_title}"),
            Self::De => format!("Training: {a_title}"),
            Self::Fr => format!("Entraînement : {a_title}"),
            Self::Ja => format!("トレーニング: {a_title}"),
            Self::Zh => format!("训练：{a_title}"),
        }
    }

    pub fn starts_at(self, a_time: &str) -> String
    {
        match self
        {
            Self::En => format!("Starts at {a_time}"),
            Self::Ru => format!("Начало в {a_time}"),
            Self::De => format!("Beginn um {a_time}"),
            Self::Fr => format!("Début à {a_time}"),
            Self::Ja => format!("{a_time}に開始"),
            Self::Zh => format!("{a_time} 开始"),
        }
    }

    pub fn expiring_title(self, a_day: ExpiryDay) -> &'static str
    {
        match (self, a_day)
        {
            (Self::En, ExpiryDay::Tomorrow) => "Expires tomorrow",
            (Self::En, ExpiryDay::Today) => "Expires today",
            (Self::Ru, ExpiryDay::Tomorrow) => "Истекает завтра",
            (Self::Ru, ExpiryDay::Today) => "Истекает сегодня",
            (Self::De, ExpiryDay::Tomorrow) => "Läuft morgen ab",
            (Self::De, ExpiryDay::Today) => "Läuft heute ab",
            (Self::Fr, ExpiryDay::Tomorrow) => "Expire demain",
            (Self::Fr, ExpiryDay::Today) => "Expire aujourd'hui",
            (Self::Ja, ExpiryDay::Tomorrow) => "明日が期限",
            (Self::Ja, ExpiryDay::Today) => "今日が期限",
            (Self::Zh, ExpiryDay::Tomorrow) => "明天到期",
            (Self::Zh, ExpiryDay::Today) => "今天到期",
        }
    }

    pub fn expired_title(self) -> &'static str
    {
        match self
        {
            Self::En => "Written off as expired",
            Self::Ru => "Списано по сроку годности",
            Self::De => "Abgelaufen und abgeschrieben",
            Self::Fr => "Retiré : date dépassée",
            Self::Ja => "期限切れで廃棄済み",
            Self::Zh => "已过期并核销",
        }
    }

    fn unit(self, a_measure: StockMeasure) -> &'static str
    {
        match (self, a_measure)
        {
            (Self::Ru, StockMeasure::G) => "г",
            (Self::Ru, StockMeasure::Ml) => "мл",
            (Self::Ru, StockMeasure::Pcs) => "шт",
            (Self::De, StockMeasure::Pcs) => "Stk.",
            (Self::Fr, StockMeasure::Pcs) => "pcs",
            (Self::Ja, StockMeasure::Pcs) => "個",
            (Self::Zh, StockMeasure::G) => "克",
            (Self::Zh, StockMeasure::Ml) => "毫升",
            (Self::Zh, StockMeasure::Pcs) => "件",
            (_, StockMeasure::G) => "g",
            (_, StockMeasure::Ml) => "ml",
            (_, StockMeasure::Pcs) => "pcs",
        }
    }

    fn more(self, a_count: usize) -> String
    {
        match self
        {
            Self::En => format!(" and {a_count} more"),
            Self::Ru => format!(" и ещё {a_count}"),
            Self::De => format!(" und {a_count} weitere"),
            Self::Fr => format!(" et {a_count} de plus"),
            Self::Ja => format!(" ほか{a_count}件"),
            Self::Zh => format!(" 等另外{a_count}项"),
        }
    }

    pub fn stock_body(self, a_store: Option<&str>, a_lines: &[StockLine], a_more: usize) -> String
    {
        let lines: Vec<String> = a_lines
            .iter()
            .map(|line| format!("{} {} {}", line.title, line.qty, self.unit(line.measure)))
            .collect();
        let mut body = match a_store
        {
            Some(store) => format!("{store}: {}", lines.join(", ")),
            None => lines.join(", "),
        };
        if a_more > 0
        {
            body.push_str(&self.more(a_more));
        }
        body
    }
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn languages_fall_back_to_english()
    {
        assert_eq!(Lang::parse("ru-RU"), Lang::Ru);
        assert_eq!(Lang::parse("zh_Hans"), Lang::Zh);
        assert_eq!(Lang::parse("uk"), Lang::En);
        assert!(LANGS.iter().all(|code| Lang::parse(code) != Lang::En || *code == "en"));
    }

    #[test]
    fn stock_body_lists_lines_store_and_rest()
    {
        let lines = [
            StockLine {
                title: "Молоко".into(),
                qty: "900".into(),
                measure: StockMeasure::Ml,
            },
            StockLine {
                title: "Яйца".into(),
                qty: "6".into(),
                measure: StockMeasure::Pcs,
            },
        ];
        assert_eq!(
            Lang::Ru.stock_body(Some("Дом"), &lines, 2),
            "Дом: Молоко 900 мл, Яйца 6 шт и ещё 2"
        );
        assert_eq!(Lang::En.stock_body(None, &lines[..1], 0), "Молоко 900 ml");
        assert_eq!(Lang::Ru.expiring_title(ExpiryDay::Tomorrow), "Истекает завтра");
    }
}
