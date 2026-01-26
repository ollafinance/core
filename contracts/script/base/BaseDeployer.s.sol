// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

import { Script, console2 } from "@forge-std/Script.sol";

/// @title BaseDeployer
/// @notice Base contract for all deployers with shared utilities
abstract contract BaseDeployer is Script {
    /// @notice Path to deployments directory
    string internal constant DEPLOYMENTS_PATH = "deployments/";

    /// @notice Get the deployment file path for a given environment
    function _getDeploymentPath(string memory env) internal pure returns (string memory) {
        return string.concat(DEPLOYMENTS_PATH, env, ".json");
    }

    /// @notice Check if a deployment file exists for the given environment
    function _deploymentExists(string memory env) internal view returns (bool) {
        string memory path = _getDeploymentPath(env);
        return vm.isFile(path);
    }

    /// @notice Read an address from the deployment file
    function _readDeployment(string memory env, string memory key) internal view returns (address) {
        string memory path = _getDeploymentPath(env);
        if (!vm.isFile(path)) {
            revert(string.concat("Deployment file not found: ", path));
        }
        string memory json = vm.readFile(path);
        return vm.parseJsonAddress(json, string.concat(".addresses.", key));
    }

    /// @notice Read an address from deployment file, return address(0) if not found
    function _tryReadDeployment(string memory env, string memory key) internal view returns (address) {
        string memory path = _getDeploymentPath(env);
        if (!vm.isFile(path)) {
            return address(0);
        }
        try vm.parseJsonAddress(vm.readFile(path), string.concat(".addresses.", key)) returns (address addr) {
            return addr;
        } catch {
            return address(0);
        }
    }

    /// @notice Initialize a new deployment JSON with metadata
    function _initDeploymentJson(string memory env, uint256 chainId, address deployer)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{\n  "network": "',
            env,
            '",\n  "chainId": ',
            _uint256ToString(chainId),
            ',\n  "deployer": "',
            _addressToString(deployer),
            '",\n  "addresses": {'
        );
    }

    /// @notice Convert uint256 to string (pure function)
    function _uint256ToString(uint256 value) internal pure returns (string memory) {
        if (value == 0) {
            return "0";
        }
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            digits -= 1;
            buffer[digits] = bytes1(uint8(48 + uint256(value % 10)));
            value /= 10;
        }
        return string(buffer);
    }

    /// @notice Convert address to string (pure function)
    function _addressToString(address addr) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory data = abi.encodePacked(addr);
        bytes memory str = new bytes(2 + data.length * 2);
        str[0] = "0";
        str[1] = "x";
        for (uint256 i = 0; i < data.length; i++) {
            str[2 + i * 2] = alphabet[uint256(uint8(data[i] >> 4))];
            str[3 + i * 2] = alphabet[uint256(uint8(data[i] & 0x0f))];
        }
        return string(str);
    }

    /// @notice Write deployment JSON to file
    function _writeDeploymentJson(string memory env, string memory json) internal {
        string memory path = _getDeploymentPath(env);
        string memory finalJson = string.concat(json, "\n}");

        // Create deployments directory if it doesn't exist
        vm.createDir(DEPLOYMENTS_PATH, true);

        vm.writeFile(path, finalJson);
        console2.log("Deployment saved to:", path);
    }

    /// @notice Add an address to the deployment JSON (for building incrementally)
    function _addAddressToJson(string memory currentJson, string memory key, address addr, bool isFirst)
        internal
        pure
        returns (string memory)
    {
        string memory comma = isFirst ? "" : ",";
        string memory addressEntry = string.concat(comma, '\n    "', key, '": "', _addressToString(addr), '"');

        // Find the closing brace of addresses and insert before it
        return string.concat(currentJson, addressEntry);
    }

    /// @notice Close the addresses object in JSON
    function _closeAddressesJson(string memory currentJson) internal pure returns (string memory) {
        return string.concat(currentJson, "\n  }");
    }

    /// @notice Log deployment of a contract
    function _logDeployment(string memory name, address addr) internal pure {
        console2.log(string.concat(name, " deployed at:"), addr);
    }
}
