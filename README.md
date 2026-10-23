# Curveball Contracts — Audit Snapshot

This repository is a self-contained source snapshot prepared for external security review. It contains the current Solidity implementation, deployment wiring, mocks, and tests. Generated output, historical deployment broadcasts, local service state, and operator tooling are intentionally excluded.

## Scope

The in-scope production contracts are:

- `contracts/CurveLaunchpad.sol`
- `contracts/CurveToken.sol`
- `contracts/CurveFeeEscrow.sol`
- `contracts/CurveLpLocker.sol`
- `contracts/CurveHolderReserve.sol`
- `contracts/libraries/CurveMath.sol`
- `contracts/interfaces/ICurveLaunchpad.sol`
- `contracts/interfaces/ICurveSingletons.sol`
- `contracts/interfaces/IIcarus.sol`

The `scripts/CurveDeploy.sol` and `scripts/Deploy.s.sol` files are included because constructor ordering, address prediction, singleton wiring, network parameters, and authority preflight checks are security-relevant. Everything under `test/` is supporting test code rather than production scope.

## Documentation

The auditor documentation starts at [`docs/README.md`](docs/README.md):

- [`docs/architecture.md`](docs/architecture.md) — topology, state ownership, lifecycle, roles, and asset flows.
- [`docs/protocol-spec.md`](docs/protocol-spec.md) — normative formulas and contract behavior.
- [`docs/integration-spec.md`](docs/integration-spec.md) — Icarus/WETH assumptions, deployment, and fork configuration.
- [`docs/security-and-invariants.md`](docs/security-and-invariants.md) — security properties, adversarial cases, and test evidence.
- [`docs/glossary.md`](docs/glossary.md) — canonical domain terminology.

## Toolchain

- Solidity: `0.8.24`
- EVM target: Shanghai
- Optimizer: enabled, 200 runs
- Test/build framework: Foundry
- Dependencies: OpenZeppelin Contracts `5.1.0`, Solady `0.1.26`, and forge-std `v1.17.0`

Install dependencies and run the local suite:

```sh
pnpm install --frozen-lockfile
make test
make sizes
```

The local suite excludes fork tests and contains 138 unit, integration, fuzz, and invariant tests.

## Fork tests

Fork tests exercise the live WETH and Icarus integrations at pinned blocks. They fail closed when invoked through the Make targets without the required RPC URL:

```sh
RISE_MAINNET_RPC_URL=<url> make test-fork-strict
RISE_TESTNET_RPC_URL=<url> make test-fork-testnet
```

The relevant network configuration is encoded in `scripts/Deploy.s.sol` and `test/fork/Lifecycle.fork.t.sol`:

| Network | Chain ID | Icarus factory |
| --- | ---: | --- |
| RISE mainnet | 4153 | `0xEe10C6a0f158bFEeef3d48Dc0D26130Cf6115615` |
| RISE testnet | 11155931 | `0x8221dfB70c9A2dE60253dcfC58231FD529bbF4F9` |

Both configurations use WETH at `0x4200000000000000000000000000000000000006`.

## Architecture and trust assumptions

`CurveLaunchpad` creates fixed-supply `CurveToken` clones, runs their bonding curves, and graduates sold-out markets into external Icarus volatile pools. `CurveFeeEscrow` accounts for creator and protocol fees and executes bounded buybacks. `CurveLpLocker` permanently holds LP positions and routes claimed fees to the escrow. `CurveHolderReserve` distributes each market's reserved tokens pro rata after graduation.

The owner can update bounded defaults for future markets, unpause the launchpad, rotate the guardian, and rescue only surplus assets. The guardian can pause launches and buys. Mainnet deployment preflight requires the owner to be a timelock with a contract proposer and requires the guardian and treasury to be contracts. Icarus and WETH are external dependencies and are not implemented in this repository; the interfaces, mocks, and fork tests document and exercise the behavior Curveball assumes from them.

## Excluded material

Compiler output, dependency directories, fuzz corpora, coverage reports, historical broadcasts, deployment caches, logs, frontend/SDK synchronization scripts, production-recording utilities, and local hosting metadata are excluded because they are generated, stale, operational, or reproducible from the included sources.
