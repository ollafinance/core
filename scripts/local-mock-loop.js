const { execSync, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const ONE_ETHER = 10n ** 18n;

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

function getEnvInt(name, def) {
  const v = process.env[name];
  if (!v) return def;
  const n = Number(v);
  return Number.isFinite(n) ? n : def;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function run(cmd, env = {}) {
  execSync(cmd, {
    stdio: 'inherit',
    env: { ...process.env, ...env },
  });
}

function cleanCastStdout(stdout) {
  // Newer cast versions append human hints like: "100000... [1e18]".
  return String(stdout || '').trim().replace(/\[[^\]]*\]/g, '').trim();
}

function parseFirstInt(stdout) {
  const cleaned = cleanCastStdout(stdout);
  const m = cleaned.match(/-?\d+/);
  if (!m) throw new Error(`Unexpected cast output: ${cleaned}`);
  return BigInt(m[0]);
}

function callUint(rpcUrl, to, sig) {
  const res = spawnSync(
    'cast',
    ['call', to, sig, '--rpc-url', rpcUrl],
    { encoding: 'utf8' }
  );
  if (res.status !== 0) {
    throw new Error(res.stderr || res.stdout || 'cast call failed');
  }
  return parseFirstInt(res.stdout);
}

function parseCastTuple(stdout) {
  const s = cleanCastStdout(stdout).replace(/[()]/g, '').replace(/\s+/g, ' ');

  if (!s) return [];

  return s
    .split(/[, ]+/)
    .map((x) => x.trim())
    .filter(Boolean)
    .map((x) => BigInt(x));
}

function callTuple(rpcUrl, to, sig) {
  const res = spawnSync('cast', ['call', to, sig, '--rpc-url', rpcUrl], { encoding: 'utf8' });
  if (res.status !== 0) {
    throw new Error(res.stderr || res.stdout || 'cast call failed');
  }
  return parseCastTuple(res.stdout);
}

function format1e18(x) {
  const neg = x < 0n;
  const v = neg ? -x : x;
  const whole = v / ONE_ETHER;
  const frac = v % ONE_ETHER;
  const fracStr = frac.toString().padStart(18, '0').slice(0, 6);
  return `${neg ? '-' : ''}${whole.toString()}.${fracStr}`;
}

function formatU256(x) {
  // Treat all balances as 18-decimal token amounts in logs.
  return format1e18(x);
}

function delta(a, b) {
  return b - a;
}

function fmtDeltaU256(d) {
  const sign = d >= 0n ? '+' : '';
  return sign + formatU256(d);
}

async function main() {
  const rpcUrl = process.env.RPC_URL || 'http://127.0.0.1:8545';
  const intervalMs = getEnvInt('INTERVAL_MS', 3000);
  const rate = process.env.RATE || '1000000000000000000';
  const deployEnv = process.env.DEPLOY_ENV || 'local';

  const deploymentsPath = path.join('contracts', 'deployments', `${deployEnv}.json`);
  if (!fs.existsSync(deploymentsPath)) {
    throw new Error(`Missing deployment file: ${deploymentsPath}. Run yarn deploy:local first.`);
  }

  const deployments = readJson(deploymentsPath);
  const stakingManager = deployments.addresses && deployments.addresses.StakingManager;
  if (!stakingManager) {
    throw new Error(`Missing deployments.addresses.StakingManager in ${deploymentsPath}`);
  }

  const core = deployments.addresses && deployments.addresses.OllaCoreProxy;
  if (!core) {
    process.stderr.write(
      `[mock-loop] warning: Missing deployments.addresses.OllaCoreProxy in ${deploymentsPath}; deposit detection and result logs will be limited\n`
    );
  }

  const withdrawalQueue = deployments.addresses && deployments.addresses.WithdrawalQueueProxy;
  if (!withdrawalQueue) {
    process.stderr.write(
      `[mock-loop] warning: Missing deployments.addresses.WithdrawalQueueProxy in ${deploymentsPath}; queued withdrawal logs will be limited\n`
    );
  }

  // One-time: configure reward rate.
  run(
    'cd contracts && forge script script/rollup/SetRewardRate.s.sol --broadcast --rpc-url ' + rpcUrl,
    { RATE: rate }
  );

  process.stdout.write(
    `[mock-loop] start rpc=${rpcUrl} env=${deployEnv} intervalMs=${intervalMs} rate=${rate}\n`
  );

  function readCoreState() {
    if (!core) return null;
    const totalAssets = callUint(rpcUrl, core, 'totalAssets()(uint256)');
    const exchangeRate = callUint(rpcUrl, core, 'exchangeRate()(uint256)');

    // AccountingState: (bufferedAssets, stakedPrincipal, rewardsVaultBalance, claimableRewards, rewardsDelta, slashingDelta, cumulativeRewards)
    const accounting = callTuple(
      rpcUrl,
      core,
      'accountingState()((uint256,uint256,uint256,uint256,uint256,uint256,uint256))'
    );
    if (accounting.length !== 7) {
      throw new Error(`Unexpected accountingState() decode length: ${accounting.length}`);
    }

    return {
      totalAssets,
      exchangeRate,
      bufferedAssets: accounting[0],
      stakedPrincipal: accounting[1],
      rewardsVaultBalance: accounting[2],
      claimableRewards: accounting[3],
      rewardsDelta: accounting[4],
      slashingDelta: accounting[5],
      cumulativeRewards: accounting[6],
    };
  }

  function readQueuedWithdrawals() {
    if (!withdrawalQueue) return null;
    return callUint(rpcUrl, withdrawalQueue, 'totalPendingAssets()(uint256)');
  }

  while (true) {
    try {
      const loopStart = Date.now();
      const stakedBefore = callUint(rpcUrl, stakingManager, 'totalStaked()(uint256)');
      const pendingUnstakesBefore = callUint(rpcUrl, stakingManager, 'pendingUnstakes()(uint256)');
      const stateBefore = readCoreState();
      const queuedBefore = readQueuedWithdrawals();

      const hasDeposits = stateBefore ? stateBefore.totalAssets > 0n : stakedBefore > 0n;
      if (!hasDeposits) {
        const parts = ['[mock-loop] skip (no deposits)'];
        if (stateBefore) parts.push(`totalAssets=${formatU256(stateBefore.totalAssets)}`);
        parts.push(`totalStaked=${formatU256(stakedBefore)}`);
        if (queuedBefore != null) parts.push(`queued=${formatU256(queuedBefore)}`);
        parts.push(`pendingUnstakes=${formatU256(pendingUnstakesBefore)}`);
        process.stdout.write(parts.join(' ') + '\n');
        await sleep(intervalMs);
        continue;
      }

      // Always print a pre-state line for debugging reverts.
      {
        const parts = ['[mock-loop] pre'];
        if (stateBefore) {
          parts.push(`totalAssets=${formatU256(stateBefore.totalAssets)}`);
          parts.push(`exchangeRate=${format1e18(stateBefore.exchangeRate)}`);
          parts.push(`buffer=${formatU256(stateBefore.bufferedAssets)}`);
          parts.push(`principal=${formatU256(stateBefore.stakedPrincipal)}`);
          parts.push(`rewardsVault=${formatU256(stateBefore.rewardsVaultBalance)}`);
          parts.push(`claimable=${formatU256(stateBefore.claimableRewards)}`);
          parts.push(`cumulativeRewards=${formatU256(stateBefore.cumulativeRewards)}`);
        }
        if (queuedBefore != null) parts.push(`queued=${formatU256(queuedBefore)}`);
        parts.push(`totalStaked=${formatU256(stakedBefore)}`);
        parts.push(`pendingUnstakes=${formatU256(pendingUnstakesBefore)}`);
        process.stdout.write(parts.join(' ') + '\n');
      }

      const steps = [];
      if (stakedBefore > 0n) {
        steps.push('tickRewards');
        run('cd contracts && forge script script/rollup/TickRewards.s.sol --broadcast --rpc-url ' + rpcUrl);
      }

      steps.push('rebalance');
      run('cd contracts && forge script script/local/OperatorRebalance.s.sol --broadcast --rpc-url ' + rpcUrl);

      steps.push('updateAccounting');
      run('cd contracts && forge script script/local/OperatorUpdateAccounting.s.sol --broadcast --rpc-url ' + rpcUrl);

      const stakedAfter = callUint(rpcUrl, stakingManager, 'totalStaked()(uint256)');
      const pendingUnstakesAfter = callUint(rpcUrl, stakingManager, 'pendingUnstakes()(uint256)');
      const stateAfter = readCoreState();
      const queuedAfter = readQueuedWithdrawals();

      const durationMs = Date.now() - loopStart;
      const parts = [`[mock-loop] did ${steps.join(' -> ')} (${durationMs}ms)`];
      parts.push(`totalStaked=${formatU256(stakedAfter)} (${fmtDeltaU256(delta(stakedBefore, stakedAfter))})`);
      parts.push(
        `pendingUnstakes=${formatU256(pendingUnstakesAfter)} (${fmtDeltaU256(
          delta(pendingUnstakesBefore, pendingUnstakesAfter)
        )})`
      );

      if (stateBefore && stateAfter) {
        parts.push(
          `totalAssets=${formatU256(stateAfter.totalAssets)} (${fmtDeltaU256(delta(stateBefore.totalAssets, stateAfter.totalAssets))})`
        );
        parts.push(
          `exchangeRate=${format1e18(stateAfter.exchangeRate)} (${fmtDeltaU256(delta(stateBefore.exchangeRate, stateAfter.exchangeRate))})`
        );
        parts.push(
          `buffer=${formatU256(stateAfter.bufferedAssets)} (${fmtDeltaU256(delta(stateBefore.bufferedAssets, stateAfter.bufferedAssets))})`
        );
        parts.push(
          `principal=${formatU256(stateAfter.stakedPrincipal)} (${fmtDeltaU256(delta(stateBefore.stakedPrincipal, stateAfter.stakedPrincipal))})`
        );
        parts.push(
          `rewardsVault=${formatU256(stateAfter.rewardsVaultBalance)} (${fmtDeltaU256(
            delta(stateBefore.rewardsVaultBalance, stateAfter.rewardsVaultBalance)
          )})`
        );
        parts.push(
          `claimable=${formatU256(stateAfter.claimableRewards)} (${fmtDeltaU256(
            delta(stateBefore.claimableRewards, stateAfter.claimableRewards)
          )})`
        );
        parts.push(
          `cumulativeRewards=${formatU256(stateAfter.cumulativeRewards)} (${fmtDeltaU256(
            delta(stateBefore.cumulativeRewards, stateAfter.cumulativeRewards)
          )})`
        );
        parts.push(`rewardsDelta=${formatU256(stateAfter.rewardsDelta)} slashingDelta=${formatU256(stateAfter.slashingDelta)}`);
      }

      if (queuedBefore != null && queuedAfter != null) {
        parts.push(`queued=${formatU256(queuedAfter)} (${fmtDeltaU256(delta(queuedBefore, queuedAfter))})`);
      }

      process.stdout.write(parts.join(' ') + '\n');
    } catch (e) {
      // Keep looping; transient failures shouldn't kill local dev.
      process.stderr.write(String(e && e.message ? e.message : e) + '\n');
    }

    await sleep(intervalMs);
  }
}

main().catch((e) => {
  process.stderr.write(String(e && e.message ? e.message : e) + '\n');
  process.exit(1);
});
