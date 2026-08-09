// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {StonkzVault} from "../../src/vault/StonkzVault.sol";
import {VaultConstants} from "../../src/vault/VaultConstants.sol";
import {VaultMockToken} from "./VaultMockToken.sol";
import {StonkzLadderFactory} from "../../src/ladder/StonkzLadderFactory.sol";
import {StonkzLadderAuction} from "../../src/ladder/StonkzLadderAuction.sol";
import {LadderSettlement} from "../../src/ladder/LadderSettlement.sol";
import {LadderConstants} from "../../src/ladder/LadderConstants.sol";
import {LadderTypes} from "../../src/ladder/LadderTypes.sol";
import {LadderVectorLoader} from "../ladder/LadderVectorLoader.sol";
import {IPoolManager} from "../../src/v4/IPoolManager.sol";
import {MockPoolManager} from "../../src/mock/MockPoolManager.sol";
import {StonkzFeeHook} from "../../src/StonkzFeeHook.sol";
import {CTOGovernor} from "../../src/CTOGovernor.sol";
import {ICTOGovernor} from "../../src/interfaces/IStonkzGovernance.sol";

/// @title VaultPhase1 — lockedBalance gate + factory vaultRef + settlement deposit (docs/10 §6, docs/09)
contract VaultPhase1 is LadderVectorLoader {
    using stdJson for string;

    StonkzVault internal vault;
    StonkzLadderFactory internal factory;
    MockPoolManager internal pm;
    StonkzFeeHook internal hook;

    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);
    address internal constant STONKZ = address(0x4663);
    address internal constant DEST = address(0xD57);

    function setUp() public {
        vault = new StonkzVault(VaultConstants.LAUNCH_RATE_SECONDS_PER_BPS, 1, 10_000);
        factory = new StonkzLadderFactory();
        pm = new MockPoolManager();
        CTOGovernor gov = new CTOGovernor();
        hook = new StonkzFeeHook(IPoolManager(address(pm)), TREASURY, ICTOGovernor(address(gov)));
        gov.setRegistry(hook);
    }

    function _duration(LadderTypes.Tier t) internal pure returns (uint256) {
        if (t == LadderTypes.Tier.God) return LadderConstants.GOD_DURATION;
        if (t == LadderTypes.Tier.H4) return LadderConstants.H4_DURATION;
        if (t == LadderTypes.Tier.Daily) return LadderConstants.DAILY_DURATION;
        return LadderConstants.ROAD_DURATION;
    }

    function _params(LadderTypes.Inputs memory inn)
        internal
        view
        returns (StonkzLadderAuction.Params memory p)
    {
        p = StonkzLadderAuction.Params({
            supply: inn.supply,
            auctionSupply: inn.auctionSupply,
            floorMcap: inn.floorMcap,
            duration: _duration(inn.tier),
            lpShareWad: inn.lpShare,
            lpHealthTargetWad: inn.lpHealthTarget,
            carveBps: inn.protocolCarveBps,
            cashHoldbackBps: inn.cashHoldbackBps,
            holdbackBps: inn.holdbackBps,
            holdbackDelivery: inn.holdbackBps > 0
                ? LadderConstants.HoldbackDelivery.Vault
                : LadderConstants.HoldbackDelivery.None,
            tier: inn.tier,
            sidePoolBps: inn.sidePoolBps,
            walletCapBps: inn.walletCapBps,
            sizeBonusBps: inn.sizeBonusBps,
            maxUniqueActives: 300,
            pairToken: address(0),
            creator: CREATOR,
            treasury: TREASURY,
            vaultRef: address(0)
        });
    }

    /// @notice docs/09 availability guard against the REAL vault.
    function test_P1_holdbackFiling_revertsWithoutVault_succeedsAfterSet() public {
        LadderTypes.Inputs memory inn = loadInputs(_loadRaw("08-locked-holdback-60.json"));
        StonkzLadderAuction.Params memory p = _params(inn);

        vm.expectRevert(StonkzLadderFactory.VaultRequiredForHoldback.selector);
        factory.file(p);

        factory.setVaultRef(address(vault));
        StonkzLadderAuction a = factory.file(p);
        assertEq(a.vaultRef(), address(vault));
        assertEq(a.holdbackBps(), 6000);
        assertEq(a.circFrac(), 0.4e18);
    }

    function test_P1_lockedBalance_excludesQueuedDirect_pathPendingCounts() public {
        VaultMockToken tok = new VaultMockToken();
        uint256 supply = 1_000_000_000 ether;
        tok.mint(CREATOR, supply);

        vm.startPrank(CREATOR);
        tok.approve(address(vault), 50_000_000 ether);
        vault.deposit(address(tok), 50_000_000 ether);
        assertEq(vault.lockedBalance(address(tok)), 50_000_000 ether);

        vault.requestDirectRelease(address(tok), 10_000_000 ether, DEST); // 1%
        assertEq(vault.lockedBalance(address(tok)), 40_000_000 ether);
        assertEq(vault.queuedDirect(address(tok)), 10_000_000 ether);
        vm.stopPrank();
    }

    /// @notice Vector 08 (60% holdback) through REAL settlement into REAL vault.
    function test_P1_e2e_vector08_settlementIntoVault() public {
        _e2eHoldbackVector("08-locked-holdback-60.json", 600_000_000 ether);
    }

    /// @notice Vector 09 vault holdback + cash HB through REAL settlement into REAL vault.
    function test_P1_e2e_vector09_settlementIntoVault() public {
        _e2eHoldbackVector("09-vault-holdback-cashhb.json", 200_000_000 ether);
    }

    function _e2eHoldbackVector(string memory file, uint256 expectedLocked) internal {
        // Factory stamps vaultRef at file (covered by holdbackFiling test). Settlement e2e
        // deploys the auction directly so this test owns setSettlement — same stamped vaultRef.
        LadderTypes.Inputs memory inn = loadInputs(_loadRaw(file));
        LadderTypes.Outputs memory exp = loadOutputs(_loadRaw(file));
        uint256 vaultAmt = (inn.supply * uint256(inn.holdbackBps)) / 10_000;
        assertEq(vaultAmt, expectedLocked, "expected custody");
        assertEq(exp.lockedTokens, expectedLocked, "vector lockedTokens");

        StonkzLadderAuction.Params memory p = _params(inn);
        p.vaultRef = address(vault);
        StonkzLadderAuction a = new StonkzLadderAuction(p);
        LadderSettlement s = new LadderSettlement(IPoolManager(address(pm)), hook, address(0));
        s.setStonkzRef(STONKZ);
        a.setSettlement(s);
        a.start();

        LadderTypes.Bid[] memory bids = loadBids(_loadRaw(file));
        for (uint256 i; i < bids.length; i++) {
            address w = bids[i].wallet;
            vm.deal(w, bids[i].size + 1 ether);
            vm.prank(w);
            a.placeBid{value: bids[i].size}(bids[i].size, bids[i].maxPrice);
        }
        a.clearAllForTest();
        assertTrue(a.graduated(), "must graduate");

        VaultMockToken tok = new VaultMockToken();
        uint256 unsold = inn.auctionSupply - a.soldTokens();
        uint256 side = (unsold * inn.sidePoolBps) / 10_000;
        uint256 mainAsk = unsold - side;
        // Mint full supply so totalSupply() matches vector (rate bps of TOTAL supply).
        tok.mint(address(s), inn.supply);
        assertGe(inn.supply, vaultAmt + mainAsk + side, "settlement token budget");

        a.settle(address(tok));

        assertEq(vault.custody(address(tok)), vaultAmt, "vault custody");
        assertEq(vault.lockedBalance(address(tok)), vaultAmt, "locked == custody pre-queue");
        assertEq(vault.balanceOf(address(tok), CREATOR), vaultAmt, "credited to creator");
        assertEq(tok.balanceOf(address(vault)), vaultAmt);

        // File a 1% direct-release request — lockedBalance drops by that amount.
        uint256 onePct = inn.supply / 100;
        vm.prank(CREATOR);
        vault.requestDirectRelease(address(tok), onePct, DEST);
        assertEq(vault.lockedBalance(address(tok)), vaultAmt - onePct, "locked drops on queue");
        assertEq(vault.custody(address(tok)), vaultAmt, "custody unchanged until execute");
    }
}
