// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Regression for fuzz-halt-005: weight basis drops on OutBudget / OutPrice
///         at the correct auction blocks (spec Ã‚Â§3). Demand basis stays distinct (Ã‚Â§4).
/// @dev Scenario twin of reference engine (sizeBonus 17.85%, multi-bid A + competitor C):
///        A: $30 @ Ã¢Ë†Å¾  +  $200 @ 5.5  ;  C: $500 @ Ã¢Ë†Å¾
///      After block 1 price Ã¢â€°Ë† 5.5125 Ã¢â€ â€™ block 2 price-out of $200 BEFORE fills Ã¢â€ â€™ basis 30.
///      $30 goes all-in during a later clear Ã¢â€ â€™ basis 0 from the following block.
contract Regression005 is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BID_FEE = WAD / 10;
    uint256 internal constant TOL = 1e15; // weight/basis dust

    StonkzAuction internal auction;
    uint256 internal wall;

    address internal constant A = address(0xA11);
    address internal constant C = address(0xC33);

    function test_weightBasis_allInThenPriceOut_timing() public {
        auction = new StonkzAuction(
            IStonkzAuction.Params({
                totalSupply: 1000 ether,
                floorMcapUsd: 5000 ether,
                graduationUsd: 0,
                durationBlocks: 15,
                epochSeconds: 1,
                maxClearsPerSync: 0,
            maxUniqueActives: 0,
                baseStepBps: 500, // 5%
                walletCapBps: 5000, // 50%
                sizeBonusBps: 1785, // 17.85% Ã¢â€ â€™ ÃŽÂ± > 0
                lpShareBps: 8000,
                holdbackBps: 0,
                kappaHundredths: 130,
                disposalMode: 0,
                pairToken: address(0),
            maxLivePositionsPerAddress: 0,
            eagerFills: false
            })
        );

        // Multi-bid A: small (all-in later) + cliff (prices out when ladder > 5.5)
        _bid(A, 30 ether, type(uint80).max);
        _bid(A, 200 ether, 55e17); // 5.5
        _bid(C, 500 ether, type(uint80).max);

        assertEq(_basis(A), 230 ether, "pre: full weight basis");
        // Demand includes all non-OutPrice
        assertEq(auction.committedLive(), 730 ether, "pre: demand basis");

        // Block 0 clear
        _step();
        assertEq(auction.auctionIndex(), 1);
        assertEq(_basis(A), 230 ether, "after b0: both live");

        // Block 1 clear Ã¢â€ â€™ price steps above 5.5
        _step();
        assertEq(auction.auctionIndex(), 2);
        assertGt(auction.price(), 55e17, "price above cliff");
        // Price-out of $200 applies at START of next clear; basis still 230 until that clear runs
        assertEq(_basis(A), 230 ether, "after b1: price-out not yet swept");

        // Block 2 clear: price-out $200 BEFORE fills Ã¢â€ â€™ basis Ã¢â€ â€™ 30 for remainder / next
        _step();
        assertEq(auction.auctionIndex(), 3);
        assertEq(_basis(A), 30 ether, "after b2: cliff dropped from weight basis");
        // Demand: OutPrice $200 gone; all-in not yet
        assertEq(auction.committedLive(), 530 ether, "demand excludes OutPrice only");

        uint256 w30 = _weight(A);
        assertGt(w30, 0, "still weighted on $30");

        // Advance until $30 position is all-in (OutBudget) Ã¢â‚¬â€ basis must hit 0 the block AFTER
        bool sawAllIn;
        uint256 prevBasis = 30 ether;
        for (uint256 i = 0; i < 10 && !auction.done(); i++) {
            _step();
            uint256 b = _basis(A);
            if (prevBasis == 30 ether && b == 0) {
                sawAllIn = true;
                // Demand still counts the all-in $30 (+ C $500); OutPrice $200 excluded
                assertEq(auction.committedLive(), 530 ether, "all-in still in demand basis");
                assertEq(_weight(A), 0, "weight zero once basis empty");
                break;
            }
            // Until all-in lands, basis stays 30 (no phantom re-add of priced-out budget)
            if (b != 0) assertEq(b, 30 ether, "no stale $200 in weight basis");
            prevBasis = b;
        }
        assertTrue(sawAllIn, "expected $30 all-in within horizon");
    }

    function _basis(address who) internal view returns (uint256) {
        (, uint256 activeBudget,,,,,,) = auction.bidders(who);
        return activeBudget;
    }

    function _weight(address who) internal view returns (uint256) {
        (uint256 weight,,,,,,,) = auction.bidders(who);
        return weight;
    }

    function _bid(address who, uint256 budget, uint256 maxPrice) internal {
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        auction.placeBid{value: budget + BID_FEE}(budget, maxPrice);
    }

    function _step() internal {
        if (wall == 0) wall = block.timestamp;
        wall += 1;
        vm.warp(wall);
        auction.poke();
    }
}
