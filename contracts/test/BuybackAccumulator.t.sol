// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {BuybackAccumulator} from "../src/BuybackAccumulator.sol";

/// @title BuybackAccumulator — C3
contract BuybackAccumulatorTest is Test {
    BuybackAccumulator acc;
    address constant STONKZ = address(0x4663);

    function setUp() public {
        acc = new BuybackAccumulator(address(0), STONKZ, address(0));
        acc.setStrategy(address(this));
    }

    function test_C3_receiveCarveAndCrankBurns() public {
        acc.receiveCarve{value: 10 ether}();
        assertEq(acc.pairBalance(), 10 ether);

        (uint256 spent, uint256 burned) = acc.crankBuyAndBurn();
        assertEq(spent, 10 ether);
        assertEq(burned, 10 ether);
        assertEq(acc.totalBurned(), 10 ether);
        assertEq(acc.pairBalance(), 0);
    }

    function test_C3_crankRespectsSizeCapAndCooldown() public {
        acc.receiveCarve{value: 1000 ether}();
        (uint256 spent,) = acc.crankBuyAndBurn();
        assertEq(spent, acc.MAX_BUY_PER_CRANK());

        vm.expectRevert();
        acc.crankBuyAndBurn();

        vm.warp(acc.lastCrankTime() + acc.CRANK_COOLDOWN());
        (spent,) = acc.crankBuyAndBurn();
        assertEq(spent, acc.MAX_BUY_PER_CRANK());
    }

    function test_C3_preGenesisParkAndRelease() public {
        acc.parkSidePoolTokens(42 ether);
        assertEq(acc.parkedSidePoolTokens(), 42 ether);
        uint256 got = acc.releaseSidePoolTokens(address(0xBEEF));
        assertEq(got, 42 ether);
        assertEq(acc.parkedSidePoolTokens(), 0);
    }

    function test_C3_genesisNotLiveRevertsCrank() public {
        BuybackAccumulator pre = new BuybackAccumulator(address(0), address(0), address(0));
        pre.receiveCarve{value: 1 ether}();
        vm.expectRevert(BuybackAccumulator.GenesisNotLive.selector);
        pre.crankBuyAndBurn();
    }

    receive() external payable {}
}
