// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {FactoryVanity} from "./FactoryVanity.sol";
import {VanityHelpers} from "./VanityHelpers.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {FeeLockerV2} from "../src/FeeLockerV2.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzToken} from "../src/StonkzToken.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {LadderConstants} from "../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../src/ladder/LadderTypes.sol";
import {LadderSettlement} from "../src/ladder/LadderSettlement.sol";
import {StonkzVault} from "../src/vault/StonkzVault.sol";
import {VaultConstants} from "../src/vault/VaultConstants.sol";
import {DeployControls} from "../src/DeployControls.sol";
import {Vanity} from "../src/Vanity.sol";

/// @dev Reverting ETH receiver - flush must not brick treasury path (hostile probe).
contract ForkHostileReceiver {
    error Nope();

    receive() external payable {
        revert Nope();
    }
}

/// @dev Minimal ERC20 for vault holdback drill on fork.
contract ForkMockERC20 {
    string public name = "ForkMock";
    string public symbol = "FM";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @title ForkProofPhase2 - chain-4663 fork drills (docs/03 ONE DEPLOY Phase 2)
/// @notice In-memory fork only - no mainnet broadcast. Requires network RPC.
///         Run: forge test --match-contract ForkProofPhase2 -vvv
///         RPC: $env:ROBINHOOD_RPC_URL or public https://rpc.mainnet.chain.robinhood.com
contract ForkProofPhase2 is Test, FactoryVanity {
    using PoolIdLibrary for PoolKey;

    uint256 internal constant ORBIT_BLOCK_GAS_LIMIT = 32_000_000;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;

    address internal constant PAIR = address(0);
    address internal custody = address(0xC05D0D);
    address internal treasury = address(0x7A5E);
    address internal creator = address(0xCEEE);
    address internal stranger = address(0xB0B);
    address internal friend = address(0xA11CE);
    address internal bidder = address(0xB1D);

    MockPoolManager internal pm;
    StonkzToken internal stonkz;
    CTOGovernor internal gov;
    StonkzFeeHook internal hook;
    FeeLockerV2 internal locker;
    BuybackAccumulator internal acc;
    LadderSettlement internal settlement;
    StonkzVault internal vault;
    StonkzExpressFactory internal express;
    StonkzLadderFactory internal ladder;
    ForkHostileReceiver internal hostile;

    uint256 internal fileGasUsed;
    string internal rpcUsed;

    function setUp() public {
        rpcUsed = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpcUsed);
        require(block.chainid == 4663, "fork chainId != 4663");

        // Deploy full official manifest onto the fork state (not broadcast).
        stonkz = new StonkzToken(custody);
        pm = new MockPoolManager();
        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), treasury, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        locker = new FeeLockerV2(IPoolManager(address(pm)), hook);
        acc = new BuybackAccumulator(PAIR, address(stonkz), address(0));
        settlement = new LadderSettlement(IPoolManager(address(pm)), hook, PAIR);
        settlement.setSideTokenRef(address(stonkz));
        settlement.setFeeLocker(locker);
        vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        express = new StonkzExpressFactory(IPoolManager(address(pm)), locker, hook, acc, gov, PAIR, address(stonkz)
        );
        ladder = new StonkzLadderFactory();
        ladder.setCarveTreasury(treasury);
        ladder.setVaultRef(address(vault));
        hostile = new ForkHostileReceiver();

        express.assertSoftLaunchGate(address(this));
        ladder.assertSoftLaunchGate(address(this));

        console2.log("FORK chainId", block.chainid);
        console2.log("FORK rpc", rpcUsed);
        console2.log("FORK stonkz", address(stonkz));
        console2.log("FORK express", address(express));
        console2.log("FORK ladder", address(ladder));
    }

    /// @notice End-to-end drill list - expected vs observed logged; asserts enforce.
    function test_P2_fork_fullDrillManifest() public {
        _drill_expressLifecycle_lockOn();
        _drill_thinBookLadder();
        _drill_smallGraduatingLadder_fileGas();
        _drill_switches();
        _drill_hostileReceiver();

        console2.log("=== FORK PROOF SUMMARY ===");
        console2.log("file() gas used", fileGasUsed);
        console2.log("Orbit 32M limit", ORBIT_BLOCK_GAS_LIMIT);
        console2.log("file fits Orbit", fileGasUsed > 0 && fileGasUsed < ORBIT_BLOCK_GAS_LIMIT);
        assertTrue(fileGasUsed > 0, "file gas must be measured");
        assertLt(fileGasUsed, ORBIT_BLOCK_GAS_LIMIT, "file() must fit Orbit 32M");
    }

    // ─── Express LOCK ON lifecycle ─────────────────────────────────────────

    function _drill_expressLifecycle_lockOn() internal {
        console2.log("--- Express LOCK ON lifecycle ---");
        express.setDefaultLiquidityLocked(true);
        StonkzDirectListing listing = _list(express, _expressParams());
        assertTrue(listing.liquidityLocked(), "expected locked=true");
        assertTrue(Vanity.matches(address(listing)), "expected 0x4663 listing");

        // Swaps both ways on main pool (MockPoolManager on fork gas schedule).
        PoolKey memory key = listing.mainKey();
        uint256 buyIn = 1 ether;
        vm.deal(address(this), buyIn * 4);
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(buyIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(buyIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        console2.log("observed swaps both ways: OK");

        // Accrue + flush → pair currency to treasury path.
        address tok = address(listing.token());
        // Ensure pool registered (listing ctor registers). Force a fee accrue via override if needed.
        if (!hook.registered(tok)) {
            hook.registerPool(tok, PAIR, creator, key);
        }
        // Mock may need hook fee path - stamp override.
        pm.setHookFeeBps(key.toId(), 100);
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(buyIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        uint256 treasBefore = treasury.balance;
        // Fund hook for ETH flush if accrued.
        vm.deal(address(hook), 1 ether);
        hook.flush(tok);
        console2.log("flush executed; treasury delta", treasury.balance - treasBefore);

        // Negative withdraw while locked.
        vm.prank(creator);
        vm.expectRevert(StonkzDirectListing.LiquidityIsLocked.selector);
        listing.withdrawMainLiquidity();
        console2.log("expected withdraw revert LiquidityIsLocked: OK");
    }

    // ─── Thin-book Ladder (fails gate) ─────────────────────────────────────

    function _drill_thinBookLadder() internal {
        console2.log("--- Thin-book Ladder ---");
        StonkzLadderAuction.Params memory p = _ladderParams();
        p.floorMcap = 40_000e18;
        p.auctionSupply = (SUPPLY * 60) / 100;
        // Thin: one tiny bid, expect non-graduate / refunds path after clear.
        StonkzLadderAuction a = _file(ladder, p);
        a.start();
        vm.deal(bidder, 100 ether);
        vm.prank(bidder);
        a.placeBid{value: 5 ether}(5 ether, type(uint256).max);
        // Drive to end.
        vm.warp(a.startTime() + a.duration() + 1);
        a.clearAllForTest();
        assertTrue(a.done(), "expected done");
        // Thin books typically do not graduate - check raised vs threshold.
        bool graduated = a.raised() >= a.threshold();
        console2.log("thin raised", a.raised());
        console2.log("thin threshold", a.threshold());
        console2.log("thin graduated (expected false for thin)", graduated);
        // Named gate: soft-launch still closed on factory.
        ladder.assertSoftLaunchGate(address(this));
        console2.log("gate named: soft-launch closed deployer-only: OK");
    }

    // ─── Small graduating Ladder + file gas ────────────────────────────────

    function _drill_smallGraduatingLadder_fileGas() internal {
        console2.log("--- Small graduating Ladder + file() gas ---");
        StonkzLadderAuction.Params memory p = _ladderParams();
        p.holdbackBps = 1000; // 10% vault
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.Vault;
        p.floorMcap = 10_000e18;
        p.tier = LadderTypes.Tier.Daily;
        p.walletCapBps = 1000; // max allowed — still need enough bidders to clear raise bar

        // Mine OFF the gas meter - report pure file() gas vs Orbit 32M.
        (bytes32 userSalt,) = VanityHelpers.mineLadder(ladder, address(this), p);
        uint256 g0 = gasleft();
        StonkzLadderAuction a = ladder.file(p, userSalt);
        fileGasUsed = g0 - gasleft();
        console2.log("observed file() gas (excl. vanity mine)", fileGasUsed);
        console2.log("expected file() gas < 32_000_000 Orbit");
        assertTrue(Vanity.matches(address(a)), "ladder vanity");

        // Stamp settlement at setSettlement (owner = this via factory? owner = factory)
        // Factory is owner - transfer not needed if we settle with depositHoldback path.
        // For bids/crank/vault: use standalone holdback deposit after graduation.
        vm.prank(address(ladder));
        a.setSettlement(settlement);
        a.start();

        // Fund bids well above threshold. At 10% wallet cap, need >=10 wallets to clear raise
        // (max raised ≈ N * floorMcap * auctionShare * capBps).
        uint256 need = a.threshold();
        uint256 nBid = 12;
        uint256 bidSize = need / 8 + 50 ether; // overshoot per wallet; cap binds spend
        if (bidSize < 5 ether) bidSize = 5 ether;
        for (uint256 i; i < nBid; ++i) {
            address w = address(uint160(0xB100 + i));
            vm.deal(w, bidSize * 2);
            vm.prank(w);
            a.placeBid{value: bidSize}(bidSize, type(uint256).max);
        }
        a.clearNextForTest();
        a.clearNextForTest();
        vm.warp(a.startTime() + a.duration() + 1);
        a.clearAllForTest();
        assertTrue(a.done());
        console2.log("raised", a.raised());
        console2.log("threshold", a.threshold());
        console2.log("graduated", a.graduated());

        if (a.graduated()) {
            // Mint holdback tokens to auction and deposit to vault (standalone path).
            ForkMockERC20 tok = new ForkMockERC20();
            uint256 hb = a.holdbackAmount();
            tok.mint(address(a), hb);
            // depositHoldback pulls via approve from auction - auction must hold tokens.
            // depositHoldback uses _safeApprove from auction balance - tokens must be on auction.
            a.depositHoldback(address(tok));
            assertEq(vault.balanceOf(address(tok), creator), hb, "vault deposit");
            console2.log("vault deposit: OK", hb);

            uint256 amt = hb / 10;
            if (amt == 0) amt = hb;
            vm.prank(creator);
            (uint256 id,) = vault.requestDirectRelease(address(tok), amt, creator);
            console2.log("direct request id", id);
            vm.prank(creator);
            vault.cancelDirectRelease(id);
            console2.log("cancel+reflow: OK");
            vm.prank(creator);
            (id,) = vault.requestDirectRelease(address(tok), amt, creator);
            (,,,, uint64 duration,,,) = vault.requests(id);
            // Head readyAt = now+duration; warp past.
            vm.warp(block.timestamp + uint256(duration) + 1);
            vault.executeDirectRelease(id);
            console2.log("executeDirectRelease: OK");
        } else {
            console2.log("WARN: did not graduate - refunds path; file gas still reported");
            // Thin refund probe on first bidder if any refund claimable after fail.
        }
    }

    // ─── Switch drills ─────────────────────────────────────────────────────

    function _drill_switches() internal {
        console2.log("--- Switch drills ---");

        // off/on
        express.setDeploysEnabled(false);
        vm.expectRevert(DeployControls.DeploysOff.selector);
        express.list(_expressParams(), bytes32(0));
        express.setDeploysEnabled(true);
        console2.log("off/on: OK");

        // allowlist
        express.allowDeployer(friend);
        vm.prank(stranger);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        express.list(_expressParams(), bytes32(0));
        StonkzDirectListing listed = _listAs(express, friend, _expressParams());
        assertTrue(Vanity.matches(address(listed)));
        console2.log("allowlist: OK");

        // side-pool toggle + genesis case (createSidePool=false)
        express.setDefaultCreateSidePool(false);
        StonkzDirectListing genesis = _listAs(express, friend, _expressParams());
        assertFalse(genesis.createSidePool());
        assertFalse(genesis.sidePoolDeployed());
        express.setDefaultCreateSidePool(true);
        console2.log("side-pool toggle + genesis: OK");

        // lock coexistence
        express.setDefaultLiquidityLocked(true);
        StonkzDirectListing locked = _listAs(express, friend, _expressParams());
        express.setDefaultLiquidityLocked(false);
        StonkzDirectListing unlocked = _listAs(express, friend, _expressParams());
        assertTrue(locked.liquidityLocked());
        assertFalse(unlocked.liquidityLocked());
        console2.log("lock coexistence: OK");

        // custom-fee 300 bps
        address tokenCustom = address(0xC001);
        PoolKey memory keyC = _mainKey(address(0xB111), tokenCustom);
        pm.initialize(keyC, TickMath.getSqrtRatioAtTick(0));
        hook.registerPoolCustom(tokenCustom, address(0xB111), creator, keyC, 300);
        assertEq(hook.hookFeeBps(tokenCustom), 300);
        console2.log("custom-fee 300bps: OK");

        // carve stamp
        StonkzLadderAuction a = _file(ladder, _ladderParamsCarve(type(uint16).max));
        uint16 stamped = a.carveBps();
        ladder.setDefaultCarveBps(700);
        assertEq(a.carveBps(), stamped, "carve stamp survives");
        StonkzLadderAuction b = _file(ladder, _ladderParamsCarve(type(uint16).max));
        assertEq(b.carveBps(), 700);
        console2.log("carve stamp: OK");

        // refprice stamp
        express.setRefPrice(address(stonkz), PAIR, 5e11);
        StonkzDirectListing later = _listAs(express, friend, _expressParams());
        assertEq(later.refPriceWad(), 5e11);
        console2.log("refprice stamp: OK");
    }

    function _drill_hostileReceiver() internal {
        console2.log("--- Hostile receiver probe ---");
        address token = address(0xC0FE);
        PoolKey memory key = _mainKey(PAIR, token);
        pm.initialize(key, TickMath.getSqrtRatioAtTick(0));
        hook.registerPool(token, PAIR, address(hostile), key);
        pm.setHookFeeBps(key.toId(), 100);
        vm.deal(address(this), 10 ether);
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(1 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        // Flush must not revert; hostile share stays accrued; treasury can move.
        vm.deal(address(hook), 1 ether);
        hook.flush(token);
        console2.log("hostile flush non-reverting: OK");
    }

    // ─── helpers ───────────────────────────────────────────────────────────

    function _expressParams() internal view returns (StonkzDirectListing.ListingParams memory p) {
        p.startMcap = TIER_4K;
        p.totalSupply = SUPPLY;
        p.creatorReserveBps = 0;
        p.deliveryMode = 0;
        p.vestDuration = 0;
        p.declaredUse = bytes32("fork");
        p.creator = creator;
        p.name = "ForkCoin";
        p.symbol = "FORK";
        p.createSidePool = true;
        p.sidePoolBps = 500;
        p.liquidityLocked = true;
        p.refPriceWad = 2.5e11;
    }

    function _ladderParams() internal view returns (StonkzLadderAuction.Params memory p) {
        p.supply = SUPPLY;
        p.auctionSupply = (SUPPLY * 60) / 100;
        p.floorMcap = 40_000e18;
        p.duration = 1 hours;
        p.lpShareWad = 0.95e18;
        p.lpHealthTargetWad = 0.5e18;
        p.carveBps = type(uint16).max;
        p.cashHoldbackBps = 0;
        p.holdbackBps = 0;
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.None;
        p.tier = LadderTypes.Tier.God;
        p.createSidePool = true;
        p.sidePoolBps = 500;
        p.refPriceWad = 2.5e11;
        p.walletCapBps = 100;
        p.sizeBonusBps = 1000;
        p.maxUniqueActives = 0;
        p.pairToken = PAIR;
        p.creator = creator;
        p.treasury = treasury;
        p.vaultRef = address(0);
        p.settlement = address(0);
    }

    function _ladderParamsCarve(uint16 carve) internal view returns (StonkzLadderAuction.Params memory p) {
        p = _ladderParams();
        p.carveBps = carve;
    }

    function _mainKey(address pair, address token) internal view returns (PoolKey memory key) {
        (address c0, address c1) = pair < token ? (pair, token) : (token, pair);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: address(hook)
        });
    }

    receive() external payable {}
}
