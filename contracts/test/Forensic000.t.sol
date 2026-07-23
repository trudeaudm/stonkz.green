// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, stdJson, console2} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";
import {TracedWaterFill} from "./forensic/TracedWaterFill.sol";

/// @notice Forensic replay of fuzz-000 to schedule cursor 5; traces Solidity fill path
///         via an instrumented mirror (StonkzAuction.sol unmodified).
contract Forensic000Test is Test {
    using stdJson for string;

    uint256 internal constant BID_FEE = 1e18 / 10;
    address internal constant ADDR_A = address(0xA11);
    address internal constant ADDR_B = address(0xB22);

    StonkzAuction internal auction;
    uint256 internal _t;

    function test_forensic000_traceBlock5() public {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-000.json"));

        IStonkzAuction.Params memory p;
        p.totalSupply = json.readUint(".params.supply");
        p.floorMcapUsd = json.readUint(".params.floorMcap");
        p.graduationUsd = json.readUint(".params.threshold");
        p.durationBlocks = uint64(json.readUint(".params.blocks"));
        p.epochSeconds = 1;
        p.maxClearsPerSync = 0;
        p.baseStepBps = uint16(json.readUint(".params.baseStepBps"));
        p.walletCapBps = uint16(json.readUint(".params.walletCapBps"));
        p.sizeBonusBps = uint16(json.readUint(".params.sizeBonusBps"));
        p.lpShareBps = uint16(json.readUint(".params.lpShareBps"));
        p.holdbackBps = uint16(json.readUint(".params.holdbackBps"));
        p.kappaHundredths = uint16(json.readUint(".params.kappaHundredths"));
        p.disposalMode = 0;
        p.pairToken = address(0);

        auction = new StonkzAuction(p);
        auction.poke();

        uint256 actionIdx;
        _t = block.timestamp;
        // Advance until auctionIndex == 5 (about to clear block 5 → vector blocks[5])
        while (auction.auctionIndex() < 5 && !auction.done()) {
            actionIdx = _applyActions(json, actionIdx);
             _t += 1;
            vm.warp(_t);
            auction.poke();
        }
        actionIdx = _applyActions(json, actionIdx);

        console2.log("FORENSIC_SOL preClear auctionIndex", auction.auctionIndex());
        console2.log("FORENSIC_SOL preClear price", auction.price());
        console2.log("FORENSIC_SOL preClear raised", auction.raised());
        console2.log("FORENSIC_SOL preClear sold", auction.sold());
        console2.log("FORENSIC_SOL offered", auction.currentOffer());

        TracedWaterFill.Snap[] memory snaps = new TracedWaterFill.Snap[](2);
        snaps[0] = _snap(ADDR_A, bytes32("A"));
        snaps[1] = _snap(ADDR_B, bytes32("B"));

        uint256 offered = auction.currentOffer();
        uint256 px = auction.price();
        uint256 cap = auction.walletCapTokens();

        (uint256 rem, bool hitCap, uint256 hits) = TracedWaterFill.run(snaps, offered, px, cap);
        rem;
        hitCap;
        hits;

        uint256 raisedBefore = auction.raised();
         _t += 1;
        vm.warp(_t);
        auction.poke();
        console2.log("FORENSIC_SOL postClear raised", auction.raised());
        console2.log("FORENSIC_SOL raisedDelta", auction.raised() - raisedBefore);
        console2.log("FORENSIC_SOL postClear sold", auction.sold());
    }

    function _snap(address who, bytes32 name) internal view returns (TracedWaterFill.Snap memory s) {
        (
            uint256 weight,
            ,
            uint256 tokens,
            uint256 activeBudget,
            uint256 activeSpent,
            uint32 activeCount,
            bool capped,
        ) = auction.bidders(who);
        s.who = who;
        s.name = name;
        s.weight = weight;
        s.committedBasis = activeBudget;
        s.tokens = tokens;
        s.activeSpent = activeSpent;
        s.activeBudget = activeBudget;
        s.active = activeCount > 0 && !capped;
        s.capped = capped;
    }

    function _applyActions(string memory json, uint256 startIdx) internal returns (uint256) {
        uint256 actionIdx = startIdx;
        while (true) {
            string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
            if (!_has(json, string.concat(ab, ".at"))) break;
            if (json.readUint(string.concat(ab, ".at")) > auction.auctionIndex()) break;
            string memory nm = json.readString(string.concat(ab, ".bid.name"));
            uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
            uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
            address who = keccak256(bytes(nm)) == keccak256(bytes("A")) ? ADDR_A : ADDR_B;
            vm.deal(who, budget + BID_FEE + 1 ether);
            vm.prank(who);
            try auction.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
            actionIdx++;
        }
        return actionIdx;
    }

    function _has(string memory json, string memory key) internal pure returns (bool) {
        return json.parseRaw(key).length > 0;
    }
}
