# Curveball auditor documentation

This directory describes the protocol implemented by the Solidity source in this repository. It is written for external reviewers and should be read together with the contracts and tests. If prose and code ever disagree, the Solidity implementation is authoritative.

## Reading order

1. [Architecture](architecture.md) — module topology, state ownership, lifecycle, trust model, and end-to-end flows.
2. [Protocol specification](protocol-spec.md) — constants, formulas, preconditions, state changes, events, and failure behavior.
3. [Integration specification](integration-spec.md) — Icarus, WETH/ERC-20, deployment wiring, chain configuration, and fork assumptions.
4. [Security properties and verification](security-and-invariants.md) — accounting invariants, pause and rescue constraints, adversarial cases, and test coverage.
5. [Glossary](glossary.md) — canonical terminology and symbols used across the documentation.

## Scope

Production scope consists of the five contracts in `contracts/`, the curve library, and the three interface files. `scripts/CurveDeploy.sol` and `scripts/Deploy.s.sol` are included because immutable wiring, constructor ordering, network parameters, and authority validation are security-relevant. Files under `test/` are supporting evidence rather than production code.

The external Icarus factory and pools, RISE WETH, OpenZeppelin, Solady, off-chain metadata content, frontends, keepers, and governance implementations are dependencies or deployment context; their implementations are not in scope here. The exact behavior Curveball requires from Icarus and WETH is specified in [Integration specification](integration-spec.md).

## Build profile

| Setting | Value |
| --- | --- |
| Solidity | `0.8.24` |
| EVM | Shanghai |
| Optimizer | enabled, 200 runs |
| Build/test system | Foundry |
| Package manager | pnpm, locked by `pnpm-lock.yaml` |

```sh
pnpm install --frozen-lockfile
make test
make sizes
```

Fork suites require `RISE_MAINNET_RPC_URL` or `RISE_TESTNET_RPC_URL`; see the integration specification for pinned blocks and commands.
