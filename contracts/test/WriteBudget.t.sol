// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task Q'/F1'/G1''': WriteBudget for ALL-SIMPLE warm clears + compound bound.
///         ALL-SIMPLE warm clear (300 actives): <=16 SSTOREs (measured ~8).
///         K compound x m positions: <= BASE + C_PER_COMPOUND_POS * K * m.
contract WriteBudgetTest is Test {
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal constant MIN_BID = 10 ether;
    uint256 internal constant N = 300;
    uint256 internal constant C_PER_CONSTRAINT = 40;
    uint256 internal constant C_PER_COMPOUND_POS = 12;
    uint256 internal constant WARM_SIMPLE_MAX = 16;

    function test_writeBudget_warmClear_allSimple() public {
        StonkzAuction a = _deploy(1);
        _seedSimple(a, N);
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1);
        a.poke();
        assertEq(a.auctionIndex(), 1);
        emit log_named_uint("tw_after_clear1", a.totalWeight());
        emit log_named_uint("accT", a.accTokensPerWeight());

        vm.warp(t0 + 2);
        emit log_named_uint("pending", a.pendingClears());
        vm.record();
        a.poke();
        (, bytes32[] memory writes) = vm.accesses(address(a));
        emit log_named_uint("warm_clear_sstores", writes.length);
        emit log_named_uint("idx_after", a.auctionIndex());
        assertEq(a.auctionIndex(), 2, "clear did not advance");
        assertLe(writes.length, WARM_SIMPLE_MAX, "ALL-SIMPLE warm exceeds write budget");
    }

    function test_writeBudget_K_compound() public {
        uint256 K = 5;
        uint256 m = 2;
        StonkzAuction a = _deploy(1);
        _seedSimple(a, 20);
        for (uint256 i = 0; i < K; i++) {
            address who = address(uint160(1000 + i));
            for (uint256 j = 0; j < m; j++) {
                vm.deal(who, MIN_BID + BID_FEE + 1 ether);
                vm.prank(who);
                a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, type(uint80).max);
            }
        }
        uint256 t0 = block.timestamp;
        vm.warp(t0 + 1);
        a.poke();
        vm.warp(t0 + 2);
        vm.record();
        a.poke();
        (, bytes32[] memory writes) = vm.accesses(address(a));
        uint256 bound = WARM_SIMPLE_MAX + C_PER_COMPOUND_POS * K * m;
        emit log_named_uint("compound_warm_sstores", writes.length);
        emit log_named_uint("bound", bound);
        assertLe(writes.length, bound, "compound write blowup");
    }

    function test_writeBudget_K_constraints_linear() public {
        StonkzAuction a = _deploy(1);
        for (uint256 i = 1; i <= 5; i++) {
            address who = address(uint160(i));
            uint256 maxP = i <= 2 ? 1 : type(uint80).max;
            vm.deal(who, MIN_BID + BID_FEE + 1 ether);
            vm.prank(who);
            a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, maxP);
        }
        for (uint256 k = 0; k < 20 && a.auctionIndex() < 10; k++) {
            vm.warp(block.timestamp + 1);
            vm.record();
            uint256 before = a.auctionIndex();
            a.poke();
            (, bytes32[] memory writes) = vm.accesses(address(a));
            if (a.auctionIndex() > before) {
                assertLe(writes.length, WARM_SIMPLE_MAX + C_PER_CONSTRAINT * 5, "constraint write blowup");
            }
        }
    }

    function test_maxLivePositions_guard() public {
        StonkzAuction a = new StonkzAuction(
            IStonkzAuction.Params({
                totalSupply: 1_000_000 ether,
                floorMcapUsd: 50_000 ether,
                graduationUsd: 0,
                durationBlocks: 100,
                epochSeconds: 1,
                maxClearsPerSync: 1,
                maxUniqueActives: 0,
                baseStepBps: 500,
                walletCapBps: 10_000,
                sizeBonusBps: 0,
                lpShareBps: 8000,
                holdbackBps: 0,
                kappaHundredths: 130,
                disposalMode: 0,
                pairToken: address(0),
                maxLivePositionsPerAddress: 2,
                eagerFills: false
            })
        );
        address who = address(0xBEEF);
        vm.deal(who, 100 ether);
        vm.prank(who);
        a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, type(uint80).max);
        vm.prank(who);
        a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, type(uint80).max);
        vm.prank(who);
        vm.expectRevert(bytes("max live positions"));
        a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, type(uint80).max);
    }

    function _deploy(uint16 maxClears) internal returns (StonkzAuction) {
        return new StonkzAuction(
            IStonkzAuction.Params({
                totalSupply: 1_000_000 ether,
                floorMcapUsd: 50_000 ether,
                graduationUsd: 0,
                durationBlocks: 100,
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
                pairToken: address(0),
                maxLivePositionsPerAddress: 0,
                eagerFills: false
            })
        );
    }

    function _seedSimple(StonkzAuction a, uint256 n) internal {
        for (uint256 i = 1; i <= n; i++) {
            address who = address(uint160(i));
            vm.deal(who, MIN_BID + BID_FEE + 1 ether);
            vm.prank(who);
            a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, type(uint80).max);
        }
    }
}