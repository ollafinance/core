import type { PublicClient } from "viem";
import { parseAbiItem } from "viem";

export async function findAllAttesters(
  publicClient: PublicClient,
  stakingManagerAddress: `0x${string}`
): Promise<`0x${string}`[]> {
  const logs = await publicClient.getLogs({
    address: stakingManagerAddress,
    event: parseAbiItem("event StakedWithProvider(address indexed attester, uint256 indexed amount)"),
    fromBlock: 0n,
  });

  const seen = new Set<string>();
  const attesters: `0x${string}`[] = [];
  for (const log of logs) {
    const attester = log.args.attester as `0x${string}`;
    if (seen.has(attester.toLowerCase())) continue;
    seen.add(attester.toLowerCase());
    attesters.push(attester);
  }
  return attesters;
}

export async function findActiveAttesters(
  publicClient: PublicClient,
  stakingManagerAddress: `0x${string}`,
  rollupRead: any
): Promise<`0x${string}`[]> {
  const logs = await publicClient.getLogs({
    address: stakingManagerAddress,
    event: parseAbiItem("event StakedWithProvider(address indexed attester, uint256 indexed amount)"),
    fromBlock: 0n,
  });

  const seen = new Set<string>();
  const active: `0x${string}`[] = [];
  for (const log of logs) {
    const attester = log.args.attester as `0x${string}`;
    if (seen.has(attester.toLowerCase())) continue;
    seen.add(attester.toLowerCase());

    const view = await rollupRead.read.getAttesterView([attester]) as any;
    if (Number(view.status) === 1 && view.effectiveBalance > 0n) {
      active.push(attester);
    }
  }
  return active;
}
