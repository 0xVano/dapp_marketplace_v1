// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";
import {Ownable} from "./utils/Ownable.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";
import {ECDSA} from "./utils/ECDSA.sol";

/// @title Marketplace
/// @notice MVP эскроу-маркетплейс: OfferRegistry + Purchase/Escrow + пул модераторов
/// @dev Полный Kleros-подобный арбитраж не входит в MVP
contract Marketplace is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint16 public constant MAX_BPS = 10_000; // 100% — предел системы счисления bps
    uint16 public feeBps; // текущая глобальная комиссия, настраивается owner'ом
    uint8 public constant MAX_MODERATORS = 5; //только в mvp

    bytes32 public constant OFFER_TYPEHASH = keccak256(
        "Offer(address seller,address token,uint256 amount,uint32 timelock,uint64 expiresAt,bytes32 contentHash,string ipfsCid,uint256 offerQuantity,uint256 nonce)"
    );
    bytes32 public constant CONFIRM_TYPEHASH = keccak256("Confirm(uint256 purchaseId,uint256 nonce)");

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    enum PurchaseState {
        None,
        Escrowed,
        Disputed,
        Settled
    }

    struct Offer {
        address seller;
        address token;
        uint256 amount; // цена за единицу товара, не общая сумма сделки
        uint32 timelock;
        uint64 expiresAt; // момент времени, после которого оффер больше нельзя купить. Если 0 — оффер бессрочный.
        bytes32 contentHash; // CID доказывает неизменность файла, а этот хэш доказывает, что именно этот человек выставил этот оффер.
        string ipfsCid;
        bool active; // true при создании; false только при cancelOffer (дальнейшие продажи стоп, непроданный остаток сгорает)
        uint256 offerQuantity; // объём лота: 0 = бесконечно. Не декрементируется при покупке — иначе 0 стало бы неотличимо от «бесконечно»
        uint256 sold; // сколько единиц уже купили. remaining = offerQuantity == 0 ? ∞ : offerQuantity - sold
    }

    struct Purchase {
        uint256 offerId;
        address buyer;
        address seller;
        address token; 
        uint256 purchaseQuantity;
        uint256 amount;
        uint256 fee;
        uint256 sellerPayout;
        uint64 autoRefundAt;
        uint64 verdictDelayUntil;
        PurchaseState state;
        uint16 verdictRefundBps; // 0 = full to seller, 10000 = full to buyer, 5000 = 50/50 split
        bool verdictSet; // true когда вердикт зафиксирован (медиана рассчитана)
        bytes32 evidenceHash;
        bool disputeLock;
    }

    uint256 public nextOfferId = 1;
    uint256 public nextPurchaseId = 1;

    address public feeRecipient;
    uint32 public verdictDelay; // после set_receiver таймер запускается заново (MVP без апелляций)

    mapping(uint256 => Offer) public offers;
    mapping(uint256 => Purchase) public purchases;
    mapping(address => bool) public allowedTokens;
    mapping(address => uint256) public nonces; //Защита от replay-атак для офчейн-подписей. Без nonce одну и ту же подпись можно было бы переиспользовать

    address[] public moderators;
    mapping(address => bool) public isModerator;
    mapping(uint256 => mapping(address => bool)) public hasVoted;
    mapping(uint256 => uint16[]) public moderatorVotes; // хранит refundBps каждого модератора для расчёта медианы

    event TokenAllowed(address indexed token, bool allowed);
    event FeeRecipientUpdated(address indexed feeRecipient);
    event VerdictDelayUpdated(uint32 verdictDelay); // в зависимости от типа дела может быть необходима разная задержка
    event ModeratorAdded(address indexed moderator);
    event ModeratorRemoved(address indexed moderator);
    event FeeBpsUpdated(uint16 feeBps);

    event OfferCreated(
        uint256 indexed offerId,
        address indexed seller,
        address indexed token,
        uint256 amount,
        uint32 timelock,
        uint64 expiresAt,
        bytes32 contentHash,
        string ipfsCid,
        uint256 offerQuantity
    );
    event OfferCancelled(uint256 indexed offerId);

    event PurchaseCreated(
        uint256 indexed purchaseId,
        uint256 indexed offerId,
        address indexed buyer,
        address seller,
        uint256 amount,
        uint256 fee,
        uint64 autoRefundAt,
        uint256 purchaseQuantity
    );
    event ReceiptConfirmed(uint256 indexed purchaseId, address indexed buyer); //возможно переименовать
	event SellerCancelled(uint256 indexed purchaseId, uint256 refund); // было (purchaseId, penalty, refund) Что это?
    event RefundedToBuyer(uint256 indexed purchaseId, uint256 amount);
    event DisputeOpened(uint256 indexed purchaseId, address indexed opener, bytes32 evidenceHash);
    event DisputeVote(uint256 indexed purchaseId, address indexed moderator, uint16 refundBps);
    event VerdictRefundBpsSet(uint256 indexed purchaseId, uint16 refundBps, uint64 verdictDelayUntil);
    event Settled(uint256 indexed purchaseId, address indexed receiver, uint256 amount, uint256 fee); //переименовать

    error InvalidFee();
    error InvalidTimelock();
    error InvalidAmount();
    error TokenNotAllowed();
    error OfferInactive();
    error OfferExpired();
    error InvalidQuantity();
    error InsufficientQuantity();
    error NotSeller();
    error NotBuyer();
    error NotParty();
    error NotModerator();
    error BadState();
    error autoRefundAtNotReached();
    error autoRefundAtPassed();
    error AlreadyVoted();
    error DisputeLocked();
    error NoPendingReceiver();
    error VerdictDelayNotReached();
    error ModeratorExists();
    error NotAModerator();
    error TooManyModerators();
    error InvalidSignature();
    error ZeroAddressError();

    /// @notice Инициализирует маркетплейс, задаёт владельца, получателя комиссий и глобальные экономические параметры
    /// @dev Вызывается один раз при деплое. Наследует Ownable(initialOwner). Проверяет feeRecipient != 0 и feeBps <= MAX_BPS
    /// @param initialOwner адрес будущего owner'а (получает права onlyOwner)
    /// @param feeRecipient_ адрес получателя комиссий протокола
    /// @param verdictDelay_ задержка в секундах между фиксацией вердикта модераторов и возможностью executeVerdict
    /// @param feeBps_ комиссия протокола в базисных пунктах (bps, 100 = 1%, 10_000 = 100%)
    constructor(address initialOwner, address feeRecipient_, uint32 verdictDelay_, uint16 feeBps_)
        Ownable(initialOwner)
    {
        if (feeRecipient_ == address(0)) revert ZeroAddressError();
        if (feeBps_ > MAX_BPS) revert InvalidFee();
        feeRecipient = feeRecipient_;
        verdictDelay = verdictDelay_;
        feeBps = feeBps_;
        emit FeeRecipientUpdated(feeRecipient_);
        emit VerdictDelayUpdated(verdictDelay_);
        emit FeeBpsUpdated(feeBps_);
    }

    // -------------------------------------------------------------------------
    // Admin
    // -------------------------------------------------------------------------

    /// @notice Разрешает или запрещает использование ERC20-токена для создания офферов и покупок
    /// @dev Доступ только у owner. Записывает флаг в allowedTokens[token]
    /// @param token адрес ERC20-контракта
    /// @param allowed true — разрешить токен, false — запретить
    function setAllowedToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddressError();
        allowedTokens[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    /// @notice Меняет адрес получателя комиссий протокола
    /// @dev Доступ только у owner. Новый адрес применяется ко всем будущим выплатам _paySeller
    /// @param feeRecipient_ новый адрес получателя комиссий, не может быть address(0)
    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddressError();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    /// @notice Меняет глобальную задержку исполнения вердикта модераторов
    /// @dev Доступ только у owner. Влияет на verdictDelayUntil, который выставляется в _setReceiver
    /// @param verdictDelay_ новая задержка в секундах после фиксации большинства голосов до executeVerdict
    function setVerdictDelay(uint32 verdictDelay_) external onlyOwner {
        verdictDelay = verdictDelay_;
        emit VerdictDelayUpdated(verdictDelay_);
    }

    /// @notice Меняет глобальную ставку комиссии протокола
    /// @dev Доступ только у owner. Применяется при каждой новой покупке: fee = total * feeBps / 10_000
    /// @param feeBps_ новая ставка в базисных пунктах, должна быть <= MAX_BPS (10_000)
    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_BPS) revert InvalidFee();
        feeBps = feeBps_;
        emit FeeBpsUpdated(feeBps_);
    }

    /// @notice Добавляет нового модератора в пул арбитров
    /// @dev Доступ только у owner. Проверяет лимит MAX_MODERATORS и отсутствие дубликата. Пушит в массив moderators и ставит isModerator=true
    /// @param moderator адрес добавляемого модератора, не может быть address(0)
    function addModerator(address moderator) external onlyOwner {
        if (moderator == address(0)) revert ZeroAddressError();
        if (isModerator[moderator]) revert ModeratorExists();
        if (moderators.length >= MAX_MODERATORS) revert TooManyModerators();
        isModerator[moderator] = true;
        moderators.push(moderator);
        emit ModeratorAdded(moderator);
    }

    /// @notice Удаляет модератора из пула арбитров
    /// @dev Доступ только у owner. Использует swap-and-pop для удаления из массива moderators за O(n) поиск + O(1) удаление
    /// @param moderator адрес удаляемого модератора, должен существовать в isModerator
    function removeModerator(address moderator) external onlyOwner {
        if (!isModerator[moderator]) revert NotAModerator();
        isModerator[moderator] = false;
        uint256 len = moderators.length;
        for (uint256 i; i < len; ++i) {
            if (moderators[i] == moderator) {
                moderators[i] = moderators[len - 1];
                moderators.pop();
                break;
            }
        }
        emit ModeratorRemoved(moderator);
    }

    /// @notice Возвращает текущее количество активных модераторов
    /// @dev View-функция без изменения состояния, читает moderators.length
    function moderatorCount() public view returns (uint256) {
        return moderators.length;
    }

    /// @notice Вычисляет порог простого большинства для голосования модераторов
    /// @dev Формула n/2 + 1, при n==0 возвращает 0 чтобы избежать деления на ноль и блокировки логики vote
    function majorityThreshold() public view returns (uint256) {
        uint256 n = moderators.length;
        return n == 0 ? 0 : n / 2 + 1;
    }

    /// @notice Вычисляет EIP-712 domain separator для защиты подписей от кросс-контрактного и кросс-чейн replay
    /// @dev Хэширует EIP712Domain(name="dApp Marketplace", version="1", chainId, verifyingContract=address(this))
    function domainSeparator() public view returns (bytes32) {
        return keccak256(
            abi.encode(
                _EIP712_DOMAIN_TYPEHASH,
                keccak256(bytes("dApp Marketplace")),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    // -------------------------------------------------------------------------
    // OfferRegistry
    // -------------------------------------------------------------------------

    /// @notice Создаёт новый оффер напрямую от имени вызывающего продавца
    /// @dev Обёртка над _createOffer, передаёт msg.sender как seller. Требует что токен разрешён в allowedTokens
    /// @param token адрес ERC20-токена расчётов по офферу
    /// @param amount цена за одну единицу товара в минимальных единицах токена
    /// @param timelock длительность эскроу в секундах (период до autoRefundAt)
    /// @param expiresAt unix-время истечения оффера; 0 — бессрочный оффер
    /// @param contentHash keccak256-хэш контента/описания для доказательства авторства оффера
    /// @param ipfsCid CID в IPFS с метаданными/файлами товара
    /// @param offerQuantity объём лота; 0 — бесконечный запас, иначе лимит единиц на продажу
    /// @return offerId идентификатор созданного оффера (инкремент nextOfferId)
    function createOffer(
        address token,
        uint256 amount,
        uint32 timelock,
        uint64 expiresAt,
        bytes32 contentHash,
        string calldata ipfsCid,
        uint256 offerQuantity
    ) external returns (uint256 offerId) {
        return _createOffer(msg.sender, token, amount, timelock, expiresAt, contentHash, ipfsCid, offerQuantity);
    }

    /// @notice Создаёт оффер через офчейн-подпись продавца (мета-транзакция/релеер)
    /// @dev Проверяет EIP-712 подпись seller'а по структуре OFFER_TYPEHASH с nonce для защиты от replay, затем делегирует в _createOffer. Инкрементирует nonces[seller]
    /// @param seller адрес продавца, чья подпись проверяется
    /// @param token адрес ERC20-токена расчётов
    /// @param amount цена за единицу товара
    /// @param timelock длительность эскроу в секундах
    /// @param expiresAt unix-время истечения оффера; 0 — бессрочно
    /// @param contentHash хэш контента для привязки оффера к автору
    /// @param ipfsCid CID в IPFS с описанием товара
    /// @param offerQuantity объём лота; 0 — бесконечно
    /// @param signature EIP-712 подпись seller'а над OFFER_TYPEHASH (seller, token, amount, timelock, expiresAt, contentHash, keccak256(ipfsCid), offerQuantity, nonce)
    /// @return offerId идентификатор созданного оффера
    function createOfferWithSig(
        address seller,
        address token,
        uint256 amount,
        uint32 timelock,
        uint64 expiresAt,
        bytes32 contentHash,
        string calldata ipfsCid,
        uint256 offerQuantity,
        bytes calldata signature
    ) external returns (uint256 offerId) {
        uint256 nonce = nonces[seller]++;
        bytes32 structHash = keccak256(
            abi.encode(
                OFFER_TYPEHASH,
                seller,
                token,
                amount,
                timelock,
                expiresAt,
                contentHash,
                keccak256(bytes(ipfsCid)),
                offerQuantity,
                nonce
            )
        );
        if (_recover(structHash, signature) != seller) revert InvalidSignature();
        return _createOffer(seller, token, amount, timelock, expiresAt, contentHash, ipfsCid, offerQuantity);
    }

    /// @notice Отменяет активный оффер продавца, останавливая дальнейшие продажи
    /// @dev Ставит active=false, уже созданные Purchase не затрагиваются. Непроданный остаток сгорает безвозвратно
    /// @param offerId идентификатор отменяемого оффера, caller должен быть offers[offerId].seller
    function cancelOffer(uint256 offerId) external {
        Offer storage offer = offers[offerId];
        if (offer.seller != msg.sender) revert NotSeller();
        if (!offer.active) revert OfferInactive();
        offer.active = false;
        emit OfferCancelled(offerId);
    }

    /// @notice Внутренний конструктор оффера с валидацией и записью в storage
    /// @dev Проверяет allowedTokens, amount!=0, timelock!=0, не истёк ли expiresAt. Инкрементирует nextOfferId и эмитит OfferCreated
    /// @param seller адрес продавца (msg.sender или восстановленный из подписи)
    /// @param token адрес ERC20-токена
    /// @param amount цена за единицу
    /// @param timelock длительность эскроу в секундах
    /// @param expiresAt unix-время истечения; 0 — бессрочно, иначе должно быть > block.timestamp
    /// @param contentHash хэш контента/описания
    /// @param ipfsCid CID в IPFS
    /// @param offerQuantity объём лота; 0 — бесконечный
    /// @return offerId идентификатор созданного оффера
    function _createOffer(
        address seller,
        address token,
        uint256 amount,
        uint32 timelock,
        uint64 expiresAt,
        bytes32 contentHash,
        string calldata ipfsCid,
        uint256 offerQuantity
    ) internal returns (uint256 offerId) {
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (amount == 0) revert InvalidAmount();
        if (timelock == 0) revert InvalidTimelock();
        if (expiresAt != 0 && expiresAt <= block.timestamp) revert OfferExpired();

        offerId = nextOfferId++;
        offers[offerId] = Offer({
            seller: seller,
            token: token,
            amount: amount,
            timelock: timelock,
            expiresAt: expiresAt,
            contentHash: contentHash,
            ipfsCid: ipfsCid,
            active: true,
            offerQuantity: offerQuantity,
            sold: 0
        });

        emit OfferCreated(offerId, seller, token, amount, timelock, expiresAt, contentHash, ipfsCid, offerQuantity);
    }

    // -------------------------------------------------------------------------
    // Escrow / Purchase
    // -------------------------------------------------------------------------

    /// @notice Покупает указанное количество единиц по офферу, блокируя средства в эскроу
    /// @dev Проверяет активность и срок оффера, лимит purchaseQuantity, инкрементирует sold, рассчитывает fee/sellerPayout/autoRefundAt, делает safeTransferFrom покупателя на контракт. Защищена от реентрантности
    /// @param offerId идентификатор покупаемого оффера
    /// @param purchaseQuantity количество единиц к покупке, должно быть >0 и не превышать остаток (если offerQuantity оффера !=0)
    /// @return purchaseId идентификатор созданной сделки эскроу
    function purchase(uint256 offerId, uint256 purchaseQuantity) external nonReentrant returns (uint256 purchaseId) {
        if (purchaseQuantity == 0) revert InvalidQuantity();

        Offer storage offer = offers[offerId];
        if (!offer.active) revert OfferInactive();
        if (offer.expiresAt != 0 && block.timestamp > offer.expiresAt) revert OfferExpired();
        if (offer.offerQuantity != 0 && offer.sold + purchaseQuantity > offer.offerQuantity) revert InsufficientQuantity();

        offer.sold += purchaseQuantity;

        uint256 total = offer.amount * purchaseQuantity;
        uint256 fee = (total * feeBps) / 10_000;
        uint256 sellerPayout = total - fee;
        uint64 autoRefundAt = uint64(block.timestamp + offer.timelock);

        purchaseId = nextPurchaseId++;
        purchases[purchaseId] = Purchase({
            offerId: offerId,
            buyer: msg.sender,
            seller: offer.seller,
            token: offer.token,
            purchaseQuantity: purchaseQuantity,
            amount: total,
            fee: fee,
            sellerPayout: sellerPayout,
            autoRefundAt: autoRefundAt,
            verdictDelayUntil: 0,
            state: PurchaseState.Escrowed,
            evidenceHash: bytes32(0),
            disputeLock: false
        });

        IERC20(offer.token).safeTransferFrom(msg.sender, address(this), total);
        emit PurchaseCreated(purchaseId, offerId, msg.sender, offer.seller, total, fee, autoRefundAt, purchaseQuantity);
    }

    /// @notice Подтверждает получение товара покупателем и выплачивает средства продавцу
    /// @dev Вызывает внутренний _confirm с msg.sender как buyer. Требует состояние Escrowed и отсутствие disputeLock. Защищена от реентрантности
    /// @param purchaseId идентификатор сделки эскроу
    function confirmReceipt(uint256 purchaseId) external nonReentrant {
        _confirm(purchaseId, msg.sender);
    }

    /// @notice Подтверждает получение товара через офчейн-подпись покупателя (релеер)
    /// @dev Проверяет EIP-712 подпись buyer'а по CONFIRM_TYPEHASH(purchaseId, nonce), инкрементирует nonces[buyer], затем вызывает _confirm. Защищена от реентрантности
    /// @param purchaseId идентификатор подтверждаемой сделки
    /// @param buyer адрес покупателя, чья подпись проверяется
    /// @param signature EIP-712 подпись buyer'а над Confirm(purchaseId, nonce)
    function confirmReceiptWithSig(uint256 purchaseId, address buyer, bytes calldata signature) external nonReentrant {
        uint256 nonce = nonces[buyer]++;
        bytes32 structHash = keccak256(abi.encode(CONFIRM_TYPEHASH, purchaseId, nonce));
        if (_recover(structHash, signature) != buyer) revert InvalidSignature();
        _confirm(purchaseId, buyer);
    }

    /// @notice Внутренняя логика подтверждения получения: валидирует право покупателя и выплачивает продавцу (обычный фロー без спора)
    /// @dev Проверяет state==Escrowed, !disputeLock, p.buyer==buyer. Эмитит ReceiptConfirmed и вызывает _paySeller для полной выплаты продавцу минус комиссия
    /// @param purchaseId идентификатор сделки
    /// @param buyer адрес покупателя, который подтверждает получение
    function _confirm(uint256 purchaseId, address buyer) internal {
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Escrowed) revert BadState();
        if (p.disputeLock) revert DisputeLocked();
        if (p.buyer != buyer) revert NotBuyer();

        emit ReceiptConfirmed(purchaseId, buyer);
        _paySeller(p, purchaseId);
    }

    /// @notice Позволяет продавцу добровольно отменить сделку и вернуть полную сумму покупателю
    /// @dev Доступен только seller'у в состоянии Escrowed без disputeLock. Ставит Settled и делает safeTransfer всей суммы p.amount покупателю. Защищена от реентрантности
    /// @param purchaseId идентификатор отменяемой сделки
    function sellerCancel(uint256 purchaseId) external nonReentrant {
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Escrowed) revert BadState();
        if (p.disputeLock) revert DisputeLocked();
        if (p.seller != msg.sender) revert NotSeller();

        p.state = PurchaseState.Settled;
        IERC20(p.token).safeTransfer(p.buyer, p.amount);
        emit SellerCancelled(purchaseId, p.amount);
        emit Settled(purchaseId, p.buyer, p.amount, 0);
    }

    /// @notice Возвращает средства покупателю после истечения таймлока, если товар не подтверждён и спора нет
    /// @dev Может вызвать keeper/любой адрес. Требует state==Escrowed, !disputeLock, block.timestamp >= autoRefundAt. Ставит Settled и переводит p.amount покупателю. Защищена от реентрантности
    /// @param purchaseId идентификатор просроченной сделки
    function refundExpired(uint256 purchaseId) external nonReentrant {
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Escrowed) revert BadState();
        if (p.disputeLock) revert DisputeLocked();
        if (block.timestamp < p.autoRefundAt) revert autoRefundAtNotReached();

        p.state = PurchaseState.Settled;
        IERC20(p.token).safeTransfer(p.buyer, p.amount);
        emit RefundedToBuyer(purchaseId, p.amount);
        emit Settled(purchaseId, p.buyer, p.amount, 0);
    }

    // -------------------------------------------------------------------------
    // MVP dispute: trusted moderators, simple majority, no staking/appeals
    // -------------------------------------------------------------------------

    /// @notice Открывает спор по сделке, блокируя эскроу от confirm/refund до вердикта
    /// @dev Доступен только buyer или seller сделки в состоянии Escrowed. Переводит в Disputed, ставит disputeLock=true и сохраняет evidenceHash
    /// @param purchaseId идентификатор оспариваемой сделки
    /// @param evidenceHash keccak256-хэш пакета доказательств (IPFS/чат/файлы), 0 если без доказательств
    function openDispute(uint256 purchaseId, bytes32 evidenceHash) external {
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Escrowed) revert BadState();
        if (p.disputeLock) revert DisputeLocked();
        if (msg.sender != p.buyer && msg.sender != p.seller) revert NotParty();

        p.state = PurchaseState.Disputed;
        p.disputeLock = true;
        p.evidenceHash = evidenceHash;
        emit DisputeOpened(purchaseId, msg.sender, evidenceHash);
    }

    /// @notice Фиксирует голос модератора в споре; при достижении большинства рассчитывает медиану и фиксирует verdictRefundBps
    /// @dev Требует isModerator[msg.sender], state==Disputed, не голосовал ранее. refundBps в базисных пунктах (0=100% продавцу, 10000=100% покупателю). Сохраняет голос в moderatorVotes, при majorityThreshold вычисляет медиану и вызывает _setReceiver
    /// @param purchaseId идентификатор оспариваемой сделки
    /// @param refundBps процент возврата покупателю в базисных пунктах (0-10000)
    function vote(uint256 purchaseId, uint16 refundBps) external {
        if (!isModerator[msg.sender]) revert NotModerator();
        if (refundBps > MAX_BPS) revert InvalidFee();
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Disputed || !p.disputeLock) revert BadState();
        if (hasVoted[purchaseId][msg.sender]) revert AlreadyVoted();

        hasVoted[purchaseId][msg.sender] = true;
        moderatorVotes[purchaseId].push(refundBps);

        emit DisputeVote(purchaseId, msg.sender, refundBps);

        uint256 need = majorityThreshold();
        if (moderatorVotes[purchaseId].length >= need) {
            uint16 medianBps = _calculateMedian(moderatorVotes[purchaseId]);
            _setReceiver(purchaseId, p, medianBps);
        }
    }

    /// @notice Вычисляет медиану массива голосов в базисных пунктах
    /// @dev Сортирует копию массива и возвращает среднее значение (для чётного количества — среднее двух центральных). Pure function, не читает storage.
    /// @param votes массив голосов модераторов (refundBps)
    /// @return медиана в базисных пунктах
    function _calculateMedian(uint16[] memory votes) internal pure returns (uint16) {
        uint256 n = votes.length;
        if (n == 0) return 0;
        
        uint16[] memory sorted = new uint16[](n);
        for (uint256 i = 0; i < n; ++i) {
            sorted[i] = votes[i];
        }
        
        for (uint256 i = 0; i < n - 1; ++i) {
            for (uint256 j = 0; j < n - i - 1; ++j) {
                if (sorted[j] > sorted[j + 1]) {
                    (sorted[j], sorted[j + 1]) = (sorted[j + 1], sorted[j]);
                }
            }
        }
        
        if (n % 2 == 1) {
            return sorted[n / 2];
        } else {
            return uint16((sorted[n / 2 - 1] + sorted[n / 2]) / 2);
        }
    }

    /// @notice Внутренняя фиксация вердикта спора (медианный refundBps) и запуск задержки перед выплатой
    /// @dev Записывает verdictRefundBps, verdictSet=true, снимает disputeLock, выставляет verdictDelayUntil = block.timestamp + verdictDelay
    /// @param purchaseId идентификатор сделки
    /// @param p storage-указатель на структуру Purchase
    /// @param refundBps медианный процент возврата покупателю в базисных пунктах (0-10000)
    function _setReceiver(uint256 purchaseId, Purchase storage p, uint16 refundBps) internal {
        p.verdictRefundBps = refundBps;
        p.verdictSet = true;
        p.disputeLock = false;
        p.verdictDelayUntil = uint64(block.timestamp + verdictDelay);
        emit VerdictRefundBpsSet(purchaseId, refundBps, p.verdictDelayUntil);
    }

    /// @notice Исполняет вердикт модераторов после истечения verdictDelay, распределяя средства по verdictRefundBps // Может быть задержана и отменена апелляцией?
    /// @dev Требует state==Disputed, verdictSet==true, block.timestamp >= verdictDelayUntil.
    /// Комиссия протокола удерживается только из доли продавца. Защищена от реентрантности.
    /// @param purchaseId идентификатор сделки с вынесенным вердиктом
    function executeVerdict(uint256 purchaseId) external nonReentrant {
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Disputed) revert BadState();
        if (!p.verdictSet) revert NoPendingReceiver();
        if (block.timestamp < p.verdictDelayUntil) revert VerdictDelayNotReached();

        uint256 buyerShare = (p.amount * p.verdictRefundBps) / MAX_BPS;
        uint256 sellerShare = p.amount - buyerShare;
        uint256 fee = (sellerShare * feeBps) / MAX_BPS;
        uint256 sellerPayout = sellerShare - fee;

        p.state = PurchaseState.Settled;
        IERC20 token = IERC20(p.token);

        if (buyerShare > 0) {
            token.safeTransfer(p.buyer, buyerShare);
        }
        if (fee > 0) {
            token.safeTransfer(feeRecipient, fee);
        }
        if (sellerPayout > 0) {
            token.safeTransfer(p.seller, sellerPayout);
        }

        emit Settled(purchaseId, p.buyer, buyerShare, fee);
        emit Settled(purchaseId, p.seller, sellerPayout, fee);
    }

    /// @notice Внутренняя выплата продавцу с удержанием комиссии протокола (обычный фロー: покупатель подтвердил получение без спора)
    /// @dev Ставит state=Settled, переводит fee на feeRecipient и sellerPayout на seller, эмитит Settled. Используется в _confirm и sellerCancel.
    /// @param p storage-указатель на структуру Purchase с заполненными fee/sellerPayout/token
    /// @param purchaseId идентификатор сделки для события Settled
    function _paySeller(Purchase storage p, uint256 purchaseId) internal {
        p.state = PurchaseState.Settled;
        IERC20 token = IERC20(p.token);
        if (p.fee > 0) token.safeTransfer(feeRecipient, p.fee);
        token.safeTransfer(p.seller, p.sellerPayout);
        emit Settled(purchaseId, p.seller, p.sellerPayout, p.fee);
    }

    /// @notice Восстанавливает адрес подписанта из EIP-712 дайджеста
    /// @dev Собирает digest = keccak256("\x19\x01" || domainSeparator() || structHash) и вызывает ECDSA.recover
    /// @param structHash хэш структуры (OFFER_TYPEHASH или CONFIRM_TYPEHASH) с уже закодированными полями
    /// @param signature ECDSA-подпись в формате 65 байт (r,s,v) или 64 байта (EIP-2098)
    /// @return адрес восстановившего подписанта
    function _recover(bytes32 structHash, bytes calldata signature) internal view returns (address) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        return ECDSA.recover(digest, signature);
    }
}
