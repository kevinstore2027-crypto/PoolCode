// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;
#kevinstore
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ................................................****+...............................................
// ...............................................**...**..............................................
// ..............................................***....**...................:+*+......................
// .............................................**+.....-*:.................**...*****.................
// ...........................................+**.......**.................**.........***..............
// ........................................****..........*******..........+*..+*+.+.....*=.............
// ....................................=****...................+****......*+...+:+.==..-*=.............
// .................................+***...........................***...**.......==..:**..............
// ...............................***........................::...::::**-.**---.......-**..............
// .............................+**...........................:..:::::::**.*****----::**...............
// ...........................+*+.................................::::::.***...-*******................
// ..........................+*................................::::::::::.***..........................
// .........................*+................................:::::::.......+*.........................
// ........................**..................................::::::........+*........................
// .......................**...........................................:::....*+.......................
// ......................**.............................................::.....**......................
// .....................**.....................................................:**.....................
// ....................-**......................................................**.....................
// ....................**............ *.*+++..................*.**+.............:*+....................
// ....................**............:***+**=............... *+***+*............:**....................
// ...................**..............****++:................+*+*+++............:+*....................
// ...................**..........:....+++++......+*+**.......+++++..::.........::**...................
// ...................**........:::::::............................:::::::.....:::**...................
// ...................**:.......:::::::...........................:::::::......:::**...................
// ...................**:............................................::.......::::**...................
// ...................**::.............+.........................+...........:::::**...................
// ...................**:::.............**......................**..........:::::-*....................
// ....................**:::............:*.....................**..........::::::**....................
// ....................**-:::::....+******.....................:******...::::::::*:....................
// .....................**::::::.....::::.......................:::::..:::::::::**.....................
// ......................**::::::...................................:::::::::::**......................
// .......................**:::::::::............................::::::::::::+**.......................
// ........................=**:::::::::::...................::::::::::::::::**.........................
// .........................:****::::::::::::::::::::::::::::::::::::::::=**+::........................
// .......................:.....****::::::::::::::::::::::::::::::::::****...:::.......................
// .........................::...::******::::::::::::::::::::::::******::..::::........................
// .............................:......:=************************+.:...::::............................
// ........................................:.::............:.::.::.:...................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
// ....................................................................................................
//
//                                    https://x.com/pcodepool
//                                    https://pcodepool.org
//
import {BaseTestHooks} from "v4-core/src/test/BaseTestHooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title IPoolcodeToken — the two calls the POOLCODE hook makes into the POOLCODE token.
/// @notice Deliberately minimal: the hook can only *push ETH in* and *read historical balances*.
/// Nothing here moves tokens, reads a holder's reward balance, or withdraws anything, so the hook never
/// holds custody of holder funds and can never influence a balance it later tallies.
interface IPoolcodeToken {
    /// @notice Forward an ETH fee into the holder reward pool. Only the token's bound hook may call it.
    function notifyFee() external payable;

    /// @notice Voting power as of the END of a past block. Reverts for a block that is not yet mined.
    function getPastVotes(address account, uint256 blockNumber) external view returns (uint256);

    /// @notice Total eligible voting supply as of the END of a past block.
    function getPastTotalVotes(uint256 blockNumber) external view returns (uint256);
}

/// @title PoolcodeHook — the Uniswap v4 hook for the one official PCODE/native-ETH pool, and the
/// version machine that rewrites the pool's own behaviour every 88 swaps.
///
/// POOLCODE is two contracts. This one owns everything that is a function of *swaps*: the pool binding,
/// the 1% buy fee, the 4% sell fee, the swap counter, the module vote and the active module. The other
/// — PoolcodeToken — owns the ERC-20, the reward ledger and the balance checkpoints votes are weighed
/// against. 100% of every fee this hook takes is forwarded to the token in the same transaction through
/// `notifyFee`; this contract never accumulates ETH and has no way to spend any.
///
/// ── the version chain ────────────────────────────────────────────────────────────────────────────
/// The pool starts at Version 1 running MODULE_BASE. Every completed swap on the canonical pool
/// increments a counter. When the counter reaches SWAPS_PER_VERSION (88) a vote *opens*: the counter
/// resets, a snapshot block is pinned, and holders have VOTE_WINDOW to pick which of the predefined
/// modules the next version should run. Swaps keep flowing the whole time — an open vote never blocks
/// the pool — but the counter that would open the *next* vote does not advance while one is open, so
/// versions can never race ahead of the votes that decide them. When the window closes, anyone may
/// `finalizeVote()`: the winning module is stored, the version increments, and the counter starts again.
///
/// ── the vote ─────────────────────────────────────────────────────────────────────────────────────
/// `1 PCODE = 1 vote`, with no cap. Weight is read from the token's checkpoint history at the snapshot
/// block pinned when the vote opened — a block that is always strictly in the past by the time any
/// ballot is cast. That is what makes the vote safe against balance reshuffling: transferring a bag to
/// a fresh wallet after the snapshot gives that wallet zero power, because the checkpoint it reads is
/// already written. Each address votes once per round, and the pool, the hook, the PoolManager and the
/// other excluded system addresses read back as zero at every block, so pool-custodied PCODE can never
/// be voted with.
///
/// ── the modules ──────────────────────────────────────────────────────────────────────────────────
/// A module is NOT code. There is no delegatecall, no external call, no upgradeable proxy and no
/// address a vote can point at — a module is a `uint8` id that selects one branch of the fee arithmetic
/// written into this contract at compile time. The set is fixed forever at MODULE_COUNT entries:
///
///   0 · BASE    — the reference pool. Buy 1%, sell 4%, flat for the whole version.
///   1 · TIDE    — entry relief. Buy fee halves to 0.5%; sell stays 4%. Cheaper to enter, same to exit.
///   2 · CASCADE — a cooling exit. The sell fee decays linearly from 4% at the start of the version to
///                 2% by its 88th swap, then the next version resets it. Buy stays 1%.
///   3 · BEACON  — every 8th swap of the version pays no fee at all; all others pay the base schedule.
///
/// Every branch does one thing only: choose a basis-point rate. The rate is then clamped into
/// [0, MAX_FEE_BPS] and charged in native ETH exactly the way the base pool charges it, so no module
/// can alter the v4 settlement path, mint or burn a delta, touch liquidity, or take a fee in the wrong
/// currency. The worst a module can do is move the fee inside a band the constants already bound.
///
/// ── trust assumptions ────────────────────────────────────────────────────────────────────────────
/// * No owner, no admin, no setter, no pause. Every parameter is a compile-time constant and the two
///   addresses it talks to (PoolManager, token) are immutable from construction.
/// * No fee any module can produce exceeds MAX_FEE_BPS (4%): it is enforced by a clamp on the single
///   line every branch funnels through, and there is no code path that writes a rate to storage.
/// * The hook cannot redirect rewards — the destination is immutable — and cannot withdraw them: the
///   only ETH-moving call it makes is `notifyFee`, which pays *into* the token.
/// * The pool is validated at initialization and pinned: only native ETH (currency0) paired with PCODE
///   (currency1) on this hook can ever bind, and only that one pool is ever serviced afterwards.
contract PoolcodeHook is BaseTestHooks {
    using BalanceDeltaLibrary for BalanceDelta;
    using PoolIdLibrary for PoolKey;

    // ── fee parameters ───────────────────────────────────────────────────────────────────────────
    /// @notice Basis-point denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Base ETH fee on a buy (ETH → PCODE). 1%.
    uint256 public constant BUY_FEE_BPS = 100;
    /// @notice Base ETH fee on a sell (PCODE → ETH). 4%.
    uint256 public constant SELL_FEE_BPS = 400;
    /// @notice The hard ceiling on any fee any module can produce. 4%, enforced by a clamp.
    uint256 public constant MAX_FEE_BPS = 400;

    // ── the version machine ──────────────────────────────────────────────────────────────────────
    /// @notice Completed swaps that unlock the next version.
    uint256 public constant SWAPS_PER_VERSION = 88;
    /// @notice How long a vote stays open once unlocked.
    uint256 public constant VOTE_WINDOW = 24 hours;

    // ── the predefined modules ───────────────────────────────────────────────────────────────────
    /// @notice 0 · BASE — the reference pool: buy 1%, sell 4%, flat.
    uint8 public constant MODULE_BASE = 0;
    /// @notice 1 · TIDE — entry relief: buy 0.5%, sell 4%.
    uint8 public constant MODULE_TIDE = 1;
    /// @notice 2 · CASCADE — cooling exit: sell decays 4% → 2% across the version's 88 swaps.
    uint8 public constant MODULE_CASCADE = 2;
    /// @notice 3 · BEACON — every 8th swap of the version is fee-free.
    uint8 public constant MODULE_BEACON = 3;
    /// @notice The number of predefined modules. Fixed forever; a vote for any id >= this reverts.
    uint8 public constant MODULE_COUNT = 4;

    /// @notice TIDE's buy fee. 0.5%.
    uint256 public constant TIDE_BUY_FEE_BPS = 50;
    /// @notice The floor CASCADE's sell fee decays to by the end of a version. 2%.
    uint256 public constant CASCADE_MIN_SELL_FEE_BPS = 200;
    /// @notice BEACON's period: every Nth swap of the version pays nothing.
    uint256 public constant BEACON_PERIOD = 8;

    /// @notice The canonical Uniswap v4 PoolManager this hook is mounted on.
    IPoolManager public immutable poolManager;
    /// @notice The PCODE token and reward ledger every fee is forwarded to. Immutable: no redirection.
    IPoolcodeToken public immutable token;

    // ── the canonical pool: bound once, at initialization ────────────────────────────────────────
    /// @notice Whether the one official pool has been bound. Binding is permanent.
    bool public poolBound;
    /// @notice The id of the bound pool.
    PoolId public canonicalPool;
    /// @notice The full key of the bound pool.
    PoolKey public poolKey;

    // ── version state ────────────────────────────────────────────────────────────────────────────
    /// @notice The live pool version. Starts at 1 and only ever increments, one per resolved vote.
    uint256 public currentVersion = 1;
    /// @notice The module id the live version runs. Version 1 always runs MODULE_BASE.
    uint8 public currentModule = MODULE_BASE;
    /// @notice Completed swaps counted toward unlocking the next version. Resets when a vote opens.
    uint256 public swapCountForNextVersion;
    /// @notice Completed swaps in the current version, counted from its activation. Modules that vary
    /// within a version (CASCADE, BEACON) read this, never the global total.
    uint256 public swapsThisVersion;
    /// @notice Completed swaps over the pool's entire life.
    uint256 public totalSwaps;

    // ── voting state ─────────────────────────────────────────────────────────────────────────────
    /// @notice Whether a vote for the next version is open right now.
    bool public voteOpen;
    /// @notice The version a currently-open (or last-resolved) vote decides the module for.
    uint256 public votingForVersion;
    /// @notice The past block a vote's weights are read at. Pinned when the vote opens.
    uint256 public voteSnapshotBlock;
    /// @notice When the open vote stops accepting ballots.
    uint256 public voteDeadline;
    /// @notice Ballots cast in the open round, by module id.
    mapping(uint8 => uint256) public voteTotals;
    /// @notice The round number an address last voted in — one ballot per address per round.
    mapping(address => uint256) public lastVotedRound;
    /// @notice How many rounds have opened. Also the key `lastVotedRound` is compared against.
    uint256 public voteRound;
    /// @notice The module a resolved vote selected, by the version it was selected for.
    mapping(uint256 => uint8) public moduleOfVersion;

    // ── events ────────────────────────────────────────────────────────────────────────────────────
    /// @notice Emitted once, when the official pool is bound.
    event PoolBound(PoolId indexed poolId, address indexed token);
    /// @notice Emitted on every completed swap, with the counter that unlocks the next version.
    event SwapCountUpdated(uint256 totalSwaps, uint256 swapCountForNextVersion, uint256 swapsThisVersion);
    /// @notice Emitted when 88 swaps complete and a vote opens.
    event VersionUnlocked(uint256 indexed nextVersion, uint256 round, uint256 snapshotBlock, uint256 deadline);
    /// @notice Emitted for every ballot.
    event VoteCast(address indexed voter, uint256 indexed round, uint8 indexed moduleId, uint256 weight);
    /// @notice Emitted when a vote resolves and a module wins.
    event ModuleSelected(uint256 indexed version, uint8 indexed moduleId, uint256 votes);
    /// @notice Emitted when the new version goes live.
    event VersionActivated(uint256 indexed version, uint8 indexed moduleId);
    /// @notice Emitted on every taxed swap.
    /// @param isBuy true when ETH was swapped in for PCODE
    /// @param ethAmount the gross ETH side of the swap the fee was charged on
    /// @param feeBps the fee rate applied, in basis points
    /// @param feeAmount the ETH fee taken and forwarded to holders
    /// @param moduleId the module that set the rate
    /// @param version the pool version the swap executed under
    event SwapTaxed(
        bool indexed isBuy,
        uint256 ethAmount,
        uint256 feeBps,
        uint256 feeAmount,
        uint8 moduleId,
        uint256 version
    );
    /// @notice Emitted when a fee is forwarded to the token's holder reward pool.
    event FeesCollected(uint256 amount, uint256 version, uint8 moduleId);

    // ── custom errors ─────────────────────────────────────────────────────────────────────────────
    error NotPoolManager();
    error NotCanonicalPool();
    error PoolAlreadyBound();
    error ExactOutSellUnsupported();
    error ZeroAddress();
    error NoVoteOpen();
    error VoteClosed();
    error VoteStillOpen();
    error AlreadyVoted();
    error UnknownModule();
    error NoVotingPower();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param pm the canonical Uniswap v4 PoolManager.
    /// @param token_ the PoolcodeToken this hook taxes for. Fixed at construction, no setter.
    constructor(IPoolManager pm, IPoolcodeToken token_) {
        if (address(pm) == address(0) || address(token_) == address(0)) revert ZeroAddress();
        poolManager = pm;
        token = token_;
        moduleOfVersion[1] = MODULE_BASE; // version 1 is the base pool, decided by no vote
        emit VersionActivated(1, MODULE_BASE);
    }

    /// @dev ETH fees arrive here via poolManager.take and leave for the token in the same call, so this
    /// contract holds no balance between transactions. Nothing else may push ETH in.
    receive() external payable onlyPoolManager {}

    // ── hook permissions ──────────────────────────────────────────────────────────────────────────
    /// @notice The callbacks this hook subscribes to: validate/bind the pool, then tax and count every
    /// swap. `beforeSwapReturnDelta` lets the exact-in buy fee be skimmed off the specified input;
    /// `afterSwapReturnDelta` lets the sell fee (and the exact-out buy fee) be taken from the settled
    /// ETH side. No liquidity or donate callbacks are claimed — the hook never touches those paths.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
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

    // ── binding the one canonical pool ────────────────────────────────────────────────────────────
    /// @notice Validate and bind the single official pool at initialization. The key must pair native
    /// ETH (currency0) with PCODE (currency1) on this hook; anything else reverts. A second
    /// initialization reverts too, so the binding is permanent and only one pool is ever serviced.
    function beforeInitialize(address, PoolKey calldata key, uint160)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        if (poolBound) revert PoolAlreadyBound();
        if (
            Currency.unwrap(key.currency0) != address(0) // native ETH
                || Currency.unwrap(key.currency1) != address(token) // PCODE
                || address(key.hooks) != address(this)
        ) revert NotCanonicalPool();
        poolBound = true;
        poolKey = key;
        canonicalPool = key.toId();
        emit PoolBound(canonicalPool, address(token));
        return IHooks.beforeInitialize.selector;
    }

    // ── the module fee schedule ───────────────────────────────────────────────────────────────────
    /// @dev The single place a fee rate is decided. Every module is one branch here, every branch
    /// returns only a basis-point number, and every return funnels through the same clamp — so no
    /// module can produce a fee above MAX_FEE_BPS, denominate one in the wrong currency, or reach any
    /// part of the v4 settlement path. `swapIndex` is the 0-based position of this swap within the
    /// current version, which is what lets a module vary inside a version without reading anything a
    /// trader controls.
    function _feeBpsFor(uint8 moduleId, bool isBuy, uint256 swapIndex) private pure returns (uint256 bps) {
        if (moduleId == MODULE_TIDE) {
            // Entry relief: half-price buys, unchanged exits.
            bps = isBuy ? TIDE_BUY_FEE_BPS : SELL_FEE_BPS;
        } else if (moduleId == MODULE_CASCADE) {
            // A cooling exit: the sell fee decays linearly from SELL_FEE_BPS at the version's first
            // swap (index 0) to exactly CASCADE_MIN_SELL_FEE_BPS at its 88th (index 87). `swapIndex` is
            // capped at that last index, so a long-running version — one whose vote has not been
            // finalized yet — holds the floor instead of decaying past it.
            if (isBuy) {
                bps = BUY_FEE_BPS;
            } else {
                uint256 last = SWAPS_PER_VERSION - 1; // the version's final swap, 0-based
                uint256 i = swapIndex >= last ? last : swapIndex;
                uint256 span = SELL_FEE_BPS - CASCADE_MIN_SELL_FEE_BPS;
                bps = SELL_FEE_BPS - (span * i / last);
            }
        } else if (moduleId == MODULE_BEACON) {
            // Every BEACON_PERIOD-th swap of the version is free. swapIndex is 0-based, so the 8th,
            // 16th, 24th … swap of the version (index 7, 15, 23 …) pays nothing.
            if ((swapIndex + 1) % BEACON_PERIOD == 0) bps = 0;
            else bps = isBuy ? BUY_FEE_BPS : SELL_FEE_BPS;
        } else {
            // MODULE_BASE, and the structural default for any id that ever slipped through.
            bps = isBuy ? BUY_FEE_BPS : SELL_FEE_BPS;
        }
        if (bps > MAX_FEE_BPS) bps = MAX_FEE_BPS; // unconditional ceiling; no branch can exceed it
    }

    /// @dev The rate the NEXT swap would pay. Reads the live module and the live in-version index.
    function _liveFeeBps(bool isBuy) private view returns (uint256) {
        return _feeBpsFor(currentModule, isBuy, swapsThisVersion);
    }

    // ── taxing swaps ──────────────────────────────────────────────────────────────────────────────
    /// @dev Direction comes from `zeroForOne` against the bound key, where ETH is currency0 and PCODE
    /// currency1 — enforced at bind time — so a buy is always ETH-in and a sell always PCODE-in no
    /// matter how a caller orders its arguments. Nothing here assumes an ordering that was not checked.
    ///
    /// The fee is denominated in native ETH, which decides where it can be charged. On an exact-in buy
    /// ETH is the specified input, so the fee is skimmed here. On a sell, and on an exact-out buy, the
    /// ETH side is unspecified and known only from the settled delta, so those are taken in afterSwap.
    ///
    /// An exact-out sell (ETH specified as output) is rejected: charging the ETH fee against a specified
    /// output would hand the trader less than the exact amount they asked for, and taking it from the
    /// PCODE input instead would denominate the fee in the wrong asset. Routers sell exact-in.
    /// The LP fee is overridden to 0 — the ETH fee is the only one.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _requireCanonical(key);
        if (!params.zeroForOne && params.amountSpecified > 0) revert ExactOutSellUnsupported();

        // exact-in buy: ETH is the specified input, so skim the module's buy rate now
        if (params.zeroForOne && params.amountSpecified < 0) {
            uint256 fee = uint256(-params.amountSpecified) * _liveFeeBps(true) / BPS;
            if (fee > 0) {
                poolManager.take(Currency.wrap(address(0)), address(this), fee);
                return (
                    IHooks.beforeSwap.selector,
                    toBeforeSwapDelta(int128(int256(fee)), 0),
                    LPFeeLibrary.OVERRIDE_FEE_FLAG
                );
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    /// @dev Take whatever ETH fee is still owed (sells and exact-out buys), forward 100% of the fee to
    /// the token's reward pool, then count the completed swap. ETH is always currency0 and PCODE always
    /// currency1 on the bound pool.
    ///
    /// The rate is read BEFORE the counter advances, so the swap is priced at the in-version index it
    /// actually occupied — the same index `beforeSwap` skimmed the buy fee at. Counting last also keeps
    /// the two halves of one swap on one rate: a module that varies within a version can never charge a
    /// buy at one index and settle it at the next.
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, int128)
    {
        _requireCanonical(key);
        bool isBuy = params.zeroForOne;
        uint8 moduleId = currentModule;
        uint256 feeBps = _feeBpsFor(moduleId, isBuy, swapsThisVersion);
        uint256 fee;
        uint256 ethAmt;
        int128 ret = 0;

        if (isBuy) {
            if (params.amountSpecified < 0) {
                ethAmt = uint256(-params.amountSpecified); // exact-in: fee already skimmed in beforeSwap
                fee = ethAmt * feeBps / BPS;
            } else {
                ethAmt = uint256(uint128(-delta.amount0())); // exact-out buy: charge on the ETH input
                fee = ethAmt * feeBps / BPS;
                if (fee > 0) poolManager.take(Currency.wrap(address(0)), address(this), fee);
                ret = int128(int256(fee));
            }
        } else {
            // SELL (exact-in) — PCODE in, ETH out is the unspecified side.
            ethAmt = uint256(uint128(delta.amount0()));
            fee = ethAmt * feeBps / BPS;
            if (fee > 0) poolManager.take(Currency.wrap(address(0)), address(this), fee);
            ret = int128(int256(fee));
        }

        // 100% of the fee leaves in the same call — the hook keeps nothing.
        if (fee > 0) {
            token.notifyFee{value: fee}();
            emit FeesCollected(fee, currentVersion, moduleId);
        }
        emit SwapTaxed(isBuy, ethAmt, feeBps, fee, moduleId, currentVersion);

        _countSwap();
        return (IHooks.afterSwap.selector, ret);
    }

    /// @dev Reject any pool but the bound canonical one.
    function _requireCanonical(PoolKey calldata key) private view {
        if (!poolBound || PoolId.unwrap(key.toId()) != PoolId.unwrap(canonicalPool)) revert NotCanonicalPool();
    }

    // ── the version machine ───────────────────────────────────────────────────────────────────────
    /// @dev Count one completed swap and, at the 88th, unlock the next version by opening a vote.
    ///
    /// While a vote is open the *unlock* counter is frozen: swaps keep being taxed and keep advancing
    /// the in-version index the modules read, but `swapCountForNextVersion` does not move, so a second
    /// version can never unlock before the first one's vote has been resolved. That is the "increment
    /// only after the current upgrade vote is resolved" rule, enforced structurally rather than by a
    /// check a caller could skip.
    ///
    /// The vote's weights are snapshotted at `block.number - 1` — already-mined, so the history the
    /// token returns for it is final and no ballot can be cast against a block still in flight.
    function _countSwap() private {
        unchecked {
            totalSwaps += 1;
            swapsThisVersion += 1;
        }
        if (!voteOpen) {
            unchecked {
                swapCountForNextVersion += 1;
            }
            if (swapCountForNextVersion >= SWAPS_PER_VERSION) {
                swapCountForNextVersion = 0;
                voteOpen = true;
                voteRound += 1;
                votingForVersion = currentVersion + 1;
                // Pinned at the unlock block itself, and the token refuses a lookup of a block that
                // is not yet mined — so the first ballot of a round can only land in a LATER block,
                // by which time this block's checkpoints are final. Pinning `block.number - 1`
                // instead would miss a balance written in the unlock block itself.
                voteSnapshotBlock = block.number;
                voteDeadline = block.timestamp + VOTE_WINDOW;
                emit VersionUnlocked(votingForVersion, voteRound, voteSnapshotBlock, voteDeadline);
            }
        }
        emit SwapCountUpdated(totalSwaps, swapCountForNextVersion, swapsThisVersion);
    }

    // ── voting ────────────────────────────────────────────────────────────────────────────────────
    /// @notice Cast your ballot for the module the next version should run. `1 PCODE = 1 vote`, no cap.
    ///
    /// Your weight is your PCODE balance as recorded at `voteSnapshotBlock` — the block the round
    /// unlocked in. The token refuses to read a block that is not yet mined, so the earliest a ballot
    /// can land is the block AFTER the snapshot, by which point that history is final. Moving tokens
    /// then changes nothing: the receiving wallet's checkpoint at the snapshot is already written and
    /// is almost certainly zero, so a bag cannot be walked from wallet to wallet to vote twice. One
    /// ballot per address per round, and the ballot is not splittable.
    /// @dev A ballot in the same block as the unlock reverts inside the token with `FutureLookup`.
    /// That costs nothing real — the vote is open for VOTE_WINDOW — and buys the guarantee that every
    /// weight is read from settled history.
    /// @param moduleId one of the predefined ids, 0..MODULE_COUNT-1. Anything else reverts.
    /// @return weight the voting power recorded for the ballot.
    function castVote(uint8 moduleId) external returns (uint256 weight) {
        if (!voteOpen) revert NoVoteOpen();
        if (block.timestamp > voteDeadline) revert VoteClosed();
        if (moduleId >= MODULE_COUNT) revert UnknownModule();
        uint256 round = voteRound;
        if (lastVotedRound[msg.sender] == round) revert AlreadyVoted();

        weight = token.getPastVotes(msg.sender, voteSnapshotBlock);
        if (weight == 0) revert NoVotingPower();

        lastVotedRound[msg.sender] = round;
        voteTotals[moduleId] += weight;
        emit VoteCast(msg.sender, round, moduleId, weight);
    }

    /// @notice Resolve the open vote once its window has closed: pick the winner, activate the next
    /// version, and let the swap counter start filling toward the one after.
    ///
    /// Permissionless — anyone may finalize, and the outcome does not depend on who does. The winner is
    /// the module with the most weight; ties and a completely unvoted round both fall back to
    /// MODULE_BASE, so the pool always has a defined, safe module and can never stall on an empty vote.
    /// @return version the version just activated.
    /// @return moduleId the module it runs.
    function finalizeVote() external returns (uint256 version, uint8 moduleId) {
        if (!voteOpen) revert NoVoteOpen();
        if (block.timestamp <= voteDeadline) revert VoteStillOpen();

        uint256 best;
        uint8 winner = MODULE_BASE;
        bool tied;
        for (uint8 i = 0; i < MODULE_COUNT; i++) {
            uint256 v = voteTotals[i];
            if (v > best) {
                best = v;
                winner = i;
                tied = false;
            } else if (v == best && v != 0) {
                tied = true;
            }
        }
        if (best == 0 || tied) winner = MODULE_BASE; // no turnout, or an exact tie: keep the base pool

        version = votingForVersion;
        moduleId = winner;

        emit ModuleSelected(version, winner, best);

        // Effects: clear the round, then activate. Clearing first means the counters below start from a
        // fully closed vote, and the next unlock cannot observe a half-resolved round.
        for (uint8 i = 0; i < MODULE_COUNT; i++) {
            if (voteTotals[i] != 0) voteTotals[i] = 0;
        }
        voteOpen = false;
        voteDeadline = 0;
        voteSnapshotBlock = 0;

        currentVersion = version;
        currentModule = winner;
        moduleOfVersion[version] = winner;
        swapsThisVersion = 0;
        swapCountForNextVersion = 0;

        emit VersionActivated(version, winner);
    }

    // ── views ─────────────────────────────────────────────────────────────────────────────────────
    /// @notice The buy fee, in basis points, the next swap would pay under the live module.
    function currentBuyFee() external view returns (uint256) {
        return _liveFeeBps(true);
    }

    /// @notice The sell fee, in basis points, the next swap would pay under the live module.
    function currentSellFee() external view returns (uint256) {
        return _liveFeeBps(false);
    }

    /// @notice The rate a given module would charge at a given in-version swap index. Pure: usable by
    /// interfaces to chart what each module on the ballot would actually do.
    function feePreview(uint8 moduleId, bool isBuy, uint256 swapIndex) external pure returns (uint256) {
        if (moduleId >= MODULE_COUNT) revert UnknownModule();
        return _feeBpsFor(moduleId, isBuy, swapIndex);
    }

    /// @notice The hard bounds of the fee schedule: the base rates and the ceiling no module can pass.
    function feeBounds() external pure returns (uint256 buyFeeBps, uint256 sellFeeBps, uint256 maxFeeBps) {
        return (BUY_FEE_BPS, SELL_FEE_BPS, MAX_FEE_BPS);
    }

    /// @notice Swaps still to go before the next version unlocks. Zero while a vote is open — the
    /// counter is frozen until that vote resolves.
    function swapsUntilNextVersion() external view returns (uint256) {
        if (voteOpen) return 0;
        return SWAPS_PER_VERSION - swapCountForNextVersion;
    }

    /// @notice The whole version machine in one call, for UIs and indexers.
    function versionState()
        external
        view
        returns (
            uint256 version,
            uint8 moduleId,
            uint256 countForNext,
            uint256 inVersionSwaps,
            uint256 lifetimeSwaps,
            bool votingOpen,
            uint256 nextVersion,
            uint256 deadline
        )
    {
        return (
            currentVersion,
            currentModule,
            swapCountForNextVersion,
            swapsThisVersion,
            totalSwaps,
            voteOpen,
            votingForVersion,
            voteDeadline
        );
    }

    /// @notice The open round's tallies, one entry per predefined module. Bounded by MODULE_COUNT, so
    /// this is a fixed-size read, never an unbounded loop.
    function voteTally() external view returns (uint256[] memory totals) {
        totals = new uint256[](MODULE_COUNT);
        for (uint8 i = 0; i < MODULE_COUNT; i++) {
            totals[i] = voteTotals[i];
        }
    }

    /// @notice The module currently leading the open round, and its weight. Falls back to MODULE_BASE
    /// on no turnout or an exact tie, matching exactly what `finalizeVote` would do right now.
    function leadingModule() external view returns (uint8 moduleId, uint256 votes) {
        uint256 best;
        uint8 winner = MODULE_BASE;
        bool tied;
        for (uint8 i = 0; i < MODULE_COUNT; i++) {
            uint256 v = voteTotals[i];
            if (v > best) {
                best = v;
                winner = i;
                tied = false;
            } else if (v == best && v != 0) {
                tied = true;
            }
        }
        if (best == 0 || tied) winner = MODULE_BASE;
        return (winner, best);
    }

    /// @notice What a wallet could vote with in the open round: its weight at the snapshot block, and
    /// whether it has already cast a ballot.
    function votingPowerOf(address account) external view returns (uint256 weight, bool alreadyVoted) {
        alreadyVoted = voteOpen && lastVotedRound[account] == voteRound;
        if (!voteOpen) return (0, alreadyVoted);
        weight = token.getPastVotes(account, voteSnapshotBlock);
    }

    /// @notice The eligible voting supply the open round is measured against.
    function voteSupply() external view returns (uint256) {
        if (!voteOpen) return 0;
        return token.getPastTotalVotes(voteSnapshotBlock);
    }

    /// @notice The bound pool: whether it is bound, its id and its key.
    function poolInfo() external view returns (bool bound, PoolId id, PoolKey memory key) {
        return (poolBound, canonicalPool, poolKey);
    }
}
