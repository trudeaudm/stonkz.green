// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test, stdJson} from "forge-std/Test.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";

/// @title LadderVectorLoader — load regenerated fixtures (not source vectors)
/// @dev Source vectors at test/vectors/ladder/ are INPUTS and must never be modified.
///      Fixtures at test/fixtures/ladder/ are produced by scripts/gen-ladder-fixtures.mjs.
abstract contract LadderVectorLoader is Test {
    using stdJson for string;

    string internal constant FIXTURE_DIR = "/test/fixtures/ladder/";

    string[10] internal VECTOR_FILES = [
        "01-thin-book-fails.json",
        "02-god-2p5k-at-bar.json",
        "03-god-5k-oversub.json",
        "04-4h-5k-at-bar.json",
        "05-daily-10k-at-bar.json",
        "06-daily-20k-heavy.json",
        "07-road-40k-at-bar.json",
        "08-locked-holdback-60.json",
        "09-vault-holdback-cashhb.json",
        "10-wallet-cap-binding.json"
    ];

    function _fixturePath(string memory file) internal view returns (string memory) {
        return string.concat(vm.projectRoot(), FIXTURE_DIR, file);
    }

    function _loadRaw(string memory file) internal view returns (string memory) {
        return vm.readFile(_fixturePath(file));
    }

    function _has(string memory json, string memory key) internal pure returns (bool) {
        return json.parseRaw(key).length > 0;
    }

    function _tier(string memory s) internal pure returns (LadderTypes.Tier) {
        bytes32 h = keccak256(bytes(s));
        if (h == keccak256("god")) return LadderTypes.Tier.God;
        if (h == keccak256("4h")) return LadderTypes.Tier.H4;
        if (h == keccak256("daily")) return LadderTypes.Tier.Daily;
        if (h == keccak256("road")) return LadderTypes.Tier.Road;
        revert(string.concat("unknown tier: ", s));
    }

    function _wallet(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(bytes(name)))));
    }

    function loadInputs(string memory json) internal pure returns (LadderTypes.Inputs memory p) {
        p.N = uint16(json.readUint(".inputs.N"));
        p.auctionSupply = json.readUint(".inputs.auctionSupply");
        p.cashHoldbackBps = uint16(json.readUint(".inputs.cashHoldbackBps"));
        p.epochSeconds = uint64(json.readUint(".inputs.epochSeconds"));
        p.floorMcap = json.readUint(".inputs.floorMcap");
        p.floorPrice = json.readUint(".inputs.floorPrice");
        p.holdbackDelivery = keccak256(bytes(json.readString(".inputs.holdbackDelivery")));
        p.holdbackBps = uint16(json.readUint(".inputs.holdbackBps"));
        p.leftoverMode = keccak256(bytes(json.readString(".inputs.leftoverMode")));
        p.lpHealthTarget = json.readUint(".inputs.lpHealthTarget");
        p.lpShare = json.readUint(".inputs.lpShare");
        p.lpShareBps = uint16(json.readUint(".inputs.lpShareBps"));
        p.maxRungsPerBlock = uint16(json.readUint(".inputs.maxRungsPerBlock"));
        p.protocolCarveBps = uint16(json.readUint(".inputs.protocolCarveBps"));
        p.raiseRatioBps = uint16(json.readUint(".inputs.raiseRatioBps"));
        p.raiseRatio = json.readUint(".inputs.raiseRatio");
        p.reserve = json.readUint(".inputs.reserve");
        p.rungIntervalUsd = json.readUint(".inputs.rungIntervalUsd");
        p.sidePoolBps = uint16(json.readUint(".inputs.sidePoolBps"));
        p.sizeBonusBps = uint16(json.readUint(".inputs.sizeBonusBps"));
        p.supply = json.readUint(".inputs.supply");
        p.threshold = json.readUint(".inputs.threshold");
        p.tier = _tier(json.readString(".inputs.tier"));
        p.walletCapBps = uint16(json.readUint(".inputs.walletCapBps"));
    }

    function loadBids(string memory json) internal view returns (LadderTypes.Bid[] memory bids) {
        uint256 n;
        while (_has(json, string.concat(".bids[", vm.toString(n), "].wallet"))) n++;
        bids = new LadderTypes.Bid[](n);
        for (uint256 i; i < n; i++) {
            string memory base = string.concat(".bids[", vm.toString(i), "]");
            bids[i] = LadderTypes.Bid({
                wallet: _wallet(json.readString(string.concat(base, ".wallet"))),
                size: json.readUint(string.concat(base, ".size")),
                maxPrice: json.readUint(string.concat(base, ".maxPrice")),
                period: json.readUint(string.concat(base, ".block"))
            });
        }
    }

    function loadPath(string memory json) internal view returns (LadderTypes.PathRow[] memory path) {
        uint256 n;
        while (_has(json, string.concat(".clearingPath[", vm.toString(n), "].block"))) n++;
        path = new LadderTypes.PathRow[](n);
        for (uint256 i; i < n; i++) {
            string memory base = string.concat(".clearingPath[", vm.toString(i), "]");
            path[i] = LadderTypes.PathRow({
                period: json.readUint(string.concat(base, ".block")),
                price: json.readUint(string.concat(base, ".price")),
                offered: json.readUint(string.concat(base, ".offered")),
                sold: json.readUint(string.concat(base, ".sold")),
                phase: keccak256(bytes(json.readString(string.concat(base, ".phase"))))
            });
        }
    }

    function loadOutputs(string memory json) internal view returns (LadderTypes.Outputs memory o) {
        o.raised = json.readUint(".outputs.raised");
        o.committed = json.readUint(".outputs.committed");
        o.raiseSplit = LadderTypes.RaiseSplit({
            toLP: json.readUint(".outputs.raiseSplit.toLP"),
            toTreasury: json.readUint(".outputs.raiseSplit.toTreasury"),
            toCreator: json.readUint(".outputs.raiseSplit.toCreator")
        });
        uint256 n;
        while (_has(json, string.concat(".outputs.fills[", vm.toString(n), "].wallet"))) n++;
        o.fills = new LadderTypes.Fill[](n);
        for (uint256 i; i < n; i++) {
            string memory base = string.concat(".outputs.fills[", vm.toString(i), "]");
            o.fills[i] = LadderTypes.Fill({
                wallet: _wallet(json.readString(string.concat(base, ".wallet"))),
                committed: json.readUint(string.concat(base, ".committed")),
                spent: json.readUint(string.concat(base, ".spent")),
                tokens: json.readUint(string.concat(base, ".tokens")),
                refund: json.readUint(string.concat(base, ".refund"))
            });
        }
        o.graduated = json.readBool(".outputs.graduated");
        uint256 r;
        while (_has(json, string.concat(".outputs.failReasons[", vm.toString(r), "]"))) r++;
        o.failReasons = new bytes32[](r);
        for (uint256 i; i < r; i++) {
            o.failReasons[i] =
                keccak256(bytes(json.readString(string.concat(".outputs.failReasons[", vm.toString(i), "]"))));
        }
        o.clearingPrice = json.readUint(".outputs.clearingPrice");
        o.mcapFDV = json.readUint(".outputs.mcapFDV");
        o.mcapCirculating = json.readUint(".outputs.mcapCirculating");
        o.lockedTokens = json.readUint(".outputs.lockedTokens");
        o.lpHealth = json.readUint(".outputs.lpHealth");
        o.lpHealthFloor = json.readUint(".outputs.lpHealthFloor");
        o.cashFloor = json.readUint(".outputs.cashFloor");
        o.cashOverCircMcap = json.readUint(".outputs.cashOverCircMcap");
        o.soldTokens = json.readUint(".outputs.soldTokens");
        o.sidePoolTokens = json.readUint(".outputs.sidePoolTokens");
        o.extraSoldFromReserve = json.readUint(".outputs.extraSoldFromReserve");
    }
}
