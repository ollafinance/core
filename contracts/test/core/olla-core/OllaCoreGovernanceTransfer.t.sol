// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IAccessControl } from "@oz/access/IAccessControl.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { IRewardsVault } from "src/core/interfaces/IRewardsVault.sol";
import { StAztec } from "src/core/StAztec.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { RewardsVault } from "src/core/RewardsVault.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { StakingManager } from "src/staking/StakingManager.sol";
import { StakingProviderRegistry } from "src/staking/StakingProviderRegistry.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

contract OllaCoreGovernanceTransferTest is Test {
    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event GovernanceProposed(address oldGovernance, address newGovernance);
    event GovernanceAccepted(address oldGovernance, address newGovernance);

    /*//////////////////////////////////////////////////////////////
                                CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant INITIAL_PROTOCOL_FEE_BP = 500;
    uint256 internal constant INITIAL_TREASURY_SPLIT_BP = 5_000;
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;

    /*//////////////////////////////////////////////////////////////
                            TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCore internal ollaCore;
    StAztec internal stAztec;
    MockSafetyModule internal safetyModule;

    WithdrawalQueue internal withdrawalQueue;
    RewardsVault internal rewardsVault;
    StakingManager internal stakingManager;
    StakingProviderRegistry internal stakingProviderRegistry;

    address internal governance;
    address internal newGovernance;

    /*//////////////////////////////////////////////////////////////
                                  SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        governance = makeAddr("governance");
        newGovernance = makeAddr("newGovernance");

        // 1. Deploy OllaCore impl + proxy (don't initialize yet)
        OllaCore ollaCoreImpl = new OllaCore();
        ERC1967Proxy ollaCoreProxy = new ERC1967Proxy(address(ollaCoreImpl), "");
        ollaCore = OllaCore(address(ollaCoreProxy));

        // 2. Deploy StakingProviderRegistry impl + proxy
        StakingProviderRegistry sprImpl = new StakingProviderRegistry();
        ERC1967Proxy sprProxy = new ERC1967Proxy(address(sprImpl), "");
        stakingProviderRegistry = StakingProviderRegistry(address(sprProxy));

        // 3. Deploy StakingManager impl + proxy
        StakingManager smImpl = new StakingManager();
        ERC1967Proxy smProxy = new ERC1967Proxy(address(smImpl), "");
        stakingManager = StakingManager(address(smProxy));

        // 4. Deploy WithdrawalQueue impl + proxy
        WithdrawalQueue wqImpl = new WithdrawalQueue();
        ERC1967Proxy wqProxy = new ERC1967Proxy(address(wqImpl), "");
        withdrawalQueue = WithdrawalQueue(address(wqProxy));

        // 5. Deploy RewardsVault impl + proxy
        RewardsVault rvImpl = new RewardsVault();
        ERC1967Proxy rvProxy = new ERC1967Proxy(address(rvImpl), "");
        rewardsVault = RewardsVault(address(rvProxy));

        // 6. Deploy non-upgradeable helpers
        asset = new MockAztec(address(this));
        stAztec = new StAztec(address(ollaCore));
        safetyModule = new MockSafetyModule(address(ollaCore));

        address rollupRegistry = makeAddr("rollupRegistry");
        address providerAdmin = makeAddr("providerAdmin");
        address providerRewardsRecipient = makeAddr("providerRewardsRecipient");

        // 7. Initialize StakingProviderRegistry
        stakingProviderRegistry.initialize(address(stakingManager), providerAdmin, providerRewardsRecipient, governance);

        // 8. Initialize StakingManager
        //    core_ MUST be the OllaCore proxy so setGasThreshold works in OllaCore.initialize
        stakingManager.initialize(
            IERC20(address(asset)),
            rollupRegistry,
            address(rewardsVault),
            address(ollaCore),
            address(stakingProviderRegistry),
            governance
        );

        // 9. Initialize WithdrawalQueue
        withdrawalQueue.initialize(address(ollaCore), governance, 180_000);

        // 10. Initialize RewardsVault
        rewardsVault.initialize(IERC20(address(asset)), address(ollaCore), governance);

        // 11. Initialize OllaCore
        ollaCore.initialize(
            IERC20(address(asset)),
            stAztec,
            stakingManager,
            INITIAL_PROTOCOL_FEE_BP,
            INITIAL_TREASURY_SPLIT_BP,
            governance,
            address(withdrawalQueue),
            IRewardsVault(address(rewardsVault)),
            address(safetyModule)
        );

        vm.prank(governance);
        ollaCore.unpause();

        // 12. Grant DEFAULT_ADMIN_ROLE to OllaCore proxy on all 4 satellites
        //     (governance is the admin on each satellite after initialize)
        vm.startPrank(governance);
        withdrawalQueue.grantRole(DEFAULT_ADMIN_ROLE, address(ollaCore));
        rewardsVault.grantRole(DEFAULT_ADMIN_ROLE, address(ollaCore));
        stakingManager.grantRole(DEFAULT_ADMIN_ROLE, address(ollaCore));
        stakingProviderRegistry.grantRole(DEFAULT_ADMIN_ROLE, address(ollaCore));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    HELPER: PERFORM GOVERNANCE TRANSFER
    //////////////////////////////////////////////////////////////*/

    function _performGovernanceTransfer() internal {
        vm.prank(governance);
        ollaCore.proposeGovernance(newGovernance);

        vm.prank(newGovernance);
        ollaCore.acceptGovernance();
    }

    /*//////////////////////////////////////////////////////////////
                      SATELLITE ROLE PROPAGATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_AcceptGovernance_PropagatesAdminRoleToSatellites() external {
        // Verify old governance has DEFAULT_ADMIN_ROLE on all 4 satellites before transfer
        assertTrue(
            withdrawalQueue.hasRole(DEFAULT_ADMIN_ROLE, governance),
            "old gov has admin on withdrawalQueue before transfer"
        );
        assertTrue(
            rewardsVault.hasRole(DEFAULT_ADMIN_ROLE, governance), "old gov has admin on rewardsVault before transfer"
        );
        assertTrue(
            stakingManager.hasRole(DEFAULT_ADMIN_ROLE, governance),
            "old gov has admin on stakingManager before transfer"
        );
        assertTrue(
            stakingProviderRegistry.hasRole(DEFAULT_ADMIN_ROLE, governance),
            "old gov has admin on stakingProviderRegistry before transfer"
        );

        // Perform governance transfer
        _performGovernanceTransfer();

        // Assert newGovernance has DEFAULT_ADMIN_ROLE on all 4 satellites
        assertTrue(withdrawalQueue.hasRole(DEFAULT_ADMIN_ROLE, newGovernance), "new gov has admin on withdrawalQueue");
        assertTrue(rewardsVault.hasRole(DEFAULT_ADMIN_ROLE, newGovernance), "new gov has admin on rewardsVault");
        assertTrue(stakingManager.hasRole(DEFAULT_ADMIN_ROLE, newGovernance), "new gov has admin on stakingManager");
        assertTrue(
            stakingProviderRegistry.hasRole(DEFAULT_ADMIN_ROLE, newGovernance),
            "new gov has admin on stakingProviderRegistry"
        );

        // Assert oldGovernance lost DEFAULT_ADMIN_ROLE on all 4 satellites
        assertFalse(withdrawalQueue.hasRole(DEFAULT_ADMIN_ROLE, governance), "old gov lost admin on withdrawalQueue");
        assertFalse(rewardsVault.hasRole(DEFAULT_ADMIN_ROLE, governance), "old gov lost admin on rewardsVault");
        assertFalse(stakingManager.hasRole(DEFAULT_ADMIN_ROLE, governance), "old gov lost admin on stakingManager");
        assertFalse(
            stakingProviderRegistry.hasRole(DEFAULT_ADMIN_ROLE, governance),
            "old gov lost admin on stakingProviderRegistry"
        );

        // Assert OllaCore proxy still has DEFAULT_ADMIN_ROLE on all 4 satellites (it wasn't revoked)
        assertTrue(
            withdrawalQueue.hasRole(DEFAULT_ADMIN_ROLE, address(ollaCore)),
            "ollaCore still has admin on withdrawalQueue"
        );
        assertTrue(
            rewardsVault.hasRole(DEFAULT_ADMIN_ROLE, address(ollaCore)), "ollaCore still has admin on rewardsVault"
        );
        assertTrue(
            stakingManager.hasRole(DEFAULT_ADMIN_ROLE, address(ollaCore)), "ollaCore still has admin on stakingManager"
        );
        assertTrue(
            stakingProviderRegistry.hasRole(DEFAULT_ADMIN_ROLE, address(ollaCore)),
            "ollaCore still has admin on stakingProviderRegistry"
        );
    }

    function test_AcceptGovernance_NewGovernanceCanManageRolesOnSatellites() external {
        // Complete a governance transfer
        _performGovernanceTransfer();

        // New governance can call grantRole on a satellite (withdrawalQueue)
        address someRole = makeAddr("someRoleHolder");

        vm.prank(newGovernance);
        withdrawalQueue.grantRole(DEFAULT_ADMIN_ROLE, someRole);
        assertTrue(withdrawalQueue.hasRole(DEFAULT_ADMIN_ROLE, someRole), "new gov can grant roles on withdrawalQueue");

        // Old governance can NOT call grantRole on a satellite (reverts with AccessControlUnauthorizedAccount)
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, governance, DEFAULT_ADMIN_ROLE
            )
        );
        vm.prank(governance);
        withdrawalQueue.grantRole(DEFAULT_ADMIN_ROLE, someRole);
    }

    function test_AcceptGovernance_OllaCoreRolesStillTransferred() external {
        bytes32 adminRole = ollaCore.DEFAULT_ADMIN_ROLE();
        bytes32 guardianRole = ollaCore.GUARDIAN_ROLE();
        bytes32 operatorRole = ollaCore.OPERATOR_ROLE();

        // Verify old governance has all OllaCore roles before transfer
        assertTrue(ollaCore.hasRole(adminRole, governance), "old gov has admin on OllaCore");
        assertTrue(ollaCore.hasRole(guardianRole, governance), "old gov has guardian on OllaCore");
        assertTrue(ollaCore.hasRole(operatorRole, governance), "old gov has operator on OllaCore");

        // Complete governance transfer
        _performGovernanceTransfer();

        // Verify OllaCore's own roles transferred correctly
        assertTrue(ollaCore.hasRole(adminRole, newGovernance), "new gov has admin on OllaCore");
        assertTrue(ollaCore.hasRole(guardianRole, newGovernance), "new gov has guardian on OllaCore");
        assertTrue(ollaCore.hasRole(operatorRole, newGovernance), "new gov has operator on OllaCore");

        // Verify old governance lost all roles on OllaCore
        assertFalse(ollaCore.hasRole(adminRole, governance), "old gov lost admin on OllaCore");
        assertFalse(ollaCore.hasRole(guardianRole, governance), "old gov lost guardian on OllaCore");
        assertFalse(ollaCore.hasRole(operatorRole, governance), "old gov lost operator on OllaCore");

        // Verify governance() returns newGovernance
        assertEq(ollaCore.governance(), newGovernance, "governance() returns newGovernance");
    }
}
