// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title CuratorBanRegistry
/// @notice Публичный, но пространственно изолированный реестр банов.
///         Бан НЕ влияет на логику Marketplace — это чисто информационный
///         сигнал: каждый куратор (интерфейс) решает сам, что скрывать у себя.
/// @dev Изоляция достигается тем, что curator одновременно является ключом
///      namespace — один куратор физически не может писать в раздел другого.
///
///      Задержка на делегирование НЕ используется: она не защищает от
///      компрометации ключа куратора, потому что setBan вызывается тем же
///      ключом напрямую и мгновенно, минуя делегирование. Реальная защита —
///      либо curator = мультисиг (Safe), либо guardian-пауза ниже, либо
///      анализ аномалий на бэкенде (эвристика вне контракта).
///
///      Причина бана (`reason`) хранится ТОЛЬКО в event, не в storage:
///      она не нужна ни одной ончейн-функции (isBanned читает лишь
///      bannedUntil), поэтому это чистые calldata-затраты (~16 gas/байт
///      ненулевой, ~4 gas/байт нулевой) вместо дорогого SSTORE. Индексатор
///      бэкенда обязан слушать BanStatusChanged и класть reason в свою
///      таблицу — это уже предусмотрено роадмапом (зеркальные SQL-таблицы).
///
///      Формат reason не валидируется контрактом: это может быть свободный
///      текст, ссылка на централизованный хостинг доказательств (скриншоты,
///      переписка) или IPFS CID — выбор куратора. Отсутствие enum/типизации
///      — осознанный компромисс: другие кураторы не смогут программно
///      фильтровать баны по категории нарушения без парсинга строки или
///      договорной конвенции (например "fraud: <ссылка>").
contract CuratorBanRegistry {
    uint64 public constant BAN_PERMANENT = type(uint64).max; // sentinel = "забанен навсегда"

    /// @notice Мягкий лимит на длину reason, чтобы куратор не раздувал
    /// calldata произвольно и не переполнял бэкенд-таблицы индексатора.
    /// Это лимит протокола, а не рекомендация — при превышении revert.
    uint256 public constant MAX_REASON_LENGTH = 512;

    /// curator => user => момент времени, до которого действует бан.
    /// 0 — не забанен, BAN_PERMANENT — навсегда, иначе — таймстамп истечения.
    mapping(address => mapping(address => uint64)) public bannedUntil;

    /// curator => delegate => право банить от имени curator (мгновенное, без задержки)
    mapping(address => mapping(address => bool)) public isDelegate;

    /// curator => guardian => право мгновенно приостановить setBan для этого curator
    mapping(address => mapping(address => bool)) public isGuardian;

    /// curator => приостановлен ли setBan (guardian'ом, из-за подозрения на компрометацию)
    mapping(address => bool) public paused;

    /// @param reason Свободный текст: ссылка на доказательства (централизованный
    /// хостинг, IPFS CID) либо описание причины. Не хранится в storage — см. @dev.
    event BanStatusChanged(
        address indexed curator,
        address indexed user,
        address indexed actor,
        uint64 bannedUntil,
        string reason
    );
    event DelegateUpdated(address indexed curator, address indexed delegate, bool active);
    event GuardianUpdated(address indexed curator, address indexed guardian, bool active);
    event PausedByGuardian(address indexed curator, address indexed guardian);
    event UnpausedByCurator(address indexed curator);

    error NotAuthorized();
    error CuratorPaused();
    error ZeroAddress();
    error ReasonTooLong();

    // -----------------------------------------------------------------
    // Баны
    // -----------------------------------------------------------------

    /// @param bannedUntil_ 0 — снять бан, BAN_PERMANENT — навсегда, иначе — unix-время истечения.
    /// @param reason Причина/доказательство бана (ссылка, CID или текст). Может быть пустой строкой.
    /// @dev Повторный вызов с тем же bannedUntil_, но новым reason — штатный способ
    ///      обновить/дополнить доказательства без изменения статуса бана: отдельная
    ///      функция для этого не нужна, setBan уже безусловно перезаписывает mapping.
    function setBan(address curator, address user, uint64 bannedUntil_, string calldata reason) external {
        if (paused[curator]) revert CuratorPaused();
        if (msg.sender != curator && !isDelegate[curator][msg.sender]) revert NotAuthorized();
        if (bytes(reason).length > MAX_REASON_LENGTH) revert ReasonTooLong();
        bannedUntil[curator][user] = bannedUntil_;
        emit BanStatusChanged(curator, user, msg.sender, bannedUntil_, reason);
    }

    function isBanned(address curator, address user) external view returns (bool) {
        uint64 until = bannedUntil[curator][user];
        return until == BAN_PERMANENT || until > block.timestamp;
    }

    // -----------------------------------------------------------------
    // Делегирование — мгновенное, без задержки (см. @dev выше почему)
    // -----------------------------------------------------------------

    function setDelegate(address delegate, bool active) external {
        if (delegate == address(0)) revert ZeroAddress();
        isDelegate[msg.sender][delegate] = active;
        emit DelegateUpdated(msg.sender, delegate, active);
    }

    // -----------------------------------------------------------------
    // Guardian — независимый от curator ключ, может только ПРИОСТАНОВИТЬ setBan.
    // Реальная защита от кражи ключа куратора: у атакующего нет guardian-ключа,
    // поэтому команда/доверенное лицо может мгновенно заморозить массовый бан-спам,
    // пока куратор не мигрирует на новый адрес.
    // -----------------------------------------------------------------

    function setGuardian(address guardian, bool active) external {
        if (guardian == address(0)) revert ZeroAddress();
        isGuardian[msg.sender][guardian] = active;
        emit GuardianUpdated(msg.sender, guardian, active);
    }

    /// @notice Guardian мгновенно замораживает setBan для curator. Снять паузу
    ///         может только сам curator (не guardian) — иначе скомпрометированный
    ///         guardian-ключ сам стал бы вектором атаки на доступность бана.
    function pause(address curator) external {
        if (!isGuardian[curator][msg.sender]) revert NotAuthorized();
        paused[curator] = true;
        emit PausedByGuardian(curator, msg.sender);
    }

    function unpause() external {
        paused[msg.sender] = false;
        emit UnpausedByCurator(msg.sender);
    }
}
