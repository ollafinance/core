// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";

import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";
import { StakeAllowanceLeakStakingManager } from "test/mocks/StakeAllowanceLeakStakingManager.sol";

/// @title OllaCoreStakeSurplusAllowanceTest
/// @notice Asserts that `OllaCore._stakeSurplus` does not leave a residual ERC-20 allowance
///         from Core to the StakingManager once the rebalance call returns. After every
///         exit path of `_stakeSurplus` — full stake, partial stake, or reverted stake —
///         the allowance from Core to the StakingManager must be zero.
contract OllaCoreStakeSurplusAllowanceTest is Test {
    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;

    /*//////////////////////////////////////////////////////////////
                                FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    StakeAllowanceLeakStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal operator;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore coreImplementation = new OllaCore();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCore(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        stakingManager = new StakeAllowanceLeakStakingManager();
        operator = makeAddr("operator");

        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));

        // Wire the staking manager mock with rewards/recipient so MockAccountingStakingManager
        // accounting hooks (harvestRewards, etc.) work — even though we're only exercising stake.
        stakingManager.setProviderRewardsRecipient(makeAddr("providerRewardsRecipient"));
        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));

        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");

        // Advance past the 1-hour rebalance cooldown initialised in OllaCore.initialize().
        vm.warp(block.timestamp + 1 hours);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _performDeposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner, 0);
        return shares;
    }

    /// @notice Sets a deposit so rebalance routes the entire deposit through `_stakeSurplus`.
    function _setupSurplusToStake(uint256 depositAmount) internal {
        _performDeposit(alice, depositAmount);
        // Disable harvested rewards & unstaked funds so the rebalance reaches StakeSurplus
        // with a clean state.
        stakingManager.setHarvestedRewards(0);
        stakingManager.setUnstakedAmount(0);
    }

    /*//////////////////////////////////////////////////////////////
                          STAKE-SURPLUS ALLOWANCE HYGIENE
    //////////////////////////////////////////////////////////////*/

    /// @notice When `stakingManager.stake()` reverts, OllaCore must end the rebalance with
    ///         zero residual allowance from Core to the StakingManager. Refunding the
    ///         tokens is not enough — the approval set immediately before the call must
    ///         also be cleared.
    function test_StakeSurplus_RevertedStake_ClearsAllowance() external {
        uint256 depositAmount = 10 * DECIMALS;
        _setupSurplusToStake(depositAmount);

        // Force the staking manager to revert in stake(): exercises OllaCore's catch branch.
        stakingManager.setStakeShouldRevert(true);

        uint256 allowanceBefore = asset.allowance(address(core), address(stakingManager));
        assertEq(allowanceBefore, 0, "pre: no residual allowance from setup");

        vm.prank(operator);
        core.rebalance();

        uint256 allowanceAfter = asset.allowance(address(core), address(stakingManager));
        assertEq(allowanceAfter, 0, "approval from Core to StakingManager must be cleared after a reverted stake");
    }

    /// @notice When `stakingManager.stake()` accepts only a portion of the requested
    ///         amount, OllaCore must end the rebalance with zero residual allowance
    ///         from Core to the StakingManager. The unstaked excess is refunded to the
    ///         Vault, and the remaining approval (`stakeable - actualStaked`) must not
    ///         persist past the call.
    function test_StakeSurplus_PartialStake_ClearsAllowance() external {
        uint256 depositAmount = 10 * DECIMALS;
        uint256 partialAmount = 4 * DECIMALS; // StakingManager accepts only 4 of the 10 ether
        _setupSurplusToStake(depositAmount);

        // Configure partial-stake mode: stake() pulls `partialAmount` via transferFrom and
        // returns it. The remaining `depositAmount - partialAmount` is refunded to the Vault.
        stakingManager.setStakePartial(partialAmount);

        uint256 allowanceBefore = asset.allowance(address(core), address(stakingManager));
        assertEq(allowanceBefore, 0, "pre: no residual allowance from setup");

        vm.prank(operator);
        core.rebalance();

        uint256 allowanceAfter = asset.allowance(address(core), address(stakingManager));

        // Sanity: the partial-stake path executed — stakingManager pulled exactly `partialAmount`.
        assertEq(
            IERC20(address(asset)).balanceOf(address(stakingManager)),
            partialAmount,
            "stakingManager pulled the partial amount via transferFrom"
        );

        assertEq(allowanceAfter, 0, "approval from Core to StakingManager must be cleared after a partial stake");
    }
}
