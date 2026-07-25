// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";
/// @title Reserves — C6 (spec §8.4 / §8.5)
contract ReservesTest is Test {
    uint256 constant BID_FEE = 0.1 ether;
    address constant A = address(0xA);

    function _base() internal pure returns (IStonkzAuction.Params memory p) {
        p.totalSupply = 100 ether;
        p.floorMcapUsd = 5000 ether;
        p.graduationUsd = 0;
        p.durationBlocks = 10;
        p.epochSeconds = 1;
        p.baseStepBps = 1000;
        p.walletCapBps = 10_000;
        p.lpShareBps = 10_000;
        p.holdbackBps = 1000; // 10% creatorReserve
        p.kappaHundredths = 130;
        p.creatorDeliveryMode = 0; // INSTANT
        p.creatorDeclaredUse = bytes32("ops");
        p.treasuryDeclaredUse = bytes32("treasury");
    }

    uint256 internal _t;

    function _graduate(StonkzAuction auction) internal {
        vm.deal(A, 200 ether);
        vm.prank(A);
        auction.placeBid{value: 100 ether + BID_FEE}(100 ether, type(uint128).max);
        if (_t == 0) _t = block.timestamp;
        for (uint256 i = 0; i < 12; i++) {
            _t += 1;
            vm.warp(_t);
            auction.poke();
        }
        require(auction.graduated(), "grad");
        auction.settle();
    }

    function test_C6_holdbackAliasCreatorReserve() public {
        StonkzAuction auction = new StonkzAuction(_base());
        assertEq(auction.holdbackBps(), 1000);
        assertEq(auction.creatorReserveBps(), 1000);
        assertEq(auction.launchSupply(), 90 ether);
    }

    function test_C6_instantTimelock10Minutes() public {
        StonkzAuction auction = new StonkzAuction(_base());
        _graduate(auction);
        (,, uint64 unlockedAt, uint256 total, uint256 claimed,) = auction.creatorReserveState();
        assertEq(total, 10 ether);
        assertEq(claimed, 0);
        assertEq(unlockedAt, uint64(block.timestamp + 10 minutes));

        vm.expectRevert();
        auction.claimCreatorReserve();

        vm.warp(unlockedAt);
        uint256 amt = auction.claimCreatorReserve();
        assertEq(amt, 10 ether);
    }

    function test_C6_vestLinear() public {
        IStonkzAuction.Params memory p = _base();
        p.creatorDeliveryMode = 1;
        p.creatorVestDuration = 100 days;
        StonkzAuction auction = new StonkzAuction(p);
        _graduate(auction);

        (,, uint64 unlockedAt,,,) = auction.creatorReserveState();
        vm.warp(uint256(unlockedAt) + 50 days);
        uint256 half = auction.claimCreatorReserve();
        assertApproxEqAbs(half, 5 ether, 1e15);

        vm.warp(uint256(unlockedAt) + 100 days);
        uint256 rest = auction.claimCreatorReserve();
        assertApproxEqAbs(half + rest, 10 ether, 1e15);
    }

    function test_C6_treasuryReserveAtSettle() public {
        IStonkzAuction.Params memory p = _base();
        p.holdbackBps = 0;
        p.lpShareBps = 8000; // 20% treasuryReserve
        StonkzAuction auction = new StonkzAuction(p);
        assertEq(auction.treasuryReserveBps(), 2000);
        _graduate(auction);
        assertGt(auction.treasuryReserveAmount(), 0);
        assertTrue(auction.treasuryDelivered());
        // lpFunds rounds down ⇒ treasury = raised − lpFunds (may exceed 20% slice by 1 wei)
        assertEq(auction.treasuryReserveAmount(), auction.raised() - (auction.raised() * 8000) / 10_000);
    }

    function test_C6_declaredUseImmutable() public {
        StonkzAuction auction = new StonkzAuction(_base());
        assertEq(auction.creatorDeclaredUse(), bytes32("ops"));
        assertEq(auction.treasuryDeclaredUse(), bytes32("treasury"));
    }
}
