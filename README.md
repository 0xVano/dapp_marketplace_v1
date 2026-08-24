To do:
- Комиссия за сделки должна настраиваться onlyOwner в любом диапазоне. От 0% до 100%. При 100% вся сумма сделки уходит в контракт, продавцу ничего.
- Регистрация через стейк, а не только по почте
- Убрать cancelFeeBps
- Добавить возможность возврата части суммы в споре

# dApp Marketplace — смарт-контракты (MVP)

Foundry-проект ядра эскроу по роудмапу и сценариям «Действия пользователей и бэкенд».

Сеть: любой EVM. Расчёты: USDT/USDC (whitelist токенов).

## Ончейн vs офчейн

Контракт отвечает только за деньги и неизменяемые факты сделки. Каталог, SIWE, email продавца, IPFS pinning, секреты автовыдачи, чат и keeper — на бэкенде. Индексируйте события ниже.

## Контракты

| Файл | Роль |
|---|---|
| `src/Marketplace.sol` | OfferRegistry + Escrow/Purchase + MVP-споры |
| `src/CuratorBanRegistry.sol` | Per-interface реестр банов (информационный, не влияет на Marketplace) |
| `src/mocks/MockERC20.sol` | Токен для тестов |

**В MVP не входит** полный децентрализованный суд (стейкинг, commit-reveal, VRF, апелляции) и глобальный кросс-интерфейсный бан.

## Жизненный цикл сделки

1. `createOffer` / `createOfferWithSig` — `id => seller, amount, timelock, IPFS CID, contentHash, feeBps (0.1–20%)`.
2. Покупатель `approve` ERC-20, затем `purchase(offerId)` — оффер одноразовый, сумма на контракте, комиссия **удерживается** до выплаты продавцу.
3. `confirmReceipt` / `confirmReceiptWithSig` — выплата продавцу (`amount - fee`) и комиссии на `feeRecipient`.
4. `sellerCancel` — возврат покупателю.
5. `refundExpired` (keeper) — если нет подтверждения и нет спора, **возврат покупателю**.
6. `openDispute` (любая сторона) — `disputeLock`, выплаты заморожены. Продавец так блокирует автовозврат, если товар выдан, а покупатель молчит.
7. Модераторы (до 5 адресов) голосуют `vote`; простое большинство вызывает `set_receiver`.
8. `executeVerdict` после `verdictDelay` (в спецификации — повторный timelock; апелляций на MVP нет).

## Бан пользователей (информационный, per-interface)

Отдельный контракт `CuratorBanRegistry`, не связан с эскроу-логикой. Пространство имён бана = адрес куратора (интерфейса): `msg.sender` при вызове `setBan` одновременно служит ключом namespace, поэтому разные интерфейсы не могут писать в чужой список — фильтрация спама на бэкенде не нужна.

**Бан не блокирует действия в `Marketplace.sol`** (`createOffer`, `purchase` и т.д. проходят как обычно) — это сигнал для фронтенда/бэкенда, что скрывать в своём каталоге.

1. `setBan(curator, user, bannedUntil)` — куратор или его делегат банит/разбанивает. `bannedUntil = 0` — снять бан, `BAN_PERMANENT` (`type(uint64).max`) — навсегда, иное значение — таймстамп истечения (временный бан).
2. `setDelegate(delegate, active)` — куратор мгновенно включает/выключает право делегата вызывать `setBan` от его имени. Без задержки: задержка не защищает от компрометации ключа куратора, поскольку `setBan` вызывается тем же ключом напрямую, минуя делегирование.
3. `setGuardian(guardian, active)` / `pause(curator)` / `unpause()` — независимый от куратора guardian-адрес может мгновенно заморозить `setBan` для куратора при подозрении на компрометацию его ключа. Снять паузу может только сам куратор (не guardian) — иначе скомпрометированный guardian стал бы отдельным вектором атаки.
4. `isBanned(curator, user)` — view-хелпер для чтения статуса.

**Рекомендация по безопасности**: если куратор — это ценный, часто используемый адрес, разумнее сделать его мультисигом (Safe), а не полагаться только на guardian-паузу.

**В MVP не входит**: глобальный (сквозной для всех интерфейсов) бан за подтверждённое мошенничество — открытый вопрос, решается отдельно (вероятно через `Ownable`/модераторский кворум `Marketplace.sol`, вне этого permissionless-реестра).

## Relayer

EIP-712: оффер и подтверждение получения можно подписать офчейн; транзакцию публикует любой адрес (relayer платит газ).

## События для индексатора

**Marketplace**: `OfferCreated`, `OfferCancelled`, `PurchaseCreated`, `ReceiptConfirmed`, `SellerCancelled`, `RefundedToBuyer`, `DisputeOpened`, `DisputeVote`, `ReceiverSet`, `Settled`.

**CuratorBanRegistry**: `BanStatusChanged`, `DelegateUpdated`, `GuardianUpdated`, `PausedByGuardian`, `UnpausedByCurator`.

Бэкенду нужны зеркальные таблицы `bans(curator, user, banned_until)`, `delegates(curator, delegate, active)`, `guardians(curator, guardian, active)`, `curator_paused(curator, paused)` — читаются обычным SQL при отдаче каталога, без RPC-запросов в блокчейн на каждый рендер.

Автовыдача только после `PurchaseCreated`, секрет **не** кладётся в IPFS.

## Команды

```bash
curl -L https://foundry.paradigm.xyz | bash
foundryup
forge install foundry-rs/forge-std
forge build
forge test -vv
```

Деплой: задать `PRIVATE_KEY`, `USDC`, опционально `USDT`, `FEE_RECIPIENT`.

```bash
forge script script/Deploy.s.sol --rpc-url $RPC --broadcast
```

После деплоя: `addModerator` (2–5 человек), `setAllowedToken`. Для `CuratorBanRegistry` отдельного деплоя владельца не требуется — контракт permissionless, каждый интерфейс использует его самостоятельно со своего адреса.

## Зафиксированные решения и допущения

- Таймер без подтверждения → покупатель; продавец спасает сделку через `openDispute`.
- Комиссия 10–2000 bps на оффер.
- `cancelFeeBps` по умолчанию в деплое 1% — в заметках «комиссия сети» не задана числом; меняйте `setCancelFeeBps`. //cancelFeeBps deleted Поменять deploy.
- `verdictDelay` по умолчанию 0, чтобы keeper сразу вызвал `executeVerdict`; для прод-зазора поставьте секунды.
- Один раунд голосования, без стейка и апелляций.
- Бан — permissionless и per-curator (namespace = `msg.sender`), без влияния на ончейн-логику Marketplace.
- Защита от компрометации ключа куратора — guardian-пауза (мгновенная заморозка `setBan`) и/или мультисиг в роли куратора; не задержка.
- Глобальный кросс-интерфейсный бан не реализован — открытый вопрос.
