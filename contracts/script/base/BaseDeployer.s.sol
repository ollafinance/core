// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.27;

// solhint-disable no-console
import { Script, console2 } from "@forge-std/Script.sol";

/// @title BaseDeployer
/// @notice Base contract for all deployers with shared utilities
abstract contract BaseDeployer is Script {
    /// @notice Path to deployments directory
    string internal constant _DEPLOYMENTS_PATH = "deployments/";

    /// @notice Write deployment JSON to file
    function _writeDeploymentJson(string memory env, string memory json) internal {
        string memory path = _getDeploymentPath(env);
        string memory finalJson = string.concat(json, "\n}");

        // Create deployments directory if it doesn't exist
        vm.createDir(_DEPLOYMENTS_PATH, true);

        vm.writeFile(path, finalJson);
    }

    /// @notice Ensure deployment artifact exists and matches the current target config.
    /// @return path Deployment artifact path.
    function _ensureDeploymentArtifact(
        string memory env,
        uint256 chainId,
        address deployer,
        bool mockAztec,
        address asset,
        address rollupRegistry,
        address lzEndpoint
    ) internal returns (string memory path) {
        path = _getDeploymentPath(env);
        vm.createDir(_DEPLOYMENTS_PATH, true);

        if (!vm.isFile(path)) {
            string memory json = string.concat(
                "{\n",
                "  \"network\": ",
                _jsonString(env),
                ",\n",
                "  \"chainId\": ",
                _uint256ToString(chainId),
                ",\n",
                "  \"deployer\": ",
                _jsonString(_addressToString(deployer)),
                ",\n",
                "  \"mode\": {\n",
                "    \"mockAztec\": ",
                mockAztec ? "true" : "false",
                "\n",
                "  },\n",
                "  \"inputs\": {\n",
                "    \"asset\": ",
                _jsonString(_addressToString(asset)),
                ",\n",
                "    \"rollupRegistry\": ",
                _jsonString(_addressToString(rollupRegistry)),
                ",\n",
                "    \"lzEndpoint\": ",
                _jsonString(_addressToString(lzEndpoint)),
                "\n",
                "  },\n",
                "  \"addresses\": {},\n",
                "  \"status\": {\n",
                "    \"phase\": \"A\",\n",
                "    \"completed\": false,\n",
                "    \"updatedAtBlock\": ",
                _uint256ToString(block.number),
                ",\n",
                "    \"flags\": {}\n",
                "\n",
                "  }\n",
                "}\n"
            );
            vm.writeFile(path, json);
            return path;
        }

        string memory existing = vm.readFile(path);
        require(
            vm.parseJsonUint(existing, ".chainId") == chainId,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.chainId"
        );
        require(
            keccak256(bytes(vm.parseJsonString(existing, ".network"))) == keccak256(bytes(env)),
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.network"
        );
        require(
            vm.parseJsonAddress(existing, ".deployer") == deployer,
            "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.deployer"
        );

        _ensureConfigCompatibility(path, existing, mockAztec, asset, rollupRegistry, lzEndpoint);

        _ensureStatusScaffold(env);
        _touchDeploymentStatus(env);
    }

    function _ensureConfigCompatibility(
        string memory path,
        string memory existing,
        bool mockAztec,
        address asset,
        address rollupRegistry,
        address lzEndpoint
    ) internal {
        bool existingMockAztec;
        bool hasMode;
        try vm.parseJsonBool(existing, ".mode.mockAztec") returns (bool parsedMockAztec) {
            existingMockAztec = parsedMockAztec;
            hasMode = true;
        } catch {
            hasMode = false;
        }

        if (hasMode) {
            require(existingMockAztec == mockAztec, "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.mode.mockAztec");
        } else {
            (bool inferredMockAztec, bool inferred) = _inferMockAztec(existing);
            if (inferred) {
                require(
                    inferredMockAztec == mockAztec, "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.mode.mockAztec"
                );
            }
            vm.writeJson(mockAztec ? "true" : "false", path, ".mode.mockAztec");
        }

        _ensureInputAddressCompatibility(path, existing, "asset", asset);
        _ensureInputAddressCompatibility(path, existing, "rollupRegistry", rollupRegistry);
        _ensureInputAddressCompatibility(path, existing, "lzEndpoint", lzEndpoint);

        if (!mockAztec) {
            require(asset != address(0), "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.asset");
            require(
                rollupRegistry != address(0), "Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.rollupRegistry"
            );
        }
    }

    function _ensureInputAddressCompatibility(
        string memory path,
        string memory existing,
        string memory key,
        address value
    ) internal {
        string memory jsonPath = string.concat(".inputs.", key);
        try vm.parseJsonAddress(existing, jsonPath) returns (address parsed) {
            require(parsed == value, string.concat("Deploy: CONFIG_MISMATCH_WITH_EXISTING_DEPLOYMENT.inputs.", key));
        } catch {
            vm.writeJson(_jsonString(_addressToString(value)), path, jsonPath);
        }
    }

    function _ensureStatusScaffold(string memory env) internal {
        string memory path = _getDeploymentPath(env);

        bool hasStatus;
        try vm.parseJsonString(vm.readFile(path), ".status.phase") returns (string memory) {
            hasStatus = true;
        } catch {
            hasStatus = false;
        }

        if (!hasStatus) {
            vm.writeJson(
                string.concat(
                    "{\"phase\":\"A\",\"completed\":false,\"updatedAtBlock\":",
                    _uint256ToString(block.number),
                    ",\"flags\":{}}"
                ),
                path,
                ".status"
            );
            return;
        }

        bool hasFlags;
        try vm.parseJson(vm.readFile(path), ".status.flags") returns (bytes memory) {
            hasFlags = true;
        } catch {
            hasFlags = false;
        }

        if (!hasFlags) {
            vm.writeJson("{}", path, ".status.flags");
        }
    }

    function _setDeploymentAddress(string memory env, string memory key, address addr) internal {
        string memory path = _getDeploymentPath(env);
        vm.writeJson(_jsonString(_addressToString(addr)), path, string.concat(".addresses.", key));
        _touchDeploymentStatus(env);
    }

    function _setDeploymentMetadataString(string memory env, string memory key, string memory value) internal {
        string memory path = _getDeploymentPath(env);
        vm.writeJson(_jsonString(value), path, string.concat(".", key));
        _touchDeploymentStatus(env);
    }

    function _setDeploymentPhase(string memory env, string memory phase, bool completed) internal {
        string memory path = _getDeploymentPath(env);
        vm.writeJson(_jsonString(phase), path, ".status.phase");
        vm.writeJson(completed ? "true" : "false", path, ".status.completed");
        vm.writeJson(_uint256ToString(block.number), path, ".status.updatedAtBlock");
    }

    function _touchDeploymentStatus(string memory env) internal {
        string memory path = _getDeploymentPath(env);
        vm.writeJson(_uint256ToString(block.number), path, ".status.updatedAtBlock");
    }

    function _setDeploymentFlag(string memory env, string memory key, bool value) internal {
        string memory path = _getDeploymentPath(env);
        vm.writeJson(value ? "true" : "false", path, string.concat(".status.flags.", key));
        _touchDeploymentStatus(env);
    }

    function _tryReadDeploymentFlag(string memory env, string memory key)
        internal
        view
        returns (bool value, bool found)
    {
        string memory path = _getDeploymentPath(env);
        if (!vm.isFile(path)) {
            return (false, false);
        }

        try vm.parseJsonBool(vm.readFile(path), string.concat(".status.flags.", key)) returns (bool parsed) {
            return (parsed, true);
        } catch {
            return (false, false);
        }
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

    function _inferMockAztec(string memory existing) internal pure returns (bool mockAztec, bool inferred) {
        address mockRollup = address(0);
        address mockRollupRegistry = address(0);

        try vm.parseJsonAddress(existing, ".addresses.MockAztecRollup") returns (address parsedMockRollup) {
            mockRollup = parsedMockRollup;
        } catch { }

        try vm.parseJsonAddress(existing, ".addresses.MockAztecRollupRegistry") returns (address parsedMockRegistry) {
            mockRollupRegistry = parsedMockRegistry;
        } catch { }

        if (mockRollup != address(0) || mockRollupRegistry != address(0)) {
            return (true, true);
        }

        return (false, false);
    }

    function _jsonString(string memory value) internal pure returns (string memory) {
        return string.concat("\"", value, "\"");
    }

    /// @notice Get the deployment file path for a given environment
    function _getDeploymentPath(string memory env) internal pure returns (string memory) {
        return string.concat(_DEPLOYMENTS_PATH, env, ".json");
    }

    /// @notice Initialize a new deployment JSON with metadata
    function _initDeploymentJson(string memory env, uint256 chainId, address deployer)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            "{\n  \"network\": \"",
            env,
            "\",\n  \"chainId\": ",
            _uint256ToString(chainId),
            ",\n  \"deployer\": \"",
            _addressToString(deployer),
            "\",\n  \"addresses\": {"
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

    /// @notice Add an address to the deployment JSON (for building incrementally)
    function _addAddressToJson(string memory currentJson, string memory key, address addr, bool isFirst)
        internal
        pure
        returns (string memory)
    {
        string memory comma = isFirst ? "" : ",";
        string memory addressEntry = string.concat(comma, "\n    \"", key, "\": \"", _addressToString(addr), "\"");

        // Find the closing brace of addresses and insert before it
        return string.concat(currentJson, addressEntry);
    }

    /// @notice Close the addresses object in JSON
    function _closeAddressesJson(string memory currentJson) internal pure returns (string memory) {
        return string.concat(currentJson, "\n  }");
    }

    /// @notice Add a metadata key-value pair to the JSON (after addresses)
    function _addMetadataToJson(string memory currentJson, string memory key, string memory value)
        internal
        pure
        returns (string memory)
    {
        return string.concat(currentJson, ",\n  \"", key, "\": \"", value, "\"");
    }

    /// @notice Log deployment of a contract
    function _logDeployment(string memory name, address addr) internal pure {
        console2.log("Deployed %s at %s", name, addr);
    }

    /// @notice Log deployment info message
    function _logInfo(string memory message) internal pure {
        console2.log("%s", message);
    }
}
