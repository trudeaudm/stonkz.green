// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task R: maxUniqueActives rejects new addresses; existing may re-bid.
contract MaxUniqueActivesTest is Test {
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal constant MIN_BID = 10 ether;

    function test_maxUniqueActives_rejectsNew_allowsExisting() public {
        StonkzAuction a = new StonkzAuction(
            IStonkzAuction.Params({
                totalSupply: 1000 ether,
                floorMcapUsd: 5000 ether,
                graduationUsd: 0,
                durationBlocks: 20,
                epochSeconds: 1,
                maxClearsPerSync: 0,
                maxUniqueActives: 2,
                baseStepBps: 500,
                walletCapBps: 10_000,
                sizeBonusBps: 0,
                lpShareBps: 8000,
                holdbackBps: 0,
                kappaHundredths: 130,
                disposalMode: 0,
                pairToken: address(0),
            maxLivePositionsPerAddress: 0,
            eagerFills: false
            })
        );

        _bid(a, address(0xA11), MIN_BID);
        _bid(a, address(0xB22), MIN_BID);
        assertEq(a.uniqueBidders(), 2);

        // Third NEW address rejected
        address c = address(0xC33);
        vm.deal(c, MIN_BID + BID_FEE + 1 ether);
        vm.prank(c);
        vm.expectRevert(bytes("max unique actives"));
        a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, type(uint80).max);

        // Existing address may add another position
        _bid(a, address(0xA11), MIN_BID);
        assertEq(a.uniqueBidders(), 2);
        assertEq(a.positionCount(address(0xA11)), 2);
    }

    function test_maxUniqueActives_zeroUnlimited() public {
        StonkzAuction a = new StonkzAuction(
            IStonkzAuction.Params({
                totalSupply: 1000 ether,
                floorMcapUsd: 5000 ether,
                graduationUsd: 0,
                durationBlocks: 20,
                epochSeconds: 1,
                maxClearsPerSync: 0,
                maxUniqueActives: 0,
                baseStepBps: 500,
                walletCapBps: 10_000,
                sizeBonusBps: 0,
                lpShareBps: 8000,
                holdbackBps: 0,
                kappaHundredths: 130,
                disposalMode: 0,
                pairToken: address(0),
            maxLivePositionsPerAddress: 0,
            eagerFills: false
            })
        );
        for (uint256 i = 1; i <= 5; i++) {
            _bid(a, address(uint160(i)), MIN_BID);
        }
        assertEq(a.uniqueBidders(), 5);
    }

    function _bid(StonkzAuction a, address who, uint256 budget) internal {
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        a.placeBid{value: budget + BID_FEE}(budget, type(uint80).max);
    }
}
