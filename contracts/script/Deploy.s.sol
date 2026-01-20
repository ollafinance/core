// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script, console2 } from "@forge-std/Script.sol";
import { OllaCore } from "src/core/OllaCore.sol";
import { StAztec } from "src/core/StAztec.sol";
import { MockAztec } from "src/mocks/MockAztec.sol";
import { MockStakingManager } from "src/mocks/MockStakingManager.sol";
import { ERC1967Proxy } from "@oz/proxy/ERC1967/ERC1967Proxy.sol";
import { IStAztec } from "src/interfaces/IStAztec.sol";
import { IStakingManager } from "src/interfaces/IStakingManager.sol";
import { IERC20 } from "@oz/token/ERC20/IERC20.sol";

contract DeployScript is Script {
    function setUp() public { }

    function run() public {
        uint256 deployerPrivateKey =
            vm.envOr("PRIVATE_KEY", uint256(0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80));
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Mocks
        MockAztec asset = new MockAztec(deployer);
        MockStakingManager stakingManager = new MockStakingManager();

        console2.log("Mock Asset deployed at:", address(asset));
        console2.log("Mock StakingManager deployed at:", address(stakingManager));

        // 2. Deploy OllaCore Implementation
        OllaCore coreImpl = new OllaCore();
        console2.log("OllaCore Implementation deployed at:", address(coreImpl));

        // 3. Deploy OllaCore Proxy (Uninitialized)
        // We pass empty bytes ("") so initialize is NOT called yet
        ERC1967Proxy coreProxy = new ERC1967Proxy(address(coreImpl), "");
        address coreAddress = address(coreProxy);
        console2.log("OllaCore Proxy deployed at:", address(coreAddress));

        // 4. Deploy StAztec (linked to Proxy)
        StAztec stAztec = new StAztec(coreAddress);
        console2.log("StAztec deployed at:", address(stAztec));

        // 5. Initialize OllaCore
        // Using deployer as governance, rewardsVault, withdrawalQueue, safetyModule for now
        address governance = deployer;
        address withdrawalQueue = deployer; // Placeholder
        address rewardsVault = deployer; // Placeholder
        address safetyModule = deployer; // Placeholder

        // Cast proxy to OllaCore to call initialize
        OllaCore(coreAddress)
            .initialize(
                IERC20(address(asset)),
                IStAztec(address(stAztec)),
                IStakingManager(address(stakingManager)),
                governance,
                withdrawalQueue,
                rewardsVault,
                safetyModule
            );
        console2.log("OllaCore Initialized");

        // 6. Setup for Dev: Mint some assets to deployer
        asset.mint(deployer, 1000 ether);
        asset.approve(coreAddress, 1000 ether);
        console2.log("Minted and Approved 1000 Mock Assets to Deployer");

        vm.stopBroadcast();
    }
}
