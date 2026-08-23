To do:
- Бан адреса
- Регистрация через стейк, а не только по почте
- Добавить в offer поле quantity, чтобы один и тот же товар можно было продавать многократно. if quantity == 0: бесконечное количество

# dApp Marketplace — смарт-контракты (MVP)

Foundry-проект ядра эскроу по роудмапу и сценариям «Действия пользователей и бэкенд».

Сеть: любой EVM. Расчёты: USDT/USDC (whitelist токенов).

## Ончейн vs офчейн

Контракт отвечает только за деньги и неизменяемые факты сделки. Каталог, SIWE, email продавца, IPFS pinning, секреты автовыдачи, чат и keeper — на бэкенде. Индексируйте события ниже.

## Контракты

| Файл | Роль |
|---|---|
| `src/Marketplace.sol` | OfferRegistry + Escrow/Purchase + MVP-споры |
| `src/mocks/MockERC20.sol` | Токен для тестов |

**В MVP не входит** gолный децентрализованный суд (стейкинг, commit-reveal, VRF, апелляции).

## Жизненный цикл сделки

1. `createOffer` / `createOfferWithSig` — `id => seller, amount, timelock, IPFS CID, contentHash, feeBps (0.1–20%)`.
2. Покупатель `approve` ERC-20, затем `purchase(offerId)` — оффер одноразовый, сумма на контракте, комиссия **удерживается** до выплаты продавцу.
3. `confirmReceipt` / `confirmReceiptWithSig` — выплата продавцу (`amount - fee`) и комиссии на `feeRecipient`.
4. `sellerCancel` — возврат покупателю минус `cancelFeeBps` («комиссия сети»).
5. `refundExpired` (keeper) — если нет подтверждения и нет спора, **возврат покупателю**.
6. `openDispute` (любая сторона) — `disputeLock`, выплаты заморожены. Продавец так блокирует автовозврат, если товар выдан, а покупатель молчит.
7. Модераторы (до 5 адресов) голосуют `vote`; простое большинство вызывает `set_receiver`.
8. `executeVerdict` после `verdictDelay` (в спецификации — повторный timelock; апелляций на MVP нет).

## Relayer

EIP-712: оффер и подтверждение получения можно подписать офчейн; транзакцию публикует любой адрес (relayer платит газ).

## События для индексатора

`OfferCreated`, `OfferCancelled`, `PurchaseCreated`, `ReceiptConfirmed`, `SellerCancelled`, `RefundedToBuyer`, `DisputeOpened`, `DisputeVote`, `ReceiverSet`, `Settled`.

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

После деплоя: `addModerator` (2–5 человек), `setAllowedToken`.

## Зафиксированные решения и допущения

- Таймер без подтверждения → покупатель; продавец спасает сделку через `openDispute`.
- Комиссия 10–2000 bps на оффер.
- `cancelFeeBps` по умолчанию в деплое 1% — в заметках «комиссия сети» не задана числом; меняйте `setCancelFeeBps`.
- `verdictDelay` по умолчанию 0, чтобы keeper сразу вызвал `executeVerdict`; для прод-зазора поставьте секунды.
- Один раунд голосования, без стейка и апелляций.
