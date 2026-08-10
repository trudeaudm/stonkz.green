// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {StonkzExpressFactory} from "../src/StonkzExpressFactory.sol";
import {StonkzLadderFactory} from "../src/ladder/StonkzLadderFactory.sol";
import {StonkzDirectListing} from "../src/StonkzDirectListing.sol";
import {StonkzLadderAuction} from "../src/ladder/StonkzLadderAuction.sol";
import {Vanity} from "../src/Vanity.sol";

/// @title VanityHelpers — mine 0x4663 salts against factory init-code hashes (tests)
library VanityHelpers {
    function mineExpress(StonkzExpressFactory factory, address deployer, StonkzDirectListing.ListingParams memory p)
        internal
        view
        returns (bytes32 userSalt, address predicted)
    {
        return Vanity.mine(address(factory), deployer, factory.listingInitCodeHash(p));
    }

    function mineLadder(StonkzLadderFactory factory, address deployer, StonkzLadderAuction.Params memory p)
        internal
        view
        returns (bytes32 userSalt, address predicted)
    {
        return Vanity.mine(address(factory), deployer, factory.auctionInitCodeHash(p));
    }
}
