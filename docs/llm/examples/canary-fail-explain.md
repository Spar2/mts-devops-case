Вывод модели на прогоне, когда cookie называлась `dts_session`. Сейчас имя — `sensor_session`.

- Что упало: проверка smoke `login` вернула HTTP 401 вместо 200 и отсутствовал сессионный токен `dts_session`.
- Что сделал конвейер: вес canary выставлен в 0, релиз sensor-canary удалён через helm uninstall.
- Затронут ли stable: нет — smoke stable прошёл успешно (HTTP 200, cookie dts_session).
- Вероятная причина: canary не готов к работе из-за отсутствия валидного секрета (использовался `sensor-secrets-wrong`).
- Что проверить дальше: `kubectl -n sensor describe secret sensor-secrets-wrong`, проверить логи контейнера api.
