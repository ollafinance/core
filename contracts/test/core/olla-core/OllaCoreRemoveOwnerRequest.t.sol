// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsVault } from "src/core/mocks/MockRewardsVault.sol";
import { MockSafetyModule } from "src/safetymodule/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/core/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";

contract OllaCoreRemoveOwnerRequestTest is Test {
    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsVault internal rewardsVault;
    MockSafetyModule internal safetyModule;
    address internal providerRewardsRecipient;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreHarness(address(proxy));

        stakingManager = new MockAccountingStakingManager();
        governance = makeAddr("governance");
        stAztec = new StAztec(address(vault));
        rewardsVault = new MockRewardsVault(asset, address(vault));
        safetyModule = new MockSafetyModule(address(coreImplementation));
        withdrawalQueue = new MockWithdrawalQueue();
        providerRewardsRecipient = makeAddr("providerRewardsRecipient");
        stakingManager.setProviderRewardsRecipient(providerRewardsRecipient);

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsVault(address(rewardsVault));

        vault.initialize(
            asset,
            stAztec,
            stakingManager,
            0,
            5_000,
            governance,
            address(withdrawalQueue),
            rewardsVault,
            address(safetyModule)
        );

        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                  _REMOVEOWNERREQUEST REVERT TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimWithdrawal_RevertWhen_RequestNotFound() external {
        // Attempt to claim a non-existent request (id 999 was never created)
        // This triggers _removeOwnerRequest with index == 0
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RequestNotFound.selector, 999));
        vault.claimRequestById(999);
    }

    function test_ClaimWithdrawal_RevertWhen_NonExistentRequestId() external {
        // Deposit to set up state
        asset.mint(alice, 10 ether);
        vm.prank(alice);
        asset.approve(address(vault), 10 ether);
        vm.prank(alice);
        vault.deposit(10 ether, alice, 0);

        // Attempt to claim request id 42 which was never created
        vm.expectRevert(abi.encodeWithSelector(IOllaCore.OllaCore__RequestNotFound.selector, 42));
        vm.prank(alice);
        vault.claimRequestById(42);
    }
}
