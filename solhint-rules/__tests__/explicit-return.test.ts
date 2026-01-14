import { RuleTester } from "solhint";

const rule = require("../explicit-return");

const ruleId = rule.RULE_ID as string;
const message = rule.DEFAULT_MESSAGE as string;

const tester = new RuleTester(ruleId, rule);

tester.run({
    valid: [
        {
            code: "pragma solidity ^0.8.24; contract C { function f() external returns (uint256) { return 1; } }",
        },
        {
            code: "pragma solidity ^0.8.24; contract C { function f() external returns (uint256 result) { result = 1; return result; } }",
        },
        {
            code: "pragma solidity ^0.8.24; contract C { function f() external returns (uint256) { uint256 x = 1; return x; } }",
        },
        {
            code: "pragma solidity ^0.8.24; contract C { function f() external { } }",
        },
        {
            code: "pragma solidity ^0.8.24; contract C { function f() external returns (uint256) { if (true) { return 1; } return 2; } }",
        },
    ],
    invalid: [
        {
            code: "pragma solidity ^0.8.24; contract C { function f() external returns (uint256 result) { result = 1; } }",
            errors: [{ message }],
        },
        {
            code: "pragma solidity ^0.8.24; contract C { function f() external returns (uint256 result, uint256 other) { result = 1; other = 2; } }",
            errors: [{ message }],
        },
    ],
});
