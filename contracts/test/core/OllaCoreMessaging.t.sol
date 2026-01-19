// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";

contract OllaCoreMessagingHarness is OllaCore {
    function exposedStake(uint256 amount) external {
        _stake(amount);
    }

    function exposedUnstake(uint256 amount) external {
        _unstake(amount);
    }
}

contract OllaCoreMessagingTest is Test {
    event StakeRequested(uint256 indexed messageId, uint256 amount);
    event UnstakeRequested(uint256 indexed messageId, uint256 amount);

    MockAztec internal asset;
    OllaCoreMessagingHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreMessagingHarness implementation = new OllaCoreMessagingHarness();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCoreMessagingHarness(address(proxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        address governance = makeAddr("governance");
        vault.initialize(asset, stAztec, stakingManager, governance);
    }

    function test_StakeMessageRoutesToStakingManager() external {
        uint256 assetsBefore = vault.totalAssets();

        vm.expectEmit(true, true, false, true, address(vault));
        emit StakeRequested(1, 10 ether);

        vault.exposedStake(10 ether);

        assertEq(stakingManager.lastStakeAmount(), 10 ether, "stake amount routed");
        assertEq(stakingManager.stakeCalls(), 1, "stake call count");
        assertEq(vault.totalAssets(), assetsBefore, "assets unchanged");
    }

    function test_UnstakeMessageRoutesToStakingManager() external {
        uint256 assetsBefore = vault.totalAssets();

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnstakeRequested(1, 4 ether);

        vault.exposedUnstake(4 ether);

        assertEq(stakingManager.lastUnstakeAmount(), 4 ether, "unstake amount routed");
        assertEq(stakingManager.unstakeCalls(), 1, "unstake call count");
        assertEq(vault.totalAssets(), assetsBefore, "assets unchanged");
    }

    function test_StakeMessageIdMonotonic() external {
        vm.expectEmit(true, true, false, true, address(vault));
        emit StakeRequested(1, 2 ether);
        vault.exposedStake(2 ether);

        vm.expectEmit(true, true, false, true, address(vault));
        emit StakeRequested(2, 3 ether);
        vault.exposedStake(3 ether);
    }

    function test_UnstakeMessageIdMonotonic() external {
        vm.expectEmit(true, true, false, true, address(vault));
        emit UnstakeRequested(1, 2 ether);
        vault.exposedUnstake(2 ether);

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnstakeRequested(2, 1 ether);
        vault.exposedUnstake(1 ether);
    }

    function test_MessageIdsIndependent() external {
        vm.expectEmit(true, true, false, true, address(vault));
        emit StakeRequested(1, 6 ether);
        vault.exposedStake(6 ether);

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnstakeRequested(1, 3 ether);
        vault.exposedUnstake(3 ether);

        vm.expectEmit(true, true, false, true, address(vault));
        emit StakeRequested(2, 1 ether);
        vault.exposedStake(1 ether);

        vm.expectEmit(true, true, false, true, address(vault));
        emit UnstakeRequested(2, 2 ether);
        vault.exposedUnstake(2 ether);
    }
}
