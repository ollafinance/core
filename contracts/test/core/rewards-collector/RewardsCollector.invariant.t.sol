// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Test } from "@forge-std/Test.sol";

import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

import { RewardsCollector } from "src/core/RewardsCollector.sol";
import { MockAztec } from "src/staking/mocks/MockAztec.sol";

contract RewardsCollectorHandler is Test {
    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    RewardsCollector public vault;
    MockAztec public asset;
    address public core;

    /*//////////////////////////////////////////////////////////////
                             CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(RewardsCollector _vault, MockAztec _asset, address _core) {
        vault = _vault;
        asset = _asset;
        core = _core;
    }

    /*//////////////////////////////////////////////////////////////
                          HANDLER ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Simulate rewards arriving by minting tokens to the vault.
    function mintRewards(uint96 amountRaw) external {
        uint256 amount = uint256(bound(amountRaw, 0, 100 ether));
        if (amount > 0) {
            asset.mint(address(vault), amount);
        }
    }

    /// @notice Call recordBalance via core.
    function recordBalance() external {
        vm.prank(core);
        try vault.recordBalance() { } catch { }
    }

    /// @notice Call withdrawToCore via core.
    function withdrawToCore() external {
        vm.prank(core);
        try vault.withdrawToCore() { } catch { }
    }
}

contract RewardsCollectorInvariantTest is Test {
    /*//////////////////////////////////////////////////////////////
                          TEST FIXTURES
    //////////////////////////////////////////////////////////////*/

    RewardsCollector internal vault;
    MockAztec internal asset;
    RewardsCollectorHandler internal handler;
    address internal core;
    address internal admin;

    /*//////////////////////////////////////////////////////////////
                                SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() external {
        core = makeAddr("core");
        admin = makeAddr("admin");

        asset = new MockAztec(address(this));

        RewardsCollector implementation = new RewardsCollector();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), "");
        vault = RewardsCollector(address(proxy));
        vault.initialize(IERC20(address(asset)), core, admin);

        handler = new RewardsCollectorHandler(vault, asset, core);
        targetContract(address(handler));
    }

    /*//////////////////////////////////////////////////////////////
                        INVARIANT CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @notice latestRecordedRewardsAmount must never exceed actual token balance.
    function invariant_RecordedNeverExceedsBalance() external view {
        uint256 recordedAmount = vault.latestRecordedRewardsAmount();
        uint256 actualBalance = asset.balanceOf(address(vault));

        assertLe(recordedAmount, actualBalance, "latestRecordedRewardsAmount must not exceed actual balance");
    }
}
