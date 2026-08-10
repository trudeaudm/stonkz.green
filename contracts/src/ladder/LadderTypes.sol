// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title LadderTypes — pinned schema mirror (docs/09 §8) for harness I/O
/// @dev Field units: money/prices in WAD; bps fields tagged; token amounts in token wei.
library LadderTypes {
    enum Tier {
        God,
        H4,
        Daily,
        Road
    }

    struct Inputs {
        uint16 N;
        uint256 auctionSupply; // token wei
        uint16 cashHoldbackBps; // bps of raised
        uint64 epochSeconds; // 0 = derive from tier
        uint256 floorMcap; // pair currency (WAD)
        uint256 floorPrice; // WAD pair/token
        bytes32 holdbackDelivery; // keccak of "none"|"vest"|"lock"|…
        uint16 holdbackBps; // bps of supply (display; circFrac=1 until vault)
        bytes32 leftoverMode;
        uint256 lpHealthTarget; // WAD fraction
        uint256 lpShare; // WAD fraction
        uint16 lpShareBps; // bps
        uint16 maxRungsPerBlock;
        uint16 protocolCarveBps; // bps of raised
        uint16 raiseRatioBps; // bps of startMcap
        uint256 raiseRatio; // WAD fraction
        uint256 reserve; // token wei
        uint256 rungIntervalUsd; // pair currency (WAD)
        uint16 sidePoolBps; // bps of LP-destined tokens
        uint16 sizeBonusBps; // bps
        uint256 supply; // token wei
        uint256 threshold; // pair currency (WAD)
        Tier tier;
        uint16 walletCapBps; // bps of auction supply
    }

    struct Bid {
        address wallet;
        uint256 size; // WAD pair
        uint256 maxPrice; // WAD pair/token
        uint256 period; // sim period index (== rung period)
    }

    struct PathRow {
        uint256 period; // 1-indexed in vectors
        uint256 price; // WAD
        uint256 offered; // token wei
        uint256 sold; // token wei
        bytes32 phase;
    }

    struct RaiseSplit {
        uint256 toLP; // WAD pair
        uint256 toTreasury; // WAD pair
        uint256 toCreator; // WAD pair
    }

    struct Fill {
        address wallet;
        uint256 committed; // WAD pair
        uint256 spent; // WAD pair
        uint256 tokens; // token wei
        uint256 refund; // WAD pair
    }

    struct Outputs {
        uint256 raised;
        uint256 committed;
        RaiseSplit raiseSplit;
        Fill[] fills;
        bool graduated;
        bytes32[] failReasons; // keccak of reason strings from vector
        uint256 clearingPrice;
        uint256 mcapFDV;
        uint256 mcapCirculating;
        uint256 lockedTokens;
        uint256 lpHealth; // WAD fraction
        uint256 lpHealthFloor; // WAD fraction
        uint256 cashFloor;
        uint256 cashOverCircMcap;
        uint256 soldTokens;
        uint256 sidePoolTokens;
        uint256 extraSoldFromReserve;
    }

    /// @notice Contract replay result — mirrors load-bearing Outputs fields.
    struct ReplayResult {
        RaiseSplit raiseSplit;
        uint256 raised;
        uint256 committed;
        Fill[] fills;
        bool graduated;
        bytes32[] failReasons;
        uint256 clearingPrice;
        uint256 lpHealth;
        uint256 lpHealthFloor;
        uint256 soldTokens;
        uint256 sidePoolTokens;
        PathRow[] clearingPath;
    }
}
