// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {FixedPointMathLib} from "solady/utils/FixedPointMathLib.sol";
import {IPoolManager} from "./v4/IPoolManager.sol";
import {PoolKey, PoolId, PoolIdLibrary} from "./v4/types/PoolKey.sol";
import {Currency} from "./v4/types/Currency.sol";

/// @notice Swap adapter for buy-and-burn. Spends pair from accumulator; returns side tokens to it.
interface IBuyExecutor {
    /// @param amountIn Pair units to spend (already pulled/approved from accumulator).
    /// @param minAmountOut Minimum side tokens (slippage floor from accumulator).
    /// @return amountOut Side tokens transferred to `msg.sender` (the accumulator).
    function buyExactIn(uint256 amountIn, uint256 minAmountOut) external payable returns (uint256 amountOut);
}

/// @title BuybackAccumulator — manual DCA buy-and-burn (PREDEPLOY-REFIT Phase 2 / spec §8.3)
/// @notice Manual funding only (ETH receive / ERC20 fund). No automatic fee path.
///         Park/strategy surface RETIRED. Crank: owner or keeper; pct of remaining; rate-limited;
///         slippage vs pre-swap pool spot; burn sideTokenRef to dEaD atomically.
contract BuybackAccumulator {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint256;

    uint256 internal constant WAD = 1e18;

    /// @dev Hard crank-size band on pctBps: 0.01%–20% of remaining.
    uint16 public constant PCT_BPS_HARD_MIN = 1;
    uint16 public constant PCT_BPS_HARD_MAX = 2000;
    /// @dev Hard slippage cap: 10%.
    uint16 public constant MAX_SLIPPAGE_BPS_CAP = 1000;

    address public owner;
    address public keeper;
    /// @notice Pair currency (address(0)=ETH). Manual fund only.
    address public immutable pairToken;
    /// @notice Side token bought+burned at crank time (settable).
    address public sideTokenRef;
    address public immutable burnSink;
    IPoolManager public poolManager;
    /// @notice Pool used for pre-swap spot (slippage). Executor performs the buy.
    PoolKey public buyPoolKey;
    bool public buyPoolKeySet;
    IBuyExecutor public executor;

    /// @notice Owner-settable crank band of remaining balance. Launch defaults 100–300 (1–3%).
    uint16 public minPctBps = 100;
    uint16 public maxPctBps = 300;
    /// @notice Owner-settable min seconds between cranks. Launch default 1 hour.
    uint64 public minCrankInterval = 1 hours;
    /// @notice Owner-settable max slippage vs pre-swap spot. Launch default 100 (1%). Cap 1000.
    uint16 public maxSlippageBps = 100;

    uint256 public pairBalance;
    uint256 public lastCrankTime;
    uint256 public totalBurned;
    uint256 public totalPairSpent;

    event OwnershipTransferred(address indexed prev, address indexed next);
    event KeeperSet(address indexed keeper);
    event SideTokenRefSet(address indexed sideToken);
    event PoolManagerSet(address indexed poolManager);
    event BuyPoolKeySet(PoolId indexed id);
    event ExecutorSet(address indexed executor);
    event CrankBandSet(uint16 minPctBps, uint16 maxPctBps);
    event MinCrankIntervalSet(uint64 seconds_);
    event MaxSlippageBpsSet(uint16 bps);
    event Funded(address indexed from, uint256 amount);
    event Cranked(uint256 amountIn, uint256 amountOut, uint256 burned, uint256 priceWad, address indexed caller);

    error NotOwner();
    error NotKeeperOrOwner();
    error ZeroAddress();
    error NotContract();
    error NothingToCrank();
    error SideTokenRefUnset();
    error ExecutorUnset();
    error BuyPoolUnset();
    error PoolManagerUnset();
    error CrankTooSoon(uint256 nextAllowed);
    error PctOutOfBand(uint16 pctBps, uint16 minBps, uint16 maxBps);
    error BandOutOfHardBounds();
    error SlippageOutOfHardCap(uint16 bps);
    error SlippageExceeded(uint256 minOut, uint256 amountOut);
    error TransferFailed();
    error BadPair();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address pairToken_, address sideTokenRef_, address burnSink_) {
        owner = msg.sender;
        pairToken = pairToken_;
        if (sideTokenRef_ != address(0) && sideTokenRef_.code.length == 0) revert NotContract();
        sideTokenRef = sideTokenRef_;
        burnSink = burnSink_ == address(0) ? address(0x000000000000000000000000000000000000dEaD) : burnSink_;
        if (sideTokenRef_ != address(0)) emit SideTokenRefSet(sideTokenRef_);
    }

    receive() external payable {
        if (pairToken != address(0)) revert BadPair();
        pairBalance += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Manual ETH top-up when pairToken==0.
    function fundETH() external payable {
        if (pairToken != address(0)) revert BadPair();
        if (msg.value == 0) revert NothingToCrank();
        pairBalance += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Manual ERC20 pair top-up when pairToken!=0. Pulls `amount` from caller.
    function fundERC20(uint256 amount) external {
        if (pairToken == address(0)) revert BadPair();
        if (amount == 0) revert NothingToCrank();
        _pullERC20(msg.sender, amount);
        pairBalance += amount;
        emit Funded(msg.sender, amount);
    }

    /// @notice Legacy alias — manual top-up only (FEECHAIN: no automatic fee path).
    function receiveFees() external payable {
        if (pairToken != address(0)) revert BadPair();
        if (msg.value == 0) revert NothingToCrank();
        pairBalance += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    /// @notice Legacy carve entry — manual ETH fund when pairToken==0.
    function receiveCarve() external payable {
        if (pairToken != address(0)) revert BadPair();
        if (msg.value == 0) revert NothingToCrank();
        pairBalance += msg.value;
        emit Funded(msg.sender, msg.value);
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, next);
        owner = next;
    }

    function setKeeper(address k) external onlyOwner {
        keeper = k;
        emit KeeperSet(k);
    }

    function setSideTokenRef(address sideToken) external onlyOwner {
        if (sideToken != address(0) && sideToken.code.length == 0) revert NotContract();
        sideTokenRef = sideToken;
        emit SideTokenRefSet(sideToken);
    }

    function setPoolManager(address pm) external onlyOwner {
        if (pm == address(0) || pm.code.length == 0) revert NotContract();
        poolManager = IPoolManager(pm);
        emit PoolManagerSet(pm);
    }

    function setBuyPoolKey(PoolKey calldata key) external onlyOwner {
        buyPoolKey = key;
        buyPoolKeySet = true;
        emit BuyPoolKeySet(key.toId());
    }

    function setExecutor(address exec) external onlyOwner {
        if (exec == address(0) || exec.code.length == 0) revert NotContract();
        executor = IBuyExecutor(exec);
        emit ExecutorSet(exec);
    }

    function setCrankBand(uint16 minBps, uint16 maxBps) external onlyOwner {
        if (minBps < PCT_BPS_HARD_MIN || maxBps > PCT_BPS_HARD_MAX || minBps > maxBps) {
            revert BandOutOfHardBounds();
        }
        minPctBps = minBps;
        maxPctBps = maxBps;
        emit CrankBandSet(minBps, maxBps);
    }

    function setMinCrankInterval(uint64 seconds_) external onlyOwner {
        minCrankInterval = seconds_;
        emit MinCrankIntervalSet(seconds_);
    }

    function setMaxSlippageBps(uint16 bps) external onlyOwner {
        if (bps > MAX_SLIPPAGE_BPS_CAP) revert SlippageOutOfHardCap(bps);
        maxSlippageBps = bps;
        emit MaxSlippageBpsSet(bps);
    }

    /// @notice Buy `pctBps` of remaining pairBalance → sideTokenRef → burn to dEaD.
    /// @dev Caller = owner or keeper. Size ∈ [minPctBps, maxPctBps]. Rate-limited.
    function crank(uint16 pctBps) external returns (uint256 amountIn, uint256 amountOut, uint256 burned) {
        if (msg.sender != owner && msg.sender != keeper) revert NotKeeperOrOwner();
        if (sideTokenRef == address(0)) revert SideTokenRefUnset();
        if (address(executor) == address(0)) revert ExecutorUnset();
        if (address(poolManager) == address(0)) revert PoolManagerUnset();
        if (!buyPoolKeySet) revert BuyPoolUnset();
        if (pctBps < minPctBps || pctBps > maxPctBps) revert PctOutOfBand(pctBps, minPctBps, maxPctBps);
        if (lastCrankTime != 0 && block.timestamp < lastCrankTime + minCrankInterval) {
            revert CrankTooSoon(lastCrankTime + minCrankInterval);
        }
        if (pairBalance == 0) revert NothingToCrank();

        amountIn = FixedPointMathLib.fullMulDiv(pairBalance, pctBps, 10_000);
        if (amountIn == 0) revert NothingToCrank();

        uint256 spotWad = _spotPairPerSideWad();
        // spotWad = pair-wei per side-token. fairOut = amountIn * WAD / spotWad.
        uint256 fairOut = FixedPointMathLib.fullMulDiv(amountIn, WAD, spotWad);
        uint256 minOut = fairOut - FixedPointMathLib.fullMulDiv(fairOut, maxSlippageBps, 10_000);

        pairBalance -= amountIn;
        lastCrankTime = block.timestamp;

        uint256 ethVal;
        if (pairToken == address(0)) {
            ethVal = amountIn;
        } else {
            _approveERC20(address(executor), amountIn);
        }

        amountOut = executor.buyExactIn{value: ethVal}(amountIn, minOut);
        if (amountOut < minOut) revert SlippageExceeded(minOut, amountOut);

        // Execution price = pair per side.
        uint256 execPriceWad = FixedPointMathLib.fullMulDiv(amountIn, WAD, amountOut);
        uint256 maxPrice = spotWad + FixedPointMathLib.fullMulDiv(spotWad, maxSlippageBps, 10_000);
        uint256 minPrice = spotWad > FixedPointMathLib.fullMulDiv(spotWad, maxSlippageBps, 10_000)
            ? spotWad - FixedPointMathLib.fullMulDiv(spotWad, maxSlippageBps, 10_000)
            : 0;
        if (execPriceWad > maxPrice || execPriceWad < minPrice) {
            revert SlippageExceeded(minOut, amountOut);
        }

        burned = amountOut;
        _pushERC20(sideTokenRef, burnSink, burned);
        totalBurned += burned;
        totalPairSpent += amountIn;
        emit Cranked(amountIn, amountOut, burned, execPriceWad, msg.sender);
    }

    /// @dev Spot as pair-wei per side-token, WAD, from buyPoolKey slot0.
    function _spotPairPerSideWad() internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = poolManager.getSlot0(buyPoolKey.toId());
        uint256 ratioX192 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        address key0 = Currency.unwrap(buyPoolKey.currency0);
        bool pairIsToken0 = key0 == pairToken;
        // token1/token0 = ratioX192 / 2^192.
        // If pair is token1: pair/side = token1/token0.
        // If pair is token0: pair/side = token0/token1 = 2^192 / ratioX192.
        if (pairIsToken0) {
            return FixedPointMathLib.fullMulDiv(uint256(1) << 192, WAD, ratioX192);
        }
        return FixedPointMathLib.fullMulDiv(ratioX192, WAD, uint256(1) << 192);
    }

    function _pullERC20(address from, uint256 amount) internal {
        (bool ok, bytes memory data) = pairToken.call(
            abi.encodeWithSignature("transferFrom(address,address,uint256)", from, address(this), amount)
        );
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _approveERC20(address spender, uint256 amount) internal {
        (bool ok,) = pairToken.call(abi.encodeWithSignature("approve(address,uint256)", spender, 0));
        ok;
        (bool ok2, bytes memory data) =
            pairToken.call(abi.encodeWithSignature("approve(address,uint256)", spender, amount));
        if (!ok2 || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _pushERC20(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory data) = token.call(abi.encodeWithSignature("transfer(address,uint256)", to, amount));
        if (!ok || (data.length != 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
