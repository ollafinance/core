# Security Policy

Olla manages staked Aztec on behalf of users. Security vulnerabilities in this codebase can
result in loss of funds. We take every report seriously and ask that you follow the responsible
disclosure process below.

## Reporting a Vulnerability

**Do not open a public GitHub issue or pull request for security vulnerabilities.**

Instead, please report vulnerabilities through
[GitHub Private Vulnerability Reporting](https://github.com/ollafinance/core/security/advisories/new).

If you are unable to use GitHub's reporting tool, email **<security@olla.finance>** with:

- A description of the vulnerability and its potential impact.
- Steps to reproduce or a proof of concept.
- The affected contract(s), function(s), and line(s) where applicable.

Encrypt sensitive details with our PGP key if available (check the repository's security tab).

## Scope

The following are **in scope** for security reports:

- All Solidity contracts under `contracts/src/`.
- Deployment and operations scripts under `contracts/script/` that affect on-chain state.
- Access control, upgrade safety, and state accounting issues.
- Issues arising from interactions between Olla contracts and external dependencies
  (Aztec rollup, LayerZero, OpenZeppelin).

The following are **out of scope**:

- Test contracts, mocks, and harnesses under `contracts/test/` and `contracts/src/*/mocks/`.
- Known trust assumptions documented in [`docs/security/trust-assumptions.md`](docs/security/trust-assumptions.md).
- Findings that require governance multisig compromise as a prerequisite (these are acknowledged
  risks — see T-3 through T-5 in the trust assumptions document).
- Gas optimizations (report these as regular issues using the audit finding template).

## Severity Classification

We use the following severity levels, aligned with our
[audit finding template](.github/ISSUE_TEMPLATE/audit_finding.yml):

| Severity | Description |
|----------|-------------|
| **Critical** | Direct loss of user funds, unauthorized minting/burning of stAztec, or full protocol compromise with no user action required. |
| **High** | Conditional loss of funds, permanent denial of service, or bypass of governance timelocks. |
| **Medium** | Temporary denial of service, incorrect accounting that does not directly drain funds, or privilege escalation within constrained roles. |
| **Low** | Deviation from specification, edge-case failures with minimal impact, or issues requiring unlikely preconditions. |

## Response Process

1. **Acknowledgment** — We will acknowledge receipt of your report within 2 business days.
2. **Assessment** — We will evaluate severity and scope, and may ask clarifying questions.
3. **Remediation** — We will develop and test a fix. For critical issues, we may deploy an
   emergency pause via the guardian role while the fix is prepared.
4. **Disclosure** — Once the fix is deployed, we will publish a security advisory crediting the
   reporter (unless anonymity is requested).

We aim to resolve critical and high severity issues within 7 days of confirmation.

## Security Practices

This repository maintains several layers of defense:

- **Static analysis**: Slither runs on every PR and is enforced in CI.
- **Testing**: Unit, integration, invariant, fuzz, and end-to-end tests (~39K lines of test code).
- **Formal verification**: Certora specs for core accounting and exchange rate invariants.
- **Storage layout validation**: CI checks prevent accidental storage collisions in upgradeable contracts.
- **Pre-commit hooks**: Formatting, linting, and static analysis run before every commit.
- **Trust assumptions**: Explicit documentation of privileged roles and external dependencies
  in [`docs/security/trust-assumptions.md`](docs/security/trust-assumptions.md).

## Audit Reports

Published audit reports are available in the [`audits/`](audits/) directory.
