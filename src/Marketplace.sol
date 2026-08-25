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
        "Offer(address seller,address token,uint256 amount,uint32 timelock,uint64 expiresAt,bytes32 contentHash,string ipfsCid,uint256 quantity,uint256 nonce)"
    );
    bytes32 public constant CONFIRM_TYPEHASH = keccak256("Confirm(uint256 purchaseId,uint256 nonce)");

    bytes32 private constant _EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    enum PurchaseState {
        None,
        Escrowed,
        Disputed,
        Settled
        // есть несколько стадий escrow
        // возможно добавить статус до подтверждения покупателем
    }

    enum Receiver {
        None,
        Seller,
        Buyer
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
        uint256 quantity; // объём лота: 0 = бесконечно. Не декрементируется при покупке — иначе 0 стало бы неотличимо от «бесконечно»
        uint256 sold; // сколько единиц уже купили. remaining = quantity == 0 ? ∞ : quantity - sold
    }

    struct Purchase {
        uint256 offerId;
        address buyer; //нельзя менять на msg.sender потому что может быть релеер
        address seller; //достать из Offer? Как и 4 строки ниже
        address token; 
        uint256 quantity; // сколько единиц куплено в этой сделке (batch)
        uint256 amount; // сумма эскроу = offer.amount (цена за единицу) * quantity
        uint256 fee;
        uint256 sellerPayout;
        uint64 autoRefundAt; //Это момент block.timestamp + offer.timelock, после истечения которого можно вернуть деньги покупателю
        uint64 verdictDelayUntil; // Задержка перед выплатой после вынесения вердикта. Будет использоваться только если нужна апелляция
        PurchaseState state;
        Receiver pendingReceiver;
        bytes32 evidenceHash; //Хэш пакета доказательств (чат + файлы), который сторона предоставляет при открытии спора
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
    mapping(uint256 => uint256) public votesForSeller; //работает для каждой сделки отдельно
    mapping(uint256 => uint256) public votesForBuyer;

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
        uint256 quantity
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
        uint256 quantity
    );
    event ReceiptConfirmed(uint256 indexed purchaseId, address indexed buyer); //возможно переименовать
	event SellerCancelled(uint256 indexed purchaseId, uint256 refund); // было (purchaseId, penalty, refund) Что это?
    event RefundedToBuyer(uint256 indexed purchaseId, uint256 amount);
    event DisputeOpened(uint256 indexed purchaseId, address indexed opener, bytes32 evidenceHash);
    event DisputeVote(uint256 indexed purchaseId, address indexed moderator, Receiver choice);
    event ReceiverSet(uint256 indexed purchaseId, Receiver receiver, uint64 verdictDelayUntil); //переименовать
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

    function setAllowedToken(address token, bool allowed) external onlyOwner {
        if (token == address(0)) revert ZeroAddressError();
        allowedTokens[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    function setFeeRecipient(address feeRecipient_) external onlyOwner {
        if (feeRecipient_ == address(0)) revert ZeroAddressError();
        feeRecipient = feeRecipient_;
        emit FeeRecipientUpdated(feeRecipient_);
    }

    function setVerdictDelay(uint32 verdictDelay_) external onlyOwner {
        verdictDelay = verdictDelay_;
        emit VerdictDelayUpdated(verdictDelay_);
    }

    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_BPS) revert InvalidFee();
        feeBps = feeBps_;
        emit FeeBpsUpdated(feeBps_);
    }

    function addModerator(address moderator) external onlyOwner {
        if (moderator == address(0)) revert ZeroAddressError();
        if (isModerator[moderator]) revert ModeratorExists();
        if (moderators.length >= MAX_MODERATORS) revert TooManyModerators();
        isModerator[moderator] = true;
        moderators.push(moderator);
        emit ModeratorAdded(moderator);
    }

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

    function moderatorCount() public view returns (uint256) {
        return moderators.length;
    }

    function majorityThreshold() public view returns (uint256) {
        uint256 n = moderators.length;
        return n == 0 ? 0 : n / 2 + 1;
    }

    /// @notice Это защита от cross-contract/cross-chain replay, обязательная часть стандарта EIP-712
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

    function createOffer(
        address token,
        uint256 amount,
        uint32 timelock,
        uint64 expiresAt,
        bytes32 contentHash,
        string calldata ipfsCid,
        uint256 quantity
    ) external returns (uint256 offerId) {
        return _createOffer(msg.sender, token, amount, timelock, expiresAt, contentHash, ipfsCid, quantity);
    }

    /// @notice Relayer: продавец подписал офчейн, транзакцию шлёт любой адрес.
    /// @dev `quantity` входит в EIP-712 `OFFER_TYPEHASH`; добавление поля меняет typehash-строку и инвалидирует старые подписи.
    function createOfferWithSig(
        address seller,
        address token,
        uint256 amount,
        uint32 timelock,
        uint64 expiresAt,
        bytes32 contentHash,
        string calldata ipfsCid,
        uint256 quantity,
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
                quantity,
                nonce
            )
        );
        if (_recover(structHash, signature) != seller) revert InvalidSignature();
        return _createOffer(seller, token, amount, timelock, expiresAt, contentHash, ipfsCid, quantity);
    }

    /// @notice Останавливает дальнейшие продажи. Уже созданные Purchase не трогает (снимок seller/token/amount/quantity).
    /// Непроданный остаток сгорает. Частичная отмена (оставить в продаже N штук) — отдельное расширение, не в MVP.
    function cancelOffer(uint256 offerId) external {
        Offer storage offer = offers[offerId];
        if (offer.seller != msg.sender) revert NotSeller();
        if (!offer.active) revert OfferInactive();
        offer.active = false;
        emit OfferCancelled(offerId);
    }

    function _createOffer(
        address seller,
        address token,
        uint256 amount,
        uint32 timelock,
        uint64 expiresAt,
        bytes32 contentHash,
        string calldata ipfsCid,
        uint256 quantity
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
            quantity: quantity,
            sold: 0
        });

        emit OfferCreated(offerId, seller, token, amount, timelock, expiresAt, contentHash, ipfsCid, quantity);
    }

    // -------------------------------------------------------------------------
    // Escrow / Purchase
    // -------------------------------------------------------------------------

    function purchase(uint256 offerId, uint256 quantity) external nonReentrant returns (uint256 purchaseId) {
        if (quantity == 0) revert InvalidQuantity();

        Offer storage offer = offers[offerId];
        if (!offer.active) revert OfferInactive();
        if (offer.expiresAt != 0 && block.timestamp > offer.expiresAt) revert OfferExpired();
        if (offer.quantity != 0 && offer.sold + quantity > offer.quantity) revert InsufficientQuantity();

        offer.sold += quantity;

        uint256 total = offer.amount * quantity;
        uint256 fee = (total * feeBps) / 10_000;
        uint256 sellerPayout = total - fee;
        uint64 autoRefundAt = uint64(block.timestamp + offer.timelock);

        purchaseId = nextPurchaseId++;
        purchases[purchaseId] = Purchase({
            offerId: offerId,
            buyer: msg.sender,
            seller: offer.seller,
            token: offer.token,
            quantity: quantity,
            amount: total,
            fee: fee,
            sellerPayout: sellerPayout,
            autoRefundAt: autoRefundAt,
            verdictDelayUntil: 0,
            state: PurchaseState.Escrowed,
            pendingReceiver: Receiver.None,
            evidenceHash: bytes32(0),
            disputeLock: false
        });

        IERC20(offer.token).safeTransferFrom(msg.sender, address(this), total);
        emit PurchaseCreated(purchaseId, offerId, msg.sender, offer.seller, total, fee, autoRefundAt, quantity);
    }

    function confirmReceipt(uint256 purchaseId) external nonReentrant {
        _confirm(purchaseId, msg.sender);
    }

    function confirmReceiptWithSig(uint256 purchaseId, address buyer, bytes calldata signature) external nonReentrant {
        uint256 nonce = nonces[buyer]++;
        bytes32 structHash = keccak256(abi.encode(CONFIRM_TYPEHASH, purchaseId, nonce));
        if (_recover(structHash, signature) != buyer) revert InvalidSignature();
        _confirm(purchaseId, buyer);
    }

    function _confirm(uint256 purchaseId, address buyer) internal {
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Escrowed) revert BadState();
        if (p.disputeLock) revert DisputeLocked();
        if (p.buyer != buyer) revert NotBuyer();

        emit ReceiptConfirmed(purchaseId, buyer);
        _paySeller(p, purchaseId);
    }

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

    /// @notice Keeper: если покупатель не подтвердил и спора нет — возврат покупателю.
    /// Продавец, чтобы не потерять оплату за доставленный товар, должен успеть openDispute.
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

    /// @notice Голос модератора. По достижении большинства вызывается set_receiver.
    function vote(uint256 purchaseId, bool forSeller) external {
        if (!isModerator[msg.sender]) revert NotModerator();
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Disputed || !p.disputeLock) revert BadState();
        if (hasVoted[purchaseId][msg.sender]) revert AlreadyVoted();

        hasVoted[purchaseId][msg.sender] = true;
        Receiver choice = forSeller ? Receiver.Seller : Receiver.Buyer;
        if (forSeller) votesForSeller[purchaseId] += 1;
        else votesForBuyer[purchaseId] += 1;

        emit DisputeVote(purchaseId, msg.sender, choice);

        uint256 need = majorityThreshold();
        if (votesForSeller[purchaseId] >= need) {
            _setReceiver(purchaseId, p, Receiver.Seller);
        } else if (votesForBuyer[purchaseId] >= need) {
            _setReceiver(purchaseId, p, Receiver.Buyer);
        }
    }

    function _setReceiver(uint256 purchaseId, Purchase storage p, Receiver receiver) internal {
        p.pendingReceiver = receiver;
        p.disputeLock = false;
        p.verdictDelayUntil = uint64(block.timestamp + verdictDelay);
        emit ReceiverSet(purchaseId, receiver, p.verdictDelayUntil);
    }

    /// @notice Выплата после вердикта (и повторного timelock/verdictDelay). Вызывает keeper или любая сторона.
    function executeVerdict(uint256 purchaseId) external nonReentrant {
        Purchase storage p = purchases[purchaseId];
        if (p.state != PurchaseState.Disputed) revert BadState();
        if (p.pendingReceiver == Receiver.None) revert NoPendingReceiver();
        if (block.timestamp < p.verdictDelayUntil) revert VerdictDelayNotReached();

        if (p.pendingReceiver == Receiver.Seller) {
            _paySeller(p, purchaseId);
        } else {
            p.state = PurchaseState.Settled;
            IERC20(p.token).safeTransfer(p.buyer, p.amount);
            emit Settled(purchaseId, p.buyer, p.amount, 0);
        }
    }

    function _paySeller(Purchase storage p, uint256 purchaseId) internal {
        p.state = PurchaseState.Settled;
        IERC20 token = IERC20(p.token);
        if (p.fee > 0) token.safeTransfer(feeRecipient, p.fee);
        token.safeTransfer(p.seller, p.sellerPayout);
        emit Settled(purchaseId, p.seller, p.sellerPayout, p.fee);
    }

    function _recover(bytes32 structHash, bytes calldata signature) internal view returns (address) {
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        return ECDSA.recover(digest, signature);
    }
}
