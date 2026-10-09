# Family Routine — клиент

Flutter-клиент для web, Android, iOS и desktop. Запуск, сборка и проверки описаны в корневом `README.md`.

- `lib/core` — конфигурация, HTTP-клиент, ошибки API, роутер и охрана маршрутов
- `lib/providers` — состояние аутентификации и данные (Riverpod)
- `lib/domain` — модели API
- `lib/ui` — экраны
- `assets/i18n` — переводы (`en.json` — эталонный набор ключей, полноту проверяет `test/i18n_test.dart`)
