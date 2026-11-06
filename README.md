# ProvableVault

A stablecoin vault for any app that pays users out of a pooled balance. Every payout is capped. Every result is provable.

It is for games, prediction markets, payroll, rewards and any backend that holds a pool of USDC or EURC and pays people from it. It is MIT licensed. Copy `src/ProvableVault.sol` into your project.

It powers [Strike](https://github.com/TryStrike/strike). The live Strike vault on Arc testnet is `0x8726144B6a122862B9F1184752d8ebA0AcD662B6`.

## Why use it

- A leaked hot key can move at most one day's cap, not the whole pool.
- Either key can pause. Only the cold key can resume.
- Each payout carries a `ref` of your choosing, so your ledger reconciles from events alone.
- Results are committed as a Merkle root that can never change. Anyone can check a result on chain.
- Payouts can go to another chain through Circle CCTP V2, with an exact approval for each burn.

## Overview

```
 users --transfer--> +-----------------+ <--- owner (cold key / multisig)
                     |  ProvableVault  |      setCap, setOperator, sweep, unpause,
 your backend        |                 |      transferOwnership
 (operator hot key)  |  caps per token |
   payout ---------> |  perTx, perDay  | --transfer--> winners
   payoutBatch ----> |                 |
   payoutCrossChain> |                 | --depositForBurn--> CCTP V2 --> other chain
   commitBatch ----> |  batchRoots[e]  |   (write-once Merkle root per epoch)
                     +-----------------+
 anyone: verifyLeaf(epoch, leaf, proof) -> true / false
 owner or operator: pause()        owner only: unpause()
```

Deposits are plain token transfers to the vault address. There is no deposit function and no approval step. Your backend credits users from the token `Transfer` log.

## Quick start

```sh
forge install foundry-rs/forge-std
forge build
forge test
```

To use it in your own project, copy `src/ProvableVault.sol` and deploy it.

## Reuse it

### Constructor

```solidity
constructor(address tokenMessenger_, address owner_, address operator_)
```

- `tokenMessenger_` is the CCTP V2 TokenMessenger on the chain you deploy to.
- `owner_` is the admin. It is a constructor argument and never the deployer, so a shared deploy wallet never owns the vault. Use a multisig or a cold key.
- `operator_` is the hot key your backend signs with.

All three must be non-zero. Owner and operator may be the same address in a test setup.

### Deploy

```sh
export OWNER=0xYourColdKeyOrMultisig
export OPERATOR=0xYourBackendHotKey
export TOKEN_MESSENGER=0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA   # optional, this is the Arc testnet default
forge script script/Deploy.s.sol --rpc-url $RPC_URL --account deployer --broadcast
```

The script holds no keys. Pass a keystore account, a ledger or a private key on the command line.

### Set caps

A token with no cap cannot be paid out. The owner sets caps per token, in the token's smallest unit. USDC and EURC use 6 decimals.

```sh
# 1,000 USDC per transaction, 10,000 USDC per UTC day
cast send $VAULT "setCap(address,uint128,uint128)" \
  0x3600000000000000000000000000000000000000 1000000000 10000000000 \
  --rpc-url $RPC_URL --account owner
```

Set the cap to zero to stop payouts of a token. Any ERC20 works, including tokens that return nothing from `transfer`.

### The operator pattern

Keep the owner key cold. Give your backend only the operator key. The operator can:

- `payout(token, to, amount, ref)` pay one address.
- `payoutBatch(token, to[], amounts[], refs[])` pay many in one transaction. The sum counts against the caps as one payout.
- `payoutCrossChain(token, mintRecipient, domain, amount, maxFee, minFinalityThreshold, ref)` pay on another chain.
- `commitBatch(epoch, root, count)` commit a result root.

The operator cannot change caps, sweep, or unpause. If the operator key leaks, the owner calls `setOperator` and the loss is bounded by one day's cap. Either key can call `pause()` at once.

Use `ref` for your own id, such as a withdrawal id or bet id. It is an indexed field of the `Payout` event.

### Cross-chain payouts

`payoutCrossChain` approves the TokenMessenger for exactly `amount`, then calls `depositForBurn`. The approval never stacks across payouts. It counts against the same caps. Use `minFinalityThreshold` 2000 for standard transfers and 1000 for fast transfers. Arc is CCTP domain 26.

`mintRecipient` is the destination address left-padded to 32 bytes.

### Commit results off chain, verify on chain

1. Each epoch (a day, a round range, a pay run), hash your results into leaves.
2. Build a sorted-pair Merkle tree. The operator calls `commitBatch(epoch, root, count)`. A root can be written once and never changed.
3. Give each user their leaf and proof. Anyone can call `verifyLeaf(epoch, leaf, proof)` and get `true` or `false`.

An epoch with no root always verifies `false`. A zero root is rejected.

Here is a TypeScript example with [viem](https://viem.sh). Each pair is hashed in sorted order, and an odd node is carried up unchanged.

```ts
import { concatHex, encodePacked, keccak256, type Hex } from "viem";

type Result = { id: Hex; user: Hex; amount: bigint };

// Include the epoch in the leaf. The preimage is 116 bytes, so it can never equal a 64 byte node.
const leafOf = (epoch: bigint, r: Result): Hex =>
  keccak256(
    encodePacked(["uint256", "bytes32", "address", "uint256"], [epoch, r.id, r.user, r.amount]),
  );

const pair = (a: Hex, b: Hex): Hex => keccak256(a < b ? concatHex([a, b]) : concatHex([b, a]));

function buildTree(leaves: Hex[]): Hex[][] {
  const levels = [leaves];
  while (levels[levels.length - 1].length > 1) {
    const prev = levels[levels.length - 1];
    const next: Hex[] = [];
    for (let i = 0; i < prev.length; i += 2) {
      next.push(i + 1 < prev.length ? pair(prev[i], prev[i + 1]) : prev[i]);
    }
    levels.push(next);
  }
  return levels;
}

function proofFor(levels: Hex[][], index: number): Hex[] {
  const proof: Hex[] = [];
  for (let l = 0; l < levels.length - 1; l++) {
    const sibling = index ^ 1;
    if (sibling < levels[l].length) proof.push(levels[l][sibling]);
    index >>= 1;
  }
  return proof;
}

// Operator: commit the root.
const epoch = 20260;
const leaves = results.map((r) => leafOf(BigInt(epoch), r));
const levels = buildTree(leaves);
const root = levels[levels.length - 1][0];
await walletClient.writeContract({ address: vault, abi, functionName: "commitBatch", args: [BigInt(epoch), root, BigInt(leaves.length)] });

// Anyone: check one result.
const ok = await publicClient.readContract({
  address: vault, abi, functionName: "verifyLeaf",
  args: [BigInt(epoch), leaves[3], proofFor(levels, 3)],
});
```

The same tree works in any language. Hash with keccak256, sort each pair of 32 byte values before hashing, and carry an odd node up.

## Public API

Operator:

```solidity
function payout(address token, address to, uint256 amount, bytes32 ref) external;
function payoutBatch(address token, address[] calldata to, uint256[] calldata amounts, bytes32[] calldata refs) external;
function payoutCrossChain(address token, bytes32 mintRecipient, uint32 domain, uint256 amount, uint256 maxFee, uint32 minFinalityThreshold, bytes32 ref) external;
function commitBatch(uint256 epoch, bytes32 root, uint256 count) external;
```

Owner:

```solidity
function setCap(address token, uint128 perTx, uint128 perDay) external;
function setOperator(address operator_) external;
function sweep(address token, address to, uint256 amount) external;
function unpause() external;
function transferOwnership(address newOwner) external;   // then newOwner calls acceptOwnership()
```

Owner or operator: `pause()`. Pending owner: `acceptOwnership()`.

Views: `verifyLeaf(epoch, leaf, proof)`, `remainingToday(token)`, `batchRoots(epoch)`, `caps(token)`, `spent(token)`, `owner()`, `operator()`, `pendingOwner()`, `paused()`, `tokenMessenger()`.

Events: `Payout`, `CrossChainPayout`, `BatchCommitted`, `Swept`, `CapSet`, `OperatorSet`, `Paused`, `Unpaused`, `OwnershipTransferStarted`, `OwnershipTransferred`.

## Arc testnet

| Item | Address |
| --- | --- |
| USDC | `0x3600000000000000000000000000000000000000` |
| EURC | `0x89B50855Aa3bE2F677cD6303Cec089B5F319D72a` |
| CCTP V2 TokenMessenger | `0x8FE6B999Dc680CcFDD5Bf7EB0974218be2542DAA` |
| CCTP domain | 26 |
| Strike vault (live) | `0x8726144B6a122862B9F1184752d8ebA0AcD662B6` |

## Security notes

- This is hackathon-grade code. It has a heavy test suite, but it has not been audited. Get an audit before it holds real money.
- The caps bound the damage of a leaked operator key. They do not stop the operator from paying the wrong person inside the cap. Keep caps low.
- Per-day caps use UTC days (`block.timestamp / 1 days`). The cap resets at midnight UTC, so a leaked key can move up to two days' caps across a day boundary in a short time.
- A payout books its spend before any external call. A token or messenger that calls back into the vault sees the spend already counted.
- The owner is a constructor argument and ownership moves in two steps, so a typo cannot hand the vault to a dead address.
- `sweep` is uncapped by design. Keep the owner on a multisig or hardware key.
- Merkle roots are write-once. A wrong root cannot be fixed, so commit the next epoch with a correct one and publish a note. Compute the tree off chain and check it with `verifyLeaf` before relying on it.
- Leaves must not be confusable with inner nodes. Include the epoch and use a leaf preimage longer than 64 bytes, as in the example.
- Tokens that charge fees on transfer or rebase are not supported. The vault pays the amount it is told and does not measure balances.
- `payoutCrossChain` passes the token to CCTP as the burn token. Only tokens CCTP can burn (USDC) will complete. Others revert at the messenger.
- The vault has no fallback and no deposit function. Native currency sent to it reverts.

## License

MIT. Copyright 2026 Strike contributors.
