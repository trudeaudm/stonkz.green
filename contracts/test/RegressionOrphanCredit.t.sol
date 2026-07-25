// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, stdJson, Vm} from "forge-std/Test.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task F1': fuzz-005 block 24 orphan-credit regression.
/// Exit-marked-live B must receive its final-block fill: ΔbidderTokens == Filled amount.
contract RegressionOrphanCreditTest is Test {
    using stdJson for string;

    uint256 internal constant BID_FEE = 1e18 / 10;
    address internal constant ADDR_A = address(0xA11);
    address internal constant ADDR_B = address(0xB22);
    address internal constant ADDR_C = address(0xC33);
    address internal constant ADDR_D = address(0xD44);

    function test_orphanCredit_fuzz005_block24() public {
        string memory json =
            vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/fuzz/fuzz-005.json"));
        StonkzAuction a = new StonkzAuction(_params(json));
        a.poke();

        uint256 t = block.timestamp;
        uint256 actionIdx;
        uint256 n = json.readUint(".params.blocks");
        for (uint256 b = 0; b < n && !a.done(); b++) {
            while (true) {
                string memory ab = string.concat(".actions[", vm.toString(actionIdx), "]");
                if (json.parseRaw(string.concat(ab, ".at")).length == 0) break;
                if (json.readUint(string.concat(ab, ".at")) > a.auctionIndex()) break;
                _place(json, ab, a);
                actionIdx++;
            }

            uint256 before = a.bidderTokens(ADDR_B);
            t += 1;
            vm.warp(t);
            vm.recordLogs();
            a.poke();

            if (b == 24) {
                uint256 after_ = a.bidderTokens(ADDR_B);
                uint256 dTok = after_ - before;
                uint256 filledTok = _sumFilledB(vm.getRecordedLogs());
                emit log_named_uint("dTok_B", dTok);
                emit log_named_uint("filledTok_B", filledTok);
                assertGt(filledTok, 0, "expected Filled for B at block 24");
                assertEq(dTok, filledTok, "orphan: Filled without bidderTokens credit");
                // Oracle fill class (~3e19); allow fuzz per-block tol
                uint256 exp = json.readUint(".blocks[24].fills.B");
                uint256 tol = exp / 1e9;
                if (tol < 1e12) tol = 1e12;
                uint256 d = dTok > exp ? dTok - exp : exp - dTok;
                assertLe(d, tol, "fill vs oracle beyond fuzz tol");
                return;
            }
        }
        fail();
    }

    function _sumFilledB(Vm.Log[] memory logs) internal pure returns (uint256 tok) {
        bytes32 sig = keccak256("Filled(address,uint256,uint256,uint256,uint64)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length < 2 || logs[i].topics[0] != sig) continue;
            address who = address(uint160(uint256(logs[i].topics[1])));
            if (who != ADDR_B) continue;
            (uint256 tAmt,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint64));
            tok += tAmt;
        }
    }

    function _place(string memory json, string memory ab, StonkzAuction a) internal {
        string memory nm = json.readString(string.concat(ab, ".bid.name"));
        uint256 budget = json.readUint(string.concat(ab, ".bid.budget"));
        uint256 maxP = json.readUint(string.concat(ab, ".bid.maxPrice"));
        address who = _addr(nm);
        vm.deal(who, budget + BID_FEE + 1 ether);
        vm.prank(who);
        try a.placeBid{value: budget + BID_FEE}(budget, maxP) {} catch {}
    }

    function _params(string memory json) internal pure returns (IStonkzAuction.Params memory p) {
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
        p.eagerFills = false;
    }

    function _addr(string memory name) internal pure returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("A")) return ADDR_A;
        if (h == keccak256("B")) return ADDR_B;
        if (h == keccak256("C")) return ADDR_C;
        if (h == keccak256("D")) return ADDR_D;
        return address(uint160(uint256(h)));
    }
}
