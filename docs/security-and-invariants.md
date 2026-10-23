# Security properties and verification

This document collects the properties the implementation attempts to preserve and points to executable evidence. It is not an audit report and does not assert the absence of vulnerabilities.

## Security model

### Assets protected

- WETH backing every ungraduated curve.
- Creator and treasury fee claims.
- WETH reserved for future market-token buybacks.
- Unsold curve-token inventory.
- Reserved market tokens owed pro rata after graduation.
- Graduated pool LP principal.
- Correct market lifecycle and immutable per-market economic policy.

### Trusted authorities

- Launchpad and escrow start with the same configured owner but have independent two-step ownership thereafter. The launchpad owner can update future-market defaults, rotate guardian, unpause, and rescue launchpad surplus; the escrow owner can rescue escrow surplus. Mainnet deployment requires the initial shared owner to expose a nonzero timelock delay.
- The guardian can stop new launches and buys, but cannot stop exits or seize assets.
- The treasury is an immutable recipient rather than an active authority.
- The configured Icarus factory/pools and RISE WETH are external trust dependencies.

### Untrusted actors

Creators, traders, claimants, buyback callers, LP-fee callers, pool pre-creators, token/quote donors, and transaction-ordering adversaries are treated as untrusted. Permissionless functions must remain safe regardless of which account triggers them.

## Executable invariants

The stateful invariant harness targets 20 actions across launch, trading, donations, pool activity, claims, rescue, administration, and pauses. Its configuration runs 256 sequences to depth 64 and requires at least 20% of calls to reach meaningful action paths.

### 1. Launchpad curve backing

```text
totalRealQuote = Σ market.realQuote
WETH balance of launchpad = totalRealQuote + tracked surplus
```

Surplus includes donations and skimmed pool balances, net of authorized rescues. Evidence: `invariant_launchpadBacksEveryCurve`.

### 2. Global WETH conservation

Every unit of mock WETH minted remains accounted for among actors, treasury, rescue sink, Curveball singletons, pools, LP fee holders, and gauge fee holders. Evidence: `invariant_wethConserved`.

### 3. Curve accounting and inventory

For every market:

```text
sold = SUPPLY − virtualToken
sold <= CURVE_SUPPLY
```

Before graduation:

```text
realQuote = virtualQuote − initialVirtualQuote
pool == address(0)
launchpad token balance >= SUPPLY − reserveTokens − sold
```

After graduation, `realQuote == 0`, all launchpad inventory except explicit later donations has been seeded or burned, and the locker owns positive LP. Evidence: `invariant_curveAccounting`.

### 4. Escrow solvency

For every asset:

```text
escrow balance >= totalOwed
```

For WETH, `totalOwed` equals creator/treasury claimable balances plus all market buyback balances. For each market token, it equals creator/treasury token claims. Evidence: `invariant_escrowBacksEveryClaim`.

### 5. Historical held ledger

```text
Σ held[token][actor] = SUPPLY − market.virtualToken
```

Before graduation, each tracked actor's held amount bounds its transferable balance and no market tokens are present in a pre-created Icarus pool. Evidence: `invariant_heldLedgerMatchesSales`.

### 6. Holder reserve bound

```text
claimed <= reserveOf[token]
reserve token balance = reserveOf[token] − claimed
```

Evidence: `invariant_reserveClaimsBounded`.

### 7. Handler-enforced properties

The handler records a violation if observed behavior contradicts:

- permanent LP custody;
- allowed market state transitions;
- pause scope;
- token supply changes;
- expected trade, claim, buyback, and rescue effects.

`invariant_handlerSawNoViolation` requires the violation count to remain zero. Deterministic reachability tests separately ensure every action and rare path is executable, preventing a vacuous fuzz result.

## Additional designed properties

### Curve-favorable rounding

Both buy and sell formulas use ceiling division for the new opposing reserve. This keeps the post-trade virtual product at or above the pre-trade product. Fee and tax charges round down. When the realized fee is split, division remainder not assigned to creator or buyback accrues to the protocol share. Fuzz tests assert that round trips cannot profit and sells cannot exceed real reserves.

### No pre-graduation pool seeding by traders

Three controls combine:

1. Curve buys have no recipient parameter.
2. Bought tokens go only to the payer.
3. Before unlock, transfers are permitted only to or from launchpad.

This prevents ordinary holders from transferring market tokens into their future Icarus pool before the launchpad performs controlled graduation. Synced token contamination is still checked and rejected as defense in depth against behavior outside the normal holder interface or a compromised external dependency.

### Market policy immutability

Creator, fee rate, creator share, buyback share, tax, starting virtual quote, and reserve allocation are stored in the market at launch. Owner changes affect only future markets.

### Exit liveness under pause

The guardian pause blocks new exposure—launches and buys—but not sells. It also does not block graduation, abort after timeout, fee claims, reserve claims, or LP fee collection. Icarus swap pause blocks buyback execution but is deliberately not checked during graduation.

### Stuck-graduation escape

After seven days, a sold-out market can enter sticky `Aborted` state. Sells reopen and remain open permanently. If the market sells out again, anyone can retry graduation without first restoring `Ready`.

### Liability-limited rescue

- Launchpad owner cannot rescue WETH backing `totalRealQuote` or any ungraduated market token.
- Escrow owner cannot rescue any asset backing `totalOwed`.
- Locker LP has no withdrawal interface.
- Holder reserves have no rescue interface.

### Pull-based claims

Fee and reserve claims pay only `msg.sender`; no caller can redirect another account's entitlement. State is cleared or marked claimed before transfer.

### Ownership permanence

Launchpad and escrow use two-step ownership and both disable renunciation. Locker and reserve have no administrator. The contracts are not upgradeable.

## Reentrancy and external-call ordering

| Path | Protection and ordering |
| --- | --- |
| Launch, buy, sell, graduate | `nonReentrant`; accounting effects precede external transfers/calls; transaction rollback restores effects on failure |
| Escrow distribute, claim, buyback, rescue | `nonReentrant`; liabilities are verified or updated before transfers |
| Locker claim | No reentrancy guard; pool is a trusted dependency, registration is immutable, and forwarding must be backed before escrow credit |
| Reserve claim | No reentrancy guard; claim flag is set before transfer and the token is a known CurveToken clone |
| Token transfer hook | No external calls; enforces lock locally |

The absence of guards on locker and reserve is coupled to the trusted pool and token implementations. Replacing those dependencies with callback-capable malicious adapters is outside the configured security model.

## Adversarial and failure cases

| Scenario | Intended behavior | Evidence |
| --- | --- | --- |
| Final fill would have zero rounded fee | Allowed only for the complete final fill, preventing a wedged curve | CurveMath unit tests |
| Trader oversells | Checked `held` subtraction or quote-reserve validation reverts | Trade and math tests |
| Market remains sold out without graduation | Abort available after seven days; next sell aborts inline | Abort tests |
| Guardian pauses | Launch and buy revert; sell and lifecycle exits continue | Admin/trade/abort tests |
| Third party creates empty pool | Graduation reuses it | Graduation tests |
| Unsynced pool donation | Skimmed before seeding | Graduation/rescue tests |
| Synced WETH donation | Matched at closing price while buffer permits; excess raises opening quote-per-token price and is not recovered through graduation | Unit and fork graduation tests |
| Pool has existing LP | Graduation reverts `PoolUsed` | Graduation tests |
| Pool has synced market tokens | Graduation reverts `PoolUsed` | Graduation tests |
| Pool reserve update does not match intended seed | Graduation reverts `MintMismatch` | Enforced in production; mocked integration behavior tested |
| Stray transfer to LP locker | Not attributed because claims use pool return values | Locker tests |
| Fee credited without prior transfer | Escrow reverts `Unbacked` | Escrow tests |
| Buyback lacks observations | Returns zero and preserves interval/credit | Escrow tests |
| TWAP call fails | Returns zero and preserves interval/credit | Escrow tests |
| Icarus is paused | Buyback skips before WETH transfer; graduation still works | Unit and fork tests |
| Small spot movement | Buyback may execute within band | Escrow tests |
| Sandwich/large spot divergence | Buyback skips | Escrow tests |
| Buyback called inside interval | Reverts `TooSoon` | Escrow/integration tests |
| Reserve claimant transferred tokens after graduation | Entitlement remains with historical curve buyer | Integration tests |
| Owner tries to rescue liabilities | Reverts | Launchpad and escrow rescue tests |
| Deployment nonce prediction shifts | Entire deployment reverts | Deployment unit tests |
| Mainnet owner is an EOA | Deployment preflight rejects | Mainnet fork deployment test |

## Explicit non-properties and assumptions

Auditors should not infer the following guarantees:

- The deployment script does not attest WETH, Icarus, timelock, guardian, or treasury bytecode hashes.
- Icarus pool pair correctness, fee units, pause behavior, reserve reporting, observation math, and fee-return behavior are trusted external assumptions exercised by fork tests.
- WETH metadata and decimals are assumed rather than checked on-chain.
- Fee-on-transfer and rebasing assets are unsupported.
- A quote-side donation cannot wedge graduation, but an initialized pool or synced market-token contamination intentionally can.
- The locker assumes a registered pool's other token is WETH; it does not independently compare the address.
- `graduate` verifies exact post-mint reserves but does not inspect the `mint` return value or assert locker LP balance on-chain.
- Mainnet owner, guardian, treasury, proposer, graduation target, and deployed Curveball addresses are not present in this snapshot.
- Holder reserve rounding dust, unclaimed entitlements, and allocations for markets that never graduate have no recovery path.
- `previewBuy` and `previewSell` ignore pause and lifecycle state and are not execution guarantees.
- Unexpected external-call failures in buyback revert; only the four named readiness conditions are non-reverting skips.

## Test coverage map

| Area | Primary executable evidence |
| --- | --- |
| Constant-product formulas, rounding, drift, dust, split conservation | `test/unit/CurveMath.t.sol` |
| Clone initialization, lock, permit, burn, unlock | `test/unit/CurveToken.t.sol` |
| Launch, deterministic address, snapshots, metadata, reserve, first buy | `test/unit/Launchpad.Launch.t.sol` |
| Buy/sell accounting, deadlines, slippage, isolation, held ledger | `test/unit/Launchpad.Trade.t.sol` |
| Timeout, sticky abort, re-sellout, regraduation | `test/unit/Launchpad.Abort.t.sol` |
| Pool seeding, orientation, donations, used pools, size margin | `test/unit/Launchpad.Graduate.t.sol` |
| Bounds, roles, pause, two-step ownership | `test/unit/Launchpad.Admin.t.sol` |
| Surplus-only rescue | `test/unit/Launchpad.Rescue.t.sol` |
| Fee backing/split/claims, buyback TWAP/band/caps, escrow rescue | `test/unit/FeeEscrow.t.sol` |
| LP permanence, fee routing, stray balances | `test/unit/LpLocker.t.sol` |
| Reserve registration, pro-rata claims, dust bound | `test/unit/HolderReserve.t.sol` |
| Deployment prediction and immutable wiring | `test/unit/Deploy.t.sol` |
| Complete asset lifecycle | `test/integration/Lifecycle.t.sol` |
| Stateful multi-market properties | `test/invariant/Invariants.t.sol`, `test/invariant/Handler.sol` |
| Real WETH/Icarus lifecycle and donation/pause assumptions | `test/fork/Lifecycle.fork.t.sol` |
| Live-network deployment policy | `test/fork/Deploy.fork.t.sol` |

## Verification snapshot

The sanitized repository was installed from `pnpm-lock.yaml`, compiled from scratch, formatted, and tested during preparation:

- local unit/integration/fuzz/invariant suite: 138 passed, 0 failed;
- RISE mainnet fork suite: 4 passed, 0 failed;
- RISE testnet fork suite: 4 passed, 0 failed;
- production contract-size build: passed, with every runtime below the EIP-170 limit.

Fork results establish compatibility with the configured external contracts at the pinned states. They do not prove that external bytecode or state cannot later change.

## Auditor review hotspots

The highest-value manual review paths are:

1. Curve rounding and sellout behavior across many partial trades.
2. Graduation against adversarial pre-created pool state and token orientation.
3. Escrow liability conservation across quote and market-token fee assets.
4. Buyback TWAP/spot comparison, pool-fee adjustment, and transfer-before-swap ordering.
5. Historical `held` accounting versus reserve distribution after transfers.
6. Immutable deployment address prediction and authority preflight assumptions.
7. External Icarus pair correctness and the locker/launchpad reliance on it.
