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

/// @title SettlementConservation — C5 skeleton (spec §9 I1, 100% LP default)
contract SettlementConservation is Test {
    StonkzLiquidityStrategy strategy;
    uint256 constant WAD = 1e18;

    function setUp() public {
        vm.etch(address(0x4663), hex"00");
        MockPoolManager pm = new MockPoolManager();
        BuybackAccumulator acc = new BuybackAccumulator(address(0), address(0x4663), address(0));
        FeeLocker fl = new FeeLocker(IPoolManager(address(pm)), acc, address(0));
        CTOGovernor gov = new CTOGovernor();
        StonkzFeeHook hook = new StonkzFeeHook(IPoolManager(address(pm)), address(0x7A5E), ICTOGovernor(address(gov)), address(this));
        gov.setRegistry(hook);
        strategy = new StonkzLiquidityStrategy(IPoolManager(address(pm)), acc, fl, hook, address(0xB111), address(0x4663));
    }

    function test_C5_conservationAtSettle_100pctLp() public {
        uint256 launchSupply = 100 ether;
        uint256 sold_ = 56.5 ether;
        uint256 creatorReserve_ = 0;
        uint256 lpFunds = 100 ether; // 100% LP
        uint256 P = 1 ether;
        uint256 reserveTokens = launchSupply - sold_; // ~43.5
        uint256 auctionExcess = 0;

        strategy.settle(sold_, lpFunds, P, reserveTokens, auctionExcess, creatorReserve_, 0, address(0xB222), address(this));

        (uint256 s, uint256 main, uint256 side, uint256 surp, uint256 excess, uint256 cr) =
            strategy.conservationBuckets();
        assertEq(s, sold_);
        assertEq(cr, creatorReserve_);
        // sold + mainPaired + sidePoolTokens + surplusRouted + excessRouted + creatorReserve == launch
        uint256 sum = strategy.conservationSum();
        assertApproxEqAbs(sum, launchSupply, 1e15, "I1 conservation");
        assertEq(side, (reserveTokens * 500) / 10_000);
        assertEq(main + side + surp, reserveTokens);
        excess; // silence
        WAD;
    }

    function test_C5_naiveFullRangeUnreachable() public {
        // Depositing ALL remaining tokens vs F_main would open catastrophically below print
        vm.expectRevert(StonkzLiquidityStrategy.NaiveFullRangeForbidden.selector);
        strategy.assertNaiveFullRangeUnreachable(100 ether, 1 ether, 10 ether);
    }

    function test_C5_priceSettingInvariant() public {
        uint256 F_main = 95 ether;
        uint256 P = 2 ether;
        uint256 need = (F_main * WAD) / P;
        assertEq((need * P) / WAD, F_main);
        strategy.settle(40 ether, 100 ether, P, 50 ether, 0, 0, 0, address(0xB222), address(this));
        assertEq(strategy.fMain(), F_main);
        assertEq(strategy.fCarve(), 5 ether);
        // mainPaired ≈ F_main/P
        assertApproxEqAbs(strategy.mainPaired(), need, 1);
    }
}
