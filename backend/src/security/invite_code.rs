use rand::rngs::OsRng;
use rand::Rng;
use sha2::{Digest, Sha256};

const ALPHABET: &[u8; 32] = b"0123456789ABCDEFGHJKMNPQRSTVWXYZ";
const CODE_LEN: usize = 12;
const GROUP_LEN: usize = 4;

pub fn generate() -> String
{
    let mut rng = OsRng;
    let raw: String = (0..CODE_LEN)
        .map(|_| ALPHABET[rng.gen_range(0..ALPHABET.len())] as char)
        .collect();

    raw.as_bytes()
        .chunks(GROUP_LEN)
        .map(|chunk| std::str::from_utf8(chunk).unwrap_or_default())
        .collect::<Vec<_>>()
        .join("-")
}

pub fn normalize(a_input: &str) -> Option<String>
{
    let normalized: String = a_input
        .chars()
        .filter(|ch| ch.is_ascii_alphanumeric())
        .map(|ch| match ch.to_ascii_uppercase()
        {
            'O' => '0',
            'I' | 'L' => '1',
            other => other,
        })
        .collect();

    let is_valid = normalized.len() == CODE_LEN && normalized.bytes().all(|byte| ALPHABET.contains(&byte));
    is_valid.then_some(normalized)
}

pub fn hash(a_normalized: &str) -> Vec<u8>
{
    let mut hasher = Sha256::new();
    hasher.update(b"family-routine/invite/v1/");
    hasher.update(a_normalized.as_bytes());
    hasher.finalize().to_vec()
}

#[cfg(test)]
mod tests
{
    use super::*;

    #[test]
    fn generated_code_is_grouped_and_normalizable()
    {
        let code = generate();

        assert_eq!(code.len(), CODE_LEN + 2);
        assert_eq!(code.matches('-').count(), 2);
        assert_eq!(normalize(&code).unwrap().len(), CODE_LEN);
    }

    #[test]
    fn normalization_tolerates_case_and_lookalikes()
    {
        assert_eq!(normalize("abcd-efgh-jk0o").unwrap(), "ABCDEFGHJK00");
        assert_eq!(normalize("1il1 2222 3333").unwrap(), "111122223333");
        assert!(normalize("too-short").is_none());
        assert!(normalize("UUUU-UUUU-UUUU").is_none());
    }

    #[test]
    fn hash_depends_on_code()
    {
        assert_ne!(hash("AAAAAAAAAAAA"), hash("AAAAAAAAAAAB"));
    }
}
