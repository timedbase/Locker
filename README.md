# 1CoinLocker

EVM smart contract for locking ERC-20 tokens (including LP tokens and fee-on-transfer tokens) with a flat native-token fee on every **create** and **withdraw** operation, priced dynamically at $1 USD via an embedded Uniswap V2 TWAP.

## Features

- **Any ERC-20** — LP tokens, fee-on-transfer tokens, governance tokens, anything
- **Cliff or linear vesting** — chosen per lock at creation
- **$1 USD native fee** — charged on both `createLock` and `withdraw`, priced via an embedded 30-minute fixed-window TWAP; falls back to a static fee before the first window completes
- **Embedded TWAP** — every `createLock` / `withdraw` silently refreshes the price if the 30-minute window has elapsed; no keeper or external call needed
- **Top up** — add more tokens to a lock via `editLock`
- **Extend** — push the unlock date further out via `extendLock` or `editLock`
- **Transfer** — assign a lock to a new wallet via `transferLock`
- **Renounce** — permanently lock tokens forever (irreversible) via `renounceLock`
- **Description** — optional label on each lock, updatable via `editLockDescription`
- **LP detection** — on-chain factory cross-check (`factory().getPair(t0,t1) == token`), works with any Uniswap V2 fork
- **Fee-on-transfer** — locked amount is always the balance delta actually received
- **Query layer** — `EnumerableSet` indexes: per-user LP / normal sets, per-token lock sets, cumulative locked amounts, paginated views

## Contracts

| File | Description |
|---|---|
| `contracts/OneCoinLocker.sol` | Main contract with embedded TWAP |

## Getting Started

```bash
npm install
npx hardhat compile
```

## Deploy

```bash
npx hardhat run scripts/deploy.js --network <network>
```

Edit `scripts/deploy.js` before deploying. The relevant parameters:

| Parameter | Description |
|---|---|
| `fee` | Static fallback fee in wei, used before the first TWAP window completes |
| `pair` | Uniswap V2 WETH/USD pair address. Set to `address(0)` to use static fee only |
| `weth` | Native token wrapper in the pair (WETH / WBNB / WMATIC …) |
| `usd` | USD stablecoin in the pair (USDC / USDT / DAI …) |
| `usdDecimals` | Decimals of the stablecoin (e.g. `6` for USDC/USDT, `18` for DAI) |

---

## Embedded TWAP

The fee oracle is baked directly into `OneCoinLocker`. There is no separate oracle contract to deploy or maintain.

**How it works:**

1. The contract is deployed with an immutable Uniswap V2 WETH/USD pair address.
2. `TWAP_PERIOD = 30 minutes`. On every `createLock` and `withdraw`, the contract calls `_tryUpdateTwap()` internally.
3. If ≥ 30 minutes have elapsed since the last window, the TWAP advances and `TwapUpdated` is emitted.
4. If the period has not elapsed, the last computed price is reused — the call never reverts due to the TWAP.
5. Before the first window completes (or if no pair is configured), the static `fee` is used instead.
6. Excess native token is always refunded.

**Price math** (UQ112x112 fixed-point, matching Uniswap V2):

```
priceAvg = Σ(UQ112x112(reserveY / reserveX) × dt) / totalTime
fee      = priceAvg × oneUSD >> 112          // oneUSD = 10^usdDecimals
```

---

## Contract Interface

### `createLock`

```solidity
function createLock(
    address token,    // ERC-20 to lock (LP tokens and fee-on-transfer supported)
    uint256 amount,   // amount to deposit (must be pre-approved)
    uint256 endTime,  // cliff date or vesting end (unix timestamp, must be future)
    LockType lockType // 0 = Cliff, 1 = Linear
) external payable returns (uint256 lockId)
```

`msg.value` must be `>= currentFee()`. Any excess is refunded. The stored lock amount is the balance delta actually received. LP status is auto-detected via on-chain factory verification.

### `withdraw`

```solidity
function withdraw(uint256 lockId) external payable
```

Claims all currently unlocked tokens. `msg.value` must be `>= currentFee()`. 100 % of the gross claimable amount is sent to the caller; no token fee is deducted. For linear locks, partial claims accumulate — call again as more vests.

### `editLock`

```solidity
function editLock(
    uint256 lockId,
    uint256 additionalAmount, // extra tokens to deposit (0 = skip)
    uint256 newEndTime        // new end timestamp, must be later (0 = skip)
) external
```

Top up the locked amount and/or extend the end date in one call. Cannot be called after any withdrawal has been made. Free (no native fee).

### `extendLock`

```solidity
function extendLock(uint256 lockId, uint256 newEndTime) external
```

Pushes the unlock / vesting-end date further out. `newEndTime` must be strictly later than the current end. Free.

### `editLockDescription`

```solidity
function editLockDescription(uint256 lockId, string calldata description) external
```

Set or update the text label on a lock. Free.

### `transferLock`

```solidity
function transferLock(uint256 lockId, address newOwner) external
```

Transfers all rights (withdraw, edit, extend, renounce) to `newOwner`. Free. The previous owner can no longer interact with the lock.

### `renounceLock`

```solidity
function renounceLock(uint256 lockId) external
```

Sets `owner = address(0)`. **Irreversible.** The tokens are locked forever — no one can withdraw, edit, extend, or transfer. Useful for proving liquidity commitment.

---

## Views

### Fee

```solidity
function currentFee() external view returns (uint256)
```

Returns the current fee in wei for one create or withdraw operation. Uses the last computed TWAP price if available; otherwise returns the static fallback `fee`.

### TWAP state

```solidity
address public immutable twapPair        // Uniswap V2 pair used for pricing
address public immutable twapWeth        // Native token wrapper
address public immutable twapUsd         // USD stablecoin
uint8   public immutable twapUsdDecimals // Stablecoin decimals
uint256 public constant  TWAP_PERIOD     // 30 minutes
uint256 public twapPrice0Avg             // Last computed UQ112x112 price (token1/token0)
uint256 public twapPrice1Avg             // Last computed UQ112x112 price (token0/token1)
uint256 public twapLastUpdated           // block.timestamp of last completed window
```

### Individual locks

```solidity
function claimable(uint256 lockId) external view returns (uint256)
function getLock(uint256 lockId) external view returns (Lock memory)
function getLockById(uint256 lockId) external view returns (Lock memory)  // alias
function getTotalLockCount() external view returns (uint256)
function isLPToken(address token) external view returns (bool)
```

### Per-user

```solidity
function getUserLockIds(address user) external view returns (uint256[] memory)
// All-time history including transferred-away locks; filter by locks[id].owner == user off-chain

function lpLockCountForUser(address user) external view returns (uint256)
function normalLockCountForUser(address user) external view returns (uint256)
function totalLockCountForUser(address user) external view returns (uint256)

function lpLocksForUser(address user) external view returns (Lock[] memory)
function normalLocksForUser(address user) external view returns (Lock[] memory)
function lpLockForUserAtIndex(address user, uint256 index) external view returns (Lock memory)
function normalLockForUserAtIndex(address user, uint256 index) external view returns (Lock memory)
```

### Per-token

```solidity
function totalLockCountForToken(address token) external view returns (uint256)
function getLocksForToken(address token, uint256 start, uint256 end) external view returns (Lock[] memory)
```

### Global stats

```solidity
function allLpTokenLockedCount() external view returns (uint256)
function allNormalTokenLockedCount() external view returns (uint256)
function totalTokenLockedCount() external view returns (uint256)

function getCumulativeLpTokenLockInfoAt(uint256 index) external view returns (CumulativeLockInfo memory)
function getCumulativeNormalTokenLockInfoAt(uint256 index) external view returns (CumulativeLockInfo memory)
function getCumulativeLpTokenLockInfo(uint256 start, uint256 end) external view returns (CumulativeLockInfo[] memory)
function getCumulativeNormalTokenLockInfo(uint256 start, uint256 end) external view returns (CumulativeLockInfo[] memory)
```

---

## Events

| Event | Emitted on |
|---|---|
| `LockCreated(lockId, owner, token, amount, startTime, endTime, lockType, isLP)` | `createLock` |
| `LockEdited(lockId, newAmount, newEndTime)` | `editLock` |
| `LockDescriptionChanged(lockId, description)` | `editLockDescription` |
| `Withdrawn(lockId, owner, amount, nativeFee)` | `withdraw` |
| `LockExtended(lockId, newEndTime)` | `extendLock` |
| `LockTransferred(lockId, from, to)` | `transferLock` |
| `LockRenounced(lockId)` | `renounceLock` |
| `TwapUpdated(price0Avg, price1Avg)` | `createLock` / `withdraw` (when window advances) |
| `FeeUpdated(newFee)` | `setFee` |
| `FeesCollected(to, amount)` | `collectFees` |

---

## Admin

| Function | Description |
|---|---|
| `setFee(uint256 newFee)` | Update the static fallback fee in wei |
| `collectFees(address to)` | Withdraw all accumulated native fees (creation + withdrawal) |

Both are `onlyOwner`. Ownership uses OpenZeppelin `Ownable`.

---

## Lock struct

```solidity
struct Lock {
    address token;
    address owner;       // address(0) = renounced
    uint256 amount;      // actual tokens received (post transfer fee)
    uint256 withdrawn;   // cumulative gross amount claimed so far
    uint256 lockDate;    // block.timestamp at creation
    uint256 startTime;   // Linear: vesting start; Cliff: 0
    uint256 endTime;     // cliff date or vesting end
    LockType lockType;   // 0 = Cliff, 1 = Linear
    bool isLP;           // verified Uniswap V2-style pair
    string description;  // optional label
}
```

---

## Security

- `ReentrancyGuard` on all state-changing functions
- `SafeERC20` for all token transfers
- Custom errors throughout (gas-efficient reverts)
- Excess native token refunded on every payable call
- LP detection uses factory cross-check — spoofed tokens that only implement `token0`/`token1` are rejected
- Fee-on-transfer tokens handled via balance delta — no assumption about received amount
- `address(0)` cannot receive a `transferLock`; use `renounceLock` for permanent locking
- TWAP pair calls are wrapped in `try/catch` — a misbehaving pair silently falls back to the static fee rather than bricking the contract
- TWAP config is immutable after deployment — the pricing pair cannot be swapped out without a redeploy
