const { execSync } = require('node:child_process');

const RPC_URL = process.env.RPC_URL || 'http://127.0.0.1:8545';

// Anvil defaults (see anvil startup banner)
const ANVIL_USER_ADDR = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8';
const ANVIL_USER_PK = '0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d';

const USER_ADDRESS = process.env.USER_ADDRESS || ANVIL_USER_ADDR;
const USER_PRIVATE_KEY = process.env.USER_PRIVATE_KEY || ANVIL_USER_PK;

function usage() {
  return [
    'Usage:',
    '  node scripts/local-cli.js god-mint-user <amountTokens> [toAddress]',
    '  node scripts/local-cli.js user-deposit <amountTokens>',
    '  node scripts/local-cli.js operator-rebalance',
    '  node scripts/local-cli.js operator-update-accounting',
    '  node scripts/local-cli.js user-initiate-withdraw-all',
    '  node scripts/local-cli.js user-claim-withdrawals',
    '',
    'Env:',
    '  RPC_URL (default http://127.0.0.1:8545)',
    `  USER_ADDRESS (default ${ANVIL_USER_ADDR})`,
    '  USER_PRIVATE_KEY (default anvil account-1)',
  ].join('\n');
}

function run(cmd, env = {}) {
  execSync(cmd, {
    stdio: 'inherit',
    env: { ...process.env, ...env },
  });
}

function requireAmount(arg) {
  if (!arg) throw new Error('Missing amountTokens');
  if (!/^[0-9]+$/.test(arg)) throw new Error(`Invalid amountTokens: ${arg}`);
  return arg;
}

function main() {
  const [, , subcommand, ...args] = process.argv;
  if (!subcommand) {
    process.stderr.write(usage() + '\n');
    process.exit(1);
  }

  switch (subcommand) {
    case 'god-mint-user': {
      const amountTokens = requireAmount(args[0]);
      const to = args[1] || USER_ADDRESS;
      run(
        `cd contracts && forge script script/local/MintAztecTo.s.sol --broadcast --rpc-url ${RPC_URL}`,
        { AMOUNT: amountTokens, TO: to }
      );
      return;
    }
    case 'user-deposit': {
      const amountTokens = requireAmount(args[0]);
      run(
        `cd contracts && forge script script/local/UserDeposit.s.sol --broadcast --rpc-url ${RPC_URL}`,
        { PRIVATE_KEY: USER_PRIVATE_KEY, AMOUNT: amountTokens }
      );
      return;
    }
    case 'operator-rebalance': {
      run(
        `cd contracts && forge script script/local/OperatorRebalance.s.sol --broadcast --rpc-url ${RPC_URL}`
      );
      return;
    }
    case 'operator-update-accounting': {
      run(
        `cd contracts && forge script script/local/OperatorUpdateAccounting.s.sol --broadcast --rpc-url ${RPC_URL}`
      );
      return;
    }
    case 'user-initiate-withdraw-all': {
      run(
        `cd contracts && forge script script/local/UserInitiateWithdrawAll.s.sol --broadcast --rpc-url ${RPC_URL}`,
        { PRIVATE_KEY: USER_PRIVATE_KEY }
      );
      return;
    }
    case 'user-claim-withdrawals': {
      run(
        `cd contracts && forge script script/local/UserClaimWithdrawals.s.sol --broadcast --rpc-url ${RPC_URL}`,
        { PRIVATE_KEY: USER_PRIVATE_KEY }
      );
      return;
    }
    default:
      throw new Error(`Unknown subcommand: ${subcommand}`);
  }
}

try {
  main();
} catch (e) {
  process.stderr.write(String(e && e.message ? e.message : e) + '\n');
  process.stderr.write(usage() + '\n');
  process.exit(1);
}
