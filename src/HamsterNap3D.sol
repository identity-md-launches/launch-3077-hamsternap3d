// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "./base/BaseHook.sol";
import {ISqueekCore} from "./interfaces/ISqueekCore.sol";
import {ISworn} from "./interfaces/ISworn.sol";

/// @title Hamster Nap 3D: a last-buyer-before-bedtime game on SqueekChain's hamster
/// @notice One Uniswap v4 hook on the NAP / ETH pool. Every buy of NAP pays 2% of its ETH into a pot
/// the hook holds and, if it spends at least 0.001 ETH, makes the buyer's wallet the latest buyer.
/// When SqueekCore certifies a nap (three consecutive settled rounds with zero work), the last
/// qualifying buyer whose buy happened before the nap's first round started takes the pot collected
/// up to that round. Sells pay no game fee and never read the core. The launch owner may replace
/// the core until permanently finalized, but cannot pause, upgrade, change fees or withdraw the pot.
/// @dev The pot is the hook's own ETH (plus ERC-6909 ETH claims on the PoolManager when the manager
/// could not pay the fee out in ETH at swap time, redeemed before any payout). `pot()` is the
/// authoritative figure: fees in minus payouts, and the hook's ETH plus claims always cover it plus
/// what deferred winners are owed.
contract HamsterNap3D is BaseHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;
    using SafeCast for int256;

    // ---------------------------------------------------------------- game constants

    /// @notice Consecutive settled zero-work rounds that make a nap (30 minutes at initial timing).
    uint64 public constant NAP_ROUNDS = 3;
    /// @notice The most records one `roundPage` call returns, so the most rounds scanned per page.
    uint64 public constant PAGE_ROUNDS = 16;
    /// @notice Maximum gas forwarded to each core read. An exhausted read is treated as unreadable,
    /// so an upgraded or broken core cannot consume all gas needed for migration or the failsafe.
    uint256 public constant CORE_READ_GAS = 5_000_000;
    /// @dev EIP-150 headroom plus call/encoding overhead so an old-core probe receives its full
    /// budget. Otherwise an owner could starve a readable probe to bypass pending-nap settlement.
    uint256 private constant MIN_CORE_READ_GAS = CORE_READ_GAS + CORE_READ_GAS / 63 + 10_000;
    /// @dev ABI size of a RoundPage with the maximum 16 five-word checkpoints.
    uint256 private constant MAX_PAGE_BYTES = 320 + uint256(PAGE_ROUNDS) * 160;
    /// @notice Buy fee in basis points of the ETH a buy spends: 2%.
    uint256 public constant FEE_BPS = 200;
    uint256 public constant BPS = 10_000;
    /// @notice The smallest buy (ETH spent, fee included) that makes the buyer the latest buyer.
    uint256 public constant MIN_QUALIFYING_BUY = 0.001 ether;
    /// @notice How long the core's frontier may stand still before the failsafe opens.
    uint256 public constant FAILSAFE_DELAY = 7 days;
    /// @notice Pages of settled rounds the failsafe itself scans before paying, so every nap the core
    /// certified before it stalled is paid to its own winner first. A longer backlog is worked through
    /// with `settleNaps` before the failsafe can pay.
    uint256 public constant FAILSAFE_SCAN_PAGES = 8;
    /// @notice Gas a payout gives the winner's wallet. A wallet that needs more, or fails, is credited
    /// in `owed` and pulls with `withdrawOwed`, which forwards all gas.
    uint256 public constant PAYOUT_GAS = 100_000;
    /// @notice The Sworn card registry on Ethereum mainnet, read live during the first game there.
    ISworn public constant SWORN = ISworn(0x0da2679000Ea5380d1361cc3Cca7D4e8c881F766);
    /// @notice The only chain on which the Sworn card check runs.
    uint256 public constant SWORN_CHAIN_ID = 1;

    // ---------------------------------------------------------------- launch wiring

    /// @notice The launch factory: the only sender allowed to open this hook's pool.
    address public immutable factory;

    /// @notice The launch's owner; only core replacement and permanent finalization are authorized.
    /// There is no ownership transfer or renunciation function.
    address public immutable owner;
    /// @notice The SqueekCore proxy followed by the game. Initial values were measured on Sepolia
    /// on 2026-11-06 and are literals, so construction never reads another contract.
    ISqueekCore public core = ISqueekCore(0xFD6C166D4B8E2962E65746a13e5a0797CD4dE0c4);
    /// @notice The active core's genesis: round 1 starts here. Updated only by setCore.
    uint64 public GENESIS_TIMESTAMP = 1793735400;
    /// @notice The active core's round length in seconds. Updated only by setCore.
    uint64 public ROUND_DURATION = 600;
    /// @notice Once true, the core address and cached timing can never be changed by this hook.
    bool public coreFinalized;

    /// @notice The pool this hook serves, bound in `beforeInitialize`.
    PoolId public poolId;
    /// @notice The launch token, read from the PoolKey when the pool is opened.
    Currency public token;
    bool public poolBound;

    // ---------------------------------------------------------------- game state

    /// @dev The state right after a buy, appended per buy in time order. Binary-searched at claim
    /// time for the last buy before a nap's first round, and at failsafe time for the last buy before
    /// the failsafe's cutoff.
    struct BuyRecord {
        uint64 round;
        uint64 time;
        uint128 cumulativeFees;
        address latestBuyer;
    }

    BuyRecord[] private _buys;

    /// @notice The last qualifying buyer so far (the wallet whose buy spent at least 0.001 ETH).
    address public latestBuyer;
    /// @notice All fees ever collected, in wei.
    uint256 public cumulativeFees;
    /// @notice All fees ever paid out (or credited to a winner that could not receive ETH), in wei.
    uint256 public cumulativePaid;
    /// @notice ETH a wallet may pull with `withdrawOwed`: a winner's payout whose transfer failed, or
    /// the part of an exact-input buy's fee reservation a partial fill did not use.
    mapping(address wallet => uint256 amount) public owed;
    /// @notice The sum of `owed`.
    uint256 public totalOwed;
    /// @notice ERC-6909 ETH claims on the PoolManager the hook holds instead of ETH.
    uint256 public claimsHeld;

    /// @notice The next round examined; 0 until the first swap or a core switch starts the scan.
    uint64 public scanRound;
    /// @notice Consecutive zero-work rounds seen ending at `scanRound - 1`.
    uint64 public zeroRun;
    /// @notice The first round of the current zero-work run.
    uint64 public zeroRunStart;
    /// @notice The highest frontier observed on the active core (rebased on each core switch).
    uint64 public lastSeenFrontier;
    /// @notice When the hook last saw `settledThroughRound` advance; the game's start until it does.
    /// The failsafe's seven days count from here (or from the frontier round's end, if later).
    uint256 public frontierSeenAt;
    /// @notice Naps settled (paid or found without a winner) so far.
    uint256 public napsSettled;
    /// @notice True once the first nap is settled: the end of the first game.
    bool public firstNapSettled;

    bool private _locked;

    // ---------------------------------------------------------------- events

    event PoolBound(PoolId indexed poolId, Currency token);
    event GameStarted(uint64 round);
    event Buy(address indexed buyer, uint256 ethSpent, uint256 fee, uint64 round, bool qualifying);
    event NapSettled(uint64 indexed napStart, address indexed winner, uint256 amount);
    event FailsafeTaken(address indexed winner, uint256 amount, uint64 frontier);
    event PayoutDeferred(address indexed winner, uint256 amount);
    event FeeRefunded(address indexed buyer, uint256 amount);
    event OwedWithdrawn(address indexed winner, uint256 amount);
    event ClaimsRedeemed(uint256 amount);
    event FrontierSeen(uint64 frontier);
    event CoreChanged(address indexed oldCore, address indexed newCore);
    event CoreFinalized(address indexed core);

    // ---------------------------------------------------------------- errors

    error NotFactory();
    error AlreadyBound();
    error PairMustBeNativeEth();
    error UnknownPool();
    error NotSworn(address buyer);
    error GameNotStarted();
    error CoreNotStale(uint256 staleAt);
    error NoQualifyingBuyer();
    error NothingToPay();
    error NothingOwed();
    error TransferFailed();
    error NotFromPoolManager();
    error Reentrancy();
    error ZeroPages();
    error CoreUnreadable();
    error NapsUnsettled(uint64 scanRound, uint64 frontier);
    error NotOwner();
    error InvalidOwner();
    error CoreIsFinalized();
    error InvalidRoundDuration();
    error InvalidCoreFrontier();
    error InsufficientCoreReadGas();

    constructor(IPoolManager poolManager_, address factory_, address owner_) BaseHook(poolManager_) {
        if (owner_ == address(0)) revert InvalidOwner();
        factory = factory_;
        owner = owner_;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (_locked) revert Reentrancy();
        _locked = true;
        _;
        _locked = false;
    }

    /// @dev ETH arrives only from the PoolManager (fee takes and claim redemptions).
    receive() external payable {
        if (msg.sender != address(poolManager)) revert NotFromPoolManager();
    }

    // ---------------------------------------------------------------- core administration

    /// @notice Replaces the core and its timing, until finalizeCore permanently disables this.
    /// Readable old-core rounds must first be scanned with settleNaps. If state or the next pending
    /// page cannot be read, the unscanned old rounds are dropped. No money or buy history is reset.
    /// @dev Every external dependency read is static. The payout lock also prevents an owner who
    /// wins a nap from switching timelines during an in-progress settlement.
    function setCore(ISqueekCore newCore) external onlyOwner nonReentrant {
        if (coreFinalized) revert CoreIsFinalized();
        _requireOldCoreCaughtUp();
        (uint64 genesis, uint64 duration) = _readConfiguration(newCore);
        (bool ok, uint64 frontier) = _readFrontierFrom(newCore);
        if (!ok) revert CoreUnreadable();
        // scanRound must represent the first round after the new frontier.
        if (frontier == type(uint64).max) revert InvalidCoreFrontier();

        address oldCore = address(core);
        core = newCore;
        GENESIS_TIMESTAMP = genesis;
        ROUND_DURATION = duration;
        scanRound = frontier + 1;
        zeroRun = 0;
        zeroRunStart = 0;
        lastSeenFrontier = frontier;
        frontierSeenAt = block.timestamp;
        emit CoreChanged(oldCore, address(newCore));
    }

    /// @notice Permanently fixes the selected core and its cached timing. This does not freeze
    /// upgrades or reporting by SqueekChain's own proxy/operator.
    function finalizeCore() external onlyOwner nonReentrant {
        if (coreFinalized) revert CoreIsFinalized();
        coreFinalized = true;
        emit CoreFinalized(address(core));
    }

    // ---------------------------------------------------------------- hook permissions

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------- callbacks

    /// @notice Only the launch factory opens the pool, once, and only paired with native ETH.
    function beforeInitialize(address sender, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (sender != factory) revert NotFactory();
        if (poolBound) revert AlreadyBound();
        if (!key.currency0.isAddressZero()) revert PairMustBeNativeEth();
        poolBound = true;
        poolId = key.toId();
        token = key.currency1;
        emit PoolBound(poolId, key.currency1);
        return this.beforeInitialize.selector;
    }

    /// @notice On a buy, runs the mainnet-only Sworn check and, for an exact-input buy, carves the
    /// 2% fee out of the ETH input. Sells pass through untouched.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert UnknownPool();
        // ETH is currency0 (address zero sorts first), so a buy of the token is zeroForOne.
        if (!params.zeroForOne) return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        _checkSworn();

        if (params.amountSpecified < 0) {
            // Exact input: the specified currency is ETH. The hook reserves 2% of it here so the pool
            // swaps the remaining 98%; afterSwap collects the ETH and, if the pool filled only part of
            // the input, keeps 2% of what was really spent and refunds the rest of the reservation.
            uint256 fee = _feeOnGross(uint256(-params.amountSpecified));
            return (this.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Collects the fee in ETH, records the buy and the latest buyer. Starts the game on the
    /// pool's first swap of either direction. The fee and the 0.001 ETH threshold are measured on the
    /// ETH the buy really spent (the pool's fill plus the fee), never on an input the pool did not use.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        if (PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert UnknownPool();
        _startGameIfNeeded();
        if (!params.zeroForOne) return (this.afterSwap.selector, 0);

        address buyer = tx.origin;
        // `delta` is the pool's own delta, before the hook's share is added: the ETH it consumed.
        uint256 poolEth = uint256(uint128(-delta.amount0()));
        uint256 fee;
        uint256 gross;
        int128 hookDeltaUnspecified;
        if (params.amountSpecified < 0) {
            // Exact input: beforeSwap reserved 2% of the specified input and the manager credits the
            // hook that much whatever the pool filled. A price limit or exhausted liquidity can leave
            // part of the input unused; then the fee is 2% of what was really spent and the unused
            // part of the reservation goes back to the buyer through `owed`.
            uint256 specified = uint256(-params.amountSpecified);
            uint256 reserved = _feeOnGross(specified);
            if (poolEth + reserved >= specified) {
                fee = reserved;
                gross = specified;
            } else {
                fee = _feeOnPoolEth(poolEth);
                if (fee > reserved) fee = reserved;
                gross = poolEth + fee;
                _refund(buyer, reserved - fee);
            }
            if (reserved > 0) _collectFee(reserved);
        } else {
            // Exact output: the pool's ETH input is the unspecified side; the hook adds the fee to it.
            fee = _feeOnPoolEth(poolEth);
            gross = poolEth + fee;
            hookDeltaUnspecified = fee.toInt128();
            if (fee > 0) _collectFee(fee);
        }
        cumulativeFees += fee;

        bool qualifying = gross >= MIN_QUALIFYING_BUY;
        if (qualifying) latestBuyer = buyer;
        uint64 round = currentRound();
        if (fee > 0 || qualifying) {
            _buys.push(
                BuyRecord({
                    round: round,
                    time: uint64(block.timestamp),
                    cumulativeFees: cumulativeFees.toUint128(),
                    latestBuyer: latestBuyer
                })
            );
        }
        emit Buy(buyer, gross, fee, round, qualifying);
        _observeFrontier();
        return (this.afterSwap.selector, hookDeltaUnspecified);
    }

    // ---------------------------------------------------------------- claims

    /// @notice Scans up to `maxPages` pages of settled rounds (16 rounds each) past the last scanned
    /// round and pays every nap found, in order. Anyone may call it; progress is kept between calls.
    /// Reverts when the core cannot be read.
    /// @return settled The number of naps settled in this call.
    function settleNaps(uint256 maxPages) external nonReentrant returns (uint256 settled) {
        if (maxPages == 0) revert ZeroPages();
        if (scanRound == 0) revert GameNotStarted();
        (bool ok, uint64 frontier) = _readFrontier();
        if (!ok) revert CoreUnreadable();
        _noteFrontier(frontier);
        bool readable;
        (settled, readable) = _scan(frontier, maxPages);
        if (!readable) revert CoreUnreadable();
    }

    /// @notice If the core's settled frontier has stood still for 7 days, the pot goes to the last
    /// qualifying buyer whose buy happened before the failsafe's cutoff (`failsafeCutoff()`: the
    /// later of the failsafe's opening and seven days ago). Anyone may trigger it; only that buyer
    /// is paid, and only the fees collected through the last buy before the cutoff: later fees stay
    /// in the pot and become payable, to the buyer who was last when they were paid, once they are
    /// themselves seven days old with the core still stale. So a buy placed in front of the
    /// failsafe call never takes the pot, and with a core that never returns every fee still reaches
    /// a buyer. Works when the core reverts, from the last frontier the hook saw. The 7 days count
    /// from the last time the hook saw the frontier advance (this call reads the core first, so an
    /// advance it finds now restarts them), or from the frontier round's end if that is later. Every
    /// nap the core certified before it stalled is settled first, to its own winner, so the failsafe
    /// pays only what those naps leave; when more than `FAILSAFE_SCAN_PAGES` pages are still
    /// unscanned it reverts with `NapsUnsettled` and `settleNaps` must catch up first. When the core
    /// cannot be read at all, nothing can be certified and the fees through the cutoff all go to the
    /// failsafe's winner.
    function failsafe() external nonReentrant {
        if (scanRound == 0) revert GameNotStarted();
        (bool ok, uint64 frontier) = _readFrontier();
        if (ok) _noteFrontier(frontier);
        frontier = lastSeenFrontier;
        uint256 staleAt = failsafeOpensAt();
        if (block.timestamp < staleAt) revert CoreNotStale(staleAt);
        if (scanRound <= frontier) {
            (, bool readable) = _scan(frontier, FAILSAFE_SCAN_PAGES);
            if (readable && scanRound <= frontier) revert NapsUnsettled(scanRound, frontier);
        }
        (address winner, uint256 cumulative) = _stateBefore(_failsafeCutoff(staleAt));
        if (winner == address(0)) revert NoQualifyingBuyer();
        if (cumulative <= cumulativePaid) revert NothingToPay();
        uint256 amount = cumulative - cumulativePaid;
        cumulativePaid = cumulative;
        emit FailsafeTaken(winner, amount, frontier);
        _pay(winner, amount);
    }

    /// @notice Decodes a raw `roundPage` answer. External only so that `_readPage` can catch a
    /// malformed answer (a core upgraded to another ABI) instead of reverting the claim.
    function decodeRoundPage(bytes calldata raw) external pure returns (ISqueekCore.RoundPage memory) {
        return abi.decode(raw, (ISqueekCore.RoundPage));
    }

    /// @notice A winner whose payout could not be delivered, or a buyer owed a partial-fill fee
    /// refund, pulls it here.
    function withdrawOwed() external nonReentrant {
        uint256 amount = owed[msg.sender];
        if (amount == 0) revert NothingOwed();
        owed[msg.sender] = 0;
        totalOwed -= amount;
        _ensureEth(amount);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit OwedWithdrawn(msg.sender, amount);
    }

    /// @notice Turns the hook's ERC-6909 ETH claims on the PoolManager into ETH. Anyone may call it.
    function redeemClaims() external nonReentrant {
        _redeemClaims();
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotFromPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
        return "";
    }

    // ---------------------------------------------------------------- views

    /// @notice Fees collected and not yet paid out: what the next nap's winner stands to take at most.
    function pot() public view returns (uint256) {
        return cumulativeFees - cumulativePaid;
    }

    /// @notice The SqueekCore round at `timestamp` (0 before genesis).
    function roundAt(uint256 timestamp) public view returns (uint64) {
        if (timestamp < GENESIS_TIMESTAMP) return 0;
        return uint64((timestamp - GENESIS_TIMESTAMP) / ROUND_DURATION + 1);
    }

    /// @notice The round the current block falls in.
    function currentRound() public view returns (uint64) {
        return roundAt(block.timestamp);
    }

    /// @notice The first second of `round`.
    function roundStart(uint64 round) public view returns (uint256) {
        if (round == 0) return GENESIS_TIMESTAMP;
        return GENESIS_TIMESTAMP + uint256(round - 1) * ROUND_DURATION;
    }

    /// @notice The first second after `round`.
    function roundEnd(uint64 round) public view returns (uint256) {
        return GENESIS_TIMESTAMP + uint256(round) * ROUND_DURATION;
    }

    /// @notice Whether the game is in its first game (before the first settled nap), when the Sworn
    /// card check applies on mainnet.
    function firstGame() public view returns (bool) {
        return !firstNapSettled;
    }

    /// @notice Whether a buy by `buyer` would pass the Sworn card check on this chain right now.
    function mayBuy(address buyer) public view returns (bool) {
        if (block.chainid != SWORN_CHAIN_ID || firstNapSettled) return true;
        return SWORN.balanceOf(buyer) >= 1;
    }

    /// @notice The number of recorded buys.
    function buyCount() external view returns (uint256) {
        return _buys.length;
    }

    /// @notice A recorded buy: the round, the fees collected through it and the latest buyer then.
    function buyAt(uint256 index) external view returns (BuyRecord memory) {
        return _buys[index];
    }

    /// @notice Who would win a nap that begins at `napStart`, and how much, from the records so far.
    function winnerBefore(uint64 napStart) external view returns (address winner, uint256 amount) {
        uint256 cumulative;
        (winner, cumulative) = _stateBefore(roundStart(napStart));
        if (winner == address(0) || cumulative <= cumulativePaid) return (winner, 0);
        amount = cumulative - cumulativePaid;
    }

    /// @notice Who the failsafe would pay if called now, as known now (the last qualifying buyer
    /// whose buy happened before `failsafeCutoff()`), and the fees collected through that buy that
    /// are not yet paid out, before any certified nap still to be settled is paid out of them.
    function failsafeWinner() external view returns (address winner, uint256 amount) {
        uint256 cumulative;
        (winner, cumulative) = _stateBefore(_failsafeCutoff(failsafeOpensAt()));
        if (winner == address(0) || cumulative <= cumulativePaid) return (winner, 0);
        amount = cumulative - cumulativePaid;
    }

    /// @notice The earliest timestamp at which the failsafe opens, given what the hook has seen so
    /// far: 7 days after the later of the last observed frontier advance (the game's start, if the
    /// core has never been readable) and the frontier round's end. A later observed advance moves it.
    function failsafeOpensAt() public view returns (uint256) {
        uint256 since = roundEnd(lastSeenFrontier);
        if (frontierSeenAt > since) since = frontierSeenAt;
        return since + FAILSAFE_DELAY;
    }

    /// @notice The moment a buy must precede to count for the failsafe now: the later of
    /// `failsafeOpensAt()` and `FAILSAFE_DELAY` ago. A buy made after the failsafe opened counts
    /// once it is itself seven days old with the core still stale, never when it is placed in front
    /// of the failsafe call.
    function failsafeCutoff() external view returns (uint256) {
        return _failsafeCutoff(failsafeOpensAt());
    }

    // ---------------------------------------------------------------- internals

    /// @dev The failsafe's cutoff for an opening at `staleAt`: that opening, or seven days ago when
    /// that is later. The cutoff never stands still while the core does, so a buyer who qualifies
    /// after the opening (or after an earlier failsafe payout) is paid once their buy is seven days
    /// old, and nothing they paid stays locked.
    function _failsafeCutoff(uint256 staleAt) private view returns (uint256) {
        uint256 aged = block.timestamp > FAILSAFE_DELAY ? block.timestamp - FAILSAFE_DELAY : 0;
        return aged > staleAt ? aged : staleAt;
    }

    function _feeOnGross(uint256 gross) private pure returns (uint256) {
        return gross * FEE_BPS / BPS;
    }

    /// @dev For an exact-output buy the pool receives the ETH net of the fee; the fee is 2% of the
    /// gross, so fee = net * 200 / 9800.
    function _feeOnPoolEth(uint256 poolEth) private pure returns (uint256) {
        return poolEth * FEE_BPS / (BPS - FEE_BPS);
    }

    function _checkSworn() private view {
        if (block.chainid != SWORN_CHAIN_ID || firstNapSettled) return;
        address buyer = tx.origin;
        if (SWORN.balanceOf(buyer) < 1) revert NotSworn(buyer);
    }

    function _startGameIfNeeded() private {
        if (scanRound != 0) return;
        uint64 round = currentRound();
        if (round == 0) round = 1;
        scanRound = round;
        // Until the core is read for the first time, the failsafe's clock starts here, not at genesis.
        frontierSeenAt = block.timestamp;
        emit GameStarted(round);
    }

    /// @dev Credits `buyer` the part of a fee reservation the pool's fill did not earn, pulled later
    /// with `withdrawOwed`. The hook already collected it from the manager, so it is always backed.
    function _refund(address buyer, uint256 amount) private {
        if (amount == 0) return;
        owed[buyer] += amount;
        totalOwed += amount;
        emit FeeRefunded(buyer, amount);
    }

    /// @dev The hook is credited `amount` of ETH by the PoolManager at the end of this swap (the fee,
    /// plus any part of an exact-input reservation to be refunded). Take it as ETH when the manager
    /// already holds enough; otherwise mint an ERC-6909 claim, redeemed later.
    function _collectFee(uint256 amount) private {
        if (address(poolManager).balance >= amount) {
            poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
        } else {
            poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
            claimsHeld += amount;
        }
    }

    /// @dev Reads the core's frontier without letting a reverting or dead core break a buy.
    function _observeFrontier() private {
        (bool ok, uint64 frontier) = _readFrontier();
        if (ok) _noteFrontier(frontier);
    }

    function _readFrontier() private view returns (bool ok, uint64 frontier) {
        return _readFrontierFrom(core);
    }

    function _readFrontierFrom(ISqueekCore target) private view returns (bool ok, uint64 frontier) {
        (bool success, bytes memory ret) = _coreRead(target, abi.encodeCall(ISqueekCore.state, ()), 256);
        // CoreState is eight static words; the first is settledThroughRound.
        if (!success || ret.length != 256) return (false, 0);
        uint256 word = abi.decode(ret, (uint256));
        if (word > type(uint64).max) return (false, 0);
        return (true, uint64(word));
    }

    function _readConfiguration(ISqueekCore target) private view returns (uint64 genesis, uint64 duration) {
        (bool ok, bytes memory ret) = _coreRead(target, abi.encodeCall(ISqueekCore.configuration, ()), 352);
        // CoreConfiguration has eleven static words. Only genesis and duration affect this game.
        if (!ok || ret.length != 352) revert CoreUnreadable();
        (, uint256 genesisWord, uint256 durationWord) = abi.decode(ret, (bytes32, uint256, uint256));
        if (genesisWord > type(uint64).max || durationWord > type(uint64).max) revert CoreUnreadable();
        if (durationWord == 0) revert InvalidRoundDuration();
        return (uint64(genesisWord), uint64(durationWord));
    }

    /// @dev Bound both forwarded gas and copied returndata. A core returning a huge malformed ABI
    /// must not exhaust the caller while it tries to recover from that very core. Expected sizes
    /// follow ISqueekCore; the external decoder still catches malformed dynamic page offsets.
    function _coreRead(ISqueekCore target, bytes memory data, uint256 maxBytes)
        private
        view
        returns (bool ok, bytes memory result)
    {
        result = new bytes(maxBytes);
        assembly ("memory-safe") {
            ok := staticcall(CORE_READ_GAS, target, add(data, 32), mload(data), add(result, 32), maxBytes)
            switch and(ok, iszero(gt(returndatasize(), maxBytes)))
            case 1 { mstore(result, returndatasize()) }
            default {
                ok := 0
                mstore(result, 0)
            }
        }
    }

    /// @dev Conservatively requires all readable pending rounds to be scanned, even if they turn
    /// out to contain no nap. Probe just the next page; settleNaps can make bounded progress first.
    function _requireOldCoreCaughtUp() private view {
        if (scanRound == 0) return;
        _requireCoreReadGas();
        (bool ok, uint64 frontier) = _readFrontier();
        if (!ok) return;
        if (frontier < lastSeenFrontier) frontier = lastSeenFrontier;
        if (scanRound > frontier) return;
        uint64 through = uint64(_pageEnd(scanRound, frontier));
        _requireCoreReadGas();
        (bool readable, ISqueekCore.RoundPage memory page) = _readPage(scanRound, through);
        if (readable && page.certifiedThroughRound >= scanRound) revert NapsUnsettled(scanRound, frontier);
    }

    function _requireCoreReadGas() private view {
        if (gasleft() < MIN_CORE_READ_GAS) revert InsufficientCoreReadGas();
    }

    function _pageEnd(uint64 from, uint64 frontier) private pure returns (uint256) {
        uint256 end = uint256(from) + PAGE_ROUNDS - 1;
        return end > frontier ? frontier : end;
    }

    /// @dev Records an observed advance of the frontier and when it was seen. The observation time
    /// is the conservative date for the failsafe: the core settled the round no later than this.
    function _noteFrontier(uint64 frontier) private {
        if (frontier > lastSeenFrontier) {
            lastSeenFrontier = frontier;
            frontierSeenAt = block.timestamp;
            emit FrontierSeen(frontier);
        }
    }

    /// @dev Scans up to `maxPages` pages of settled rounds from `scanRound` through `frontier` and
    /// settles every nap found, in order. `readable` is false when the core's `roundPage` could not
    /// be read or certified nothing; the scan stops there and `scanRound` keeps what was done.
    function _scan(uint64 frontier, uint256 maxPages) private returns (uint256 settled, bool readable) {
        readable = true;
        uint64 from = scanRound;
        for (uint256 page = 0; page < maxPages && from <= frontier; page++) {
            uint64 through = uint64(_pageEnd(from, frontier));
            (bool ok, ISqueekCore.RoundPage memory result) = _readPage(from, through);
            uint64 certified = ok ? result.certifiedThroughRound : 0;
            if (certified > through) certified = through;
            if (certified < from) {
                readable = false;
                break;
            }

            uint256 index;
            for (uint64 round = from; round <= certified; round++) {
                bool hadWork = index < result.rounds.length && result.rounds[index].roundId == round;
                if (hadWork) {
                    index++;
                    zeroRun = 0;
                } else {
                    if (zeroRun == 0) zeroRunStart = round;
                    zeroRun++;
                    if (zeroRun == NAP_ROUNDS) {
                        _settleNap(zeroRunStart);
                        settled++;
                    }
                }
            }
            from = certified + 1;
        }
        scanRound = from;
    }

    /// @dev Reads one page of rounds `from..through` without letting a reverting, codeless or
    /// re-ABI'd core revert the caller: the caller decides what an unreadable core means.
    function _readPage(uint64 from, uint64 through) private view returns (bool ok, ISqueekCore.RoundPage memory page) {
        (bool success, bytes memory ret) =
            _coreRead(core, abi.encodeCall(ISqueekCore.roundPage, (from - 1, through, PAGE_ROUNDS)), MAX_PAGE_BYTES);
        if (!success) return (false, page);
        try this.decodeRoundPage(ret) returns (ISqueekCore.RoundPage memory decoded) {
            return (true, decoded);
        } catch {
            return (false, page);
        }
    }

    /// @dev The state after the last buy strictly before timestamp `bound`. Timestamps remain
    /// ordered across core switches; stored round numbers are historical and can move backwards.
    function _stateBefore(uint256 bound) private view returns (address winner, uint256 cumulative) {
        uint256 length = _buys.length;
        if (length == 0 || _buys[0].time >= bound) return (address(0), 0);
        // Largest index whose key < bound. _buys[lo].key < bound holds throughout.
        uint256 lo = 0;
        uint256 hi = length - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            if (_buys[mid].time < bound) lo = mid;
            else hi = mid - 1;
        }
        BuyRecord storage record = _buys[lo];
        return (record.latestBuyer, record.cumulativeFees);
    }

    function _settleNap(uint64 napStart) private {
        napsSettled++;
        firstNapSettled = true;
        (address winner, uint256 cumulative) = _stateBefore(roundStart(napStart));
        uint256 amount;
        if (winner != address(0) && cumulative > cumulativePaid) {
            amount = cumulative - cumulativePaid;
            cumulativePaid = cumulative;
        }
        emit NapSettled(napStart, winner, amount);
        if (amount > 0) _pay(winner, amount);
    }

    /// @dev Pays a winner; a winner that cannot receive ETH is credited instead and never blocks.
    /// The call gives the wallet a bounded `PAYOUT_GAS` and copies none of its return data, so a
    /// wallet (an EOA with EIP-7702 code included) that burns gas or answers with a huge payload can
    /// only fail its own payout, never the claim that carries it.
    function _pay(address winner, uint256 amount) private {
        _ensureEth(amount);
        bool ok;
        assembly ("memory-safe") {
            ok := call(PAYOUT_GAS, winner, amount, 0, 0, 0, 0)
        }
        if (!ok) {
            owed[winner] += amount;
            totalOwed += amount;
            emit PayoutDeferred(winner, amount);
        }
    }

    function _ensureEth(uint256 amount) private {
        if (address(this).balance < amount && claimsHeld > 0) _redeemClaims();
    }

    function _redeemClaims() private {
        uint256 amount = claimsHeld;
        if (amount == 0) return;
        claimsHeld = 0;
        poolManager.unlock(abi.encode(amount));
        emit ClaimsRedeemed(amount);
    }
}
