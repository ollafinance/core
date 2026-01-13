// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "dependencies/@openzeppelin-contracts-5.5.0-rc.1/proxy/ERC1967/ERC1967Proxy.sol";
import { Math } from "dependencies/@openzeppelin-contracts-5.5.0-rc.1/utils/math/Math.sol";

import { OllaCore } from "src/core/OllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";

contract OllaCoreTest is Test {
    using Math for uint256;

    event Deposit(address indexed caller, address indexed receiver, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );
    event RequestWithdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event RequestRedeem(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event ClaimWithdraw(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);
    event ClaimRedeem(address indexed owner, address indexed receiver, uint256 assets, uint256 shares);

    uint256 internal constant DECIMALS = 1e18;

    MockAztec internal asset;
    OllaCore internal vault;
    StAztec internal stAztec;
    address internal alice;
    address internal bob;

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCore implementation = new OllaCore();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = OllaCore(address(proxy));

        stAztec = new StAztec(address(vault));
        vault.initialize(asset, stAztec);

        alice = makeAddr("alice");
        bob = makeAddr("bob");
    }

    function _deposit(address owner, uint256 assets) internal returns (uint256 shares) {
        asset.mint(owner, assets);
        vm.prank(owner);
        asset.approve(address(vault), assets);
        vm.prank(owner);
        shares = vault.deposit(assets, owner);
    }

    function test_DepositMintsAtExchangeRate() external {
        uint256 firstShares = _deposit(alice, 100 * DECIMALS);
        assertEq(firstShares, 100 * DECIMALS, "initial shares");

        asset.mint(address(vault), 50 * DECIMALS);

        uint256 totalAssetsBefore = vault.totalAssets();
        uint256 totalSharesBefore = stAztec.totalSupply();

        uint256 expectedShares = (50 * DECIMALS).mulDiv(totalSharesBefore, totalAssetsBefore, Math.Rounding.Floor);
        uint256 secondShares = _deposit(bob, 50 * DECIMALS);

        assertEq(secondShares, expectedShares, "shares at exchange rate");
    }

    function test_DepositsAreInstant() external {
        uint256 shares = _deposit(alice, 10 * DECIMALS);

        assertEq(stAztec.balanceOf(alice), shares, "shares minted");
        assertEq(vault.totalAssets(), 10 * DECIMALS, "assets buffered");
    }

    function test_EmitDepositEvent() external {
        uint256 assets = 10 * DECIMALS;

        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.expectEmit(true, true, true, true, address(vault));
        emit Deposit(alice, alice, assets, assets);

        vm.prank(alice);
        vault.deposit(assets, alice);
    }

    function test_EmitRequestWithdrawAndClaimEvents() external {
        _deposit(alice, 40 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RequestWithdraw(alice, alice, 10 * DECIMALS, 10 * DECIMALS);

        vm.prank(alice);
        uint256 shares = vault.requestWithdraw(10 * DECIMALS, alice, alice);

        assertEq(shares, 10 * DECIMALS, "shares burned");
        assertEq(stAztec.balanceOf(alice), 30 * DECIMALS, "remaining shares");

        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdraw(bob, alice, alice, 10 * DECIMALS, 10 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ClaimWithdraw(alice, alice, 10 * DECIMALS, 10 * DECIMALS);

        vm.prank(bob);
        vault.claimWithdraw(alice);

        assertEq(asset.balanceOf(alice), 10 * DECIMALS, "assets received");
    }

    function test_EmitRequestRedeemAndClaimEvents() external {
        _deposit(alice, 25 * DECIMALS);

        vm.prank(alice);
        stAztec.approve(address(vault), 5 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(vault));
        emit RequestRedeem(alice, bob, 5 * DECIMALS, 5 * DECIMALS);

        vm.prank(bob);
        uint256 assets = vault.requestRedeem(5 * DECIMALS, bob, alice);

        assertEq(assets, 5 * DECIMALS, "assets expected");

        vm.expectEmit(true, true, true, true, address(vault));
        emit Withdraw(bob, bob, alice, 5 * DECIMALS, 5 * DECIMALS);

        vm.expectEmit(true, true, true, true, address(vault));
        emit ClaimRedeem(alice, bob, 5 * DECIMALS, 5 * DECIMALS);

        vm.prank(bob);
        vault.claimWithdraw(alice);
    }

    function test_RequestWithdrawAndClaim() external {
        _deposit(alice, 40 * DECIMALS);

        vm.prank(alice);
        uint256 shares = vault.requestWithdraw(10 * DECIMALS, alice, alice);

        assertEq(shares, 10 * DECIMALS, "shares burned");
        assertEq(stAztec.balanceOf(alice), 30 * DECIMALS, "remaining shares");

        vm.prank(bob);
        vault.claimWithdraw(alice);

        assertEq(asset.balanceOf(alice), 10 * DECIMALS, "assets received");
    }

    function test_RevertWhen_PendingWithdrawalExists() external {
        _deposit(alice, 20 * DECIMALS);

        vm.prank(alice);
        vault.requestWithdraw(5 * DECIMALS, alice, alice);

        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCorePendingWithdrawal.selector, alice));
        vm.prank(alice);
        vault.requestWithdraw(1 * DECIMALS, alice, alice);
    }

    function test_RevertWhen_NoPendingWithdrawal() external {
        vm.expectRevert(abi.encodeWithSelector(OllaCore.OllaCoreNoPendingWithdrawal.selector, alice));
        vault.claimWithdraw(alice);
    }

    function test_RevertWhen_UnauthorizedRedeem() external {
        _deposit(alice, 15 * DECIMALS);

        vm.expectRevert();
        vm.prank(bob);
        vault.requestRedeem(5 * DECIMALS, bob, alice);
    }

    function test_RequestRedeemWithApproval() external {
        _deposit(alice, 25 * DECIMALS);

        vm.prank(alice);
        stAztec.approve(address(vault), 5 * DECIMALS);

        vm.prank(bob);
        uint256 assets = vault.requestRedeem(5 * DECIMALS, bob, alice);

        assertEq(assets, 5 * DECIMALS, "assets expected");
        assertEq(stAztec.balanceOf(alice), 20 * DECIMALS, "shares reduced");
    }

    function testFuzz_DepositMintsShares(uint96 assets) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        uint256 shares = _deposit(alice, assets);

        assertEq(shares, assets, "shares minted at 1:1");
        assertEq(stAztec.balanceOf(alice), shares, "shares balance");
        assertEq(vault.totalAssets(), assets, "assets buffered");
    }

    function testFuzz_RequestWithdrawBurnsShares(uint96 assets, uint96 withdrawAssets) external {
        assets = uint96(bound(assets, 1, type(uint96).max));
        withdrawAssets = uint96(bound(withdrawAssets, 1, assets));

        _deposit(alice, assets);

        vm.prank(alice);
        uint256 shares = vault.requestWithdraw(withdrawAssets, alice, alice);

        assertEq(shares, withdrawAssets, "shares burned");
        assertEq(stAztec.balanceOf(alice), assets - withdrawAssets, "shares remaining");

        vm.prank(bob);
        uint256 claimed = vault.claimWithdraw(alice);

        assertEq(claimed, withdrawAssets, "claimed assets");
        assertEq(asset.balanceOf(alice), withdrawAssets, "assets received");
    }

    function testFuzz_RequestRedeemWithApproval(uint96 assets, uint96 redeemShares) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        _deposit(alice, assets);

        redeemShares = uint96(bound(redeemShares, 1, assets));

        vm.prank(alice);
        stAztec.approve(address(vault), redeemShares);

        uint256 expectedAssets =
            uint256(redeemShares).mulDiv(vault.totalAssets(), stAztec.totalSupply(), Math.Rounding.Floor);

        vm.prank(bob);
        uint256 assetsOut = vault.requestRedeem(redeemShares, bob, alice);

        assertEq(assetsOut, expectedAssets, "assets expected");
        assertEq(stAztec.balanceOf(alice), assets - redeemShares, "shares reduced");
    }
}
