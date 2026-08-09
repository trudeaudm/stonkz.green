// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, stdJson} from "forge-std/Test.sol";
import {IStonkzAuction} from "../../IStonkzAuction.sol";
import {StonkzAuction} from "../../StonkzAuction.sol";
import {console2} from "forge-std/console2.sol";
import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";

/// @notice Forensic harness from the H1 ghost-active investigation (fuzz-022
///         pending-dust / projSpent probe on address A). Part of a pushed STOP
///         arc; retained under test/forensics/ for history — not a regression lock.
contract ForensicH1Ghost2 is Test {
    using stdJson for string;
    uint256 constant WAD = 1e18;
    uint256 constant BID_FEE = 1e18 / 10;
    uint256 constant ACC_PREC = 1e18;
    uint256 _t;
    StonkzAuction lazy;
    StonkzAuction eager;
    string json;
    address constant A = address(0xA11);

    function test_h1_pending_dust() public {
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-022.json"));
        lazy = _deploy(false);
        eager = _deploy(true);
        lazy.poke(); eager.poke(); _t = block.timestamp;
        uint256 actionIdx;
        for (uint256 b = 0; b < 4 && !lazy.done(); b++) {
            actionIdx = _placeDue(actionIdx);
            if (b >= 1) {
                console2.log("======== PRE ========");
                console2.log("b", b);
                _dumpA("L", lazy);
                _dumpA("E", eager);
            }
            _t += 1; vm.warp(_t);
            lazy.poke(); eager.poke();
            if (b >= 1) {
                console2.log("======== POST ========");
                console2.log("b", b);
                _dumpA("L", lazy);
                _dumpA("E", eager);
            }
        }
    }

    function _dumpA(string memory tag, StonkzAuction a) internal view {
        (uint256 w, uint256 ab, uint256 aspent, uint16 ac, uint256 rd, uint256 ud, uint256 tok,) = a.bidders(A);
        uint256 pendU = 0;
        if (w > 0) {
            uint256 accrued = FixedPointMathLib.mulDiv(w, a.accUsdPerWeight(), WAD);
            pendU = accrued > ud ? accrued - ud : 0;
        }
        uint256 pendT = 0;
        if (w > 0) {
            uint256 accruedT = FixedPointMathLib.mulDiv(w, a.accTokensPerWeight(), WAD * ACC_PREC);
            pendT = accruedT > rd ? accruedT - rd : 0;
        }
        console2.log(tag);
        console2.log("w", w);
        console2.log("ab", ab);
        console2.log("aspent", aspent);
        console2.log("pendU", pendU);
        console2.log("pendT", pendT);
        console2.log("proj", aspent + pendU);
        console2.log("dustAddr", ab <= aspent + pendU + 1e9 ? 1 : 0);
        console2.log("ac", uint256(ac));
        console2.log("nActive", a.activeAddressCount());
        // pos1
        (uint256 bud,, uint256 spent,,, , StonkzAuction.PosStatus st,) = a.positions(1);
        console2.log("p1st", uint256(st));
        console2.log("p1spent", spent);
        console2.log("p1budLeft", bud > spent ? bud - spent : 0);
        console2.log("p1dust", bud <= spent + pendU + 1e9 ? 1 : 0);
        if (a.nextPositionId() >= 2) {
            (uint256 bud2,, uint256 spent2,,, , StonkzAuction.PosStatus st2,) = a.positions(2);
            console2.log("p2st", uint256(st2));
            console2.log("p2spent", spent2);
            console2.log("p2budLeft", bud2 > spent2 ? bud2 - spent2 : 0);
        }
    }

    function _placeDue(uint256 actionIdx) internal returns (uint256) {
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

    function _deploy(bool e) internal returns (StonkzAuction) {
        IStonkzAuction.Params memory p;
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
        p.eagerFills = e;
        return new StonkzAuction(p);
    }
}
