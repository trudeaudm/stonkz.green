// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task M: OutPrice USD claim pre-settle must not forfeit filled tokens.
contract RegressionClaimForfeit is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BID_FEE = WAD / 10;

    StonkzAuction internal auction;
    uint256 internal wall;

    address internal constant A = address(0xA11);
    address internal constant B = address(0xB22);

    function test_outPriceUsdClaim_preservesTokensThroughSettle() public {
        auction = new StonkzAuction(
            IStonkzAuction.Params({
                totalSupply: 1000 ether,
                floorMcapUsd: 5000 ether,
                graduationUsd: 0, // always graduate if any raise
                durationBlocks: 12,
                epochSeconds: 1,
                maxClearsPerSync: 0,
            maxUniqueActives: 0,
                baseStepBps: 1000, // 10% steps â€” cliff hits quickly
                walletCapBps: 10_000,
                sizeBonusBps: 0,
                lpShareBps: 8000,
                holdbackBps: 0,
                kappaHundredths: 130,
                disposalMode: 0,
                pairToken: address(0),
            eagerFills: false
            })
        );

        uint256 floor = auction.price(); // 5e18
        // A: will fill some then price out when ladder exceeds cliff
        uint256 budgetA = 200 ether;
        uint256 cliff = floor + floor / 10; // one step above floor â‰ˆ 5.5
        _bid(A, budgetA, cliff);
        // B: stays in to drive price and graduation volume
        _bid(B, 5000 ether, type(uint256).max);

        // Clear until A is OutPrice and has some fills
        bool pricedOut;
        uint256 filled;
        for (uint256 i = 0; i < 12 && !auction.done(); i++) {
            _step();
            (, , , uint256 spent, uint256 tokens, StonkzAuction.PosStatus st,,,) = auction.positions(1);
            filled = tokens;
            if (st == StonkzAuction.PosStatus.OutPrice && tokens > 0 && spent > 0) {
                pricedOut = true;
                break;
            }
        }
        assertTrue(pricedOut, "A should be OutPrice with fills");
        assertGt(filled, 0, "A filled some tokens");

        (, uint256 bud,, uint256 spentBefore,,,,,) = auction.positions(1);
        uint256 unspent = bud - spentBefore;
        assertGt(unspent, 0, "unspent USD remains");

        // Pre-settle USD claim
        uint256 balBefore = A.balance;
        vm.prank(A);
        auction.claim(1);
        assertEq(A.balance - balBefore, unspent, "USD claim == budget-spent");

        // Tokens must survive on the position
        (, , , , uint256 tokensAfterUsd, , bool usdClaimed, bool tokClaimed,) = auction.positions(1);
        assertTrue(usdClaimed, "usd claimed");
        assertFalse(tokClaimed, "tokens not yet claimed");
        assertEq(tokensAfterUsd, filled, "tokens preserved after USD claim");

        // Finish auction + settle
        while (!auction.done()) _step();
        assertTrue(auction.graduated(), "graduate");
        auction.settle();
        assertTrue(auction.settled());

        // Token claim
        uint256 credBefore = auction.claimableTokens(A);
        vm.prank(A);
        auction.claim(1);
        assertEq(auction.claimableTokens(A) - credBefore, filled, "token credit == filled");

        (, , , , uint256 tokensFinal, , , bool tokClaimed2,) = auction.positions(1);
        assertTrue(tokClaimed2, "tokens claimed");
        assertEq(tokensFinal, 0, "position tokens zeroed after credit");

        // Exact wei G: accounted == sold
        assertEq(auction.tokensAccounted(), auction.sold(), "G tokens accounted");
        assertEq(auction.totalEscrowed(), auction.escrowBook(), "escrow book");
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
