// SPDX-License-Identifier: Apache-2.0
// Copyright 2025 Aztlan Labs

pragma solidity ^0.8.19;

import "@oz/token/ERC20/IERC20.sol";
import "@oz/token/ERC20/utils/SafeERC20.sol";
import "@oz/access/Ownable.sol";

// Simplified status enum from StakingLib
enum Status {
    NONE,
    VALIDATING,
    ZOMBIE,
    EXITING
}

struct Exit {
    uint256 withdrawalId;
    uint256 amount;
    uint256 exitableAt;
    address recipient;
    bool exists;
}

contract StakingStub is Ownable {
    using SafeERC20 for IERC20;

    IERC20 public immutable stakingToken;
    uint256 public constant DEPOSIT_AMOUNT = 32 ether; // Fixed deposit amount like StakingLib
    uint256 public exitDelay = 1 days; // Simplified exit delay

    mapping(address => Status) public status;
    mapping(address => Exit) public exits;
    mapping(address => uint256) public effectiveBalance;

    address public slasher;

    event Deposited(address indexed attester, uint256 amount);
    event WithdrawalInitiated(address indexed attester, address recipient, uint256 amount);
    event WithdrawFinalised(address indexed attester, address recipient, uint256 amount);
    event Slashed(address indexed attester, uint256 amount);

    constructor(address _stakingToken, address initialOwner) Ownable(initialOwner) {
        stakingToken = IERC20(_stakingToken);
        slasher = initialOwner; // Owner can slash for testing
    }

    // Deposit function - imitating StakingLib.deposit()
    function deposit(address attester) external {
        require(status[attester] == Status.NONE, "Already deposited");
        require(attester != address(0), "Invalid attester");

        stakingToken.safeTransferFrom(msg.sender, address(this), DEPOSIT_AMOUNT);

        status[attester] = Status.VALIDATING;
        effectiveBalance[attester] = DEPOSIT_AMOUNT;

        emit Deposited(attester, DEPOSIT_AMOUNT);
    }

    // Initiate withdrawal - imitating StakingLib.initiateWithdraw()
    function initiateWithdraw(address attester, address recipient) external returns (bool) {
        require(recipient != address(0), "Invalid recipient");
        require(status[attester] == Status.VALIDATING, "Not validating");
        require(msg.sender == attester, "Not attester");

        uint256 amount = effectiveBalance[attester];
        require(amount > 0, "No balance");

        status[attester] = Status.EXITING;
        exits[attester] = Exit({
            withdrawalId: 0, // Simplified
            amount: amount,
            exitableAt: block.timestamp + exitDelay,
            recipient: recipient,
            exists: true
        });

        emit WithdrawalInitiated(attester, recipient, amount);
        return true;
    }

    // Finalise withdrawal - imitating StakingLib.finaliseWithdraw()
    function finaliseWithdraw(address attester) external {
        Exit memory exit = exits[attester];
        require(exit.exists, "Not exiting");
        require(exit.exitableAt <= block.timestamp, "Not yet exitable");

        delete exits[attester];
        status[attester] = Status.NONE;
        effectiveBalance[attester] = 0;

        stakingToken.safeTransfer(exit.recipient, exit.amount);

        emit WithdrawFinalised(attester, exit.recipient, exit.amount);
    }

    // Slash function - imitating StakingLib.slash()
    function slash(address attester, uint256 amount) external {
        require(msg.sender == slasher, "Not slasher");

        if (exits[attester].exists) {
            // If exiting, slash from exit amount
            if (exits[attester].amount >= amount) {
                exits[attester].amount -= amount;
            } else {
                exits[attester].amount = 0;
            }
        } else {
            // Slash from effective balance
            if (effectiveBalance[attester] >= amount) {
                effectiveBalance[attester] -= amount;
            } else {
                effectiveBalance[attester] = 0;
            }
            // If balance goes to 0, set to ZOMBIE
            if (effectiveBalance[attester] == 0 && status[attester] == Status.VALIDATING) {
                status[attester] = Status.ZOMBIE;
            }
        }

        emit Slashed(attester, amount);
    }

    // Get attester view - imitating StakingLib.getAttesterView()
    function getAttesterView(address attester) external view returns (Status, uint256, Exit memory) {
        return (status[attester], effectiveBalance[attester], exits[attester]);
    }

    // Set exit delay for testing
    function setExitDelay(uint256 _exitDelay) external onlyOwner {
        exitDelay = _exitDelay;
    }

    // Set slasher
    function setSlasher(address _slasher) external onlyOwner {
        slasher = _slasher;
    }
}
