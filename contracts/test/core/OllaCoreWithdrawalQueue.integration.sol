// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { WithdrawalQueue } from "src/core/WithdrawalQueue.sol";
import { IWithdrawalQueue } from "src/interfaces/IWithdrawalQueue.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";

contract OllaCoreWithdrawalQueueHarness is OllaCore {
    function exposedIncreaseRewardsVaultBalance(uint256 amount) external {
        _increaseRewardsVaultBalance(amount);
    }
}

contract OllaCoreWithdrawalQueueTest is Test {
    event WithdrawalRequested(
        uint256 indexed requestId,
        address indexed receiver,
        uint256 shares,
        uint256 assetsExpected,
        uint256 exchangeRate
    );

    MockAztec internal asset;
    OllaCoreWithdrawalQueueHarness internal vault;
    StAztec internal stAztec;
    MockStakingManager internal stakingManager;
    WithdrawalQueue internal queue;
    address internal governance;
    address internal rewardsVault;
    address internal safetyModule;
    address internal alice;
    address internal bob;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreWithdrawalQueueHarness coreImplementation = new OllaCoreWithdrawalQueueHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        vault = OllaCoreWithdrawalQueueHarness(address(coreProxy));

        stAztec = new StAztec(address(vault));
        stakingManager = new MockStakingManager();
        governance = makeAddr("governance");
        rewardsVault = makeAddr("rewardsVault");
        safetyModule = makeAddr("safetyModule");

        WithdrawalQueue queueImplementation = new WithdrawalQueue();
        ERC1967Proxy queueProxy = new ERC1967Proxy(address(queueImplementation), "");
        queue = WithdrawalQueue(address(queueProxy));

        vault.initialize(asset, stAztec, stakingManager, governance, address(queue), rewardsVault, safetyModule);
        queue.initialize(address(vault), governance);

        bytes32 operatorRole = vault.OPERATOR_ROLE();
        vm.startPrank(governance);
        vault.grantRole(operatorRole, address(this));
        vm.stopPrank();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function test_RequestRedeem_BurnsShares() external {
        uint256 shares = _deposit(alice, 10 ether);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(4 ether, alice);

        assertEq(requestId, 1, "request id starts at 1");
        assertEq(stAztec.balanceOf(alice), shares - 4 ether, "shares burned on request");
    }

    function test_RequestRedeem_LocksAssetsExpectedAtRequestRate() external {
        _deposit(alice, 12 ether);
        uint256 rate = vault.exchangeRate();
        uint256 shares = 5 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, alice);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(request.assetsExpected, expectedAssets, "assetsExpected locked at request rate");
        assertEq(request.rate, rate, "rate locked at request time");

        vault.exposedIncreaseRewardsVaultBalance(3 ether);
        uint256 updatedRate = vault.exchangeRate();
        assertGt(updatedRate, rate, "exchange rate should increase after rewards");
        request = queue.getRequest(requestId);
        assertEq(request.assetsExpected, expectedAssets, "assetsExpected unchanged after rate update");
        assertEq(request.rate, rate, "rate remains locked after update");
    }

    function test_RequestRedeem_EventMatchesQueueStorage() external {
        _deposit(alice, 20 ether);
        uint256 rate = vault.exchangeRate();
        uint256 shares = 7 ether;
        uint256 expectedAssets = shares * rate / 1e18;

        vm.expectEmit(true, true, false, true, address(vault));
        emit WithdrawalRequested(1, bob, shares, expectedAssets, rate);

        vm.prank(alice);
        uint256 requestId = vault.requestRedeem(shares, bob);

        IWithdrawalQueue.WithdrawalRequest memory request = queue.getRequest(requestId);
        assertEq(request.user, bob, "queue stores receiver");
        assertEq(request.shares, shares, "queue stores share amount");
        assertEq(request.assetsExpected, expectedAssets, "queue stores assets expected");
        assertEq(request.rate, rate, "queue stores request rate");
    }

    function test_RevertWhen_ActiveRequestExists() external {
        _deposit(alice, 15 ether);

        vm.prank(alice);
        vault.requestRedeem(5 ether, alice);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCorePendingWithdrawalExists.selector, alice));
        vm.prank(alice);
        vault.requestRedeem(2 ether, alice);
    }

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
        return shares;
    }
}
