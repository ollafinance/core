// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20Permit } from "@oz/token/ERC20/extensions/IERC20Permit.sol";
import { Math } from "@oz/utils/math/Math.sol";

import { IOllaCore } from "src/core/interfaces/IOllaCore.sol";
import { OllaVault } from "src/vault/OllaVault.sol";
import { IOllaVault } from "src/vault/interfaces/IOllaVault.sol";
import { StAztec } from "src/vault/StAztec.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";
import { MockRewardsAccumulator } from "src/core/mocks/MockRewardsAccumulator.sol";
import { MockSafetyModule } from "src/safetymodule/mocks/MockSafetyModule.sol";
import { MockWithdrawalQueue } from "src/vault/mocks/MockWithdrawalQueue.sol";
import { MockAccountingStakingManager } from "test/mocks/MockAccountingStakingManager.sol";
import { OllaCoreHarness } from "test/core/olla-core/OllaCoreHarness.sol";
import { MockOllaGovernance } from "test/mocks/MockOllaGovernance.sol";

contract OllaCoreSlippageTest is Test {
    using Math for uint256;

    /*//////////////////////////////////////////////////////////////
                              CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 internal constant DECIMALS = 1e18;
    uint256 internal constant BP_DIVISOR = 10_000;
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    /*//////////////////////////////////////////////////////////////
                           TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    MockAztec internal asset;
    OllaCoreHarness internal core;
    OllaVault internal vault;
    StAztec internal stAztec;
    MockAccountingStakingManager internal stakingManager;
    address internal governance;
    address internal alice;
    address internal bob;
    address internal permitOwner;
    uint256 internal permitOwnerKey;
    MockWithdrawalQueue internal withdrawalQueue;
    MockRewardsAccumulator internal rewardsAccumulator;
    MockSafetyModule internal safetyModule;

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        asset = new MockAztec(address(this));

        OllaCoreHarness coreImplementation = new OllaCoreHarness();
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImplementation), "");
        core = OllaCoreHarness(address(coreProxy));

        OllaVault vaultImplementation = new OllaVault();
        ERC1967Proxy vaultProxy = new ERC1967Proxy(address(vaultImplementation), "");
        vault = OllaVault(address(vaultProxy));

        stakingManager = new MockAccountingStakingManager();
        governance = address(new MockOllaGovernance());
        stAztec = new StAztec(address(vault));
        rewardsAccumulator = new MockRewardsAccumulator(asset, address(core));
        safetyModule = new MockSafetyModule(address(core), address(vault));
        withdrawalQueue = new MockWithdrawalQueue();

        stakingManager.setRewardsToken(asset);
        stakingManager.setRewardsAccumulator(address(rewardsAccumulator));

        core.initialize(
            asset, stAztec, stakingManager, 500, 5_000, governance, rewardsAccumulator, address(safetyModule)
        );
        vault.initialize(asset, stAztec, address(withdrawalQueue), address(core), governance);

        vm.prank(governance);
        core.setVault(address(vault));
        vm.prank(governance);
        core.unpause();
        vm.prank(governance);
        vault.unpause();

        alice = makeAddr("alice");
        bob = makeAddr("bob");
        permitOwnerKey = 0xA11CE;
        permitOwner = vm.addr(permitOwnerKey);
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

    function _signPermit(
        IERC20Permit token,
        address owner,
        uint256 ownerKey,
        address spender,
        uint256 value,
        uint256 deadline
    ) internal view returns (uint8 v, bytes32 r, bytes32 s) {
        uint256 nonce = token.nonces(owner);
        bytes32 digest = _buildPermitDigest(token, owner, spender, value, nonce, deadline);
        (v, r, s) = vm.sign(ownerKey, digest);
        return (v, r, s);
    }

    function _buildPermitDigest(
        IERC20Permit token,
        address owner,
        address spender,
        uint256 value,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32 digest) {
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline));
        digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        return digest;
    }

    /// @dev Calls the 3-arg deposit(uint256,address,uint256) overload via low-level call.
    function _depositWithSlippage(address caller, uint256 assets, address recipient, uint256 minSharesOut)
        internal
        returns (uint256 shares)
    {
        vm.prank(caller);
        (bool success, bytes memory data) = address(vault)
            .call(abi.encodeWithSignature("deposit(uint256,address,uint256)", assets, recipient, minSharesOut));
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        shares = abi.decode(data, (uint256));
    }

    /// @dev Calls the 7-arg depositWithPermit overload with slippage protection.
    function _depositWithPermitAndSlippage(
        address owner,
        uint256 ownerKey,
        uint256 assets,
        address recipient,
        uint256 minSharesOut
    ) internal returns (uint256 shares) {
        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), owner, ownerKey, address(vault), assets, deadline);
        vm.prank(owner);
        (bool success, bytes memory data) = address(vault)
            .call(
                abi.encodeWithSignature(
                    "depositWithPermit(uint256,address,uint256,uint256,uint8,bytes32,bytes32)",
                    assets,
                    recipient,
                    minSharesOut,
                    deadline,
                    v,
                    r,
                    s
                )
            );
        if (!success) {
            assembly {
                revert(add(data, 32), mload(data))
            }
        }
        shares = abi.decode(data, (uint256));
    }

    /*//////////////////////////////////////////////////////////////
                         DEPOSIT SLIPPAGE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice 1. Deposit with minSharesOut exactly equal to expected shares (1:1 rate).
    function test_DepositWithMinShares_SucceedsWhenExactMatch() external {
        uint256 assets = 100 * DECIMALS;
        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        // At 1:1, expected shares == assets
        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 shares = _depositWithSlippage(alice, assets, alice, expectedShares);

        assertEq(shares, expectedShares, "shares match expected at 1:1 rate");
        assertEq(stAztec.balanceOf(alice), shares, "alice received shares");
    }

    /// @notice 2. Deposit with minSharesOut=0 always succeeds (same as original).
    function test_DepositWithMinShares_SucceedsWhenMinIsZero() external {
        uint256 assets = 50 * DECIMALS;
        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        uint256 shares = _depositWithSlippage(alice, assets, alice, 0);

        assertGt(shares, 0, "shares minted");
        assertEq(stAztec.balanceOf(alice), shares, "alice received shares");
    }

    /// @notice 3. Slippage check fires when rate changes after initial deposit.
    function test_RevertWhen_DepositWithMinShares_SlippageExceeded() external {
        // Initial deposit by alice at 1:1
        _performDeposit(alice, 100 * DECIMALS);

        // Simulate rewards accrual by funding the accumulator; totalAssets() reads its live balance.
        deal(address(asset), address(rewardsAccumulator), 50 * DECIMALS);

        // Bob wants to deposit 50 tokens, expecting old 1:1 rate
        uint256 bobAssets = 50 * DECIMALS;
        asset.mint(bob, bobAssets);
        vm.prank(bob);
        asset.approve(address(vault), bobAssets);

        // Preview shows fewer shares now (rate > 1:1)
        uint256 actualExpected = vault.previewDeposit(bobAssets);
        // Set minSharesOut to old 1:1 expectation (50 * DECIMALS) which is > actualExpected
        uint256 staleMinSharesOut = bobAssets;
        assertGt(staleMinSharesOut, actualExpected, "stale expectation exceeds actual shares");

        vm.expectRevert(
            abi.encodeWithSelector(IOllaVault.OllaVault__SlippageExceeded.selector, actualExpected, staleMinSharesOut)
        );
        _depositWithSlippage(bob, bobAssets, bob, staleMinSharesOut);
    }

    /// @notice 4. Fuzz: deposit amount, compute expected shares via previewDeposit, verify success.
    function testFuzz_DepositWithMinShares_SlippageProtection(uint96 assets) external {
        assets = uint96(bound(assets, 1, type(uint96).max));

        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 shares = _depositWithSlippage(alice, assets, alice, expectedShares);

        assertEq(shares, expectedShares, "shares match previewDeposit");
        assertEq(stAztec.balanceOf(alice), shares, "alice received shares");
    }

    /*//////////////////////////////////////////////////////////////
                  DEPOSIT WITH PERMIT + SLIPPAGE TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice 5. Full permit flow with slippage protection that passes.
    function test_DepositWithPermitAndMinShares_SucceedsEndToEnd() external {
        uint256 assets = 100 * DECIMALS;
        asset.mint(permitOwner, assets);

        uint256 expectedShares = vault.previewDeposit(assets);
        uint256 shares = _depositWithPermitAndSlippage(permitOwner, permitOwnerKey, assets, permitOwner, expectedShares);

        assertEq(shares, expectedShares, "shares match expected");
        assertEq(stAztec.balanceOf(permitOwner), shares, "permitOwner received shares");
        assertEq(IERC20Permit(address(asset)).nonces(permitOwner), 1, "nonce incremented");
    }

    /// @notice 6. Permit variant where slippage check fires.
    function test_RevertWhen_DepositWithPermitAndMinShares_SlippageExceeded() external {
        // Initial deposit to set up non-1:1 rate; live-source funding keeps totalAssets honest.
        _performDeposit(alice, 100 * DECIMALS);
        deal(address(asset), address(rewardsAccumulator), 50 * DECIMALS);

        uint256 assets = 50 * DECIMALS;
        asset.mint(permitOwner, assets);

        uint256 actualExpected = vault.previewDeposit(assets);
        uint256 staleMinSharesOut = assets; // old 1:1 expectation

        assertGt(staleMinSharesOut, actualExpected, "stale expectation exceeds actual shares");

        uint256 deadline = block.timestamp + 1 days;
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(IERC20Permit(address(asset)), permitOwner, permitOwnerKey, address(vault), assets, deadline);

        vm.expectRevert(
            abi.encodeWithSelector(IOllaVault.OllaVault__SlippageExceeded.selector, actualExpected, staleMinSharesOut)
        );
        vm.prank(permitOwner);
        (bool success,) = address(vault)
            .call(
                abi.encodeWithSignature(
                    "depositWithPermit(uint256,address,uint256,uint256,uint8,bytes32,bytes32)",
                    assets,
                    permitOwner,
                    staleMinSharesOut,
                    deadline,
                    v,
                    r,
                    s
                )
            );
        // vm.expectRevert consumes the revert, so success is irrelevant here
        (success);
    }

    /*//////////////////////////////////////////////////////////////
                    BACKWARDS COMPATIBILITY TESTS
    //////////////////////////////////////////////////////////////*/

    /// @notice 17. Original 2-arg ERC-4626 deposit works unchanged.
    function test_OriginalDeposit_StillWorks() external {
        uint256 assets = 9 * DECIMALS;
        asset.mint(alice, assets);
        vm.prank(alice);
        asset.approve(address(vault), assets);

        vm.prank(alice);
        uint256 shares = vault.deposit(assets, alice);

        assertEq(shares, assets, "deposit shares at 1:1");
        assertEq(stAztec.balanceOf(alice), assets, "shares minted");
    }
}
