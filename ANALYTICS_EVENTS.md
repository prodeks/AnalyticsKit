# Аналитика: покупки и пейволы

Все события уходят одновременно в **Firebase, Facebook, AppsFlyer и Mixpanel**.
Начиная с версии **2.0.7** источник покупки больше не хранится в префиксе события. Вместо `adapty_` / `storekit_` используется параметр `purchase_service` со значением `adapty` или `storekit`.

События одного показа пейвола связаны между собой через `presentation_id`, поэтому воронку видно целиком.

---

## Показ экрана

| Событие | Когда срабатывает |
|---|---|
| `paywall_shown` | Пользователь увидел экран с подпиской |
| `paywall_closed` | Пользователь закрыл экран (с пометкой, была ли покупка) |
| `Onboarding_Started` | Начался онбординг (верхняя точка воронки) |

## Воронка покупки

| Событие | Когда срабатывает |
|---|---|
| `paywall_checkout_initiated` | Нажата кнопка покупки, до окна оплаты Apple |
| `Paywall_Start_Button_tap` | Дублирующее событие для воронки |
| `paywall_checkout_cancelled` | Пользователь закрыл окно оплаты |
| `PayWall_Lifetime_button_tap` | Выбран Lifetime (`tap_source=option_select`) или нажат Subscribe при выбранном Lifetime (`purchase_button`) |

## Результат покупки

| Событие | Когда срабатывает |
|---|---|
| `sale_confirmation_success` | Оплата прошла (сюда же уходит выручка в Facebook) |
| `sale_confirmation_cancel` | Пользователь отменил оплату |
| `sale_confirmation_fail` | Ошибка при оплате |
| `sale_confirmation_restore` | Пользователь восстановил подписку |

### Пример успешной покупки

```
Открытие пейвола
  → Начат чекаут
  → Покупка успешна (+ выручка в Facebook)
  → Закрытие пейвола (куплено: да)
```

Если отмена — вместо успеха: «Покупка отменена» + «Чекаут отменён».
Если ошибка — «Покупка не удалась» + «Ошибка покупки» с деталями.

---

## Ошибки (для диагностики)

| Событие | Когда срабатывает |
|---|---|
| `purchase_failed` | Покупка не прошла (не считая обычной отмены) |
| `restore_failed` | Не удалось восстановить покупки |
| `prices_load_failed` | Не загрузились цены из App Store |
| `paywall_show_failed` | Пейвол не удалось показать |
| `paywall_fetch_failed` | Не удалось загрузить пейвол из сети |

---

## Параметры событий

### Общие параметры (показ и покупки)

| Параметр | Описание |
|---|---|
| `purchase_service` | Источник покупки: `adapty` или `storekit` |
| `paywall_id` | ID пейвола |
| `placement_id` | Площадка/точка, откуда показан пейвол или начата покупка |
| `product_id` | ID товара |
| `price` / `value` | Цена товара |
| `currency` | Валюта |
| `variation_id` | ID варианта A/B-теста |
| `presentation_id` | ID конкретного показа (для связи событий) |
| `purchased` | Была ли покупка при закрытии экрана (да/нет) |
| `tap_source` | Для `PayWall_Lifetime_button_tap`: `option_select` или `purchase_button` |

`PayWall_Lifetime_button_tap` is logged by `PaywallController`. Host custom paywalls call `didSelectProduct(_:previous:)`; `purchase(_:)` logs the checkout tap automatically. There is no `paywall_name` parameter — Adapty's paywall name is `paywall_id`.

### Параметры ошибок

| Параметр | Описание |
|---|---|
| `reason` | Категория ошибки (см. справочник ниже) |
| `error_description` | Текстовое описание ошибки |
| `error_domain` | Техническая область ошибки (`AdaptyError`, `SKErrorDomain` и т.д.) |
| `error_code` | Числовой код ошибки |
| `failed_identifiers` | Список ID товаров, которые не загрузились (для `prices_load_failed`) |

**Какие параметры в каком событии ошибки:**

| Событие | Параметры |
|---|---|
| `purchase_failed` | `purchase_service`, `reason`, `product_id`, `placement_id`, `error_domain`, `error_code`, `price`, `currency`, `paywall_id`, `presentation_id`, `variation_id` |
| `restore_failed` | `purchase_service`, `reason`, `error_domain`, `error_code` |
| `prices_load_failed` | `purchase_service`, `reason`, `error_description`, `error_domain`, `error_code`, `failed_identifiers` |
| `paywall_show_failed` | `purchase_service`, `placement_id`, `reason`, `error_description`, `error_domain`, `error_code` |
| `paywall_fetch_failed` | `purchase_service`, `placement_id`, `error_description`, `error_domain`, `error_code` |

---

## Справочник причин ошибок (`reason`)

### Покупки и восстановление

| Значение | Что означает |
|---|---|
| `cancelled` | Пользователь отменил оплату |
| `network_error` | Проблема с сетью |
| `payment_invalid` | Оплата невозможна/некорректна |
| `storekit_sync_failed` | Не удалось синхронизироваться с App Store |

### Показ и загрузка пейвола

| Значение | Что означает |
|---|---|
| `missing_product_identifiers` | В настройках не указаны ID товаров |
| `invalid_product_identifiers` | ID товаров указаны, но не найдены в App Store |
| `missing_paywall_data` | Adapty не вернул данные пейвола |
| `custom_view_unavailable` | Кастомный экран не удалось создать |
| `unconfigured_placement` | Запрошена ненастроенная площадка |
| `missing_view_identifier` | Не удалось определить экран для площадки |
| `products_not_loaded` | Пейвол запросили до загрузки товаров |
| `network_error` | Проблема с сетью |
| `storekit_error` | Ошибка App Store / StoreKit |
| `unknown` | Неизвестная ошибка |

### Внутренние коды ошибок (`error_code`)

Собственные коды (отрицательные, чтобы не пересекаться с кодами Apple/Adapty):

| Код | Что означает |
|---|---|
| -1 | Не указаны ID товаров |
| -2 | ID товаров не совпадают с App Store |
| -101 | Adapty не вернул данные пейвола |
| -102 | Не создался кастомный экран |
| -103 | Площадка не настроена |
| -104 | Не определён экран для площадки |
| -105 | Товары ещё не загружены |

Положительные коды приходят напрямую от Apple (`SKErrorDomain`) или Adapty (`AdaptyError`).

## Feature flags

`experimentVariant(for:)` читает вариант Mixpanel-флага. Если SDK вернул fallback (флаг не загрузился, пользователя нет в охвате, сеть недоступна), метод возвращает `nil`.

Показ эксперимента (`$experiment_started`) отправляет сам Mixpanel SDK в момент чтения варианта. Это событие не проходит через `log(e:)`, поэтому его нет в Firebase, Facebook и AppsFlyer.
