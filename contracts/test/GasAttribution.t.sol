// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IStonkzAuction} from "../src/IStonkzAuction.sol";
import {StonkzAuction} from "../src/StonkzAuction.sol";

/// @notice Task P: cost attribution for 300-active clears (no mechanism changes).
/// @dev Verdict: per-address (bidder) SSTOREs dominate (~87%); per-position ~12%.
contract GasAttributionTest is Test {
    uint256 internal constant BID_FEE = 1e18 / 10;
    uint256 internal constant MIN_BID = 10 ether;
    uint256 internal constant N = 300;

    // Layout bases from `forge inspect StonkzAuction storage-layout` (post Task R)
    uint256 internal constant SLOT_POSITIONS = 14;
    uint256 internal constant SLOT_BIDDERS = 15;

    mapping(bytes32 => uint8) internal _kind; // 1=position, 2=bidder

    function test_P_attribution_300actives() public {
        _indexSlots(N);

        StonkzAuction a = _deploy(1);
        _seed(a, N);

        vm.warp(block.timestamp + 1);
        (uint256 gas1, Attr memory c1) = _meterPoke(a);
        _logAttr("clear1_after_seed", gas1, c1);

        vm.warp(block.timestamp + 1);
        (uint256 gas2, Attr memory c2) = _meterPoke(a);
        _logAttr("clear2_warm", gas2, c2);

        // 32-clear: gas only (stateDiff on 32 clears OOMs the recorder)
        StonkzAuction b = _deploy(32);
        _seed(b, N);
        vm.warp(block.timestamp + 64);
        uint256 g0 = gasleft();
        b.poke();
        uint256 gas32 = g0 - gasleft();
        emit log_named_uint("poke32_gas", gas32);
        emit log_named_uint("avg_gas_per_clear_in_poke32", gas32 / 32);

        StonkzAuction c = _deploy(1);
        _seed(c, N);
        uint256 sumSeq;
        uint256 gFirst;
        uint256 gRest;
        for (uint256 i = 0; i < 32; i++) {
            vm.warp(block.timestamp + 1);
            uint256 g = gasleft();
            c.poke();
            uint256 used = g - gasleft();
            sumSeq += used;
            if (i == 0) gFirst = used;
            else gRest += used;
        }
        emit log_named_uint("seq32_first_clear_gas", gFirst);
        emit log_named_uint("seq32_avg_warm_clear_gas", gRest / 31);
        emit log_named_uint("seq32_avg_all_gas", sumSeq / 32);

        // Dominance check: position must NOT be the majority of SSTOREs
        assertTrue(c2.bidderWriteOps > c2.positionWriteOps, "bidder dominates position");
        assertTrue((c2.positionWriteOps * 100) / c2.sstoreOps < 50, "position not dominant");
    }

    struct Attr {
        uint256 sloadOps;
        uint256 sstoreOps;
        uint256 uniqueWrites;
        uint256 globalWriteOps;
        uint256 positionWriteOps;
        uint256 bidderWriteOps;
        uint256 otherMapWriteOps;
        uint256 zeroToNonZero;
        uint256 nonZeroMutate;
    }

    function _indexSlots(uint256 n) internal {
        for (uint256 id = 1; id <= n; id++) {
            bytes32 base = keccak256(abi.encode(id, SLOT_POSITIONS));
            for (uint256 o = 0; o < 6; o++) {
                _kind[bytes32(uint256(base) + o)] = 1;
            }
        }
        for (uint256 i = 1; i <= n; i++) {
            bytes32 base = keccak256(abi.encode(address(uint160(i)), SLOT_BIDDERS));
            for (uint256 o = 0; o < 6; o++) {
                _kind[bytes32(uint256(base) + o)] = 2;
            }
        }
    }

    function _meterPoke(StonkzAuction a) internal returns (uint256 gasUsed, Attr memory attr) {
        vm.startStateDiffRecording();
        uint256 g0 = gasleft();
        a.poke();
        gasUsed = g0 - gasleft();
        Vm.AccountAccess[] memory accs = vm.stopAndReturnStateDiff();

        bytes32[] memory seen = new bytes32[](4096);
        uint256 seenN;

        for (uint256 i = 0; i < accs.length; i++) {
            if (accs[i].account != address(a)) continue;
            Vm.StorageAccess[] memory sa = accs[i].storageAccesses;
            for (uint256 j = 0; j < sa.length; j++) {
                if (sa[j].reverted) continue;
                if (!sa[j].isWrite) {
                    attr.sloadOps++;
                    continue;
                }
                attr.sstoreOps++;
                if (sa[j].previousValue == bytes32(0) && sa[j].newValue != bytes32(0)) {
                    attr.zeroToNonZero++;
                } else if (sa[j].previousValue != sa[j].newValue) {
                    attr.nonZeroMutate++;
                }
                bytes32 slot = sa[j].slot;
                uint8 k = _kind[slot];
                if (k == 1) attr.positionWriteOps++;
                else if (k == 2) attr.bidderWriteOps++;
                else if (_isGlobalScalar(uint256(slot))) attr.globalWriteOps++;
                else attr.otherMapWriteOps++;

                bool already;
                for (uint256 t = 0; t < seenN; t++) {
                    if (seen[t] == slot) {
                        already = true;
                        break;
                    }
                }
                if (!already && seenN < seen.length) {
                    seen[seenN++] = slot;
                    attr.uniqueWrites++;
                }
            }
        }
    }

    function _isGlobalScalar(uint256 slot) internal pure returns (bool) {
        // slots 2–13 (incl. uniqueBidders), activeAddrs length@17, escrow totals@21–23
        if (slot >= 2 && slot <= 13) return true;
        if (slot == 17 || slot == 21 || slot == 22 || slot == 23) return true;
        return false;
    }

    function _logAttr(string memory tag, uint256 gasUsed, Attr memory a) internal {
        emit log_string(string.concat("--- ", tag, " ---"));
        emit log_named_uint("gas", gasUsed);
        emit log_named_uint("sload_ops", a.sloadOps);
        emit log_named_uint("sstore_ops", a.sstoreOps);
        emit log_named_uint("unique_write_slots", a.uniqueWrites);
        emit log_named_uint("global_write_ops", a.globalWriteOps);
        emit log_named_uint("position_write_ops", a.positionWriteOps);
        emit log_named_uint("bidder_write_ops", a.bidderWriteOps);
        emit log_named_uint("other_map_write_ops", a.otherMapWriteOps);
        emit log_named_uint("sstore_zero_to_nonzero", a.zeroToNonZero);
        emit log_named_uint("sstore_nonzero_mutate", a.nonZeroMutate);
        if (a.sstoreOps > 0) {
            emit log_named_uint("pct_position_of_sstores", (a.positionWriteOps * 100) / a.sstoreOps);
            emit log_named_uint("pct_bidder_of_sstores", (a.bidderWriteOps * 100) / a.sstoreOps);
        }
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
                pairToken: address(0)
            })
        );
    }

    function _seed(StonkzAuction a, uint256 n) internal {
        for (uint256 i = 1; i <= n; i++) {
            address who = address(uint160(i));
            vm.deal(who, MIN_BID + BID_FEE + 1 ether);
            vm.prank(who);
            a.placeBid{value: MIN_BID + BID_FEE}(MIN_BID, type(uint256).max);
        }
    }
}
