// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.27;

import { IERC20 } from "@oz/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@oz/token/ERC20/utils/SafeERC20.sol";
import { IERC20Mintable } from "src/interfaces/IERC20Mintable.sol";
import { AttesterConfig, AttesterView, Exit, Status, Timestamp } from "src/staking/libraries/AztecTypes.sol";
import { G1Point, G2Point } from "src/staking/libraries/BN254Lib.sol";
import { IMockAztecRollup } from "src/staking/mocks/IMockAztecRollup.sol";

/// @title MockAztecRollup
/// @notice Mock Aztec rollup for testing staking flows.
/// @dev Implements a subset of IStaking interface for testing.
/// @author Olla Core contributors
contract MockAztecRollup is IMockAztecRollup {
    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Default activation threshold used when constructor arg is 0.
    uint256 public constant DEFAULT_ACTIVATION_THRESHOLD = 200_000e18;

    /// @notice Maximum basis points value (100%).
    uint256 public constant MAX_BPS = 10_000;

    /*//////////////////////////////////////////////////////////////
                                  STATE
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    IERC20 public immutable STAKING_ASSET;
    uint256 private _activationThreshold;

    /// @inheritdoc IMockAztecRollup
    mapping(address attester => uint256 stake) public stakes;
    /// @notice Total stake currently active on the rollup.
    uint256 public totalStaked;
    /// @inheritdoc IMockAztecRollup
    mapping(address attester => address withdrawer) public withdrawers;
    mapping(address attester => Exit exit) private _exits;
    mapping(address attester => G1Point publicKey) private _publicKeys;
    /// @inheritdoc IMockAztecRollup
    mapping(address sequencer => uint256 rewards) public pendingRewards;
    /// @inheritdoc IMockAztecRollup
    mapping(address sequencer => bool shouldFail) public claimShouldFail;

    /// @notice Rewards accrued per second when `tick` is called.
    uint256 public rewardRatePerSecond;
    /// @notice Last timestamp used for reward accrual.
    uint256 public lastTick;

    /// @notice Recipient used for tick() reward accrual.
    address public rewardsCoinbase;

    /*//////////////////////////////////////////////////////////////
                               CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IERC20 stakingAsset, uint256 activationThreshold) {
        STAKING_ASSET = stakingAsset;
        _activationThreshold = activationThreshold == 0 ? DEFAULT_ACTIVATION_THRESHOLD : activationThreshold;
        lastTick = block.timestamp;
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
        uint256 previousStake = stakes[_attester];
        STAKING_ASSET.safeTransferFrom(msg.sender, address(this), _activationThreshold);
        stakes[_attester] = _activationThreshold;
        if (previousStake > 0) {
            totalStaked = totalStaked - previousStake + _activationThreshold;
        } else {
            totalStaked += _activationThreshold;
        }
        withdrawers[_attester] = _withdrawer;
        _publicKeys[_attester] = _publicKeyInG1;
        emit Deposit(_attester, _withdrawer, _publicKeyInG1, _publicKeyInG2, _proofOfPossession, _activationThreshold);
    }

    /// @inheritdoc IMockAztecRollup
    function initiateWithdraw(address _attester, address _recipient) external override returns (bool) {
        if (withdrawers[_attester] != msg.sender) {
            revert MockAztecRollup__NotWithdrawer();
        }
        // Zombie exit (isRecipient=false): claim it by setting recipient
        if (_exits[_attester].exists) {
            if (!_exits[_attester].isRecipient) {
                _exits[_attester].recipientOrWithdrawer = _recipient;
                _exits[_attester].isRecipient = true;
                return true;
            }
            revert MockAztecRollup__AlreadyExiting();
        }

        uint256 amount = stakes[_attester];
        stakes[_attester] = 0;
        if (amount > 0) {
            totalStaked -= amount;
        }

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
    function claimSequencerRewards(address _coinbase) external override returns (uint256) {
        if (claimShouldFail[_coinbase]) {
            revert MockAztecRollup__ClaimFailed();
        }
        uint256 amount = pendingRewards[_coinbase];
        if (amount > 0) {
            pendingRewards[_coinbase] = 0;
            IERC20Mintable(address(STAKING_ASSET)).mint(_coinbase, amount);
            emit RewardsClaimed(_coinbase, _coinbase, amount);
        }
        return amount;
    }

    /*//////////////////////////////////////////////////////////////
                             REWARD ACCRUAL
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMockAztecRollup
    function tick(address coinbase) external override returns (uint256 added) {
        uint256 dt = block.timestamp - lastTick;
        if (dt == 0) return 0;

        added = rewardRatePerSecond * dt;
        if (added > 0) {
            pendingRewards[coinbase] += added;
        }
        lastTick = block.timestamp;
    }

    /// @inheritdoc IMockAztecRollup
    function setRewardRatePerSecond(uint256 newRate) external override {
        rewardRatePerSecond = newRate;
    }

    /// @inheritdoc IMockAztecRollup
    function addRewards(address coinbase, uint256 amount) external override {
        pendingRewards[coinbase] += amount;
    }

    /// @inheritdoc IMockAztecRollup
    function setRewardsCoinbase(address coinbase) external override {
        rewardsCoinbase = coinbase;
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

    /// @inheritdoc IMockAztecRollup
    function setExternalExit(address _attester, uint256 _amount, uint256 _exitableAt) external override {
        // Decrement totalStaked to mirror what initiateWithdraw does,
        // so the rollup's view stays consistent with the protocol's.
        uint256 currentStake = stakes[_attester];
        if (currentStake > 0) {
            totalStaked -= currentStake;
            stakes[_attester] = 0;
        }

        address withdrawer = withdrawers[_attester];
        if (withdrawer == address(0)) {
            withdrawer = address(this);
        }
        _exits[_attester] = Exit({
            withdrawalId: 0,
            amount: _amount,
            exitableAt: Timestamp.wrap(_exitableAt),
            recipientOrWithdrawer: withdrawer,
            isRecipient: false,
            exists: true
        });
    }

    /// @inheritdoc IMockAztecRollup
    function setExitRecipient(address _attester, address _recipient) external override {
        if (_exits[_attester].exists) {
            _exits[_attester].recipientOrWithdrawer = _recipient;
            _exits[_attester].isRecipient = true;
        }
    }

    /// @inheritdoc IMockAztecRollup
    function setClaimShouldFail(address _sequencer, bool _shouldFail) external override {
        claimShouldFail[_sequencer] = _shouldFail;
    }

    /// @inheritdoc IMockAztecRollup
    function clearAttester(address _attester) external override {
        uint256 currentStake = stakes[_attester];
        if (currentStake > 0) {
            totalStaked -= currentStake;
        }
        stakes[_attester] = 0;
        withdrawers[_attester] = address(0);
        delete _exits[_attester];
        delete _publicKeys[_attester];
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
    function getAttesterView(address _attester) external view override returns (AttesterView memory) {
        Exit memory exit = _exits[_attester];
        Status status;
        uint256 effectiveBalance;

        if (exit.exists) {
            status = exit.isRecipient ? Status.EXITING : Status.ZOMBIE;
            effectiveBalance = 0; // Funds are in exit.amount when exiting
        } else if (stakes[_attester] > 0) {
            status = Status.VALIDATING;
            effectiveBalance = stakes[_attester];
        } else {
            status = Status.NONE;
            effectiveBalance = 0;
        }

        return AttesterView({
            status: status,
            effectiveBalance: effectiveBalance,
            exit: exit,
            config: AttesterConfig({ publicKey: _publicKeys[_attester], withdrawer: withdrawers[_attester] })
        });
    }

    /// @inheritdoc IMockAztecRollup
    function getActivatedAttesterCount() external pure override returns (uint256) {
        return 0;
    }
}
