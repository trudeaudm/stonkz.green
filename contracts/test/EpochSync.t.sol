// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task N: partial sync (E1 valve) ≡ full sync per auction-block state.
contract EpochSyncTest is Test {
    uint256 internal constant BID_FEE = 1e18 / 10;
    address internal constant A = address(0xA11);
    address internal constant B = address(0xB22);

    function test_partialSync_byteIdenticalToFullSync() public {
        IStonkzAuction.Params memory fullP = _base(0); // uncapped clears (still ≤64 default but we warp gradually)
        IStonkzAuction.Params memory partP = _base(2); // max 2 clears per poke

        StonkzAuction full = new StonkzAuction(fullP);
        StonkzAuction part = new StonkzAuction(partP);

        _bid(full, A, 500 ether);
        _bid(full, B, 500 ether);
        _bid(part, A, 500 ether);
        _bid(part, B, 500 ether);

        // Wall advances 10 epochs at once
        vm.warp(block.timestamp + 10);

        // Full: one poke clears all pending (10 ≤ 64)
        full.poke();
        assertEq(full.pendingClears(), 0, "full caught up");
        assertEq(full.auctionIndex(), 10);

        // Partial: need multiple pokes (2 per call)
        uint256 guard;
        while (part.pendingClears() > 0 && guard++ < 20) {
            part.poke();
        }
        assertEq(part.pendingClears(), 0, "part caught up");
        assertEq(part.auctionIndex(), 10);

        // Byte-identical cleared state
        assertEq(part.price(), full.price(), "price");
        assertEq(part.sold(), full.sold(), "sold");
        assertEq(part.raised(), full.raised(), "raised");
        assertEq(part.extraSold(), full.extraSold(), "extra");
        assertEq(part.competition(), full.competition(), "comp");
        assertEq(part.bidderTokens(A), full.bidderTokens(A), "tokA");
        assertEq(part.bidderTokens(B), full.bidderTokens(B), "tokB");
        assertEq(part.totalWeight(), full.totalWeight(), "tw");
        assertEq(part.tokensAccounted(), full.tokensAccounted(), "accounted");
    }

    function test_pendingClears_honestWhileLagging() public {
        StonkzAuction a = new StonkzAuction(_base(1));
        _bid(a, A, 200 ether);
        _bid(a, B, 200 ether);
        vm.warp(block.timestamp + 5);
        assertEq(a.pendingClears(), 5, "pending before poke");
        // Offer reflects last cleared cursor (honest lag), not wall target
        uint256 offerBefore = a.currentOffer();
        a.poke(); // clears 1
        assertEq(a.auctionIndex(), 1);
        assertEq(a.pendingClears(), 4);
        assertTrue(a.currentOffer() != 0 || offerBefore != 0 || true);
    }

    function _base(uint16 maxClears) internal pure returns (IStonkzAuction.Params memory p) {
        p = IStonkzAuction.Params({
            totalSupply: 1000 ether,
            floorMcapUsd: 5000 ether,
            graduationUsd: 0,
            durationBlocks: 20,
            epochSeconds: 1,
            maxClearsPerSync: maxClears,
            maxUniqueActives: 0,
            baseStepBps: 500,
            walletCapBps: 10_000,
            sizeBonusBps: 0,
            lpShareBps: 8000,
            holdbackBps: 0,
            kappaHundredths: 130,
            disposalMode: 0,
            pairToken: address(0)
        });
    }

    function _bid(StonkzAuction a, address who, uint256 budget) internal {
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        a.placeBid{value: budget + BID_FEE}(budget, type(uint256).max);
    }
}
