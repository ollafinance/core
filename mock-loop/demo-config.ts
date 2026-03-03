import type { RunConfig } from "./lib/types.js";

// ============================================================================
// DEMO CONFIG — 10–20 minute frontend demo
// ============================================================================
//
// 4 automated users cycle through deposit → earn → withdraw → claim → re-deposit
// while a 5th account is yours to control manually via the frontend.
//
// Start:
//   Terminal 1:  yarn dev:chain
//   Terminal 2:  yarn deploy:local
//   Terminal 3:  yarn dev:mock-loop:demo
//
// Your manual account (Anvil Account 5):
//   Address:     0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
//   Private Key: 0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba
//   → Import this key into MetaMask to interact via the frontend.
//   → Seeded with a 100K AZTEC deposit at startup (tick 2).
//
// Reward growth: ~7–8% visible return over 20 minutes.
// Tick interval:  3 seconds (human-readable pace for watching the frontend).
// Rebalance:      every 30 seconds (exchange rate updates visibly).
//
// ============================================================================
// TIMELINE (at 3s / tick)
// ============================================================================
//
//  0:00–0:20   All 5 users deposit, first rebalance stakes funds
//  0:20–2:30   Rewards accrue, exchange rate climbs
//  2:30–4:00   User 4 (small) withdraws → claims → re-deposits bigger
//  4:00–5:00   User 2 adds more, rewards keep flowing
//  5:00–7:00   User 3 withdraws → claims → re-deposits bigger
//  7:30–9:00   User 1 (whale) exits → claims → re-deposits bigger
// 10:00–12:00  User 2 exits → claims → re-deposits
// 13:00–20:00  Second round of withdrawals for all 4 automated users
//     20:00+   Steady state — rebalances & rewards continue indefinitely
//
// ============================================================================

// ---------------------------------------------------------------------------
// Anvil private keys (accounts 1–5; account 0 is the deployer/operator)
// ---------------------------------------------------------------------------
const ACCT1_PK =
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d"; // 0x70997970…  (whale)
const ACCT2_PK =
  "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a"; // 0x3C44CdDd…  (medium)
const ACCT3_PK =
  "0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6"; // 0x90F79bf6…  (solid)
const ACCT4_PK =
  "0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a"; // 0x15d34AAf…  (small)
const ACCT5_PK =
  "0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba"; // 0x9965507D…  (YOU)

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Convert a whole-token amount to its 18-decimal string representation. */
const aztec = (n: number): string => (BigInt(n) * 10n ** 18n).toString();

/** Rebalance every 10 ticks starting at tick 7 (≈ every 30 s). */
const isRebalanceTick = (_s: any, tick: number): boolean =>
  tick >= 7 && (tick - 7) % 10 === 0;

/** Run only on an exact tick. */
const onTick = (t: number) => (_s: any, tick: number) => tick === t;

/** Claim window: run once within a tick range (stops after first success). */
const claimWindow = (from: number, to: number) => (s: any, tick: number) =>
  !s?.completed && tick >= from && tick < to;

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------

const demoConfig: RunConfig = {
  rpcUrl: "http://127.0.0.1:8545",
  deployEnv: "local",
  intervalMs: 3_000, // 3 s per tick

  scenarios: [
    // =======================================================================
    // INFRASTRUCTURE — every tick
    // =======================================================================
    {
      type: "provider-keys",
      enabled: true,
      shouldRun: (_s, _t) => true,
      minKeys: 3,
      seedCount: 5,
    },
    {
      type: "refill-keys",
      enabled: true,
      shouldRun: (_s, _t) => true,
      seedCount: 5,
    },
    {
      type: "mock-rewards",
      enabled: true,
      shouldRun: (_s, _t) => true,
      rateBps: 2, // 0.02 % per tick ≈ 0.2 % per rebalance cycle
    },

    // =======================================================================
    // REBALANCE HEARTBEAT — ticks 7, 17, 27, 37, …
    // =======================================================================
    {
      type: "time-advance",
      enabled: true,
      shouldRun: isRebalanceTick,
      seconds: 3601, // 1 hour + 1 second — clears rebalance cooldown (1h); well within accounting staleness limit (2h)
    },
    {
      type: "rebalance",
      enabled: true,
      shouldRun: isRebalanceTick,
    },
    {
      type: "accounting",
      enabled: true,
      shouldRun: isRebalanceTick,
    },

    // =======================================================================
    // PHASE 1 — INITIAL DEPOSITS  (ticks 1–4)
    // =======================================================================
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(1),
      amount: aztec(500_000), // User 1 — whale
      privateKey: ACCT1_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(1),
      amount: aztec(100_000), // User 2 — medium
      privateKey: ACCT2_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(2),
      amount: aztec(200_000), // User 3 — solid
      privateKey: ACCT3_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(2),
      amount: aztec(100_000), // User 5 — YOUR seed deposit
      privateKey: ACCT5_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(4),
      amount: aztec(50_000), // User 4 — small
      privateKey: ACCT4_PK,
    },

    // =======================================================================
    // PHASE 2 — USER 4 WITHDRAWAL CYCLE  (ticks 50 → 82)
    //   withdraw at 50, claim ~70, re-deposit at 82
    // =======================================================================
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: onTick(50),
      privateKey: ACCT4_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: claimWindow(70, 80),
      privateKey: ACCT4_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(82),
      amount: aztec(75_000), // re-deposits bigger
      privateKey: ACCT4_PK,
    },

    // Extra: User 2 tops up
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(90),
      amount: aztec(150_000),
      privateKey: ACCT2_PK,
    },

    // =======================================================================
    // PHASE 3 — USER 3 WITHDRAWAL CYCLE  (ticks 100 → 132)
    // =======================================================================
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: onTick(100),
      privateKey: ACCT3_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: claimWindow(120, 130),
      privateKey: ACCT3_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(132),
      amount: aztec(250_000),
      privateKey: ACCT3_PK,
    },

    // =======================================================================
    // PHASE 4 — USER 1 (WHALE) WITHDRAWAL CYCLE  (ticks 155 → 182)
    // =======================================================================
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: onTick(155),
      privateKey: ACCT1_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: claimWindow(170, 180),
      privateKey: ACCT1_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(182),
      amount: aztec(600_000), // whale re-enters even bigger
      privateKey: ACCT1_PK,
    },

    // =======================================================================
    // PHASE 5 — USER 2 WITHDRAWAL CYCLE  (ticks 200 → 232)
    // =======================================================================
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: onTick(200),
      privateKey: ACCT2_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: claimWindow(220, 230),
      privateKey: ACCT2_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(232),
      amount: aztec(300_000),
      privateKey: ACCT2_PK,
    },

    // =======================================================================
    // PHASE 6 — SECOND ROUND: Users 4 & 3  (ticks 260 → 342)
    // =======================================================================
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: onTick(260),
      privateKey: ACCT4_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: claimWindow(280, 290),
      privateKey: ACCT4_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(292),
      amount: aztec(100_000),
      privateKey: ACCT4_PK,
    },

    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: onTick(310),
      privateKey: ACCT3_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: claimWindow(330, 340),
      privateKey: ACCT3_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(342),
      amount: aztec(150_000),
      privateKey: ACCT3_PK,
    },

    // =======================================================================
    // PHASE 7 — SECOND ROUND: Users 1 & 2  (ticks 360 → 432)
    // =======================================================================
    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: onTick(360),
      privateKey: ACCT1_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: claimWindow(380, 390),
      privateKey: ACCT1_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(392),
      amount: aztec(500_000),
      privateKey: ACCT1_PK,
    },

    {
      type: "user-initiate-withdraw",
      enabled: true,
      shouldRun: onTick(400),
      privateKey: ACCT2_PK,
    },
    {
      type: "user-claim",
      enabled: true,
      shouldRun: claimWindow(420, 430),
      privateKey: ACCT2_PK,
    },
    {
      type: "user-deposit",
      enabled: true,
      shouldRun: onTick(432),
      amount: aztec(200_000),
      privateKey: ACCT2_PK,
    },
  ],
};

export default demoConfig;
