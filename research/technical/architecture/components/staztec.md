# StAztec — Non-Rebasable ERC20 Token

| Section | Specification |
| --- | --- |
| **Purpose** | ERC20 receipt token — supply changes via mint and burn only, no rebasing. |
| **State Variables (typed)** | `uint256 totalSupply`; `mapping(address=>uint256) balances`; `mapping(address=>mapping(address=>uint256)) allowances`; `address ollaCore`; `mapping(address=>uint256) nonces` |
| **Events** | `Transfer(address,address,uint256)`; `Approval(address,address,uint256)` |
| **Roles and Permissions** | `MINTER_ROLE` = OllaCore; `BURNER_ROLE` = OllaCore; `DEFAULT_ADMIN_ROLE` = guardian multisig |
| **Key Functions (typed and role scoped)** | `function mint(address to,uint256 amount)` — only `MINTER_ROLE`; `function burn(address from,uint256 amount)` — only `BURNER_ROLE`; `function permit(address owner,address spender,uint256 value,uint256 deadline,uint8 v,bytes32 r,bytes32 s)` — public; ERC20 functions public and standard |

