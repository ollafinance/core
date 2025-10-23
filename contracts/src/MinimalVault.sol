// SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

import "@oz/token/ERC20/IERC20.sol";
import "@oz/token/ERC20/utils/SafeERC20.sol";
import "./GuardianPause.sol";

contract MinimalVault is GuardianPause {
    using SafeERC20 for IERC20;

    IERC20 public immutable aztecToken;
    mapping(address => uint256) public userShares;
    mapping(address => uint256) public pendingWithdrawals;

    uint256 public totalShares;
    uint256 public totalAssets;
    uint256 public accumulatedRewards;
    uint256 public withdrawalBuffer;

    address public internalOperator;

    event Deposited(address indexed user, uint256 assets, uint256 shares);
    event Withdrawn(address indexed user, uint256 assets, uint256 shares);
    event RewardsProcessed(uint256 rewards);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event OperatorAllowanceTransferred(uint256 amount);

    constructor(
        address _aztecToken,
        address _operator,
        address _guardian
    ) GuardianPause(_guardian) {
        aztecToken = IERC20(_aztecToken);
        internalOperator = _operator;
    }

    modifier whenNotPaused() override {
        require(!paused, "Contract paused");
        _;
    }

    function setInternalOperator(address _operator) external onlyOwner {
        require(_operator != address(0), "Invalid operator");
        address oldOperator = internalOperator;
        internalOperator = _operator;
        emit OperatorUpdated(oldOperator, _operator);
    }

    function deposit(uint256 amount) external whenNotPaused {
        require(amount > 0, "Invalid amount");

        // Transfer AZTEC tokens from user to vault
        aztecToken.safeTransferFrom(msg.sender, address(this), amount);

        uint256 shares = calculateShares(amount);
        userShares[msg.sender] += shares;
        totalShares += shares;
        totalAssets += amount;

        // Transfer tokens to operator for staking
        aztecToken.safeTransfer(internalOperator, amount);

        emit Deposited(msg.sender, amount, shares);
    }

    function withdraw(uint256 shares) external whenNotPaused {
        require(userShares[msg.sender] >= shares, "Insufficient shares");

        uint256 assets = calculateAssets(shares);
        userShares[msg.sender] -= shares;
        totalShares -= shares;

        // Try immediate withdrawal from buffer
        if (withdrawalBuffer >= assets) {
            withdrawalBuffer -= assets;
            aztecToken.safeTransfer(msg.sender, assets);
        } else {
            // Queue for later processing
            pendingWithdrawals[msg.sender] += assets;
            // Note: In a real implementation, this would request unstaking
        }

        emit Withdrawn(msg.sender, assets, shares);
    }

    // Process staking rewards (called by internal operator)
    function processRewards(uint256 newRewards) external {
        require(msg.sender == internalOperator, "Not operator");
        require(newRewards > 0, "Invalid rewards amount");

        // Transfer reward tokens from operator to vault
        aztecToken.safeTransferFrom(internalOperator, address(this), newRewards);

        accumulatedRewards += newRewards;
        totalAssets += newRewards;
        withdrawalBuffer += newRewards;

        emit RewardsProcessed(newRewards);
    }

    // Calculate shares based on current exchange rate
    function calculateShares(uint256 assets) public view returns (uint256) {
        if (totalShares == 0) {
            return assets; // 1:1 ratio for first deposit
        }
        return (assets * totalShares) / totalAssets;
    }

    // Calculate assets from shares
    function calculateAssets(uint256 shares) public view returns (uint256) {
        if (totalShares == 0) return 0;
        return (shares * totalAssets) / totalShares;
    }

    // Get user balance information
    function getUserBalance(address user) external view returns (
        uint256 shares,
        uint256 underlyingValue,
        uint256 pendingWithdrawal
    ) {
        shares = userShares[user];
        underlyingValue = calculateAssets(shares);
        pendingWithdrawal = pendingWithdrawals[user];
    }

    // Get vault statistics
    function getVaultStats() external view returns (
        uint256 _totalShares,
        uint256 _totalAssets,
        uint256 _accumulatedRewards,
        uint256 _withdrawalBuffer
    ) {
        return (totalShares, totalAssets, accumulatedRewards, withdrawalBuffer);
    }

    // Emergency function to add to withdrawal buffer (for testing/operator management)
    function addToWithdrawalBuffer(uint256 amount) external onlyOwner {
        require(amount > 0, "Invalid amount");
        withdrawalBuffer += amount;
    }
}
