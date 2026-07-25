// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title StonkzDirectListing (SKELETON)
/// @notice Instant coins: creator funds liquidity at thinner ($4k) or thicker
///         ($8k) starting mcap. Friendly INSTANT tag, LP burn forced,
///         minimum liquidity floor. No auction, no bonding curve.
/// @dev Settlement matches IPO path (spec §8): 95% LP funds → main pool at print;
///      flat 5% carve → BuybackAccumulator; 5% LP tokens → side pool; FeeLocker custody.
///      (Supersedes the old 15/85 market-buy split.)
contract StonkzDirectListing {
    constructor() {
        revert("TODO");
    }
}
