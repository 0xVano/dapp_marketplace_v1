To do:
- Добавить регистрацию модератором через стейкинг, слешинг стейка
- Сколько и как слешится за неправильные решения

# dApp Marketplace — смарт-контракты (MVP)

Foundry-проект ядра эскроу по роудмапу и сценариям «Действия пользователей и бэкенд».

Сеть: любой EVM. Расчёты: USDT/USDC (whitelist токенов).

## Ончейн vs офчейн

Контракт отвечает только за деньги и неизменяемые факты сделки. Каталог, SIWE, email продавца, IPFS pinning, секреты автовыдачи, чат и keeper — на бэкенде. Индексируйте события ниже.

## Контракты

| Файл                           | Роль                                                                  |
| ------------------------------ | --------------------------------------------------------------------- |
| `src/Marketplace.sol`          | OfferRegistry + Escrow/Purchase + MVP-споры                           |
| `src/CuratorBanRegistry.sol`   | Per-interface реестр банов (информационный, не влияет на Marketplace) |
| `src/mocks/MockERC20.sol`      | Токен для тестов                                                      |
| `src/CuratorStakeRegistry.sol` | Per-interface anti-sybil стейк-регистрация                            |

**В MVP не входит** полный децентрализованный суд (стейкинг, commit-reveal, VRF, апелляции) и глобальный кросс-интерфейсный бан.

## Жизненный цикл сделки

1. `createOffer` / `createOfferWithSig` — `id => seller, amount, timelock, IPFS CID, contentHash, feeBps (0.1–20%)`.
2. Покупатель `approve` ERC-20, затем `purchase(offerId)` — оффер одноразовый, сумма на контракте, комиссия **удерживается** до выплаты продавцу.
3. `confirmReceipt` / `confirmReceiptWithSig` — выплата продавцу (`amount - fee`) и комиссии на `feeRecipient`.
4. `sellerCancel` — возврат покупателю.
5. `refundExpired` (keeper) — если нет подтверждения и нет спора, **возврат покупателю**.
6. `openDispute` (покупатель или продавец) — `disputeLock`, выплаты заморожены. Продавец так блокирует автовозврат, если товар выдан, а покупатель молчит.
7. Модераторы (до 5 адресов) голосуют `vote(purchaseId, refundBps)`; **refundBps в базисных пунктах 0–10000** (0 = 100% продавцу, 10000 = 100% покупателю, 5000 = 50/50). При достижении простого большинства считается **медиана** голосов и фиксируется как `verdictRefundBps`.
8. `executeVerdict` после `verdictDelay` — **распределяет средства по verdictRefundBps**, комиссия протокола удерживается **только из доли продавца**. Апелляций на MVP нет.

## Бан пользователей (информационный, per-interface)

Отдельный контракт `CuratorBanRegistry`, не связан с эскроу-логикой. Пространство имён бана = адрес куратора (интерфейса): `msg.sender` при вызове `setBan` одновременно служит ключом namespace, поэтому разные интерфейсы не могут писать в чужой список — фильтрация спама на бэкенде не нужна.

**Бан не блокирует действия в `Marketplace.sol`** (`createOffer`, `purchase` и т.д. проходят как обычно) — это сигнал для фронтенда/бэкенда, что скрывать в своём каталоге.

1. `setBan(curator, user, bannedUntil)` — куратор или его делегат банит/разбанивает. `bannedUntil = 0` — снять бан, `BAN_PERMANENT` (`type(uint64).max`) — навсегда, иное значение — таймстамп истечения (временный бан).
2. `setDelegate(delegate, active)` — куратор мгновенно включает/выключает право делегата вызывать `setBan` от его имени. Без задержки: задержка не защищает от компрометации ключа куратора, поскольку `setBan` вызывается тем же ключом напрямую, минуя делегирование.
3. `setGuardian(guardian, active)` / `pause(curator)` / `unpause()` — независимый от куратора guardian-адрес может мгновенно заморозить `setBan` для куратора при подозрении на компрометацию его ключа. Снять паузу может только сам куратор (не guardian) — иначе скомпрометированный guardian стал бы отдельным вектором атаки.
4. `isBanned(curator, user)` — view-хелпер для чтения статуса.

**Рекомендация по безопасности**: если куратор — это ценный, часто используемый адрес, разумнее сделать его мультисигом (Safe), а не полагаться только на guardian-паузу.

**В MVP не входит**: глобальный (сквозной для всех интерфейсов) бан за подтверждённое мошенничество — открытый вопрос, решается отдельно (вероятно через `Ownable`/модераторский кворум `Marketplace.sol`, вне этого permissionless-реестра).



## Стейк-регистрация (permissionless, per-interface, anti-sybil)

Отдельный контракт `CuratorStakeRegistry`, не связан с эскроу-логикой и спорами `Marketplace.sol`. Альтернатива подтверждению почты: пользователь (продавец **или** покупатель — контракт не различает роли) вносит возвращаемый стейк в пользу конкретного куратора (интерфейса). Пространство имён — как в `CuratorBanRegistry`: `curator = msg.sender` при настройке, поэтому один пользователь может независимо стейкать сразу у нескольких кураторов.


- `setTokenConfig(token, accepted, minStakeAmount)` — куратор сам решает, какие токены принимает и какой минимальный стейк считает достаточным для eligibility.
- `setUnstakeCooldown(cooldown)` — куратор задаёт задержку между `requestUnstake` и `withdraw`; это окно, в течение которого куратор/делегат ещё может успеть вызвать `slash` до вывода средств.
- `stake(curator, token, amount)` / `requestUnstake(curator)` / `withdraw(curator)` — внесение и возврат стейка пользователем.
- `isEligible(curator, user)` — view-хелпер для бэкенда: читается вместо (или вместе с) флагом `emailVerified` при решении, допускать ли пользователя к каталогу.
- `slash(curator, user, amount, to)` — изъятие стейка. Вызывает сам куратор или его делегат (`setDelegate`, без задержки активации — та же причина, что и у `CuratorBanRegistry`: задержка не защищает от компрометации ключа). **Модераторов и голосования внутри контракта нет** — если фронтенду нужен коллегиальный вердикт, `delegate` указывается на multisig (Safe) или отдельный контракт со своей логикой модерации.
- `setGuardian(guardian, active)` / `pause(curator)` / `unpause()` — тот же guardian-паттерн, что и в `CuratorBanRegistry`, но здесь пауза блокирует `slash`, а не `stake`/`withdraw` — пользователь всегда может вывести свои деньги (после кулдауна), даже если ключ куратора скомпрометирован и приостановлен.

**Рекомендация по безопасности**: как и для `CuratorBanRegistry` — если куратор является ценным адресом, разумнее сделать его мультисигом (Safe), а не полагаться только на guardian-паузу.

**В MVP не входит**: ограничения на адрес-получатель изъятого стейка (`to` в `slash`) — контракт не мешает куратору направить конфискованное себе в казну; сдерживающий фактор — репутация фронтенда, а не код.

## Relayer

EIP-712: оффер и подтверждение получения можно подписать офчейн; транзакцию публикует любой адрес (relayer платит газ).

## События для индексатора

**Marketplace**: `OfferCreated`, `OfferCancelled`, `PurchaseCreated`, `ReceiptConfirmed`, `SellerCancelled`, `RefundedToBuyer`, `DisputeOpened`, `DisputeVote(uint256,address,uint16 refundBps)`, `VerdictRefundBpsSet(uint256,uint16 refundBps,uint64 verdictDelayUntil)`, `Settled`.

**CuratorBanRegistry**: `BanStatusChanged`, `DelegateUpdated`, `GuardianUpdated`, `PausedByGuardian`, `UnpausedByCurator`.

**CuratorStakeRegistry**: `TokenConfigUpdated`, `UnstakeCooldownUpdated`, `DelegateUpdated`, `GuardianUpdated`, `PausedByGuardian`, `UnpausedByCurator`, `Staked`, `UnstakeRequested`, `Withdrawn`, `Slashed`.

Бэкенду нужны зеркальные таблицы `bans(curator, user, banned_until)`, `delegates(curator, delegate, active)`, `guardians(curator, guardian, active)`, `curator_paused(curator, paused)`,`stakes(curator, user, token, amount, unlock_at)`, `token_config(curator, token, accepted, min_stake)` — читаются обычным SQL при отдаче каталога, без RPC-запросов в блокчейн на каждый рендер.

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
- Комиссия 0–10000 bps, то есть от 0 до 100%. Общая для всех офферов.
- `cancelFeeBps` по умолчанию в деплое 1% — в заметках «комиссия сети» не задана числом; меняйте `setCancelFeeBps`. //cancelFeeBps deleted Поменять deploy.
- `verdictDelay` по умолчанию 0, чтобы keeper сразу вызвал `executeVerdict`; для прод-зазора поставьте секунды.
- **Спор: модераторы голосуют `refundBps` (0–10000), считается медиана при большинстве. Комиссия протокола удерживается только из доли продавца.**
- Один раунд голосования, без стейка и апелляций.
- Защита от компрометации ключа куратора — guardian-пауза (мгновенная заморозка `setBan`) и/или мультисиг в роли куратора; не задержка.
- Бан — permissionless и per-curator (namespace = `msg.sender`), без влияния на ончейн-логику Marketplace.
- Глобальный кросс-интерфейсный бан не реализован и не будет. Каждый интерфейс решает сам кого банить а кого нет. 