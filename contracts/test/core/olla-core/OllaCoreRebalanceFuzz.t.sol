// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";

/*//////////////////////////////////////////////////////////////
                    REBALANCE FUZZ HANDLER
//////////////////////////////////////////////////////////////*/

/// @title OllaCoreRebalanceFuzzHandler
/// @notice Stateful handler that drives random rebalance-related actions for invariant testing.
contract OllaCoreRebalanceFuzzHandler is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec public asset;
    OllaCore public core;
    OllaVault public vault;
    StAztec public stAztec;
    MockAccountingStakingManager public stakingManager;
    MockRewardsVault public rewardsVault;
    MockWithdrawalQueue public withdrawalQueue;
    address public operator;
    address public governance;

    address[] public actors;

    /*//////////////////////////////////////////////////////////////
                          GHOST VARIABLES
    //////////////////////////////////////////////////////////////*/

    bool public ghost_rebalanceCalled;
    bool public ghost_backwardTransition;
    uint256 public ghost_highestStepOrdinal;
    uint256 public ghost_rebalanceCallCount;
    uint256 public ghost_depositCallCount;
    uint256 public ghost_maxBuffered;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(
        MockAztec _asset,
        OllaCore _core,
        OllaVault _vault,
        StAztec _stAztec,
        MockAccountingStakingManager _stakingManager,
        MockRewardsVault _rewardsVault,
        MockWithdrawalQueue _withdrawalQueue,
        address _operator,
        address _governance
    ) {
        asset = _asset;
        core = _core;
        vault = _vault;
        stAztec = _stAztec;
        stakingManager = _stakingManager;
        rewardsVault = _rewardsVault;
        withdrawalQueue = _withdrawalQueue;
        operator = _operator;
        governance = _governance;

        for (uint256 i = 0; i < 5; i++) {
            actors.push(makeAddr(string(abi.encode("fuzzActor", i))));
        }
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    /*//////////////////////////////////////////////////////////////
                             HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(uint96 amount, uint256 actorSeed) external {
        uint256 assets = uint256(bound(amount, 1, type(uint96).max));
        address actor = actors[bound(actorSeed, 0, actors.length - 1)];

        asset.mint(actor, assets);
        vm.startPrank(actor);
        asset.approve(address(vault), assets);

        try vault.deposit(assets, actor, 0) {
            ghost_depositCallCount += 1;
        } catch { }
        vm.stopPrank();
    }

    function setStakingState(uint96 totalStakedSeed, uint96 claimableRewardsSeed, uint96 harvestedSeed) external {
        uint256 totalStaked = uint256(bound(totalStakedSeed, 0, type(uint96).max));
        uint256 claimableRewards = uint256(bound(claimableRewardsSeed, 0, type(uint96).max));
        uint256 harvested = uint256(bound(harvestedSeed, 0, type(uint96).max));

        stakingManager.setTotalStaked(totalStaked);
        stakingManager.setClaimableRewards(claimableRewards);
        stakingManager.setHarvestedRewards(harvested);
    }

    function rebalanceSingleStep() external {
        IOllaCore.RebalanceProgress memory progressBefore = core.rebalanceProgress();
        uint256 stepBefore = uint256(progressBefore.step);

        vm.prank(operator);
        try core.rebalance() {
            ghost_rebalanceCalled = true;
            ghost_rebalanceCallCount += 1;
        } catch {
            return;
        }

        IOllaCore.RebalanceProgress memory progressAfter = core.rebalanceProgress();
        uint256 stepAfter = uint256(progressAfter.step);

        if (stepBefore != uint256(IOllaCore.RebalanceStep.Done)) {
            if (stepAfter < stepBefore) {
                ghost_backwardTransition = true;
            }
        }

        if (stepAfter > ghost_highestStepOrdinal) {
            ghost_highestStepOrdinal = stepAfter;
        }

        if (stepAfter == uint256(IOllaCore.RebalanceStep.Done)) {
            ghost_highestStepOrdinal = 0;
        }

        uint256 buffered = vault.bufferedAssets();
        if (buffered > ghost_maxBuffered) {
            ghost_maxBuffered = buffered;
        }
    }

    function advanceTime(uint32 secondsSeed) external {
        uint256 elapsed = uint256(bound(secondsSeed, 1, 7 days));
        vm.warp(block.timestamp + elapsed);
    }
}

/*//////////////////////////////////////////////////////////////
                  REBALANCE FUZZ INVARIANT TEST
//////////////////////////////////////////////////////////////*/

/// @title OllaCoreRebalanceFuzzTest
/// @notice Invariant test suite that checks rebalance state-machine properties under random inputs.
contract OllaCoreRebalanceFuzzTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAztec internal asset;
    MockAccountingStakingManager internal stakingManager;
    MockWithdrawalQueue internal withdrawalQueue;
    MockSafetyModule internal safetyModule;
    MockRewardsVault internal rewardsVault;
    OllaCoreRebalanceFuzzHandler internal handler;
    address internal operator;
    address internal governance;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        // Deploy Core
        OllaCore implementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(implementation), "");
        core = OllaCore(address(coreProxy));

        // Deploy Vault
        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        stakingManager = new MockAccountingStakingManager();
        withdrawalQueue = new MockWithdrawalQueue();
        rewardsVault = new MockRewardsVault(asset, address(core));
        safetyModule = new MockSafetyModule(address(implementation), address(vault));

        address providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));

        core.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            5_000,
            governance,
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
        );

        vault.initialize(asset, stAztec, address(withdrawalQueue), address(safetyModule), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();

        vm.prank(governance);
        vault.unpause();

        operator = makeAddr("operator");
        bytes32 operatorRole = core.OPERATOR_ROLE();
        vm.startPrank(governance);
        core.grantRole(operatorRole, operator);
        vm.stopPrank();

        handler = new OllaCoreRebalanceFuzzHandler(
            asset, core, vault, stAztec, stakingManager, rewardsVault, withdrawalQueue, operator, governance
        );

        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                      INVARIANT: TOTAL ASSETS CONSISTENT
    //////////////////////////////////////////////////////////////*/

    function invariant_TotalAssetsEqualBuckets() external view {
        IOllaCore.AccountingState memory accounting = core.accountingState();
        uint256 expectedTotal = vault.bufferedAssets() + accounting.stakedPrincipal + accounting.rewardsVaultBalance
            + accounting.claimableRewards - accounting.slashingDelta;

        assertEq(core.totalAssets(), expectedTotal, "totalAssets must equal sum of buckets");
    }

    /*//////////////////////////////////////////////////////////////
               INVARIANT: REBALANCE STEPS ONLY MOVE FORWARD
    //////////////////////////////////////////////////////////////*/

    function invariant_NoBackwardTransition() external view {
        assertFalse(handler.ghost_backwardTransition(), "rebalance step must not go backward within a cycle");
    }

    /*//////////////////////////////////////////////////////////////
              INVARIANT: BUFFERED ASSETS ARE REASONABLE
    //////////////////////////////////////////////////////////////*/

    function invariant_BufferedAssetsReasonable() external view {
        uint256 vaultBalance = asset.balanceOf(address(vault));

        assertLe(vault.bufferedAssets(), vaultBalance, "bufferedAssets must not exceed vault asset balance");
    }
}
