// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {SafeERC20} from "./libraries/SafeERC20.sol";

/// @title CuratorStakeRegistry
/// @notice Permissionless anti-sybil барьер для регистрации на стороне фронтенда: вместо
///         (или вместе с) подтверждением почты пользователь может внести возвращаемый
///         стейк "в пользу" конкретного куратора (интерфейса). Один пользователь может
///         одновременно держать независимые стейки у нескольких кураторов — namespace
///         изолирован тем же способом, что и в CuratorBanRegistry: curator = msg.sender
///         при настройке, поэтому кураторы физически не могут трогать чужой namespace.
///
/// @dev НЕ связан с Marketplace.sol и его спорами. Обман в конкретной сделке — это эскроу-
///      логика Marketplace (там деньги просто возвращаются пострадавшей стороне), а не повод
///      трогать этот стейк. Slash здесь — наказание за нарушение ПРАВИЛ ФРОНТЕНДА (спам,
///      мультиаккаунты, обход бана и т.д.), решение о котором принимает сам куратор.
///
///      Модераторов/голосования внутри контракта нет: curator либо решает сам, либо
///      делегирует право вызывать slash/setBan мультисигу (Safe) или отдельному контракту
///      со своей логикой модерации (голосование, DAO, что угодно) — с точки зрения этого
///      реестра это просто ещё один адрес-делегат.
contract CuratorStakeRegistry {
    using SafeERC20 for IERC20;

    struct Stake {
        address token;
        uint256 amount;
        uint64 unlockAt; // 0, если вывод не запрошен
    }

    /// curator => user => стейк пользователя в пользу этого куратора
    mapping(address => mapping(address => Stake)) public stakes;

    /// curator => token => принимается ли токен этим куратором
    mapping(address => mapping(address => bool)) public acceptedToken;
    /// curator => token => минимальный стейк для eligibility в этом токене
    mapping(address => mapping(address => uint256)) public minStake;
    /// curator => кулдаун между requestUnstake и withdraw (свой у каждого фронтенда)
    mapping(address => uint32) public unstakeCooldown;

    /// curator => delegate => право вызывать slash/паузу-независимые админ-действия от имени curator
    mapping(address => mapping(address => bool)) public isDelegate;
    /// curator => guardian => право мгновенно приостановить slash для этого curator
    mapping(address => mapping(address => bool)) public isGuardian;
    /// curator => приостановлен ли slash (guardian'ом, при подозрении на компрометацию ключа)
    mapping(address => bool) public paused;

    event TokenConfigUpdated(address indexed curator, address indexed token, bool accepted, uint256 minStake);
    event UnstakeCooldownUpdated(address indexed curator, uint32 cooldown);
    event DelegateUpdated(address indexed curator, address indexed delegate, bool active);
    event GuardianUpdated(address indexed curator, address indexed guardian, bool active);
    event PausedByGuardian(address indexed curator, address indexed guardian);
    event UnpausedByCurator(address indexed curator);

    event Staked(address indexed curator, address indexed user, address token, uint256 amount, uint256 totalStake);
    event UnstakeRequested(address indexed curator, address indexed user, uint64 unlockAt);
    event Withdrawn(address indexed curator, address indexed user, uint256 amount);
    event Slashed(address indexed curator, address indexed user, address indexed actor, uint256 amount, address to);

    error TokenNotAccepted();
    error BelowMinStake();
    error NoStake();
    error TokenMismatch();
    error UnstakeAlreadyRequested();
    error UnstakeNotRequested();
    error CooldownNotReached();
    error NotAuthorized();
    error CuratorPaused();
    error InvalidSlashAmount();
    error ZeroAddress();

    // -------------------------------------------------------------------------
    // Настройка namespace куратора (msg.sender = curator, как в CuratorBanRegistry)
    // -------------------------------------------------------------------------

    /// @notice Настроить, принимает ли curator конкретный token для стейка в своём namespace,
    ///         и какой минимальный размер стейка в нём считается достаточным для eligibility.
    /// @dev msg.sender неявно и есть curator — отдельного параметра curator нет намеренно,
    ///      чтобы исключить возможность настроить чужой namespace. Повторный вызов с новым
    ///      minStakeAmount не проверяет и не трогает уже существующие стейки пользователей —
    ///      их isEligible() пересчитается сам по новому порогу при следующем чтении.
    /// @param token Адрес ERC-20 токена, для которого меняется конфигурация (например USDT/USDC).
    /// @param accepted true — токен принимается этим curator для стейка, false — стейк в этом
    ///        токене больше недоступен новым вызовам stake() (существующие стейки не трогает).
    /// @param minStakeAmount Минимальная сумма в этом токене, при которой stakes[msg.sender][user]
    ///        считается достаточной для isEligible() (в единицах токена, с учётом его decimals).
    function setTokenConfig(address token, bool accepted, uint256 minStakeAmount) external {
        if (token == address(0)) revert ZeroAddress();
        acceptedToken[msg.sender][token] = accepted;
        minStake[msg.sender][token] = minStakeAmount;
        emit TokenConfigUpdated(msg.sender, token, accepted, minStakeAmount);
    }

    /// @notice Установить длительность кулдауна между requestUnstake() и withdraw() для
    ///         пользователей, застейкавших в пользу msg.sender (curator).
    /// @dev Кулдаун — это окно времени, в течение которого curator/делегат ещё может успеть
    ///      вызвать slash() до того, как пользователь заберёт стейк обратно. 0 означает
    ///      мгновенный вывод без задержки (эквивалент отсутствия анти-sybil защиты от
    ///      быстрого выхода после нарушения).
    /// @param cooldown Длительность кулдауна в секундах.
    function setUnstakeCooldown(uint32 cooldown) external {
        unstakeCooldown[msg.sender] = cooldown;
        emit UnstakeCooldownUpdated(msg.sender, cooldown);
    }

    /// @notice Назначить или отозвать делегата, который может вызывать slash() от имени
    ///         msg.sender (curator) — например адрес multisig-кошелька (Safe) или отдельного
    ///         контракта с собственной логикой модерации фронтенда.
    /// @dev Без задержки на активацию — по той же причине, что и в CuratorBanRegistry:
    ///      задержка не защищает от компрометации ключа curator, т.к. slash() этим же
    ///      ключом проходит напрямую, минуя делегирование. Реальная защита — guardian-пауза
    ///      ниже и/или curator = мультисиг.
    /// @param delegate Адрес, которому выдаётся или у которого отзывается право вызывать slash()
    ///        от имени msg.sender.
    /// @param active true — делегату разрешено вызывать slash() от имени curator,
    ///        false — право отозвано.
    function setDelegate(address delegate, bool active) external {
        if (delegate == address(0)) revert ZeroAddress();
        isDelegate[msg.sender][delegate] = active;
        emit DelegateUpdated(msg.sender, delegate, active);
    }

    /// @notice Назначить или отозвать guardian-адрес, независимый от ключа curator, способный
    ///         мгновенно приостановить slash() для msg.sender при подозрении на компрометацию
    ///         ключа curator.
    /// @dev Guardian не может ни стейкать/слэшить от имени curator, ни снимать собственную
    ///      паузу — только ставить её (см. pause()/unpause()).
    /// @param guardian Адрес, назначаемый или снимаемый с роли guardian для msg.sender.
    /// @param active true — guardian получает право вызывать pause(msg.sender),
    ///        false — право отозвано.
    function setGuardian(address guardian, bool active) external {
        if (guardian == address(0)) revert ZeroAddress();
        isGuardian[msg.sender][guardian] = active;
        emit GuardianUpdated(msg.sender, guardian, active);
    }

    /// @notice Guardian мгновенно замораживает slash() для указанного curator — аварийная
    ///         мера при подозрении, что ключ curator скомпрометирован и им могут начать
    ///         массово изымать чужие стейки.
    /// @dev Снять паузу может только сам curator через unpause(), а не guardian — иначе
    ///      скомпрометированный guardian сам стал бы вектором атаки (мог бы вечно держать
    ///      slash() заблокированным для атакованного curator).
    /// @param curator Адрес namespace'а, для которого guardian (msg.sender) ставит паузу.
    function pause(address curator) external {
        if (!isGuardian[curator][msg.sender]) revert NotAuthorized();
        paused[curator] = true;
        emit PausedByGuardian(curator, msg.sender);
    }

    /// @notice Снять паузу со slash() в собственном namespace.
    /// @dev msg.sender неявно и есть curator, чью паузу снимают — вызвать unpause() за
    ///      другого curator невозможно, только за самого себя.
    function unpause() external {
        paused[msg.sender] = false;
        emit UnpausedByCurator(msg.sender);
    }

    // -------------------------------------------------------------------------
    // Стейк пользователя (буквально любой адрес — продавец, покупатель, неважно)
    // -------------------------------------------------------------------------

    /// @notice Внести (или дополнить) стейк в пользу конкретного curator. Один и тот же
    ///         msg.sender может независимо застейкать у нескольких curator одновременно —
    ///         это просто разные записи в stakes[curator][msg.sender], без ограничений
    ///         сверху в этом контракте.
    /// @dev При первом стейке (stakes[curator][msg.sender].amount == 0) сумма должна сразу
    ///      покрывать minStake[curator][token] и фиксирует token для этой пары curator/user.
    ///      При довнесении token должен совпадать с уже зафиксированным, а вывод не должен
    ///      быть запрошен (unlockAt == 0) — иначе непонятно, должен ли довнесённый остаток
    ///      тоже попадать под уже запущенный кулдаун.
    /// @param curator Namespace, в пользу которого делается стейк (адрес фронтенда/куратора).
    /// @param token Адрес ERC-20 токена стейка; должен быть принят этим curator
    ///        (acceptedToken[curator][token] == true).
    /// @param amount Сумма пополнения стейка в единицах token.
    function stake(address curator, address token, uint256 amount) external {
        if (!acceptedToken[curator][token]) revert TokenNotAccepted();

        Stake storage s = stakes[curator][msg.sender];
        if (s.amount == 0) {
            if (amount < minStake[curator][token]) revert BelowMinStake();
            s.token = token;
        } else {
            if (s.token != token) revert TokenMismatch();
            if (s.unlockAt != 0) revert UnstakeAlreadyRequested(); // нельзя доливать во время вывода
        }

        s.amount += amount;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit Staked(curator, msg.sender, token, amount, s.amount);
    }

    /// @notice Запросить вывод стейка у конкретного curator — запускает кулдаун, по
    ///         истечении которого можно будет вызвать withdraw().
    /// @dev Пока идёт кулдаун, у curator (или его делегата/multisig'а) есть время заметить
    ///      нарушение правил фронтенда и вызвать slash() до фактического вывода средств.
    ///      На время кулдауна eligibility (isEligible()) не меняется — пользователь всё ещё
    ///      считается зарегистрированным вплоть до withdraw().
    /// @param curator Namespace, из которого запрашивается вывод стейка msg.sender.
    function requestUnstake(address curator) external {
        Stake storage s = stakes[curator][msg.sender];
        if (s.amount == 0) revert NoStake();
        if (s.unlockAt != 0) revert UnstakeAlreadyRequested();

        s.unlockAt = uint64(block.timestamp + unstakeCooldown[curator]);
        emit UnstakeRequested(curator, msg.sender, s.unlockAt);
    }

    /// @notice Забрать стейк из namespace curator после истечения кулдауна.
    /// @dev Удаляет запись stakes[curator][msg.sender] целиком (token, amount, unlockAt),
    ///      так что следующий stake() для этой пары curator/user начнётся "с нуля" и сможет
    ///      зафиксировать любой принимаемый token заново.
    /// @param curator Namespace, из которого выводится стейк msg.sender.
    function withdraw(address curator) external {
        Stake storage s = stakes[curator][msg.sender];
        if (s.amount == 0) revert NoStake();
        if (s.unlockAt == 0) revert UnstakeNotRequested();
        if (block.timestamp < s.unlockAt) revert CooldownNotReached();

        uint256 amount = s.amount;
        address token = s.token;
        delete stakes[curator][msg.sender];

        IERC20(token).safeTransfer(msg.sender, amount);
        emit Withdrawn(curator, msg.sender, amount);
    }

    /// @notice Проверить, считается ли user зарегистрированным через стейк в namespace curator.
    /// @dev То, что читает бэкенд/индексатор фронтенда вместо (или вместе с) флагом
    ///      emailVerified при решении, допускать ли пользователя к действиям в каталоге.
    ///      Возвращает false в том числе если curator уже отозвал acceptedToken для того
    ///      token, в котором исторически застейкан user (порог/токен могли измениться позже).
    /// @param curator Namespace, в котором проверяется eligibility user.
    /// @param user Адрес, чья eligibility проверяется.
    /// @return eligible true, если текущий стейк user у curator удовлетворяет действующим
    ///         acceptedToken/minStake для того token, в котором сделан этот стейк.
    function isEligible(address curator, address user) external view returns (bool eligible) {
        Stake storage s = stakes[curator][user];
        return acceptedToken[curator][s.token] && s.amount >= minStake[curator][s.token];
    }

    // -------------------------------------------------------------------------
    // Slash — наказание за нарушение правил фронтенда, решает сам curator/делегат.
    // Никакого голосования: если фронтенду нужен коллегиальный вердикт — curator
    // указывает delegate = адрес multisig'а (Safe) или отдельного контракта модерации.
    // -------------------------------------------------------------------------

    /// @notice Изъять часть (или весь) стейк user из namespace curator за нарушение правил
    ///         пользования фронтендом. Не имеет отношения к спорам по конкретным сделкам
    ///         в Marketplace.sol — это отдельное основание, целиком на усмотрение curator.
    /// @dev Вызывать может либо сам curator, либо адрес из isDelegate[curator] (см.
    ///      setDelegate) — например multisig или контракт с собственным голосованием.
    ///      Если после изъятия остаток стейка равен нулю, запись stakes[curator][user]
    ///      удаляется целиком (аналогично withdraw()), чтобы следующий stake() начинался
    ///      "с нуля". Защищено guardian-паузой (см. pause()) на случай компрометации ключа
    ///      curator.
    /// @param curator Namespace, из которого изымается стейк user.
    /// @param user Адрес, чей стейк частично или полностью изымается.
    /// @param amount Сумма изъятия в единицах token, которым застейкан user; не может быть
    ///        нулевой и не может превышать текущий stakes[curator][user].amount.
    /// @param to Адрес получателя изъятых средств — определяет curator (казна фронтенда,
    ///        пострадавший пользователь и т.д.); контракт этого не ограничивает.
    function slash(address curator, address user, uint256 amount, address to) external {
        if (paused[curator]) revert CuratorPaused();
        if (msg.sender != curator && !isDelegate[curator][msg.sender]) revert NotAuthorized();
        if (to == address(0)) revert ZeroAddress();

        Stake storage s = stakes[curator][user];
        if (s.amount == 0) revert NoStake();
        if (amount == 0 || amount > s.amount) revert InvalidSlashAmount();

        address token = s.token;
        s.amount -= amount;
        if (s.amount == 0) delete stakes[curator][user]; // остаток пуст — освобождаем запись

        IERC20(token).safeTransfer(to, amount);
        emit Slashed(curator, user, msg.sender, amount, to);
    }
}
