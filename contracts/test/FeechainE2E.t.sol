// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../src/mock/MockPoolManager.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";
import {FeeLocker} from "../legacy/FeeLocker.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";
import {StonkzLiquidityStrategy} from "../legacy/StonkzLiquidityStrategy.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {TickMath} from "../src/v4/TickMath.sol";

/// @title FeechainE2E — FEECHAIN Phase 4 end-to-end: settle → swap → flush → side compound.
contract FeechainE2E is Test {
    using PoolIdLibrary for PoolKey;

    MockPoolManager internal pm;
    StonkzFeeHook internal hook;
    CTOGovernor internal gov;
    BuybackAccumulator internal acc;
    FeeLocker internal locker;
    StonkzLiquidityStrategy internal strategy;

    address internal constant PAIR = address(0); // native — flush exercises real ETH balances
    address internal constant USER = address(0xB222);
    address internal constant STONKZ = address(0x4663);
    address payable internal treasury;
    address payable internal creator;

    function setUp() public {
        vm.etch(STONKZ, hex"00");
        pm = new MockPoolManager();
        vm.deal(address(pm), 1_000_000 ether);
        treasury = payable(address(0x7A5E));
        creator = payable(address(0xCEEE));
        vm.deal(treasury, 0);
        vm.deal(creator, 0);

        gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), treasury, ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        acc = new BuybackAccumulator(PAIR, STONKZ, address(0));
        locker = new FeeLocker(IPoolManager(address(pm)), acc, address(0));
        strategy = new StonkzLiquidityStrategy(
            IPoolManager(address(pm)), acc, locker, hook, PAIR, STONKZ
        );
    }

    function _readMain() internal view returns (PoolKey memory key) {
        (Currency c0, Currency c1, uint24 fee, int24 spacing, address hooksAddr) = strategy.mainPoolKey();
        key = PoolKey(c0, c1, fee, spacing, hooksAddr);
    }

    function _readSide() internal view returns (PoolKey memory key) {
        (Currency c0, Currency c1, uint24 fee, int24 spacing, address hooksAddr) = strategy.sidePoolKey();
        key = PoolKey(c0, c1, fee, spacing, hooksAddr);
    }

    function _swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) internal {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1;
        pm.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(amountIn), sqrtPriceLimitX96: limit
            }),
            ""
        );
    }

    /// @notice Full Phase 4 path: auction settle → keys → both-direction swaps → flush → side compound.
    function test_e2e_settle_swap_flush_sideCompound() public {
        // Confirm protocolFeeBps is factory-default stamped (cap 4000), not hardcoded per-pool.
        assertEq(hook.PROTOCOL_FEE_BPS_MAX(), 4000, "protocol fee cap 4000 bps = 40%");
        hook.setDefaultProtocolFeeBps(3000); // bps = 30% of hook fee — mutable factory default
        assertEq(hook.defaultProtocolFeeBps(), 3000);

        uint256 lpFunds = 95 ether;
        uint256 fCarve = (lpFunds * 500) / 10_000; // 4.75 ether
        vm.deal(address(this), fCarve);
        strategy.settle{value: fCarve}(50 ether, lpFunds, 1 ether, 100 ether, 0, 0, 0, USER, creator);

        // Keys: main fee 0 pips + hook; side 3000 pips + no hook
        PoolKey memory mainKey = _readMain();
        PoolKey memory sideKey = _readSide();
        assertEq(mainKey.fee, 0, "main LP fee 0 pips = 0%");
        assertEq(mainKey.hooks, address(hook), "main hooks = fee hook");
        assertEq(pm.poolHook(mainKey.toId()), address(hook), "main poolManager hook set");
        assertTrue(strategy.sidePoolDeployed(), "side deployed");
        assertEq(sideKey.fee, 3000, "side LP fee 3000 pips = 0.3%");
        assertEq(sideKey.hooks, address(0), "side hooks zero");
        assertEq(pm.poolHook(sideKey.toId()), address(0), "side never hooked");

        // Stamped protocol share matches mutable factory default at register time
        assertEq(hook.protocolFeeBps(USER), 3000, "stamped protocolFeeBps from factory default");
        assertEq(hook.hookFeeBps(USER), 100, "stamped hookFeeBps 100 bps = 1%");
        assertEq(hook.feeReceiver(USER), creator);

        // FeeLocker main route retired — no pair→BuybackAccumulator path
        uint256 mainLock = strategy.mainLockId();
        vm.expectRevert(FeeLocker.MainFeeCrankRetired.selector);
        locker.crankMainFees(mainLock);

        // Carve only on accumulator (automatic fee path severed)
        assertEq(acc.pairBalance(), fCarve, "accumulator holds carve only");

        // Swaps both directions on main (mock quotes pair-side fee on |amountSpecified|)
        bool pairIsC0 = Currency.unwrap(mainKey.currency0) == PAIR;
        uint256 buyIn = 100 ether;
        uint256 sellIn = 50 ether;
        _swap(mainKey, pairIsC0, buyIn); // pair → token
        _swap(mainKey, !pairIsC0, sellIn); // token → pair

        uint256 gross = ((buyIn + sellIn) * uint256(hook.hookFeeBps(USER))) / 10_000;
        uint256 expectProto = (gross * uint256(hook.protocolFeeBps(USER))) / 10_000;
        uint256 expectRecv = gross - expectProto;
        assertEq(hook.tokenPairProceeds(USER), expectProto, "protocol accrued");
        assertEq(hook.receiverPairProceeds(USER), expectRecv, "receiver accrued");

        uint256 treasBefore = treasury.balance;
        uint256 recvBefore = creator.balance;
        hook.flush(USER);
        assertEq(hook.tokenPairProceeds(USER), 0, "protocol bucket cleared");
        assertEq(hook.receiverPairProceeds(USER), 0, "receiver bucket cleared");
        assertEq(treasury.balance, treasBefore + expectProto, "treasury holds protocol share");
        assertEq(creator.balance, recvBefore + expectRecv, "feeReceiver holds remainder");

        // Accumulator untouched by flush (manual DCA only)
        assertEq(acc.pairBalance(), fCarve, "no automatic fee into accumulator");

        // Side pool: accrue LP fees → compound; nothing collected out to treasury/receiver
        uint256 sideFee0 = 1 ether;
        uint256 sideFee1 = 2 ether;
        pm.accrueFees(sideKey.toId(), strategy.sidePositionId(), sideFee0, sideFee1);
        (uint256 pending0, uint256 pending1) = pm.pendingFees(sideKey.toId(), strategy.sidePositionId());
        assertEq(pending0, sideFee0);
        assertEq(pending1, sideFee1);

        uint256 treasMid = treasury.balance;
        uint256 recvMid = creator.balance;
        uint256 accMid = acc.pairBalance();
        locker.crankSideCompound(strategy.sideLockId());

        (pending0, pending1) = pm.pendingFees(sideKey.toId(), strategy.sidePositionId());
        assertEq(pending0, 0, "side fees collected into compound");
        assertEq(pending1, 0, "side fees collected into compound");
        assertEq(treasury.balance, treasMid, "side compound: nothing to treasury");
        assertEq(creator.balance, recvMid, "side compound: nothing to feeReceiver");
        assertEq(acc.pairBalance(), accMid, "side compound: nothing to accumulator");
    }

    receive() external payable {}
}
