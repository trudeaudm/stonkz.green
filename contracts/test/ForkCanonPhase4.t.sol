// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "@v4-core/src/interfaces/IProtocolFees.sol";
import {ProtocolFeeLibrary} from "@v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {PoolKey as CanonPoolKey} from "@v4-core/src/types/PoolKey.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";
import {Currency as CanonCurrency} from "@v4-core/src/types/Currency.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {PoolKey, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {BuybackAccumulator, IBuyExecutor} from "../src/BuybackAccumulator.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
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
import {StonkzLaunchToken} from "../src/StonkzLaunchToken.sol";

/// @dev Reverting ETH receiver - flush must not brick treasury path (hostile probe).
contract ForkHostileReceiver {
    error Nope();

    receive() external payable {
        revert Nope();
    }
}

/// @dev 1:1 pair→side executor for fork accumulator fund→crank→burn (V4 buy path unset).
contract ForkMockBuyExecutor is IBuyExecutor {
    ForkMockERC20 public immutable side;
    uint256 public outWad = 1e18;

    constructor(ForkMockERC20 side_) {
        side = side_;
    }

    function buyExactIn(uint256 amountIn, uint256 minAmountOut) external payable returns (uint256 amountOut) {
        amountOut = (amountIn * outWad) / 1e18;
        require(amountOut >= minAmountOut, "slip");
        side.transfer(msg.sender, amountOut);
    }

    receive() external payable {}
}

/// @dev Minimal ERC20 for vault holdback + hostile-probe pool currency.
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

/// @dev Minimal V4FeeAdapter surface (RH protocolFeeController).
interface IV4FeeAdapter {
    function policy() external view returns (address);
    function POOL_MANAGER() external view returns (address);
    function TOKEN_JAR() external view returns (address);
    function feeSetter() external view returns (address);
    function owner() external view returns (address);
    function ZERO_FEE_SENTINEL() external view returns (uint24);
    function getFee(CanonPoolKey memory key) external view returns (uint24);
}

/// @title ForkCanonPhase4 - V4-CANON Phase 4 fork gate vs RH singleton PoolManager
/// @notice In-memory fork only - no mainnet broadcast. Requires network RPC.
///         Run: forge test --match-contract ForkCanonPhase4 -vvv
///         RPC: $env:ROBINHOOD_RPC_URL or https://rpc.mainnet.chain.robinhood.com
/// @dev Production path under test uses V4Adapter wrapping the deployed singleton
///      (NOT MockPoolManager). Hook CREATE2-mined to flag-valid 0x088 address.
contract ForkCanonPhase4 is Test {
    using PoolIdLibrary for PoolKey;

    // --- RH Chain 4663 pins (docs / V4-CANON Phase 4) ---------------------
    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant UNIVERSAL_ROUTER = 0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 internal constant ORBIT_BLOCK_GAS_LIMIT = 32_000_000;
    /// @dev Launch-deploy Phase 2 mock figure (vanity CREATE2 file) for comparison.
    uint256 internal constant MOCK_FILE_GAS_REF = 29_300_052;
    uint256 internal constant SUPPLY = 1_000_000 ether;
    uint256 internal constant TIER_4K = 4000e18;
    uint256 internal constant ETH_LIST_BUFFER = 1 ether;

    address internal constant PAIR = address(0);
    address internal custody = address(0xC05D0D);
    address internal treasury = address(0x7A5E);
    address internal creator = address(0xCEEE);
    address internal stranger = address(0xB0B);
    address internal friend = address(0xA11CE);
    address internal bidder = address(0xB1D);

    ICanonPM internal manager;
    V4Adapter internal adapter;
    IPoolManager internal pm; // adapter as IPoolManager - production path

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
    uint256 internal listSaltNonce;
    string internal rpcUsed;
    address internal feeController;
    uint24 internal sidePoolProtocolFeePacked;
    uint24 internal mainPoolProtocolFeePacked;

    function setUp() public {
        rpcUsed = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpcUsed);
        require(block.chainid == 4663, "fork chainId != 4663");

        manager = ICanonPM(RH_POOL_MANAGER);
        require(address(manager).code.length > 0, "RH PM missing code");
        require(UNIVERSAL_ROUTER.code.length > 0, "UR pin missing code");
        require(PERMIT2.code.length > 0, "Permit2 pin missing code");

        adapter = new V4Adapter(manager);
        pm = IPoolManager(address(adapter));

        stonkz = new StonkzToken(custody);
        gov = new CTOGovernor();
        hook = _deployFlagHook();
        hook.bindCanonManager(manager);
        gov.setRegistry(hook);
        locker = new FeeLockerV2(pm, hook);
        acc = new BuybackAccumulator(PAIR, address(stonkz), address(0));
        settlement = new LadderSettlement(pm, hook, PAIR);
        settlement.setSideTokenRef(address(stonkz));
        settlement.setFeeLocker(locker);
        vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        // Express: production requires sideTokenRef from birth (STONKZ_REF / stand-in).
        // Park-on-unset RETIRED (PREDEPLOY-REFIT Phase 3a) — fork drills the set-ref path only.
        express = new StonkzExpressFactory(pm, locker, hook, acc, gov, PAIR, address(stonkz));
        ladder = new StonkzLadderFactory();
        ladder.setVaultRef(address(vault));
        ladder.setSideTokenRef(address(stonkz));
        hostile = new ForkHostileReceiver();

        express.assertSoftLaunchGate(address(this));
        ladder.assertSoftLaunchGate(address(this));

        _probeProtocolFeeController();

        console2.log("FORK chainId", block.chainid);
        console2.log("FORK rpc", rpcUsed);
        console2.log("FORK PM singleton", RH_POOL_MANAGER);
        console2.log("FORK adapter", address(adapter));
        console2.log("FORK hook (flags)", address(hook));
        console2.log("FORK UR", UNIVERSAL_ROUTER);
        console2.log("FORK Permit2", PERMIT2);
        console2.log("FORK feeController", feeController);
        console2.log("FORK express", address(express));
        console2.log("FORK ladder", address(ladder));
    }

    /// @notice End-to-end drill list - adapted from launch-deploy ForkProofPhase2.
    function test_P4_fork_fullDrillManifest() public {
        _drill_expressLifecycle_lockOn_urStyleSwap();
        _drill_thinBookLadder();
        _drill_smallGraduatingLadder_fileGas_settleVault();
        _drill_switches();
        _drill_hostileReceiver();
        _drill_accumulatorFundCrankBurn();

        console2.log("=== FORK CANON PHASE 4 SUMMARY ===");
        console2.log("file() gas used", fileGasUsed);
        console2.log("mock Phase2 file() ref", MOCK_FILE_GAS_REF);
        console2.log("Orbit 32M limit", ORBIT_BLOCK_GAS_LIMIT);
        console2.log("file fits Orbit", fileGasUsed > 0 && fileGasUsed < ORBIT_BLOCK_GAS_LIMIT);
        console2.log("side protocolFee packed", uint256(sidePoolProtocolFeePacked));
        console2.log("main protocolFee packed", uint256(mainPoolProtocolFeePacked));
        assertTrue(fileGasUsed > 0, "file gas must be measured");
        assertLt(fileGasUsed, ORBIT_BLOCK_GAS_LIMIT, "file() must fit Orbit 32M");
    }

    function test_P4_protocolFeeController_sidePoolExposure() public view {
        assertTrue(feeController != address(0), "controller set on RH PM");
        assertEq(IV4FeeAdapter(feeController).POOL_MANAGER(), RH_POOL_MANAGER);
        // Main LP fee 0 -> no Uniswap protocol take (docs/06 architecture).
        assertEq(mainPoolProtocolFeePacked, 0, "main LP0 protocol fee");
        // Side LP 3000 pips: native-math schedule -> 5bp each direction (500 pips).
        uint16 zfo = ProtocolFeeLibrary.getZeroForOneFee(sidePoolProtocolFeePacked);
        uint16 ofo = ProtocolFeeLibrary.getOneForZeroFee(sidePoolProtocolFeePacked);
        assertEq(zfo, 500, "side zfo 5bp");
        assertEq(ofo, 500, "side ofo 5bp");
        assertLe(zfo, 500, "side exposure <=5bp");
        assertLe(ofo, 500, "side exposure <=5bp");
    }

    // =======================================================================
    // drills
    // =======================================================================

    function _drill_expressLifecycle_lockOn_urStyleSwap() internal {
        console2.log("--- Express LOCK ON + UR-style adapter swap ---");
        express.setDefaultLiquidityLocked(true);
        StonkzDirectListing listing = _list(express, _expressParams());
        assertTrue(listing.liquidityLocked(), "expected locked=true");
        // Factories on v4-canon do not enforce 0x4663 vanity - plain CREATE2 salts OK.
        assertTrue(HookVanity.flagsOf(address(hook)) == HookVanity.HOOK_FLAGS, "hook flags");

        PoolKey memory key = listing.mainKey();
        assertEq(key.hooks, address(hook), "PoolKey.hooks bound (no setPoolHook)");

        // Express production ask sits ABOVE spot (token-only). zeroForOne buys need cash
        // BELOW the live tick. Seed a thin ETH bid for this drill only so adapter.swap
        // (UR unlock/settle path) can complete both ways against the singleton.
        // Near-boundary cash may still take a token1 dust — pre-approve via deal.
        StonkzLaunchToken tok = listing.token();
        deal(address(tok), address(this), 1_000 ether);
        tok.approve(address(adapter), type(uint256).max);

        (, int24 liveTick,,) = adapter.getSlot0(key.toId());
        int24 cashHi = _alignDown(liveTick, 60) - 60 * 5; // well below live tick
        int24 cashLo = cashHi - 60 * 20;
        if (cashLo < _alignDown(TickMath.MIN_TICK, 60)) {
            cashLo = _alignDown(TickMath.MIN_TICK, 60);
        }
        require(cashHi > cashLo, "cash range");
        vm.deal(address(this), 5 ether);
        adapter.modifyLiquidity{value: 1 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: cashLo, tickUpper: cashHi, liquidityDelta: int256(1e15), salt: bytes32("drillcash")
            }),
            ""
        );
        console2.log("seeded drill cash bid below live tick");

        uint256 buyIn = 0.05 ether;
        // Buy (ETH->token): UR-equivalent unlock via V4Adapter. zeroForOne limit toward MIN.
        adapter.swap{value: buyIn * 2}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(buyIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        console2.log("observed UR-style buy via adapter: OK");

        // Buy proves UR-equivalent unlock/settle vs singleton + hook fee take.
        // Sell (token exact-in, fee on ETH unspecified) needs output-denominated fee math;
        // skip here — FeeHookPhase1 covers exact-out pair-side; buy path is the production
        // Express flow (pair in -> token out).
        console2.log("UR-style sell skipped (pair-out fee denom); buy path OK");

        // Accrue path already ran in beforeSwap; flush protocol share to treasury.
        uint256 treasBefore = treasury.balance;
        uint256 accrued = hook.receiverPairProceeds(address(tok)) + hook.tokenPairProceeds(address(tok));
        console2.log("accrued pair proceeds", accrued);
        hook.flush(address(tok));
        console2.log("flush executed; treasury delta", treasury.balance - treasBefore);

        vm.prank(creator);
        vm.expectRevert(StonkzDirectListing.LiquidityIsLocked.selector);
        listing.withdrawMainLiquidity();
        console2.log("expected withdraw revert LiquidityIsLocked: OK");
    }

    function _drill_thinBookLadder() internal {
        console2.log("--- Thin-book Ladder ---");
        StonkzLadderAuction.Params memory p = _ladderParams();
        p.floorMcap = 40_000e18;
        p.auctionSupply = (SUPPLY * 60) / 100;
        StonkzLadderAuction a = ladder.file(p);
        a.start();
        vm.deal(bidder, 100 ether);
        vm.prank(bidder);
        a.placeBid{value: 5 ether}(5 ether, type(uint256).max);
        vm.warp(a.startTime() + a.duration() + 1);
        a.clearAllForTest();
        assertTrue(a.done(), "expected done");
        bool graduated = a.raised() >= a.threshold();
        console2.log("thin raised", a.raised());
        console2.log("thin threshold", a.threshold());
        console2.log("thin graduated (expected false for thin)", graduated);
        assertFalse(a.graduated(), "thin must not graduate");
        ladder.assertSoftLaunchGate(address(this));
        console2.log("gate named: soft-launch closed deployer-only: OK");
    }

    function _drill_smallGraduatingLadder_fileGas_settleVault() internal {
        console2.log("--- Small graduating Ladder + file() gas + settle/vault ---");
        StonkzLadderAuction.Params memory p = _ladderParams();
        p.holdbackBps = 1000; // 10% vault
        p.holdbackDelivery = LadderConstants.HoldbackDelivery.Vault;
        p.floorMcap = 10_000e18;
        p.tier = LadderTypes.Tier.Daily;
        p.walletCapBps = 1000;

        // Fresh settlement instance (LadderSettlement is single-use).
        LadderSettlement settleInst = new LadderSettlement(pm, hook, PAIR);
        settleInst.setSideTokenRef(address(stonkz));
        settleInst.setFeeLocker(locker);

        uint256 g0 = gasleft();
        StonkzLadderAuction a = ladder.file(p);
        fileGasUsed = g0 - gasleft();
        console2.log("observed file() gas (no vanity mine on this branch)", fileGasUsed);
        console2.log("compare mock Phase2 file()", MOCK_FILE_GAS_REF);
        console2.log("expected file() gas < 32_000_000 Orbit");

        vm.prank(address(ladder));
        a.setSettlement(settleInst);
        a.start();

        uint256 need = a.threshold();
        uint256 nBid = 12;
        uint256 bidSize = need / 8 + 50 ether;
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
            ForkMockERC20 tok = new ForkMockERC20();
            uint256 unsold = a.auctionSupply() > a.soldTokens() ? a.auctionSupply() - a.soldTokens() : 0;
            uint256 side = (unsold * a.sidePoolBps()) / 10_000;
            uint256 mainAsk = unsold - side;
            uint256 hb = a.holdbackAmount();
            tok.mint(address(settleInst), hb + mainAsk + side);

            a.settle(address(tok));
            assertTrue(settleInst.askLiquidity() > 0 || settleInst.cashLiquidity() > 0, "settle LP");
            assertEq(vault.balanceOf(address(tok), creator), hb, "vault deposit via settle");
            console2.log("settle + vault deposit: OK", hb);

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
            vm.warp(block.timestamp + uint256(duration) + 1);
            vault.executeDirectRelease(id);
            console2.log("executeDirectRelease: OK");
        } else {
            console2.log("WARN: did not graduate - refunds path; file gas still reported");
        }
    }

    function _drill_switches() internal {
        console2.log("--- Switch drills ---");

        express.setDeploysEnabled(false);
        vm.expectRevert(DeployControls.DeploysOff.selector);
        express.list{value: ETH_LIST_BUFFER}(_expressParams(), bytes32(0));
        express.setDeploysEnabled(true);
        console2.log("off/on: OK");

        express.allowDeployer(friend);
        vm.deal(stranger, ETH_LIST_BUFFER);
        vm.prank(stranger);
        vm.expectRevert(DeployControls.DeployerNotAllowed.selector);
        express.list{value: ETH_LIST_BUFFER}(_expressParams(), bytes32(uint256(1)));
        StonkzDirectListing listed = _listAs(express, friend, _expressParams());
        assertTrue(address(listed.token()) != address(0));
        console2.log("allowlist: OK");

        express.setDefaultCreateSidePool(false);
        StonkzDirectListing genesis = _listAs(express, friend, _expressParams());
        assertFalse(genesis.createSidePool());
        assertFalse(genesis.sidePoolDeployed());
        express.setDefaultCreateSidePool(true);
        console2.log("side-pool toggle + genesis: OK");

        express.setDefaultLiquidityLocked(true);
        StonkzDirectListing locked = _listAs(express, friend, _expressParams());
        express.setDefaultLiquidityLocked(false);
        StonkzDirectListing unlocked = _listAs(express, friend, _expressParams());
        assertTrue(locked.liquidityLocked());
        assertFalse(unlocked.liquidityLocked());
        express.setDefaultLiquidityLocked(true);
        console2.log("lock coexistence: OK");

        // Custom-fee 300 bps - stamp only (owner); no setPoolHook.
        address tokenCustom = address(uint160(0xC001));
        PoolKey memory keyC = _mainKey(address(0xB111), tokenCustom);
        adapter.initialize(keyC, TickMath.getSqrtRatioAtTick(0));
        hook.registerPoolCustom(tokenCustom, address(0xB111), creator, keyC, 300);
        assertEq(hook.hookFeeBps(tokenCustom), 300);
        console2.log("custom-fee 300bps: OK");

        StonkzLadderAuction a = ladder.file(_ladderParamsCarve(type(uint16).max));
        uint16 stamped = a.carveBps();
        ladder.setDefaultCarveBps(700);
        assertEq(a.carveBps(), stamped, "carve stamp survives");
        StonkzLadderAuction b = ladder.file(_ladderParamsCarve(type(uint16).max));
        assertEq(b.carveBps(), 700);
        console2.log("carve stamp: OK");

        express.setRefPrice(address(stonkz), PAIR, 5e11);
        StonkzDirectListing later = _listAs(express, friend, _expressParams());
        assertEq(later.refPriceWad(), 5e11);
        console2.log("refprice stamp: OK");
    }

    function _drill_hostileReceiver() internal {
        console2.log("--- Hostile receiver probe ---");
        ForkMockERC20 tok = new ForkMockERC20();
        address token = address(tok);
        // Seed liquidity so a real-PM swap can complete (beforeSwap still accrues).
        PoolKey memory key = _mainKey(PAIR, token);
        uint160 mid = TickMath.getSqrtRatioAtTick(0);
        adapter.initialize(key, mid);
        hook.registerPool(token, PAIR, address(hostile), key);

        tok.mint(address(this), 1_000_000 ether);
        tok.approve(address(adapter), type(uint256).max);
        // ETH cash below spot so zeroForOne buy can hit liquidity (pair=ETH=c0).
        int24 lo = int24(-60 * 100);
        int24 hi = int24(-60);
        vm.deal(address(this), 10 ether);
        adapter.modifyLiquidity{value: 2 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: lo, tickUpper: hi, liquidityDelta: int256(1e15), salt: bytes32("hostile")
            }),
            ""
        );

        adapter.swap{value: 2 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(0.1 ether),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        // Flush must not revert; hostile share stays accrued; treasury can move.
        hook.flush(token);
        console2.log("hostile flush non-reverting: OK");
    }

    /// @notice Accumulator v2 fund→crank→burn on the fork (mock executor; real PM for spot).
    function _drill_accumulatorFundCrankBurn() internal {
        console2.log("--- Accumulator fund -> crank -> burn ---");
        address dead = address(0x000000000000000000000000000000000000dEaD);
        ForkMockERC20 side = new ForkMockERC20();
        ForkMockBuyExecutor exec = new ForkMockBuyExecutor(side);
        side.mint(address(exec), 1_000_000 ether);

        BuybackAccumulator a2 = new BuybackAccumulator(PAIR, address(side), address(0));
        a2.setPoolManager(address(adapter));
        a2.setExecutor(address(exec));
        a2.setKeeper(friend);

        // Spot pool for slippage bound (1:1).
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(PAIR),
            currency1: Currency.wrap(address(side)),
            fee: 3000,
            tickSpacing: 60,
            hooks: address(0)
        });
        require(PAIR < address(side), "curr order");
        adapter.initialize(key, uint160(1) << 96);
        a2.setBuyPoolKey(key);

        vm.deal(address(this), address(this).balance + 100 ether);
        a2.fundETH{value: 100 ether}();
        assertEq(a2.pairBalance(), 100 ether);

        vm.prank(friend);
        (uint256 inAmt, uint256 outAmt, uint256 burned) = a2.crank(200); // 2%
        assertEq(inAmt, 2 ether);
        assertEq(outAmt, 2 ether);
        assertEq(burned, 2 ether);
        assertEq(a2.pairBalance(), 98 ether);
        assertEq(a2.totalBurned(), 2 ether);
        assertEq(side.balanceOf(dead), 2 ether);
        console2.log("accumulator fund->crank->burn: OK");
    }

    // =======================================================================
    // helpers
    // =======================================================================

    function _deployFlagHook() internal returns (StonkzFeeHook h) {
        bytes memory creation = abi.encodePacked(
            type(StonkzFeeHook).creationCode, abi.encode(pm, treasury, ICTOGovernor(address(gov)))
        );
        bytes32 initCodeHash = keccak256(creation);
        bytes32 salt;
        address predicted;
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        bool found;
        for (uint256 i; i < 1_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
            );
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no flag salt");
        h = new StonkzFeeHook{salt: salt}(pm, treasury, ICTOGovernor(address(gov)));
        require(address(h) == predicted, "flag create2");
        h.validateHookAddress(address(h));
    }

    function _probeProtocolFeeController() internal {
        feeController = IProtocolFees(address(manager)).protocolFeeController();
        console2.log("protocolFeeController", feeController);
        if (feeController == address(0) || feeController.code.length == 0) {
            console2.log("WARN: no fee controller code");
            return;
        }
        IV4FeeAdapter ctrl = IV4FeeAdapter(feeController);
        console2.log("adapter.policy", ctrl.policy());
        console2.log("adapter.TOKEN_JAR", ctrl.TOKEN_JAR());
        console2.log("adapter.feeSetter", ctrl.feeSetter());
        console2.log("adapter.owner", ctrl.owner());

        // Side pool key shape: LP fee 3000 pips, no hook.
        CanonPoolKey memory sideKey = CanonPoolKey({
            currency0: CanonCurrency.wrap(address(0)),
            currency1: CanonCurrency.wrap(address(1)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });
        sidePoolProtocolFeePacked = ctrl.getFee(sideKey);

        // Main pool key shape: LP fee 0 + flag-valid hooks.
        CanonPoolKey memory mainKey = CanonPoolKey({
            currency0: CanonCurrency.wrap(address(0)),
            currency1: CanonCurrency.wrap(address(1)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(uint160(HookVanity.HOOK_FLAGS)))
        });
        mainPoolProtocolFeePacked = ctrl.getFee(mainKey);

        console2.log(
            "side getFee zfo/ofo",
            ProtocolFeeLibrary.getZeroForOneFee(sidePoolProtocolFeePacked),
            ProtocolFeeLibrary.getOneForZeroFee(sidePoolProtocolFeePacked)
        );
        console2.log("main getFee packed", uint256(mainPoolProtocolFeePacked));
    }

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

    function _alignDown(int24 tick, int24 spacing) internal pure returns (int24) {
        int24 rem = tick % spacing;
        if (rem < 0) rem += spacing;
        return rem == 0 ? tick : tick - rem;
    }

    function _list(StonkzExpressFactory factory, StonkzDirectListing.ListingParams memory p)
        internal
        returns (StonkzDirectListing listing)
    {
        vm.deal(address(this), address(this).balance + ETH_LIST_BUFFER);
        // Plain userSalt - factories on this branch do not enforce vanity prefix.
        listing = factory.list{value: ETH_LIST_BUFFER}(p, bytes32(++listSaltNonce));
    }

    function _listAs(StonkzExpressFactory factory, address who, StonkzDirectListing.ListingParams memory p)
        internal
        returns (StonkzDirectListing listing)
    {
        vm.deal(who, ETH_LIST_BUFFER + 0.1 ether);
        bytes32 salt = bytes32(++listSaltNonce);
        vm.prank(who);
        listing = factory.list{value: ETH_LIST_BUFFER}(p, salt);
    }

    receive() external payable {}
}
