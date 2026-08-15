// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {Vanity} from "../src/Vanity.sol";

/// @title VanityHelpers — mine 0x4663 salts against factory init-code hashes (tests)
library VanityHelpers {
    /// @dev Express vanity is on the TOKEN (CREATE listing nonce=1), not the listing.
    function mineExpress(StonkzExpressFactory factory, address deployer, StonkzDirectListing.ListingParams memory p)
        internal
        view
        returns (bytes32 userSalt, address predictedListing)
    {
        bytes32 initCodeHash = factory.listingInitCodeHash(p);
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        for (uint256 i; i < 1_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            userSalt = bytes32(i);
            predictedListing = factory.predictListingAddress(deployer, userSalt, initCodeHash);
            address predictedToken = factory.predictTokenAddress(predictedListing);
            if (Vanity.matches(predictedToken) && predictedListing.code.length == 0) {
                return (userSalt, predictedListing);
            }
        }
        revert("Vanity: no token salt in 1e6");
    }

    function mineLadder(StonkzLadderFactory factory, address deployer, StonkzLadderAuction.Params memory p)
        internal
        view
        returns (bytes32 userSalt, address predicted)
    {
        return Vanity.mine(address(factory), deployer, factory.auctionInitCodeHash(p));
    }
}
