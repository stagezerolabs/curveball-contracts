.PHONY: build test sizes require-fork-tests test-fork test-fork-strict test-fork-testnet

build:
	forge build

test:
	forge test --threads 1 --no-match-path 'test/fork/*'

sizes:
	forge build --sizes

require-fork-tests:
	@ls test/fork/*.t.sol >/dev/null 2>&1 || { echo "No fork tests found in test/fork/."; exit 2; }

test-fork-strict: require-fork-tests
	@test -n "$(RISE_MAINNET_RPC_URL)" || { echo "RISE_MAINNET_RPC_URL is required for strict fork tests."; exit 2; }
	CI_FORK=1 forge test --match-path 'test/fork/*' --match-contract MainnetFork

test-fork-testnet: require-fork-tests
	@test -n "$(RISE_TESTNET_RPC_URL)" || { echo "RISE_TESTNET_RPC_URL is required for strict fork tests."; exit 2; }
	CI_FORK=1 forge test --match-path 'test/fork/*' --match-contract TestnetFork

test-fork: test-fork-strict test-fork-testnet
