# Glossary

These terms are used consistently across the code and documentation.

| Term | Definition |
| --- | --- |
| **Aborted** | Sticky market state entered when a sold-out market remains ungraduated for seven days. Sells remain possible; buys remain possible while inventory exists and launchpad is unpaused; graduation remains available whenever the curve sells out again. |
| **Adapter** | A concrete implementation occupying an external seam. Icarus pools and RISE WETH are external adapters used through narrow interfaces. |
| **BPS** | Basis points with denominator 10,000. 100 bps = 1%. |
| **Buyback balance** | Quote-token fee credit assigned to a market for later permissionless swaps into its token and burn. It is included in escrow `totalOwed`. |
| **Creator** | Account that calls `launch`; receives the snapshotted creator fee share and all creator tax. |
| **Creator share** | Snapshotted fraction of `fee` credited to the creator. It does not apply to tax because all tax already belongs to the creator. |
| **Creator tax** | Per-market surcharge selected at launch within the current `taxCapBps`; credited entirely to the creator. |
| **Curve fee** | Fee rate assessed on curve buys and sells. Later LP fee amounts come from Icarus but use the market's same creator and buyback share percentages. Distinct from creator tax and launch fee. |
| **Curve inventory** | The 800,000-token portion of supply offered through the bonding curve. |
| **Curve supply (`C`)** | Fixed 800,000-token maximum sold by the curve and denominator for holder-reserve claims. |
| **Deep module** | A module that provides substantial behavior behind a relatively small interface. `CurveLaunchpad` is the primary coordinating deep module. |
| **Fee policy** | Creator, creator fee share, and buyback fee share snapshotted per market. The market also snapshots curve fee and tax. |
| **Graduated** | Terminal market state after the curve's quote and token inventory seed an Icarus pool, LP is locked, and remaining launchpad inventory is burned. |
| **Graduation target** | Intended real quote raised when all curve inventory sells, subject to curve-favorable integer rounding across trades. Snapshotted indirectly through the market's initial virtual quote. |
| **Guardian** | Address that can pause new launches and buys. It cannot unpause, change policy, rescue assets, or stop exit paths. |
| **Held ledger** | `held[token][account]`, tracking net curve purchases and sales. It freezes at graduation and determines holder-reserve entitlement; it is not current post-graduation ERC-20 ownership. |
| **Holder reserve** | Optional allocation minted directly to `CurveHolderReserve` at launch and paid pro rata after graduation. Maximum 40,000 tokens or 4% of total supply. |
| **Icarus** | External Aerodrome-style factory and volatile pools used for graduated liquidity, LP fee collection, swaps, and TWAP observations. |
| **Implementation** | Code behind a module's interface. `CurveToken` also uses “implementation” in the EIP-1167 sense: one deployed logic contract delegated to by all market-token clones. |
| **Interface** | Everything a caller must know to use a module correctly: callable functions plus invariants, ordering, errors, configuration, and external assumptions. |
| **Launch fee** | Immutable flat WETH payment sent directly to treasury on each launch; it does not enter the fee escrow. |
| **Locker** | `CurveLpLocker`, the ownerless singleton with no LP withdrawal interface that permanently holds graduation LP and forwards claimed fees. |
| **Market** | One launched token and its curve state, snapshotted policy, reserves, historical holdings, and eventual Icarus pool. |
| **Module** | A contract or library with an interface and implementation. Curveball's principal modules are launchpad, token, escrow, locker, reserve, and curve math. |
| **Non-curve supply** | `S − C = 200,000` tokens allocated among holder reserve, pool seed, and graduation burn. |
| **Pool seed** | WETH and market tokens transferred into the Icarus pool during graduation before LP is minted to the locker. |
| **Protocol share** | Residual fee amount credited to treasury after creator and buyback allocations, including division dust. |
| **Quote token** | ERC-20 used for curve reserves, fees, pool quote side, and buybacks. Configured as RISE WETH. |
| **Ready** | State reached when a `Trading` market sells all curve inventory. Trading closes while permissionless graduation becomes available. |
| **Real quote** | Actual WETH backing an ungraduated market's seller liability. It equals `virtualQuote − initialVirtualQuote` before graduation. |
| **Reserve module** | `CurveHolderReserve`, not to be confused with virtual curve reserves or Icarus pool reserves. |
| **Seam** | Location where a module's interface permits another implementation or external dependency. Icarus and WETH are the primary external seams. |
| **Singleton** | One directly deployed protocol-wide instance. Launchpad, escrow, locker, and holder reserve are singletons. |
| **Spot output** | Current pool output returned by `getAmountOut` after pool fee, used to validate buyback execution against TWAP. |
| **Total owed** | Escrow's aggregate liability per asset. For quote token it includes claims and every market's buyback balance. |
| **Total real quote** | Launchpad's aggregate WETH liability across all ungraduated markets. |
| **Trading** | Normal curve state in which buys and sells are allowed, subject to pause for buys. |
| **Treasury** | Immutable recipient of launch fees and protocol fee claims. It has no special control interface merely by being treasury. |
| **TWAP** | Icarus time-weighted average output. Buyback uses two 30-minute windows but requires more than three observations so it can exclude a possibly empty pre-graduation observation. |
| **Virtual reserves (`vT`, `vQ`)** | Accounting reserves driving the constant-product curve. Only `realQuote` represents actual seller-backing WETH. |
| **WETH** | RISE wrapped native asset at `0x4200000000000000000000000000000000000006`, used strictly as ERC-20 by production Curveball. |

## Symbols

| Symbol | Meaning |
| --- | --- |
| `S` | Total token supply, 1,000,000 tokens |
| `C` | Curve supply, 800,000 tokens |
| `vT` | Current virtual token reserve |
| `vQ` | Current virtual quote reserve |
| `vQ0` | Initial virtual quote reserve |
| `k` | Virtual constant product `vT × vQ` |
| `BPS` | 10,000 |
