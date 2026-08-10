// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title DeployControls — factory switches: deploysEnabled + allowlist (docs/03 Factory switches)
/// @notice Mutable on each factory instance; gate checked at file/list. Stamp switches (side/lock)
///         land in later phases. Allowlist is NOT renounceable — purpose = factory migration.
/// @dev Birth state (RIDER A): deploysEnabled=true + allowlist = {constructor msg.sender}.
///      Semantics: off → all blocked; on+empty → open; on+nonempty → allowlisted only.
abstract contract DeployControls {
    address public owner;

    /// @notice Master deploy switch. False blocks every file/list regardless of allowlist.
    bool public deploysEnabled;

    /// @notice Owner-managed deployer set. Empty + deploysEnabled ⇒ open (any caller).
    mapping(address => bool) public isDeployerAllowed;

    /// @notice Count of allowlisted addresses. Used to distinguish empty vs nonempty without iteration.
    uint256 public allowlistCount;

    event OwnerTransferred(address indexed prev, address indexed next);
    event DeploysEnabled(bool enabled);
    event DeployerAllowed(address indexed deployer);
    event DeployerRevoked(address indexed deployer);

    error NotOwner();
    error DeploysOff();
    error DeployerNotAllowed();
    error ZeroAddress();
    error AlreadyAllowed();
    error NotOnAllowlist();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @dev Soft-launch gate closed at birth: on + deployer-only allowlist (RIDER A).
    constructor() {
        owner = msg.sender;
        deploysEnabled = true;
        isDeployerAllowed[msg.sender] = true;
        allowlistCount = 1;
        emit DeploysEnabled(true);
        emit DeployerAllowed(msg.sender);
    }

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        emit OwnerTransferred(owner, next);
        owner = next;
    }

    function setDeploysEnabled(bool enabled) external onlyOwner {
        deploysEnabled = enabled;
        emit DeploysEnabled(enabled);
    }

    function allowDeployer(address deployer) external onlyOwner {
        if (deployer == address(0)) revert ZeroAddress();
        if (isDeployerAllowed[deployer]) revert AlreadyAllowed();
        isDeployerAllowed[deployer] = true;
        unchecked {
            ++allowlistCount;
        }
        emit DeployerAllowed(deployer);
    }

    /// @notice Remove a deployer. Emptying the list (open mode) is allowed; the allowlist
    ///         *feature* is not renounceable — owner can always re-add.
    function revokeDeployer(address deployer) external onlyOwner {
        if (!isDeployerAllowed[deployer]) revert NotOnAllowlist();
        isDeployerAllowed[deployer] = false;
        unchecked {
            --allowlistCount;
        }
        emit DeployerRevoked(deployer);
    }

    /// @notice Soft-launch / migration gate. docs/03 switch 4.
    function _requireDeployAllowed(address account) internal view {
        if (!deploysEnabled) revert DeploysOff();
        if (allowlistCount > 0 && !isDeployerAllowed[account]) revert DeployerNotAllowed();
    }

    /// @notice Deploy-script / ops assertion for RIDER A birth (or post-config) state.
    /// @dev Reverts if soft-launch gate is not closed: must be enabled + nonempty allowlist
    ///      containing `expectedDeployer`.
    function assertSoftLaunchGate(address expectedDeployer) public view {
        if (!deploysEnabled) revert DeploysOff();
        if (allowlistCount == 0) revert DeployerNotAllowed();
        if (!isDeployerAllowed[expectedDeployer]) revert DeployerNotAllowed();
    }
}
