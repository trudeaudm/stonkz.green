// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";
import {IPoolManager as ICanonPM} from "@v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@v4-core/src/libraries/Hooks.sol";
import {PoolKey as CanonPoolKey} from "@v4-core/src/types/PoolKey.sol";
import {Currency as CanonCurrency} from "@v4-core/src/types/Currency.sol";
import {IHooks} from "@v4-core/src/interfaces/IHooks.sol";

import {IPoolManager} from "../src/v4/IPoolManager.sol";
import {V4Adapter} from "../src/v4/V4Adapter.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "../src/v4/types/PoolKey.sol";
import {Currency} from "../src/v4/types/Currency.sol";
import {BalanceDelta} from "../src/v4/types/BalanceDelta.sol";
import {TickMath} from "../src/v4/TickMath.sol";
import {LiquidityAmounts} from "../src/v4/LiquidityAmounts.sol";
import {StonkzFeeHook} from "../src/StonkzFeeHook.sol";
import {HookVanity} from "../src/HookVanity.sol";
import {CTOGovernor} from "../src/CTOGovernor.sol";
import {ICTOGovernor} from "../src/interfaces/IStonkzGovernance.sol";

/// @dev Minimal 18-decimal ERC-20 for a MOONER-like main (1e8 supply class).
contract MoonerLikeToken {
    string public name = "MOONERLIKE";
    string public symbol = "MOONL";
    uint8 public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
    }

    function approve(address spender, uint256 amt) external returns (bool) {
        allowance[msg.sender][spender] = amt;
        return true;
    }

    function transfer(address to, uint256 amt) external returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        return true;
    }

    function transferFrom(address from, address to, uint256 amt) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amt;
        balanceOf[from] -= amt;
        balanceOf[to] += amt;
        return true;
    }
}

/// @title HookFeeDirections — pair-notional fee in all four swap directions vs RH PoolManager
/// @notice Fork-only. New hook (flags 0x0CC) on a MOONER-like pool: 1e8-class supply, ~$4k
///         spot (≈4.65e7 tokens/ETH), hookFeeBps=100. Exercises V4Adapter.swap.
contract HookFeeDirections is Test {
    using PoolIdLibrary for PoolKey;

    address internal constant RH_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant PAIR = address(0);
    address internal constant TREASURY = address(0x7A5E);
    address internal constant CREATOR = address(0xCE0);

    uint16 internal constant BPS = 100;
    int24 internal constant TICK_SPACING = 60;
    int24 internal constant TICK_LO = -887220;
    int24 internal constant TICK_HI = 887220;
    /// @dev ≈ ln(4.65e7)/ln(1.0001), aligned to spacing 60. MOONER spot class ($4k / 1e8).
    int24 internal constant SPOT_TICK = 176580;

    ICanonPM internal manager;
    V4Adapter internal adapter;
    StonkzFeeHook internal hook;
    MoonerLikeToken internal token;
    PoolKey internal key;
    string internal rpcUsed;

    function setUp() public {
        rpcUsed = vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com"));
        vm.createSelectFork(rpcUsed);
        require(block.chainid == 4663, "fork chainId != 4663");

        manager = ICanonPM(RH_POOL_MANAGER);
        require(address(manager).code.length > 0, "RH PM missing code");

        adapter = new V4Adapter(manager);

        CTOGovernor gov = new CTOGovernor();
        hook = _deployFlagHook(gov);
        gov.setRegistry(hook);

        token = new MoonerLikeToken();
        require(address(token) > PAIR, "token must be currency1");

        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(SPOT_TICK);
        key = PoolKey({
            currency0: Currency.wrap(PAIR),
            currency1: Currency.wrap(address(token)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });
        adapter.initialize(key, sqrtPriceX96);

        CanonPoolKey memory ckey = CanonPoolKey({
            currency0: CanonCurrency.wrap(PAIR),
            currency1: CanonCurrency.wrap(address(token)),
            fee: 0,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        assertEq(PoolId.unwrap(key.toId()), keccak256(abi.encode(ckey)), "pool id encode");

        hook.registerPoolCustom(address(token), PAIR, CREATOR, key, BPS);
        assertEq(hook.hookFeeBps(address(token)), BPS);
        hook.validateHookAddress(address(hook));
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, uint160(0x0CC));

        uint256 tokenLiq = 10_000_000 ether;
        uint256 ethLiq = 10 ether;
        token.mint(address(this), tokenLiq + 50_000 ether);
        token.approve(address(adapter), type(uint256).max);
        vm.deal(address(this), address(this).balance + 5_000 ether);

        uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(TICK_LO),
            TickMath.getSqrtRatioAtTick(TICK_HI),
            ethLiq,
            tokenLiq
        );
        require(liq > 0, "liq");
        adapter.modifyLiquidity{value: ethLiq}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: TICK_LO,
                tickUpper: TICK_HI,
                liquidityDelta: int256(uint256(liq)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev (a) All four directions: fee = 1% of pair notional, not 1% of token-wei as ETH.
    function test_a_four_directions_pair_notional() public {
        _assertTokenUnchanged(_swapExactInBuy(0.001 ether));
        _assertTokenUnchanged(_swapExactOutBuy(1_000 ether));
        _assertTokenUnchanged(_swapExactInSell(10_000 ether));
        _assertTokenUnchanged(_swapExactOutSell(1e12));
    }

    /// @dev (b) Exact-in buy 0.001 ETH → 1e13 wei fee (live-correct specified take).
    function test_b_exactIn_buy_fee_matches_live_1e13() public {
        uint256 fee = _swapExactInBuy(0.001 ether);
        assertEq(fee, 1e13, "0.001 ETH in -> 1e13 wei fee");
    }

    /// @dev (c) Hook launch-token balance never increases from any direction.
    function test_c_fee_currency_invariant_token_balance() public {
        test_a_four_directions_pair_notional();
    }

    /// @dev (d) 75/25 split + flush in all four directions.
    function test_d_split_accrual_flush() public {
        uint256 rec0 = hook.receiverPairProceeds(address(token));
        uint256 prot0 = hook.tokenPairProceeds(address(token));

        uint256 f1 = _swapExactInBuy(0.001 ether);
        uint256 f2 = _swapExactOutBuy(1_000 ether);
        uint256 f3 = _swapExactInSell(10_000 ether);
        uint256 f4 = _swapExactOutSell(1e12);
        uint256 fees = f1 + f2 + f3 + f4;

        uint256 rec = hook.receiverPairProceeds(address(token)) - rec0;
        uint256 prot = hook.tokenPairProceeds(address(token)) - prot0;
        assertEq(rec + prot, fees, "accrued == taken");
        // 2500 bps protocol, floored per swap — sum of floors, not floor of sum.
        uint256 protExpect = (f1 * 2500) / 10_000 + (f2 * 2500) / 10_000 + (f3 * 2500) / 10_000
            + (f4 * 2500) / 10_000;
        assertEq(prot, protExpect, "25% protocol");
        assertEq(rec, fees - protExpect, "75% receiver");

        uint256 creatorBefore = CREATOR.balance;
        uint256 treasuryBefore = TREASURY.balance;
        hook.flush(address(token));
        assertEq(CREATOR.balance - creatorBefore, rec, "flush receiver");
        assertEq(TREASURY.balance - treasuryBefore, prot, "flush treasury");
        assertEq(hook.receiverPairProceeds(address(token)), 0);
        assertEq(hook.tokenPairProceeds(address(token)), 0);
    }

    /// @dev (e) Permissionless V4Adapter.swap{value} cannot replay the silent-overcharge vector.
    function test_e_adapter_cannot_overcharge_exactIn_sell() public {
        uint256 hookBefore = address(hook).balance;
        uint256 tokBefore = token.balanceOf(address(hook));
        // Old vector: 100-token exact-in sell + 2 ETH attached → hook took 1 ETH.
        BalanceDelta d = adapter.swap{value: 2 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(100 ether),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        uint256 fee = address(hook).balance - hookBefore;
        assertEq(token.balanceOf(address(hook)), tokBefore, "token invariant");
        assertTrue(fee != 1 ether, "old silent-overcharge (1 ETH) must not recur");
        assertLt(fee, 0.01 ether, "fee is 1% of ETH out, not 1% of token-wei");
        // User ETH delta is a credit (sell) after refund; must not be a ~1 ETH debt.
        int128 d0 = d.amount0();
        assertTrue(d0 > 0, "seller receives ETH");
        assertLt(uint256(uint128(d0)), 1 ether, "ETH out is tiny, not a 1 ETH hook debt");
        console2.log("adapter 100-token sell fee wei", fee);
        console2.log("adapter 100-token sell user d0", uint256(uint128(d0)));
    }

    // ── direction helpers ────────────────────────────────────────────────

    function _swapExactInBuy(uint256 ethIn) internal returns (uint256 fee) {
        uint256 hookBefore = address(hook).balance;
        uint256 tokBefore = token.balanceOf(address(hook));
        adapter.swap{value: ethIn}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: -int256(ethIn),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        fee = address(hook).balance - hookBefore;
        assertEq(token.balanceOf(address(hook)), tokBefore, "token invariant buy exact-in");
        assertEq(fee, (ethIn * BPS) / 10_000, "exact-in buy = 1% of specified ETH");
        console2.log("exact-in buy fee", fee);
    }

    function _swapExactOutBuy(uint256 tokensOut) internal returns (uint256 fee) {
        uint256 hookBefore = address(hook).balance;
        uint256 tokBefore = token.balanceOf(address(hook));
        BalanceDelta d = adapter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true,
                amountSpecified: int256(tokensOut),
                sqrtPriceLimitX96: TickMath.MIN_SQRT_RATIO + 1
            }),
            ""
        );
        fee = address(hook).balance - hookBefore;
        assertEq(token.balanceOf(address(hook)), tokBefore, "token invariant buy exact-out");

        // Old bug: fee = tokensOut * 100 / 10_000 = 10 ETH for 1_000 tokens.
        uint256 broken = (tokensOut * BPS) / 10_000;
        assertTrue(fee != broken, "must not take 1% of token-wei as ETH");
        assertTrue(fee != 10 ether, "negative: old exact-out buy overcharge");

        int128 d0 = d.amount0();
        require(d0 < 0, "buyer pays ETH");
        uint256 userPaid = uint256(uint128(-d0));
        uint256 poolIn = userPaid - fee;
        assertEq(fee, (poolIn * BPS) / 10_000, "fee = 1% of actual ETH input");
        assertLt(fee, 0.01 ether, "fee is ~1% of ~2e-5 ETH, not 10 ETH");
        console2.log("exact-out buy 1000 tokens fee", fee);
        console2.log("exact-out buy pool ETH in", poolIn);
        console2.log("exact-out buy BROKEN would be", broken);
    }

    function _swapExactInSell(uint256 tokensIn) internal returns (uint256 fee) {
        uint256 hookBefore = address(hook).balance;
        uint256 tokBefore = token.balanceOf(address(hook));
        BalanceDelta d = adapter.swap{value: 2 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(tokensIn),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        fee = address(hook).balance - hookBefore;
        assertEq(token.balanceOf(address(hook)), tokBefore, "token invariant sell exact-in");

        uint256 broken = (tokensIn * BPS) / 10_000;
        assertTrue(fee != broken, "must not take 1% of token-wei as ETH");
        assertTrue(fee != 100 ether, "negative: old exact-in sell 10k-token fee");

        int128 d0 = d.amount0();
        require(d0 > 0, "seller receives ETH");
        uint256 userOut = uint256(uint128(d0));
        uint256 gross = userOut + fee;
        assertEq(fee, (gross * BPS) / 10_000, "fee = 1% of ETH received (gross)");
        assertLt(fee, 1 ether, "fee is ~1% of ETH out, not 100 ETH");
        console2.log("exact-in sell tokens", tokensIn);
        console2.log("exact-in sell fee", fee);
        console2.log("exact-in sell ETH gross", gross);
        console2.log("exact-in sell BROKEN would be", broken);
    }

    function _swapExactOutSell(uint256 ethOut) internal returns (uint256 fee) {
        uint256 hookBefore = address(hook).balance;
        uint256 tokBefore = token.balanceOf(address(hook));
        adapter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false,
                amountSpecified: int256(ethOut),
                sqrtPriceLimitX96: TickMath.MAX_SQRT_RATIO - 1
            }),
            ""
        );
        fee = address(hook).balance - hookBefore;
        assertEq(token.balanceOf(address(hook)), tokBefore, "token invariant sell exact-out");
        assertEq(fee, (ethOut * BPS) / 10_000, "exact-out sell = 1% of specified ETH");
        console2.log("exact-out sell fee", fee);
    }

    function _assertTokenUnchanged(uint256) internal view {
        // token invariant asserted inside each _swap*; this keeps (a) explicit.
    }

    function _deployFlagHook(CTOGovernor gov) internal returns (StonkzFeeHook h) {
        bytes memory creation = abi.encodePacked(
            type(StonkzFeeHook).creationCode,
            abi.encode(IPoolManager(address(adapter)), TREASURY, ICTOGovernor(address(gov)), address(this))
        );
        bytes32 initCodeHash = keccak256(creation);
        bytes32 salt;
        address predicted;
        uint256 freemem;
        assembly {
            freemem := mload(0x40)
        }
        bool found;
        for (uint256 i; i < 1_000_000; ++i) {
            assembly {
                mstore(0x40, freemem)
            }
            salt = bytes32(i);
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, initCodeHash))))
            );
            if ((uint160(predicted) & Hooks.ALL_HOOK_MASK) == HookVanity.HOOK_FLAGS) {
                found = true;
                break;
            }
        }
        require(found, "no flag salt");
        h = new StonkzFeeHook{salt: salt}(
            IPoolManager(address(adapter)), TREASURY, ICTOGovernor(address(gov)), address(this)
        );
        require(address(h) == predicted, "flag create2");
        h.validateHookAddress(address(h));
    }

    receive() external payable {}
}
