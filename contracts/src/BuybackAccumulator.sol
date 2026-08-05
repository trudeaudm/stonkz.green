// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title BuybackAccumulator — carve + pre-genesis parking + manual DCA (spec §8.3)
/// @notice Immutable. Automatic main-fee routing RETIRED (FEECHAIN Phase 4). Remains treasury's
///         manually-funded DCA instrument: settle carve, park/release side tokens, permissionless
///         bounded STONKZ4663 buy + burn. `receiveFees` is manual top-up only.
contract BuybackAccumulator {
    uint256 public constant MAX_BUY_PER_CRANK = 500 ether; // hardcoded bound — no admin
    uint256 public constant CRANK_COOLDOWN = 30; // seconds

    address public immutable pairToken; // USDG / WETH (native = address(0) accepted as ETH)
    address public immutable stonkz4663; // address(0) until genesis; crank reverts until set via constructor
    address public immutable burnSink; // typically address(0xdead) or token burn

    uint256 public pairBalance; // tracked carve + fees (ETH or ERC20 units)
    uint256 public parkedSidePoolTokens; // pre-genesis side-pool parking (spec §8.2a)
    uint256 public lastCrankTime;
    uint256 public totalBurned;

    event CarveReceived(address indexed from, uint256 amount);
    event FeeReceived(address indexed from, uint256 amount);
    event SidePoolParked(address indexed from, uint256 tokens);
    event SidePoolReleased(address indexed to, uint256 tokens);
    event BuyAndBurn(uint256 pairSpent, uint256 stonkzBurned, address indexed cranker);

    error CooldownActive(uint256 nextAllowed);
    error NothingToCrank();
    error GenesisNotLive();
    error OnlyStrategy();

    address public strategy; // set once — StonkzLiquidityStrategy / authorized depositor

    constructor(address pairToken_, address stonkz4663_, address burnSink_) {
        pairToken = pairToken_;
        stonkz4663 = stonkz4663_;
        burnSink = burnSink_ == address(0) ? address(0x000000000000000000000000000000000000dEaD) : burnSink_;
    }

    /// @notice One-shot wiring after LiquidityStrategy deploy (immutable thereafter).
    function setStrategy(address strategy_) external {
        require(strategy == address(0), "set");
        strategy = strategy_;
    }

    receive() external payable {
        pairBalance += msg.value;
        emit CarveReceived(msg.sender, msg.value);
    }

    /// @notice Receive pair-currency carve from settle (spec §8.1). Native ETH path.
    function receiveCarve() external payable {
        require(msg.value > 0, "zero");
        pairBalance += msg.value;
        emit CarveReceived(msg.sender, msg.value);
    }

    /// @notice Manual pair-currency top-up for DCA (FEECHAIN Phase 4: no automatic fee path).
    function receiveFees() external payable {
        require(msg.value > 0, "zero");
        pairBalance += msg.value;
        emit FeeReceived(msg.sender, msg.value);
    }

    /// @notice Pre-genesis park of side-pool user tokens (spec §8.2a).
    function parkSidePoolTokens(uint256 amount) external {
        require(msg.sender == strategy || strategy == address(0), "auth");
        require(amount > 0, "zero");
        parkedSidePoolTokens += amount;
        emit SidePoolParked(msg.sender, amount);
    }

    /// @notice Release parked tokens to deploySidePool (permissionless caller; tokens credited to `to`).
    function releaseSidePoolTokens(address to) external returns (uint256 amount) {
        amount = parkedSidePoolTokens;
        require(amount > 0, "empty");
        parkedSidePoolTokens = 0;
        emit SidePoolReleased(to, amount);
    }

    /// @notice Bounded STONKZ4663 market buy + burn. Hardcoded size cap + cooldown (spec §8.3).
    function crankBuyAndBurn() external returns (uint256 pairSpent, uint256 burned) {
        if (stonkz4663 == address(0)) revert GenesisNotLive();
        if (lastCrankTime != 0 && block.timestamp < lastCrankTime + CRANK_COOLDOWN) {
            revert CooldownActive(lastCrankTime + CRANK_COOLDOWN);
        }
        if (pairBalance == 0) revert NothingToCrank();

        pairSpent = pairBalance > MAX_BUY_PER_CRANK ? MAX_BUY_PER_CRANK : pairBalance;
        pairBalance -= pairSpent;
        lastCrankTime = block.timestamp;

        // Mock conversion 1:1 until real pool; burn accounting.
        burned = pairSpent;
        totalBurned += burned;
        emit BuyAndBurn(pairSpent, burned, msg.sender);
    }
}
