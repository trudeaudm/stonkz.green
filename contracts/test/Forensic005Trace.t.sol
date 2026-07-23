// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, stdJson, console2} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";
import {TracedWaterFill} from "./forensic/TracedWaterFill.sol";

contract Forensic005Trace is Test {
    using stdJson for string;

    uint256 internal constant BID_FEE = 1e18 / 10;
    StonkzAuction internal auction;
    uint256 internal _t;
    address internal constant A = address(0xA11);
    address internal constant B = address(0xB22);
    address internal constant C = address(0xC33);

    function test_trace005_block25() public {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-005.json"));
        IStonkzAuction.Params memory p;
        p.totalSupply = json.readUint(".params.supply");
        p.floorMcapUsd = json.readUint(".params.floorMcap");
        p.graduationUsd = json.readUint(".params.threshold");
        p.durationBlocks = uint64(json.readUint(".params.blocks"));
        p.epochSeconds = 1;
        p.maxClearsPerSync = 0;
        p.maxUniqueActives = 0;
        p.baseStepBps = uint16(json.readUint(".params.baseStepBps"));
        p.walletCapBps = uint16(json.readUint(".params.walletCapBps"));
        p.sizeBonusBps = uint16(json.readUint(".params.sizeBonusBps"));
        p.lpShareBps = uint16(json.readUint(".params.lpShareBps"));
        p.holdbackBps = uint16(json.readUint(".params.holdbackBps"));
        p.kappaHundredths = uint16(json.readUint(".params.kappaHundredths"));
        if (p.kappaHundredths < 100) p.kappaHundredths = 100;
        p.eagerFills = false;
        auction = new StonkzAuction(p);
        auction.poke();
        _t = block.timestamp;
        uint256 ai;
        while (auction.auctionIndex() < 25 && !auction.done()) {
            ai = _apply(json, ai);
             _t += 1;
            vm.warp(_t);
            auction.poke();
        }
        ai = _apply(json, ai);
        console2.log("preClear idx", auction.auctionIndex());
        console2.log("price", auction.price());
        console2.log("raised", auction.raised());
        console2.log("sold", auction.sold());
        console2.log("offered", auction.currentOffer());
        console2.log("activeN", auction.activeAddressCount());

        TracedWaterFill.Snap[] memory snaps = new TracedWaterFill.Snap[](3);
        snaps[0] = _snap(A, bytes32("A"));
        snaps[1] = _snap(B, bytes32("B"));
        snaps[2] = _snap(C, bytes32("C"));
        TracedWaterFill.run(snaps, auction.currentOffer(), auction.price(), auction.walletCapTokens());
    }

    function _snap(address who, bytes32 name) internal view returns (TracedWaterFill.Snap memory s) {
        (uint256 weight,,, uint256 tokens, uint256 activeBudget, uint256 activeSpent, uint32 activeCount, bool capped,) =
            auction.bidders(who);
        s.who = who;
        s.name = name;
        s.weight = weight;
        s.committedBasis = activeBudget;
        s.tokens = tokens;
        s.activeSpent = activeSpent;
        s.activeBudget = activeBudget;
        s.active = activeCount > 0 && !capped;
        s.capped = capped;
        console2.logBytes32(name);
        console2.log("pre weight", weight);
        console2.log("pre tokens", tokens);
        console2.log("pre activeBudget", activeBudget);
        console2.log("pre activeSpent", activeSpent);
        console2.log("pre activeCount", activeCount);
        console2.log("pre capped", capped ? 1 : 0);
    }

    function _apply(string memory json, uint256 startIdx) internal returns (uint256) {
        uint256 actionIdx = startIdx;
        while (true) {
            string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
            if (json.parseRaw(string.concat(ab, ".at")).length == 0) break;
            if (json.readUint(string.concat(ab, ".at")) > auction.auctionIndex()) break;
            string memory nm = json.readString(string.concat(ab, ".bid.name"));
            uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
            uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
            address who = address(uint160(uint256(keccak256(bytes(nm)))));
            if (keccak256(bytes(nm)) == keccak256(bytes("A"))) who = A;
            if (keccak256(bytes(nm)) == keccak256(bytes("B"))) who = B;
            if (keccak256(bytes(nm)) == keccak256(bytes("C"))) who = C;
            vm.deal(who, budget + BID_FEE + 1 ether);
            vm.prank(who);
            try auction.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
            actionIdx++;
        }
        return actionIdx;
    }
}
