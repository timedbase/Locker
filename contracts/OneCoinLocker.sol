// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

interface IUniswapV2Pair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function factory() external view returns (address);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

interface IUniswapV2PairTWAP {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 r0, uint112 r1, uint32 ts);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}

/// @title 1CoinLocker
/// @notice Lock any ERC-20 — including LP tokens and fee-on-transfer tokens.
contract OneCoinLocker is ReentrancyGuard, Ownable {
    using SafeERC20 for IERC20;
    using EnumerableSet for EnumerableSet.AddressSet;
    using EnumerableSet for EnumerableSet.UintSet;

    // ─── Types ────────────────────────────────────────────────────────────────

    enum LockType {
        Cliff,  // 100 % released at endTime
        Linear  // released pro-rata from startTime → endTime
    }

    struct Lock {
        address token;
        address owner;       // address(0) = renounced (permanently locked)
        uint256 amount;      // actual tokens received (after any transfer fee)
        uint256 withdrawn;
        uint256 lockDate;
        uint256 startTime;   // Linear: vesting start; Cliff: unused (0)
        uint256 endTime;     // cliff date or vesting end
        LockType lockType;
        bool isLP;
        string description;
    }

    /// @notice Tracks total currently-locked balance and factory for a token.
    struct CumulativeLockInfo {
        address token;
        address factory;  // address(0) for normal tokens
        uint256 amount;   // sum of all active lock amounts (decrements on withdrawal)
    }

    // ─── State ────────────────────────────────────────────────────────────────

    /// @notice Static fallback fee (wei) used when the TWAP is not yet primed.
    uint256 public fee;

    // ── Embedded TWAP (immutable config, set at construction) ─────────────────
    /// @notice Uniswap V2 pair used for TWAP pricing. address(0) = static fee only.
    address public immutable twapPair;
    /// @notice Native token wrapper in the pair (WETH / WBNB / …).
    address public immutable twapWeth;
    /// @notice USD stablecoin in the pair (USDC / USDT / DAI / …).
    address public immutable twapUsd;
    /// @notice Decimal precision of the stablecoin (e.g. 6 for USDC, 18 for DAI).
    uint8   public immutable twapUsdDecimals;

    bool    private immutable _twapWethIsToken0;

    uint256 public constant TWAP_PERIOD = 30 minutes;

    // ── Embedded TWAP (mutable window state) ─────────────────────────────────
    uint256 public twapPrice0Avg;
    uint256 public twapPrice1Avg;
    uint256 public twapLastUpdated;

    uint256 private _twapP0CumLast;
    uint256 private _twapP1CumLast;
    uint32  private _twapTimestampLast;

    uint256 public lockCount;

    mapping(uint256 => Lock) public locks;

    // All-time lock ID history per address (never shrinks; includes transferred-away locks)
    mapping(address => uint256[]) private _userLockIds;

    mapping(address => EnumerableSet.UintSet) private _userLpLockIds;
    mapping(address => EnumerableSet.UintSet) private _userNormalLockIds;

    EnumerableSet.AddressSet private _lpLockedTokens;
    EnumerableSet.AddressSet private _normalLockedTokens;

    mapping(address => EnumerableSet.UintSet) private _tokenToLockIds;
    mapping(address => CumulativeLockInfo) public cumulativeLockInfo;

    // ─── Events ───────────────────────────────────────────────────────────────

    event LockCreated(
        uint256 indexed lockId,
        address indexed owner,
        address indexed token,
        uint256 amount,
        uint256 startTime,
        uint256 endTime,
        LockType lockType,
        bool isLP
    );
    event LockEdited(uint256 indexed lockId, uint256 newAmount, uint256 newEndTime);
    event LockDescriptionChanged(uint256 indexed lockId, string description);
    event Withdrawn(uint256 indexed lockId, address indexed owner, uint256 amount, uint256 nativeFee);
    event LockExtended(uint256 indexed lockId, uint256 newEndTime);
    event LockTransferred(uint256 indexed lockId, address indexed from, address indexed to);
    event LockRenounced(uint256 indexed lockId);
    event FeeUpdated(uint256 newFee);
    event TwapUpdated(uint256 price0Avg, uint256 price1Avg);
    event FeesCollected(address indexed to, uint256 amount);

    // ─── Errors ───────────────────────────────────────────────────────────────

    error InsufficientFee(uint256 required, uint256 provided);
    error NotLockOwner();
    error LockRenounced_();
    error EndTimeNotInFuture();
    error NewEndTimeNotLater();
    error ZeroAmount();
    error NothingToWithdraw();
    error ZeroAddress();
    error SameOwner();
    error NativeTransferFailed();
    error LockAlreadyWithdrawn();
    error NoEditParameters();
    error WethNotInPair();

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier onlyLockOwner(uint256 lockId) {
        address owner = locks[lockId].owner;
        if (owner == address(0)) revert LockRenounced_();
        if (owner != msg.sender) revert NotLockOwner();
        _;
    }

    // ─── Constructor ──────────────────────────────────────────────────────────

    /**
     * @param _fee       Static fallback fee in wei (used before TWAP is primed).
     * @param _pair      Uniswap V2 WETH/USD pair for TWAP. Pass address(0) to
     *                   disable TWAP and use only the static fallback fee.
     * @param _weth      Native token wrapper address (must be token0 or token1).
     * @param _usd       USD stablecoin address.
     * @param _usdDecimals Decimals of the stablecoin (e.g. 6 or 18).
     */
    constructor(
        uint256 _fee,
        address _pair,
        address _weth,
        address _usd,
        uint8   _usdDecimals
    ) Ownable(msg.sender) {
        fee = _fee;

        bool wethIs0;
        if (_pair != address(0)) {
            IUniswapV2PairTWAP p = IUniswapV2PairTWAP(_pair);
            address t0 = p.token0();
            address t1 = p.token1();
            wethIs0 = (t0 == _weth);
            if (!wethIs0 && t1 != _weth) revert WethNotInPair();
            (, , uint32 ts) = p.getReserves();
            _twapP0CumLast     = p.price0CumulativeLast();
            _twapP1CumLast     = p.price1CumulativeLast();
            _twapTimestampLast = ts;
        }

        twapPair          = _pair;
        twapWeth          = _weth;
        twapUsd           = _usd;
        twapUsdDecimals   = _usdDecimals;
        _twapWethIsToken0 = wethIs0;
    }

    // ─── Core: Create ─────────────────────────────────────────────────────────

    /**
     * @notice Lock tokens until `endTime`. Charges $1 in native token (TWAP-priced).
     * @param token     ERC-20 to lock. LP and fee-on-transfer tokens are supported.
     * @param amount    Amount to transfer (approval required). Stored amount equals the
     *                  balance delta received — handles fee-on-transfer tokens correctly.
     * @param endTime   Cliff date or vesting end (must be in the future).
     * @param lockType  Cliff = full unlock at endTime; Linear = pro-rata from now.
     * @return lockId   Unique identifier for the created lock.
     */
    function createLock(
        address token,
        uint256 amount,
        uint256 endTime,
        LockType lockType
    ) external payable nonReentrant returns (uint256 lockId) {
        _tryUpdateTwap();
        uint256 required = _getFeeNative();
        if (msg.value < required) revert InsufficientFee(required, msg.value);
        if (amount == 0) revert ZeroAmount();
        if (endTime <= block.timestamp) revert EndTimeNotInFuture();

        uint256 balBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(token).balanceOf(address(this)) - balBefore;
        if (received == 0) revert ZeroAmount();

        lockId = lockCount++;

        uint256 startTime = (lockType == LockType.Linear) ? block.timestamp : 0;
        bool _isLP = _detectLP(token);

        locks[lockId] = Lock({
            token: token,
            owner: msg.sender,
            amount: received,
            withdrawn: 0,
            lockDate: block.timestamp,
            startTime: startTime,
            endTime: endTime,
            lockType: lockType,
            isLP: _isLP,
            description: ""
        });

        _userLockIds[msg.sender].push(lockId);
        _tokenToLockIds[token].add(lockId);

        if (_isLP) {
            _userLpLockIds[msg.sender].add(lockId);
            _lpLockedTokens.add(token);
        } else {
            _userNormalLockIds[msg.sender].add(lockId);
            _normalLockedTokens.add(token);
        }

        CumulativeLockInfo storage info = cumulativeLockInfo[token];
        if (info.token == address(0)) {
            info.token   = token;
            info.factory = _isLP ? _getFactory(token) : address(0);
        }
        info.amount += received;

        _refund(msg.value - required);

        emit LockCreated(lockId, msg.sender, token, received, startTime, endTime, lockType, _isLP);
    }

    // ─── Core: Withdraw ───────────────────────────────────────────────────────

    /**
     * @notice Withdraw all currently claimable tokens. Charges $1 in native token.
     *         100 % of the claimable amount is transferred to the caller.
     */
    function withdraw(uint256 lockId) external payable nonReentrant onlyLockOwner(lockId) {
        _tryUpdateTwap();
        uint256 required = _getFeeNative();
        if (msg.value < required) revert InsufficientFee(required, msg.value);

        Lock storage lock = locks[lockId];
        uint256 gross = _claimable(lock);
        if (gross == 0) revert NothingToWithdraw();

        lock.withdrawn += gross;

        CumulativeLockInfo storage info = cumulativeLockInfo[lock.token];
        info.amount -= gross;

        if (lock.withdrawn >= lock.amount) {
            _tokenToLockIds[lock.token].remove(lockId);
            if (lock.isLP) {
                _userLpLockIds[msg.sender].remove(lockId);
                if (info.amount == 0) _lpLockedTokens.remove(lock.token);
            } else {
                _userNormalLockIds[msg.sender].remove(lockId);
                if (info.amount == 0) _normalLockedTokens.remove(lock.token);
            }
        }

        IERC20(lock.token).safeTransfer(msg.sender, gross);

        _refund(msg.value - required);

        emit Withdrawn(lockId, msg.sender, gross, required);
    }

    // ─── Core: Extend ─────────────────────────────────────────────────────────

    /// @notice Push the unlock / vesting-end date further into the future. Free.
    function extendLock(uint256 lockId, uint256 newEndTime)
        external
        nonReentrant
        onlyLockOwner(lockId)
    {
        Lock storage lock = locks[lockId];
        if (newEndTime <= lock.endTime) revert NewEndTimeNotLater();
        lock.endTime = newEndTime;
        emit LockExtended(lockId, newEndTime);
    }

    // ─── Core: Edit ───────────────────────────────────────────────────────────

    /**
     * @notice Top up a lock's amount and/or push its end date. Free.
     *         Reverts if any withdrawal has already been made — use `extendLock`
     *         to extend a partially-vested linear lock.
     * @param additionalAmount Extra tokens to deposit (0 = no top-up).
     * @param newEndTime       New end timestamp, must be later (0 = no change).
     */
    function editLock(
        uint256 lockId,
        uint256 additionalAmount,
        uint256 newEndTime
    ) external nonReentrant onlyLockOwner(lockId) {
        Lock storage lock = locks[lockId];
        if (lock.withdrawn > 0) revert LockAlreadyWithdrawn();
        if (additionalAmount == 0 && newEndTime == 0) revert NoEditParameters();

        if (newEndTime != 0) {
            if (newEndTime <= lock.endTime) revert NewEndTimeNotLater();
            lock.endTime = newEndTime;
        }

        if (additionalAmount != 0) {
            uint256 balBefore = IERC20(lock.token).balanceOf(address(this));
            IERC20(lock.token).safeTransferFrom(msg.sender, address(this), additionalAmount);
            uint256 received = IERC20(lock.token).balanceOf(address(this)) - balBefore;
            if (received == 0) revert ZeroAmount();
            lock.amount += received;
            cumulativeLockInfo[lock.token].amount += received;
        }

        emit LockEdited(lockId, lock.amount, lock.endTime);
    }

    /// @notice Set or update the description label on a lock. Free.
    function editLockDescription(uint256 lockId, string calldata description)
        external
        nonReentrant
        onlyLockOwner(lockId)
    {
        locks[lockId].description = description;
        emit LockDescriptionChanged(lockId, description);
    }

    // ─── Core: Transfer ───────────────────────────────────────────────────────

    /// @notice Transfer lock ownership to `newOwner`. Free.
    function transferLock(uint256 lockId, address newOwner)
        external
        nonReentrant
        onlyLockOwner(lockId)
    {
        if (newOwner == address(0)) revert ZeroAddress();
        if (newOwner == msg.sender) revert SameOwner();

        Lock storage lock = locks[lockId];
        address prev = lock.owner;
        lock.owner = newOwner;

        _userLockIds[newOwner].push(lockId);

        if (lock.isLP) {
            _userLpLockIds[prev].remove(lockId);
            _userLpLockIds[newOwner].add(lockId);
        } else {
            _userNormalLockIds[prev].remove(lockId);
            _userNormalLockIds[newOwner].add(lockId);
        }

        emit LockTransferred(lockId, prev, newOwner);
    }

    // ─── Core: Renounce ───────────────────────────────────────────────────────

    /// @notice Permanently lock tokens (owner → address(0)). Irreversible.
    function renounceLock(uint256 lockId) external nonReentrant onlyLockOwner(lockId) {
        Lock storage lock = locks[lockId];
        if (lock.isLP) {
            _userLpLockIds[msg.sender].remove(lockId);
        } else {
            _userNormalLockIds[msg.sender].remove(lockId);
        }
        lock.owner = address(0);
        emit LockRenounced(lockId);
    }

    // ─── Views ────────────────────────────────────────────────────────────────

    /// @notice Current fee in native token (wei) for one create or withdraw operation.
    function currentFee() external view returns (uint256) {
        return _getFeeNative();
    }

    /// @notice Gross claimable amount (no deductions — full amount sent to caller on withdraw).
    function claimable(uint256 lockId) external view returns (uint256) {
        return _claimable(locks[lockId]);
    }

    /// @notice Full Lock struct for a given ID.
    function getLock(uint256 lockId) external view returns (Lock memory) {
        return locks[lockId];
    }

    /// @notice Alias for getLock.
    function getLockById(uint256 lockId) external view returns (Lock memory) {
        return locks[lockId];
    }

    /// @notice Total number of locks ever created.
    function getTotalLockCount() external view returns (uint256) {
        return lockCount;
    }

    /// @notice Returns true if `token` is a verified Uniswap V2-style LP pair.
    function isLPToken(address token) external view returns (bool) {
        return _detectLP(token);
    }

    // Per-user views
    function getUserLockIds(address user) external view returns (uint256[] memory) {
        return _userLockIds[user];
    }

    function lpLockCountForUser(address user) public view returns (uint256) {
        return _userLpLockIds[user].length();
    }

    function normalLockCountForUser(address user) public view returns (uint256) {
        return _userNormalLockIds[user].length();
    }

    function totalLockCountForUser(address user) external view returns (uint256) {
        return lpLockCountForUser(user) + normalLockCountForUser(user);
    }

    function lpLocksForUser(address user) external view returns (Lock[] memory) {
        uint256 len = _userLpLockIds[user].length();
        Lock[] memory result = new Lock[](len);
        for (uint256 i = 0; i < len; i++) result[i] = locks[_userLpLockIds[user].at(i)];
        return result;
    }

    function normalLocksForUser(address user) external view returns (Lock[] memory) {
        uint256 len = _userNormalLockIds[user].length();
        Lock[] memory result = new Lock[](len);
        for (uint256 i = 0; i < len; i++) result[i] = locks[_userNormalLockIds[user].at(i)];
        return result;
    }

    function lpLockForUserAtIndex(address user, uint256 index) external view returns (Lock memory) {
        require(index < _userLpLockIds[user].length(), "Index out of bounds");
        return locks[_userLpLockIds[user].at(index)];
    }

    function normalLockForUserAtIndex(address user, uint256 index) external view returns (Lock memory) {
        require(index < _userNormalLockIds[user].length(), "Index out of bounds");
        return locks[_userNormalLockIds[user].at(index)];
    }

    // Per-token views
    function totalLockCountForToken(address token) external view returns (uint256) {
        return _tokenToLockIds[token].length();
    }

    function getLocksForToken(address token, uint256 start, uint256 end)
        external view returns (Lock[] memory)
    {
        uint256 total = _tokenToLockIds[token].length();
        if (total == 0) return new Lock[](0);
        if (end >= total) end = total - 1;
        uint256 len = end - start + 1;
        Lock[] memory result = new Lock[](len);
        for (uint256 i = 0; i < len; i++) result[i] = locks[_tokenToLockIds[token].at(start + i)];
        return result;
    }

    // Global stats
    function allLpTokenLockedCount() public view returns (uint256) {
        return _lpLockedTokens.length();
    }

    function allNormalTokenLockedCount() public view returns (uint256) {
        return _normalLockedTokens.length();
    }

    function totalTokenLockedCount() external view returns (uint256) {
        return allLpTokenLockedCount() + allNormalTokenLockedCount();
    }

    function getCumulativeLpTokenLockInfoAt(uint256 index) external view returns (CumulativeLockInfo memory) {
        return cumulativeLockInfo[_lpLockedTokens.at(index)];
    }

    function getCumulativeNormalTokenLockInfoAt(uint256 index) external view returns (CumulativeLockInfo memory) {
        return cumulativeLockInfo[_normalLockedTokens.at(index)];
    }

    function getCumulativeLpTokenLockInfo(uint256 start, uint256 end)
        external view returns (CumulativeLockInfo[] memory)
    {
        uint256 total = _lpLockedTokens.length();
        if (total == 0) return new CumulativeLockInfo[](0);
        if (end >= total) end = total - 1;
        uint256 len = end - start + 1;
        CumulativeLockInfo[] memory result = new CumulativeLockInfo[](len);
        for (uint256 i = 0; i < len; i++) result[i] = cumulativeLockInfo[_lpLockedTokens.at(start + i)];
        return result;
    }

    function getCumulativeNormalTokenLockInfo(uint256 start, uint256 end)
        external view returns (CumulativeLockInfo[] memory)
    {
        uint256 total = _normalLockedTokens.length();
        if (total == 0) return new CumulativeLockInfo[](0);
        if (end >= total) end = total - 1;
        uint256 len = end - start + 1;
        CumulativeLockInfo[] memory result = new CumulativeLockInfo[](len);
        for (uint256 i = 0; i < len; i++) result[i] = cumulativeLockInfo[_normalLockedTokens.at(start + i)];
        return result;
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    /// @notice Update the static fallback fee (wei), used before TWAP is primed.
    function setFee(uint256 newFee) external onlyOwner {
        fee = newFee;
        emit FeeUpdated(newFee);
    }

    /// @notice Withdraw all accumulated native fees to `to`.
    function collectFees(address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        uint256 balance = address(this).balance;
        _sendNative(to, balance);
        emit FeesCollected(to, balance);
    }

    // ─── Internals ────────────────────────────────────────────────────────────

    /**
     * @dev Attempts to advance the embedded TWAP by one 30-minute window.
     *      Silently skips if the pair is unset, the window hasn't elapsed, or
     *      any external call to the pair fails. Safe to call on every interaction.
     */
    function _tryUpdateTwap() internal {
        if (twapPair == address(0)) return;

        IUniswapV2PairTWAP p = IUniswapV2PairTWAP(twapPair);

        uint112 r0; uint112 r1; uint32 pairTs;
        try p.getReserves() returns (uint112 _r0, uint112 _r1, uint32 _ts) {
            if (_r0 == 0 || _r1 == 0) return;
            r0 = _r0; r1 = _r1; pairTs = _ts;
        } catch { return; }

        uint32 blockTs  = uint32(block.timestamp);
        uint32 elapsed  = blockTs - _twapTimestampLast;
        if (elapsed < uint32(TWAP_PERIOD)) return;

        uint256 p0Cum; uint256 p1Cum;
        try p.price0CumulativeLast() returns (uint256 v) { p0Cum = v; } catch { return; }
        try p.price1CumulativeLast() returns (uint256 v) { p1Cum = v; } catch { return; }

        // Add contribution from any time since the pair's last on-chain update.
        // Uses unchecked to match Uniswap V2's intentional uint256 wrap-around.
        if (pairTs != blockTs) {
            unchecked {
                uint32 dt = blockTs - pairTs;
                p0Cum += (uint256(uint224(r1)) << 112) / uint256(r0) * dt;
                p1Cum += (uint256(uint224(r0)) << 112) / uint256(r1) * dt;
            }
        }

        unchecked {
            twapPrice0Avg = (p0Cum - _twapP0CumLast) / elapsed;
            twapPrice1Avg = (p1Cum - _twapP1CumLast) / elapsed;
        }

        _twapP0CumLast     = p0Cum;
        _twapP1CumLast     = p1Cum;
        _twapTimestampLast = blockTs;
        twapLastUpdated    = block.timestamp;

        emit TwapUpdated(twapPrice0Avg, twapPrice1Avg);
    }

    /**
     * @dev Returns the current fee in native token (wei).
     *      Uses the embedded TWAP if the pair is set and a price has been computed.
     *      Falls back to the static `fee` otherwise.
     */
    function _getFeeNative() internal view returns (uint256) {
        if (twapPair != address(0) && (twapPrice0Avg != 0 || twapPrice1Avg != 0)) {
            uint256 oneUsd = 10 ** uint256(twapUsdDecimals);
            // If WETH is token0: price1Avg = UQ112x112(token0/token1) = WETH per USD
            // If WETH is token1: price0Avg = UQ112x112(token1/token0) = WETH per USD
            uint256 avg = _twapWethIsToken0 ? twapPrice1Avg : twapPrice0Avg;
            uint256 price = (avg * oneUsd) >> 112;
            if (price > 0) return price;
        }
        return fee;
    }

    /**
     * @dev Verifies a V2-style LP token via factory cross-check.
     *      All three external calls are try/catch — returns false on any failure.
     */
    function _detectLP(address token) internal view returns (bool) {
        address factory;
        try IUniswapV2Pair(token).factory() returns (address f) { factory = f; } catch { return false; }
        if (factory == address(0)) return false;

        address t0; address t1;
        try IUniswapV2Pair(token).token0() returns (address a) { t0 = a; } catch { return false; }
        try IUniswapV2Pair(token).token1() returns (address b) { t1 = b; } catch { return false; }
        if (t0 == address(0) || t1 == address(0)) return false;

        try IUniswapV2Factory(factory).getPair(t0, t1) returns (address p) {
            return p == token;
        } catch { return false; }
    }

    function _getFactory(address token) internal view returns (address) {
        try IUniswapV2Pair(token).factory() returns (address f) { return f; } catch { return address(0); }
    }

    function _claimable(Lock storage lock) internal view returns (uint256) {
        if (lock.lockType == LockType.Cliff) {
            if (block.timestamp < lock.endTime) return 0;
            return lock.amount - lock.withdrawn;
        }
        if (block.timestamp <= lock.startTime) return 0;
        uint256 elapsed = block.timestamp >= lock.endTime
            ? lock.endTime - lock.startTime
            : block.timestamp - lock.startTime;
        uint256 duration = lock.endTime - lock.startTime;
        uint256 vested = (lock.amount * elapsed) / duration;
        return vested > lock.withdrawn ? vested - lock.withdrawn : 0;
    }

    function _refund(uint256 excess) internal {
        if (excess == 0) return;
        _sendNative(msg.sender, excess);
    }

    function _sendNative(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }
}
