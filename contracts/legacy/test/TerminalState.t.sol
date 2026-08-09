// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../IStonkzAuction.sol";
import {StonkzAuction} from "../StonkzAuction.sol";

/// @title TerminalState — C4 basics (spec §8.0)
contract TerminalStateTest is Test {
    uint256 constant BID_FEE = 0.1 ether;
    address constant A = address(0xA);
    uint256 internal _t;

    function _steps(StonkzAuction auction, uint256 n) internal {
        if (_t == 0) _t = block.timestamp;
        for (uint256 i = 0; i < n; i++) {
            _t += 1;
            vm.warp(_t);
            auction.poke();
        }
    }

    function _params() internal pure returns (IStonkzAuction.Params memory p) {
        p.totalSupply = 100 ether;
        p.floorMcapUsd = 5000 ether;
        p.graduationUsd = 0;
        p.durationBlocks = 10;
        p.epochSeconds = 1;
        p.baseStepBps = 1000;
        p.walletCapBps = 10_000;
        p.lpShareBps = 10_000; // 100% LP default
        p.kappaHundredths = 130;
    }

    function test_C4_settledExclusive() public {
        StonkzAuction auction = new StonkzAuction(_params());
        vm.deal(A, 100 ether);
        vm.prank(A);
        auction.placeBid{value: 50 ether + BID_FEE}(50 ether, type(uint128).max);
        _steps(auction, 12);
        assertTrue(auction.done() && auction.graduated());
        auction.settle();
        assertEq(uint8(auction.terminal()), uint8(IStonkzAuction.Terminal.Settled));
        assertTrue(auction.settled());

        vm.expectRevert();
        auction.settle();
        vm.prank(auction.creator());
        vm.expectRevert();
        auction.runAway();
    }

    function test_C4_failedExclusive() public {
        IStonkzAuction.Params memory p = _params();
        p.graduationUsd = 2000 ether;
        p.lpShareBps = 8000;
        StonkzAuction auction = new StonkzAuction(p);
        vm.deal(A, 100 ether);
        vm.prank(A);
        auction.placeBid{value: 50 ether + BID_FEE}(50 ether, type(uint128).max);
        _steps(auction, 12);
        assertTrue(auction.done() && !auction.graduated());
        auction.settle();
        assertEq(uint8(auction.terminal()), uint8(IStonkzAuction.Terminal.Failed));
        assertTrue(auction.settled());
    }

    function test_C4_ranAwayExclusive() public {
        StonkzAuction auction = new StonkzAuction(_params());
        vm.deal(A, 100 ether);
        vm.prank(A);
        auction.placeBid{value: 50 ether + BID_FEE}(50 ether, type(uint128).max);
        auction.runAway();
        assertEq(uint8(auction.terminal()), uint8(IStonkzAuction.Terminal.RanAway));
        assertFalse(auction.settled());
        assertTrue(auction.done() && !auction.graduated());

        vm.expectRevert();
        auction.settle();
    }
}
