# Family Routine

Семейное пространство для рутины, расписаний и общих финансов.

- `backend/` — API на Rust (Axum + sqlx + PostgreSQL)
- `shared-schema/` — DTO, общие для API
- `frontend/` — клиент на Flutter (web, Android, iOS, desktop)
- `deploy/` — конфигурация внешнего TLS-прокси (Caddy)
- `docs/SECURITY.md` — модель безопасности и эксплуатация секретов

## Быстрый запуск (Docker)

1. Скопируйте `.env.example` в `.env` и заполните значения:

   | Переменная | Как получить |
   |---|---|
   | `DB_PASSWORD` | `openssl rand -hex 24` (только `[0-9a-f]`, чтобы не экранировать в URL) |
   | `DATA_ENC_KEY` | `openssl rand -base64 32` — ключ шифрования банковских токенов |
   | `PASSWORD_PEPPER` | `openssl rand -base64 32` — секрет для хешей паролей |
   | `APP_DOMAIN` | домен, указывающий на сервер; `localhost` для локальной проверки |

2. `docker compose up -d --build`
3. Откройте `https://<APP_DOMAIN>`. Для публичного домена Caddy сам получит сертификат Let's Encrypt; для `localhost` используется локальный сертификат Caddy.

Наружу публикуются только порты 80/443 прокси. PostgreSQL находится во внутренней сети без доступа извне, бэкенд доступен только через nginx фронтенда.

> `DATA_ENC_KEY` и `PASSWORD_PEPPER` храните отдельно от резервных копий БД. Потеря `DATA_ENC_KEY` делает сохранённые банковские токены нечитаемыми, потеря `PASSWORD_PEPPER` — делает невозможным вход для всех пользователей. Подробнее — в `docs/SECURITY.md`.

## Разработка

### Бэкенд

```bash
service postgresql start
createdb family_routine
export DATABASE_URL=postgres://user:pass@127.0.0.1/family_routine
export DATA_ENC_KEY=$(openssl rand -base64 32)
export PASSWORD_PEPPER=$(openssl rand -base64 32)
export COOKIE_SECURE=false
export ALLOWED_ORIGINS=http://localhost:5173
cargo run -p backend
```

Миграции применяются автоматически при старте. Существующая база, созданная вручную из `01_init_schema.sql`, подхватывается без пересоздания.

Переменные окружения бэкенда:

| Переменная | По умолчанию | Назначение |
|---|---|---|
| `DATABASE_URL` | — | строка подключения PostgreSQL |
| `DATA_ENC_KEY` | — | base64, ровно 32 байта |
| `PASSWORD_PEPPER` | — | base64, не меньше 32 байт |
| `BIND_ADDR` | `0.0.0.0:3000` | адрес прослушивания |
| `ALLOWED_ORIGINS` | пусто | список origin через запятую для CORS; пусто — CORS выключен (same-origin) |
| `COOKIE_SECURE` | `true` | флаг `Secure` у сессионной cookie; `false` только для локального http |
| `COOKIE_SAMESITE` | `strict` | `strict`, `lax` или `none` (только вместе с `COOKIE_SECURE=true`) |
| `TRUST_PROXY` | `false` | брать IP клиента из `X-Real-IP` (включать только за своим прокси) |
| `RUST_LOG` | `info,sqlx=warn` | уровень логирования |

Проверки:

```bash
cargo clippy -p backend -p shared-schema --all-targets
cargo test -p backend
cargo +nightly fmt --all
```

Интеграционные тесты (`backend/tests`) используют `#[sqlx::test]` и создают временные базы, поэтому `DATABASE_URL` должен указывать на пользователя с правом `CREATEDB`.

После изменения SQL-запросов обновите офлайн-описание для Docker-сборки:

```bash
cargo sqlx prepare --workspace -- --all-targets
```

Стиль кода Rust задаётся `rustfmt.toml` (скобки Allman), форматирование — nightly-версией `rustfmt`.

### Фронтенд

```bash
cd frontend
flutter pub get
flutter run -d chrome --web-port 5173 --dart-define=API_URL=http://localhost:3000
flutter analyze
flutter test
```

- В web-сборке сессия хранится в HttpOnly-cookie (недоступна JavaScript), на мобильных и desktop — токен в защищённом хранилище ОС (Keychain / Keystore).
- Без `API_URL` web-клиент обращается к тому же origin, с которого загружен (`/api` проксируется nginx).
- Продакшен-сборка: `flutter build web --release --csp --no-web-resources-cdn` — без динамической генерации кода и без загрузки CanvasKit с внешних CDN, что позволяет строгую Content-Security-Policy.

## Вступление в группу

Участник добавляется только по одноразовому коду приглашения:

1. Администратор группы нажимает «Пригласить», выбирает роль и получает код вида `XXXX-XXXX-XXXX` (действует 7 дней, показывается один раз).
2. Код передаётся человеку лично (мессенджер, устно).
3. Человек вводит код в разделе «Семейные группы → Вступить по коду».

Сервер хранит только хеш кода, ответы не позволяют узнать, зарегистрирован ли чей-то email.
