// SPDX-License-Identifier: Apache-2.0
pragma solidity >=0.8.24 <0.9.0;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { Exit, Status, Timestamp } from "src/libraries/AztecTypes.sol";
import { G1Point, G2Point } from "src/libraries/BN254Lib.sol";
import { IMockAztecRollup } from "src/mocks/IMockAztecRollup.sol";

/// @title MockAztecRollup
/// @notice Mock Aztec rollup for testing staking flows.
/// @dev Implements a subset of IStaking interface for testing.
/// @author Olla Core contributors
contract MockAztecRollup is IMockAztecRollup {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    IERC20 public immutable STAKING_ASSET;
    uint256 private _activationThreshold;

    /// @inheritdoc IMockAztecRollup
    mapping(address attester => uint256 stake) public stakes;
    /// @inheritdoc IMockAztecRollup
    mapping(address attester => address withdrawer) public withdrawers;
    mapping(address attester => Exit exit) private _exits;
    /// @inheritdoc IMockAztecRollup
    mapping(address sequencer => uint256 rewards) public pendingRewards;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 stakingAsset, uint256 activationThreshold) {
        STAKING_ASSET = stakingAsset;
        _activationThreshold = activationThreshold;
    }

    /*//////////////////////////////////////////////////////////////
                            STAKING FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function deposit(
        address _attester,
        address _withdrawer,
        G1Point calldata _publicKeyInG1,
        G2Point calldata _publicKeyInG2,
        G1Point calldata _proofOfPossession,
        bool
    ) external override {
        STAKING_ASSET.safeTransferFrom(msg.sender, address(this), _activationThreshold);
        stakes[_attester] = _activationThreshold;
        withdrawers[_attester] = _withdrawer;
        emit Deposit(_attester, _withdrawer, _publicKeyInG1, _publicKeyInG2, _proofOfPossession, _activationThreshold);
    }

    /// @inheritdoc IMockAztecRollup
    function initiateWithdraw(address _attester, address _recipient) external override returns (bool) {
        if (withdrawers[_attester] != msg.sender) {
            revert MockAztecRollup__NotWithdrawer();
        }
        if (_exits[_attester].exists) {
            revert MockAztecRollup__AlreadyExiting();
        }

        uint256 amount = stakes[_attester];
        _exits[_attester] = Exit({
            withdrawalId: 0,
            amount: amount,
            exitableAt: Timestamp.wrap(block.timestamp), // Immediate for testing
            recipientOrWithdrawer: _recipient,
            isRecipient: true,
            exists: true
        });

        emit WithdrawInitiated(_attester, _recipient, amount);
        return true;
    }

    /// @inheritdoc IMockAztecRollup
    function finalizeWithdraw(address _attester) external override {
        Exit memory exit = _exits[_attester];
        if (!exit.exists) {
            revert MockAztecRollup__NotExiting();
        }
        if (!exit.isRecipient) {
            revert MockAztecRollup__InitiateWithdrawNeeded();
        }
        if (Timestamp.unwrap(exit.exitableAt) > block.timestamp) {
            revert MockAztecRollup__NotReady();
        }

        uint256 amount = exit.amount;
        stakes[_attester] = 0;
        delete _exits[_attester];

        STAKING_ASSET.safeTransfer(exit.recipientOrWithdrawer, amount);
        emit WithdrawFinalized(_attester, exit.recipientOrWithdrawer, amount);
    }

    /// @inheritdoc IMockAztecRollup
    function claimSequencerRewards(address _recipient) external override returns (uint256) {
        uint256 amount = pendingRewards[msg.sender];
        if (amount > 0) {
            pendingRewards[msg.sender] = 0;
            STAKING_ASSET.safeTransfer(_recipient, amount);
            emit RewardsClaimed(msg.sender, _recipient, amount);
        }
        return amount;
    }

    /*//////////////////////////////////////////////////////////////
                             TEST HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function setRewards(address _sequencer, uint256 _amount) external override {
        pendingRewards[_sequencer] = _amount;
    }

    /// @inheritdoc IMockAztecRollup
    function setActivationThreshold(uint256 _threshold) external override {
        _activationThreshold = _threshold;
    }

    /// @inheritdoc IMockAztecRollup
    function setExitReady(address _attester, uint256 _exitableAt) external override {
        if (_exits[_attester].exists) {
            _exits[_attester].exitableAt = Timestamp.wrap(_exitableAt);
        }
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function getExit(address _attester) external view override returns (Exit memory) {
        return _exits[_attester];
    }

    /// @inheritdoc IMockAztecRollup
    function getStatus(address _attester) external view override returns (Status) {
        if (_exits[_attester].exists) {
            return _exits[_attester].isRecipient ? Status.EXITING : Status.ZOMBIE;
        }
        return stakes[_attester] > 0 ? Status.VALIDATING : Status.NONE;
    }

    /// @inheritdoc IMockAztecRollup
    function getActivationThreshold() external view override returns (uint256) {
        return _activationThreshold;
    }

    /// @inheritdoc IMockAztecRollup
    function getSequencerRewards(address _sequencer) external view override returns (uint256) {
        return pendingRewards[_sequencer];
    }

    /// @inheritdoc IMockAztecRollup
    function getActiveAttesterCount() external pure override returns (uint256) {
        return 0;
    }
}
