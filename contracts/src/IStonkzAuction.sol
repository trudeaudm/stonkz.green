// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title IStonkzAuction — the Stonkz Ladder Auction
/// @notice Per-capita fills with a size tilt, demand-gated ladder price,
///         three-phase weight-paced release, reserve top-ups, graduation refunds.
/// @dev THE SPEC IS docs/mechanism-spec.md. THE ORACLE IS reference/engine.js.
interface IStonkzAuction {
    // ---- events (the indexer schema; the_book.exe consumes these) ----
    event BidPlaced(address indexed bidder, uint256 indexed positionId, uint256 budget, uint256 maxPrice, uint64 blockNum);
    event Filled(address indexed bidder, uint256 tokens, uint256 spent, uint256 price, uint64 blockNum);
    event PricedOut(address indexed bidder, uint256 indexed positionId, uint256 claimable, uint64 blockNum);
    event Capped(address indexed bidder, uint64 blockNum);
    event AllIn(address indexed bidder, uint256 indexed positionId, uint64 blockNum);
    event PriceStepped(uint256 newPrice, uint256 effStepBps, uint64 blockNum);
    event ReserveToppedUp(uint256 tokens, uint256 price, uint64 blockNum);
    event Graduated(uint256 raised, uint256 settlePrice, uint256 realizedKappaBps);
    event Failed(uint256 raised, uint256 threshold);
    event Settled(uint256 pairedTokens, uint256 lpFunds, uint256 surplus, uint256 auctionExcess, uint8 disposalMode);
    event BellRungEarly(address indexed creator, uint64 blockNum);
    event CreatorRanAway(address indexed creator, uint256 bondForfeited);

    struct Params {
        uint256 totalSupply;
        uint256 floorMcapUsd;        // $2k–$100k, 1e18
        uint256 graduationUsd;       // must pass raise-ceiling validation
        uint64  durationBlocks;
        uint16  baseStepBps;         // demand-scaled at runtime, clamp >= 0
        uint16  walletCapBps;        // of total supply
        uint16  sizeBonusBps;        // per 2x capital; 0 = pure per-capita
        uint16  lpShareBps;          // of raise -> LP; creator gets the rest
        uint16  holdbackBps;         // of total supply
        uint16  kappaHundredths;     // design print/avg ratio, e.g. 130
        uint8   disposalMode;        // 0 thickerLP, 1 holders, 2 creator, 3 burn
        address pairToken;           // USDG or WETH
    }

    function placeBid(uint256 budget, uint256 maxPrice) external payable returns (uint256 positionId);
    function claim(uint256 positionId) external;            // tokens + unspent, per state
    function poke() external;                                // advance blocks lazily (O(1) accounting)
    function ringBellEarly() external;                       // creator; only if graduated
    function runAway() external;                             // creator; pre-settlement cancel + bonded refunds
    function settle() external;                              // permissionless after end
}
