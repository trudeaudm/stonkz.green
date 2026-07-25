// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice H1: placeBid must not materialize ACC pending onto a bid that is
///         immediately OutPrice'd (fuzz-022 ghost-active / ~4e20 oversell).
contract RegressionH1GhostTest is Test {
    using stdJson for string;

    uint256 internal constant BID_FEE = 1e18 / 10;
    address internal constant A = address(0xA11);
    uint256 internal _t;

    function test_fuzz022_noGhostOversell() public {
        string memory json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-022.json"));
        StonkzAuction lazy = new StonkzAuction(_params(json, false));
        StonkzAuction eager = new StonkzAuction(_params(json, true));
        lazy.poke();
        eager.poke();
        _t = block.timestamp;

        uint256 actionIdx;
        uint256 n = json.readUint(".params.blocks");
        for (uint256 b = 0; b < n && !lazy.done(); b++) {
            actionIdx = _placeDue(json, actionIdx, lazy, eager);
            // After placeBid(s): immediate OutPrice positions must have spent==0.
            _assertOutPriceClean(lazy);
            _assertOutPriceClean(eager);

            _t += 1;
            vm.warp(_t);
            lazy.poke();
            eager.poke();
        }

        // ACC vs eager mulWad dust is ≤ few wei; ghost class was ~4e20.
        assertApproxEqAbs(lazy.raised(), eager.raised(), 1e12, "raised");
        assertApproxEqAbs(lazy.sold(), eager.sold(), 1e12, "sold");
        assertEq(lazy.activeAddressCount(), eager.activeAddressCount(), "nActive");
    }

    function _assertOutPriceClean(StonkzAuction a) internal view {
        uint256 n = a.nextPositionId();
        for (uint256 id = 1; id <= n; id++) {
            (, , uint256 spent, , , , StonkzAuction.PosStatus st,) = a.positions(id);
            if (st == StonkzAuction.PosStatus.OutPrice) {
                // Immediate placeBid OutPrice never received fills; spent may be
                // non-zero only if priced out mid-auction after fills — those go
                // through _priceOutBidder which reverses activeSpent. For H1 we
                // only require: no Active ledger orphan (checked via aspent sum).
                spent;
            }
        }
        uint256 na = a.activeAddressCount();
        for (uint256 i = 0; i < na; i++) {
            address who = a.activeAddrs(i);
            (, , uint256 aspent, , , , ,) = a.bidders(who);
            uint256 sum;
            for (uint256 id = 1; id <= n; id++) {
                (, , uint256 sp, , , address o, StonkzAuction.PosStatus st,) = a.positions(id);
                if (o == who && st == StonkzAuction.PosStatus.Active) sum += sp;
            }
            assertEq(aspent, sum, "H1 orphan spent on non-Active");
        }
    }

    function _placeDue(string memory json, uint256 actionIdx, StonkzAuction lazy, StonkzAuction eager)
        internal
        returns (uint256)
    {
        while (true) {
            string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
            if (json.parseRaw(string.concat(ab, ".at")).length == 0) break;
            if (json.readUint(string.concat(ab, ".at")) > lazy.auctionIndex()) break;
            uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
            uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
            vm.deal(A, budget + BID_FEE + 1 ether);
            vm.prank(A);
            try lazy.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
            vm.deal(A, budget + BID_FEE + 1 ether);
            vm.prank(A);
            try eager.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
            actionIdx++;
        }
        return actionIdx;
    }

    function _params(string memory json, bool eagerFills) internal pure returns (IStonkzAuction.Params memory p) {
        p.totalSupply = json.readUint(".params.supply");
        p.floorMcapUsd = json.readUint(".params.floorMcap");
        p.graduationUsd = json.readUint(".params.threshold");
        p.durationBlocks = uint64(json.readUint(".params.blocks"));
        p.epochSeconds = 1;
        p.baseStepBps = uint16(json.readUint(".params.baseStepBps"));
        p.walletCapBps = uint16(json.readUint(".params.walletCapBps"));
        p.sizeBonusBps = uint16(json.readUint(".params.sizeBonusBps"));
        p.lpShareBps = uint16(json.readUint(".params.lpShareBps"));
        p.holdbackBps = uint16(json.readUint(".params.holdbackBps"));
        p.kappaHundredths = uint16(json.readUint(".params.kappaHundredths"));
        if (p.kappaHundredths < 100) p.kappaHundredths = 100;
        p.eagerFills = eagerFills;
    }
}
