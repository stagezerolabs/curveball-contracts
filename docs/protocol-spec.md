# Protocol specification

This document specifies the observable behavior of the current contracts. “Must,” “may,” and “reverts” describe the implementation in this repository, not intended future behavior.

## Conventions

- `BPS = 10,000`.
- Token and quote amounts are integer base units. Production parameters use `ether` units because RISE WETH and the launched tokens use 18 decimals, and the launchpad constructor rejects any quote token whose `decimals()` is not 18.
- `S` is total token supply, `C` is curve supply, `vT` and `vQ` are virtual token and quote reserves, and `k = vT × vQ`.
- Integer division rounds down unless `ceil` or `ceilDiv` is stated.
- Transfers use `SafeERC20` except for internal mint/burn operations.
- Every transaction is atomic: any downstream revert restores earlier state changes and transfers.

## Protocol constants

| Constant | Value | Meaning |
| --- | ---: | --- |
| `SUPPLY` (`S`) | 1,000,000 tokens | Supply minted by every market token |
| `CURVE_SUPPLY` (`C`) | 800,000 tokens | Maximum inventory sold through the curve |
| Non-curve supply | 200,000 tokens | Inventory available for holder reserve, pool seed, and graduation burn |
| `MAX_RESERVE_TOKENS` | 40,000 tokens | `(S − C)² / S` |
| `MAX_RESERVE_BPS` | 400 bps | 4% of total supply |
| `MAX_FEE_BPS` | 200 bps | Maximum curve trading fee |
| `MAX_TAX_BPS` | 50 bps | Maximum creator tax cap |
| `MAX_LAUNCH_FEE` | 0.01 quote token | Constructor bound; deployed value is immutable |
| `MIN_TARGET` | 0.01 quote token | Minimum configurable graduation target |
| `GRADUATION_TIMEOUT` | 7 days | Delay before a `Ready` market can abort |
| Name length | 1–64 bytes | Enforced by token initialization |
| Symbol length | 1–12 bytes | Enforced by token initialization |
| URI length | 1–2,048 bytes | Enforced by launchpad; URI is event-only |
| `BUYBACK_INTERVAL` | 1 hour | Minimum time between successful buybacks per market |
| `BUYBACK_CHUNK_BPS` | 2,500 bps | Nominal 25% of remaining buyback credit |
| `BUYBACK_MAX_IMPACT_BPS` | 25 bps | Input cap of 0.25% of pool quote reserves |
| `BUYBACK_SLIPPAGE_BPS` | 100 bps | 1% tolerance below fee-adjusted TWAP |
| `TWAP_WINDOWS` | 2 | Two 30-minute Icarus observation windows |

Deployment defaults are separate from hard bounds:

| Default | Value |
| --- | ---: |
| Launch fee | 0.001 WETH |
| Curve fee | 75 bps |
| Creator share of curve fee | 5,000 bps (50%) |
| Buyback share of curve fee | 2,500 bps (25%) |
| Creator-tax cap | 50 bps |
| Testnet graduation target | 0.01 WETH |
| Mainnet graduation target | Supplied through `CURVE_GRADUATION_TARGET`; not present in this snapshot |

## Market data model

Each token maps to one `Market`:

| Field | Meaning |
| --- | --- |
| `creator` | Launch caller and recipient of creator fee/tax credits |
| `feeBps` | Snapshotted fee rate charged on curve buys and sells |
| `creatorShareBps` | Snapshotted creator share of `fee` |
| `buybackShareBps` | Snapshotted buyback share of `fee` |
| `taxBps` | Creator-selected tax, bounded by the launch-time cap |
| `state` | `None`, `Trading`, `Ready`, `Graduated`, or `Aborted` |
| `virtualToken` | Current virtual token reserve |
| `virtualQuote` | Current virtual quote reserve |
| `initialVirtualQuote` | Launch-time virtual quote reserve |
| `realQuote` | Quote owed to this ungraduated curve |
| `reserveTokens` | Supply minted to `CurveHolderReserve` |
| `readyAt` | Timestamp of first sellout from `Trading` |
| `pool` | Graduated Icarus pool, otherwise zero |

Before graduation:

```text
sold = S − virtualToken
0 <= sold <= C
realQuote = virtualQuote − initialVirtualQuote
```

`held[token][account]` records net tokens bought from and sold back to the curve. It is not a transferable claim token and is not updated by post-graduation ERC-20 transfers.

## Curve math

### Starting virtual quote

For a requested graduation target:

```text
vQ0 = target × (S − C) / C
```

The multiplication must divide exactly by `C`; `target` must be nonzero; and `vQ0 + target` must fit `uint128`. With the fixed supplies, `vQ0 = target / 4`, so valid targets must satisfy the exact integer ratio. `CurveLaunchpad` additionally requires `target >= MIN_TARGET`.

### Buy quote

Inputs are current `vT`, `vQ`, available curve inventory `remaining`, maximum all-in spend, fee rate, and tax rate.

```text
budget = floor(maxSpend × BPS / (BPS + feeBps + taxBps))
candidateTokens = vT − ceil(k / (vQ + budget))
```

If `candidateTokens <= remaining`:

```text
tokensOut = candidateTokens
curveQuote = budget
```

Otherwise the final fill clamps to remaining inventory:

```text
tokensOut = remaining
curveQuote = ceil(k / (vT − remaining)) − vQ
```

Then:

```text
fee = floor(curveQuote × feeBps / BPS)
tax = floor(curveQuote × taxBps / BPS)
spent = curveQuote + fee + tax
```

Rules:

- `maxSpend` must be nonzero and at most `uint128.max`.
- `remaining` must be nonzero.
- `tokensOut` must be nonzero.
- The resulting all-in `spent` never exceeds `maxSpend`.
- If `feeBps` is nonzero and `fee` rounds to zero, the buy reverts as dust, except when it fills the entire remaining inventory.
- The final-fill exemption prevents an unfillable dust remainder immediately below sellout.
- Rounding preserves or increases the virtual constant product; it never advantages a round trip against the curve.

### Sell quote

```text
gross = vQ − ceil(k / (vT + amount))
fee = floor(gross × feeBps / BPS)
tax = floor(gross × taxBps / BPS)
net = gross − fee − tax
```

Rules:

- `amount` and `gross` must be nonzero.
- `gross` may not exceed the market's `realQuote`.
- A nonzero fee rate whose fee rounds to zero causes `DustTrade`.
- Selling more than the caller's `held` amount fails through checked arithmetic before tokens are transferred.

### Pool-seed token amount

At a virtual-reserve spot price:

```text
tokensFor(quoteAmount) = floor(quoteAmount × vT / vQ)
```

At exact sellout with no rounding drift, `vT = 200,000`, `vQ = 1.25 × target`, and `realQuote = target`, producing an ideal 160,000-token pool seed. The 40,000-token reserve cap leaves at least this amount from the 200,000 non-curve supply.

### Fee split

```text
creator = floor(fee × creatorShareBps / BPS) + tax
buyback = floor(fee × buybackShareBps / BPS)
protocol = fee + tax − creator − buyback
```

The creator receives all tax. Division remainder accrues to the protocol. The creator and buyback shares may sum to at most 100%.

## `CurveLaunchpad` specification

### Construction

The constructor requires nonzero treasury, quote token, Icarus factory, escrow, locker, reserve, and guardian addresses; inherited ownership construction governs the owner address. Launch fee must not exceed 0.01 quote token. Fee defaults and graduation target must pass the bounds below.

Construction stores all dependency addresses and launch fee immutably, deploys and seals one `CurveToken` implementation, sets guardian/defaults/target, and emits their update events.

### `launch(meta, taxBps, reserveBps, maxSpend, minOut)`

Availability: permissionless, nonreentrant, and blocked while paused.

Preconditions:

- URI byte length is 1–2,048.
- Token name and symbol later pass token initialization bounds.
- `taxBps <= current feeDefaults.taxCapBps`.
- `SUPPLY × reserveBps / BPS <= MAX_RESERVE_TOKENS`.
- If `maxSpend == 0`, `minOut` must also be zero.
- Caller has approved the immutable launch fee and any optional first-buy WETH.

Effects:

1. Uses and increments the caller's launch nonce to deploy a deterministic clone.
2. Snapshots creator and current economic policy in a `Trading` market with `vT = S`, `vQ = initialVirtualQuote`, and zero real quote.
3. Transfers immutable launch fee directly to treasury.
4. Initializes the clone and mints reserve allocation to the reserve module and the remainder to launchpad.
5. Registers nonzero reserve after backing exists.
6. Emits `LaunchCreated`, including metadata URI.
7. If `maxSpend != 0`, executes `_buy` for the launch caller and returns its output.

All effects revert atomically if any later step fails.

### `predictToken(creator)`

Returns the deterministic address for `creator` at its current `launchNonce`. A successful launch consumes that nonce; a reverted launch does not.

### `buy(token, maxSpend, minOut, deadline)`

Availability: permissionless, nonreentrant, blocked while paused, allowed only in `Trading` or `Aborted`.

- Reverts when `block.timestamp > deadline`; equality is valid.
- Computes the buy as specified above and requires `tokensOut >= minOut`.
- Updates reserves and liabilities before transfers.
- Transfers curve quote to launchpad and fee/tax directly to escrow, then records the split.
- Transfers market tokens only to `msg.sender` and increments only that account's `held` ledger.
- When the last curve token sells from `Trading`, changes state to `Ready`, records `readyAt`, and emits `GraduationReady`.
- When the last curve token sells from `Aborted`, emits `GraduationReady` but preserves `Aborted`.
- Emits `Trade` with all-in `spent`, token output, fee, tax, and post-trade virtual reserves.

### `sell(token, amount, minOut, deadline)`

Availability: permissionless to a token holder, nonreentrant, and not blocked by pause.

- Reverts when `block.timestamp > deadline`; equality is valid.
- If state is `Ready` and the seven-day timeout has elapsed, first changes state to `Aborted` and emits `GraduationAborted`.
- Proceeds only in `Trading` or `Aborted`.
- Requires quoted `net >= minOut` and sufficient `held` amount, token allowance, and curve quote reserve.
- Decreases `held`, increases `vT`, decreases `vQ`, and decreases both real-quote liabilities by gross output.
- Pulls tokens to launchpad, sends net quote to seller, and transfers fee/tax to escrow before distribution.
- Emits `Trade` with net quote received, token input, fee, tax, and post-trade reserves.

### `previewBuy` and `previewSell`

These views run current curve math but deliberately ignore market state and pause. Math-level errors and checked-arithmetic errors may still revert; they are quotations, not guarantees that the corresponding state-changing call is currently allowed.

### Launchpad views

- `market(token)` returns the complete stored `Market` value.
- `predictToken(creator)` returns the creator's next deterministic clone address.
- `curveSupply()` returns the fixed 800,000-token reserve-claim denominator.
- `feePolicy(token)` returns the market's creator, creator share, and buyback share for escrow accounting.
- `poolOf(token)` returns the registered graduated pool or zero before graduation.
- Public getters expose immutable dependencies/configuration, current defaults, guardian/pause state, aggregate liabilities, per-creator nonce, and per-account `held` values.

### `graduate(token)`

Availability: permissionless and nonreentrant; not blocked by launchpad or Icarus pause.

Precondition: market is `Ready`, or is `Aborted` with exactly all `C` curve tokens sold.

Effects and checks, in order:

1. Set state to `Graduated`, clear market `realQuote`, and subtract it from `totalRealQuote`.
2. Permanently unlock the token.
3. Discover or create the canonical volatile Icarus pool. Reject an existing pool with nonzero LP supply.
4. Record pool and call `skim(launchpad)` to remove unsynced balances.
5. Read reserves by orientation and reject nonzero synced market-token reserve.
6. Define `quoteInPool = realQuote + syncedQuoteReserve`.
7. Define:

   ```text
   tokensToPool = min(
       floor(quoteInPool × vT / vQ),
       S − C − reserveTokens,
       launchpad token balance
   )
   ```

8. Transfer only `realQuote` WETH—the existing synced quote remains in the pool—and transfer `tokensToPool`.
9. Mint LP directly to the locker.
10. Re-read reserves and require exact equality with `tokensToPool` and `quoteInPool`; otherwise `MintMismatch`.
11. Record the pool's current observation count in the escrow (`markGraduated`) as the buyback TWAP zero point.
12. Burn the launchpad's entire remaining market-token balance.
13. Register token/pool with the locker and emit `Graduated`.

Unsynced WETH is skimmed to launchpad surplus. Synced WETH is matched at the closing price while inventory permits; excess beyond the available token buffer raises the pool's opening quote-per-token price and is not recovered through graduation. Existing LP or synced market-token reserve is rejected.

Production ignores the return value from `pool.mint`. It verifies exact token/quote reserves afterward but does not independently assert nonzero LP output or query the locker LP balance; those Icarus semantics are integration assumptions exercised by fork tests.

### `abortGraduation(token)`

Permissionless and nonreentrant. Requires `Ready` and `block.timestamp >= readyAt + 7 days`. Sets `Aborted` and emits `GraduationAborted`. It does not alter reserves or liabilities.

### Administrative calls

- `setFeeDefaults`: owner-only. Requires `feeBps <= 200`, `taxCapBps <= 50`, and `creatorShareBps + buybackShareBps <= 10,000`. Affects future markets only.
- `setGraduationTarget`: owner-only. Requires at least 0.01 quote token and valid exact initial-reserve arithmetic. Affects future markets only.
- `setGuardian`: owner-only and nonzero.
- `pause`: guardian-only. Sets `paused = true`; it does not stop exit/liveness paths.
- `unpause`: owner-only. Sets `paused = false`.
- `renounceOwnership`: always reverts.
- Ownership transfer follows OpenZeppelin `Ownable2Step`.

### Launchpad rescue

Owner-only and nonreentrant:

- Quote token: amount may not exceed `balanceOf(launchpad) − totalRealQuote`.
- A known market token: rescuable only after `Graduated`.
- Unrelated assets: rescuable.

The function emits `Rescued`; transfer behavior remains subject to the asset contract.

## `CurveToken` specification

- The implementation constructor binds immutable `launchpad = msg.sender` and seals implementation storage.
- A clone may initialize exactly once, only through the bound launchpad.
- Initialization validates name and symbol byte lengths and mints exactly `supply`: `reserveAmount` to the reserve recipient and the remainder to launchpad.
- Before unlock, only minting and transfers with the launchpad as sender or recipient are allowed. Holder-to-holder transfers, holder burns, reserve transfers, and allowance/permit-based transfers between non-launchpad addresses revert `Locked`.
- `unlock` is launchpad-only and irreversible.
- After unlock, standard transfers and holder burns are enabled.
- Permit2 automatic infinite allowance is disabled.
- Solady derives the permit domain per clone from its address and name.

## `CurveFeeEscrow` specification

### Liability model

```text
totalOwed[quoteToken]
    = sum of creator quote claims
    + sum of treasury quote claims
    + sum of every market buybackBalance

totalOwed[marketToken]
    = creator token claims + treasury token claims
```

Every recorded credit must already be backed by the escrow's balance.

### `distribute(token, asset, fee, tax)`

- Caller must be launchpad or the immutable locker address returned by `launchpad.locker()`.
- Asset must be the immutable quote token or `token` itself.
- Escrow balance must cover previous `totalOwed[asset] + fee + tax`.
- Uses the market's snapshotted creator and fee shares.
- Creator and treasury shares become pull claims.
- For quote asset, all `fee + tax` enters `totalOwed` and the buyback share enters `buybackBalance[token]`.
- For market-token asset, only creator and protocol shares enter `totalOwed`; the buyback share burns immediately.
- Emits `FeeAccrued`.

### `claim(asset)`

Permissionless for the caller's own credit. Returns zero without an event if nothing is owed. Otherwise clears the caller's credit, decreases `totalOwed`, transfers the asset, and emits `FeeClaimed`.

### `buyback(token)`

Permissionless and nonreentrant.

Misuse conditions revert:

- no graduated pool: `NotGraduated`;
- prior successful buyback less than one hour ago: `TooSoon`;
- no buyback credit: `NothingToBuy`.

Environmental readiness is handled as a non-reverting skip:

1. Call pool `sync`.
2. Require that both windows the TWAP call will sample were recorded after this market's
   graduation, using the observation count stored by `markGraduated`; otherwise `FewObservations`.
   Icarus appends observations and never rewrites history, so `observationLength − 1 − TWAP_WINDOWS`
   (the earliest sampled observation) must be at least the graduation count. This keeps zeroed
   observations that can accumulate in a pre-created, pre-synced empty pool out of every TWAP
   sample. A market never marked by the launchpad fails closed.
3. Compute nominal input as 25% of balance, or all of it if that rounds to zero.
4. Cap input to 0.25% of the orientation-correct quote reserve.
5. Request two-window fee-free TWAP output; catch failure as `QuoteFailed`. Output zero also skips
   as `FewObservations`: an empty reference is never a price to buy against.
6. If factory is paused, skip as `PoolPaused` before transferring quote.
7. Compute:

   ```text
   minOut = floor(twapOut × (BPS − poolFeeBps) / BPS)
   minOut = floor(minOut × (BPS − 100) / BPS)
   ```

8. Get current fee-adjusted spot output. Zero or output below `minOut` skips as `Slippage`.

On success, set `lastBuyback`, reduce market buyback credit and quote liability, transfer quote to the pool, request the orientation-correct token output, measure the actual token balance increase, burn it, and emit `BuybackBurned`.

Skip paths emit `BuybackSkipped`, return zero, preserve credit, and do not advance the interval. Only TWAP `quote` is caught; failures in `sync`, orientation/reserve reads, fee lookup, spot quote, transfers, or swap revert atomically.

### Escrow rescue and ownership

The owner may rescue only `balance − totalOwed` for an asset. The function is nonreentrant and emits `Rescued`. Ownership is two-step and cannot be renounced.

## `CurveLpLocker` specification

- Constructor fixes launchpad and escrow forever.
- Only launchpad may register a pool; each pool may be registered once.
- No function can withdraw or transfer LP principal.
- Anyone may call `claim(pool)` for a registered pool.
- The locker calls `claimFees`, interprets returned amounts by `token0` orientation, and treats the other asset as quote.
- Each nonzero returned amount is transferred to escrow before `distribute(token, asset, amount, 0)`.
- Stray asset balances are not credited because accounting uses returned amounts rather than balance differences.
- Emits `PoolRegistered` and `LpFeesClaimed`.

Correct asset attribution relies on the trusted factory returning the canonical token/quote pool; the locker does not independently compare the other token with launchpad's configured quote token.

## `CurveHolderReserve` specification

- Constructor fixes launchpad forever; there is no owner.
- Only launchpad may register a reserve.
- Registration amount must be nonzero, not previously registered, and already backed by token balance.
- `claimable` returns zero before graduation or after the account claimed.
- After graduation:

  ```text
  claimable = floor(reserveOf[token] × launchpad.held(token, account) / C)
  ```

- `claim` is for `msg.sender`, once, and rejects zero entitlement.
- Claim status is set before transfer.
- Round-down dust, unclaimed balances, and never-graduated market reserves have no rescue path and remain in the module by design.

## State and pause matrix

| Operation | Trading | Ready | Aborted | Graduated | Blocked by launchpad pause? |
| --- | ---: | ---: | ---: | ---: | ---: |
| Launch new market | n/a | n/a | n/a | n/a | Yes |
| Buy | Yes | No | Yes, if inventory exists | No | Yes |
| Sell | Yes | No before timeout; aborts and sells after timeout | Yes | No | No |
| Explicit abort | No | After timeout | No | No | No |
| Graduate | No | Yes | Only at sellout | No | No |
| LP fee claim | n/a | n/a | n/a | Yes | No |
| Fee claim | Any accrued balance | Any accrued balance | Any accrued balance | Any accrued balance | No |
| Buyback | No pool | No pool | No pool | Yes | No; Icarus pause causes skip |
| Reserve claim | No | No | No | Yes | No |

## Custom events

| Module | Events |
| --- | --- |
| Launchpad | `LaunchCreated`, `Trade`, `GraduationReady`, `GraduationAborted`, `Graduated`, `FeeDefaultsUpdated`, `GraduationTargetUpdated`, `GuardianUpdated`, `Rescued`, `Paused`, `Unpaused` |
| Token | `Unlocked` plus inherited ERC-20 events |
| Escrow | `FeeAccrued`, `FeeClaimed`, `BuybackBurned`, `BuybackSkipped`, `Rescued` |
| Locker | `PoolRegistered`, `LpFeesClaimed` |
| Reserve | `ReserveRegistered`, `ReserveClaimed` |

`Trade.quoteAmount` is all-in spend for a buy and net receipt for a sell. The URI is not stored in contract storage; it is emitted in `LaunchCreated` and also remains visible in launch transaction calldata.

## Custom errors

| Module | Errors |
| --- | --- |
| Launchpad | `InvalidConfig`, `InvalidLaunch`, `NotTrading`, `Slippage`, `Expired`, `NotReady`, `NotAbortable`, `PoolUsed`, `MintMismatch`, `NotGuardian`, `EnforcedPause`, `RenounceDisabled`, `NotRescuable` |
| Curve math | `InvalidTarget`, `InvalidAmount`, `SoldOut`, `ZeroOutput`, `DustTrade`, `InsufficientReserve` |
| Token | `NotLaunchpad`, `AlreadyInitialized`, `InvalidMetadata`, `Locked` |
| Escrow | `Unauthorized`, `InvalidAsset`, `Unbacked`, `NotGraduated`, `TooSoon`, `NothingToBuy`, `ExceedsSurplus`, `RenounceDisabled` |
| Locker | `NotLaunchpad`, `AlreadyRegistered`, `UnregisteredPool` |
| Reserve | `NotLaunchpad`, `InvalidAmount`, `AlreadyRegistered`, `Unbacked`, `NotGraduated`, `AlreadyClaimed`, `NothingToClaim` |
| Deployment | `AddressPredictionMismatch`, `WiringMismatch`, `UnsupportedChain`, `Preflight` |

Inherited OpenZeppelin, Solady, `SafeERC20`, arithmetic-panic, and external dependency reverts remain possible and are not replaced with protocol-specific errors.
