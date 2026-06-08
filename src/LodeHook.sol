// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {ILodeHook} from "./interfaces/ILodeHook.sol";

contract LodeHook is BaseHook, ILodeHook {
    using PoolIdLibrary for PoolKey;
    using SafeCast for uint256;

    error Unauthorized();
    error InvalidConfig();
    error PoolNotConfigured();
    error GloballyPaused();
    error PoolPaused();

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event FactoryUpdated(address indexed factory);
    event GuardianUpdated(address indexed guardian);
    event GlobalPaused(bool paused, address by);
    event PoolPausedSet(PoolId indexed poolId, bool paused, address by);

    uint24 public constant override MAX_PREMIUM_BPS = 500;
    uint24 internal constant BPS_DENOMINATOR = 10_000;

    address public owner;
    address public factory;
    address public guardian;
    bool public globalPaused;

    mapping(PoolId => PoolConfig) internal _poolConfigs;
    mapping(PoolId => bool) public poolPaused;
    mapping(PoolId => uint256) public override lastAuctionBlock;

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrFactory() {
        if (msg.sender != owner && msg.sender != factory) revert Unauthorized();
        _;
    }

    modifier onlyOwnerOrGuardian() {
        if (msg.sender != owner && msg.sender != guardian) revert Unauthorized();
        _;
    }

    constructor(IPoolManager _manager, address _owner, address _guardian) BaseHook(_manager) {
        if (_owner == address(0) || _guardian == address(0)) revert InvalidConfig();
        owner = _owner;
        guardian = _guardian;
        emit OwnershipTransferred(address(0), _owner);
        emit GuardianUpdated(_guardian);
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function configurePool(
        PoolKey calldata key,
        uint24 premiumBps,
        address splitter,
        address operator,
        uint128 minAuctionInputSize
    ) external override onlyOwnerOrFactory {
        if (premiumBps > MAX_PREMIUM_BPS) revert InvalidConfig();
        if (splitter == address(0) || operator == address(0)) revert InvalidConfig();
        PoolId id = key.toId();
        _poolConfigs[id] = PoolConfig({
            active: true,
            premiumBps: premiumBps,
            splitter: splitter,
            operator: operator,
            minAuctionInputSize: minAuctionInputSize
        });
        lastAuctionBlock[id] = 0;
        emit PoolConfigured(id, premiumBps, splitter, operator, minAuctionInputSize);
    }

    function deactivatePool(PoolKey calldata key) external override onlyOwnerOrFactory {
        deactivatePoolById(key.toId());
    }

    function deactivatePoolById(PoolId id) public override onlyOwnerOrFactory {
        if (!_poolConfigs[id].active) revert PoolNotConfigured();
        _poolConfigs[id].active = false;
        emit PoolConfigured(id, 0, address(0), address(0), 0);
    }

    function setFactory(address _factory) external onlyOwner {
        factory = _factory;
        emit FactoryUpdated(_factory);
    }

    function setGuardian(address _guardian) external onlyOwner {
        if (_guardian == address(0)) revert InvalidConfig();
        guardian = _guardian;
        emit GuardianUpdated(_guardian);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidConfig();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function pauseGlobal() external onlyOwnerOrGuardian {
        globalPaused = true;
        emit GlobalPaused(true, msg.sender);
    }

    function unpauseGlobal() external onlyOwner {
        globalPaused = false;
        emit GlobalPaused(false, msg.sender);
    }

    function setPoolPaused(PoolKey calldata key, bool paused) external onlyOwnerOrGuardian {
        if (!paused && msg.sender != owner) revert Unauthorized();
        PoolId id = key.toId();
        poolPaused[id] = paused;
        emit PoolPausedSet(id, paused, msg.sender);
    }

    function poolConfig(PoolId id) external view override returns (PoolConfig memory) {
        return _poolConfigs[id];
    }

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId id = key.toId();
        if (globalPaused || poolPaused[id]) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        PoolConfig memory cfg = _poolConfigs[id];
        if (!cfg.active || cfg.premiumBps == 0) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (block.number <= lastAuctionBlock[id]) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (params.amountSpecified == type(int256).min) {
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        uint256 swapAmount = params.amountSpecified < 0
            ? uint256(-params.amountSpecified)
            : uint256(params.amountSpecified);

        if (swapAmount < cfg.minAuctionInputSize) {
            emit AuctionSkipped(id, block.number, swapAmount, "below min");
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        uint256 premium = (swapAmount * cfg.premiumBps) / BPS_DENOMINATOR;
        if (premium == 0) {
            emit AuctionSkipped(id, block.number, swapAmount, "premium truncated");
            return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }

        lastAuctionBlock[id] = block.number;

        Currency inputCurrency = params.zeroForOne ? key.currency0 : key.currency1;
        bool inputIsSpecified = params.amountSpecified < 0;

        poolManager.take(inputCurrency, cfg.splitter, premium);

        emit AuctionFilled(id, block.number, inputCurrency, premium, sender);

        int128 premiumI128 = SafeCast.toInt128(SafeCast.toInt256(premium));
        BeforeSwapDelta delta = inputIsSpecified
            ? toBeforeSwapDelta(premiumI128, int128(0))
            : toBeforeSwapDelta(int128(0), premiumI128);

        return (BaseHook.beforeSwap.selector, delta, 0);
    }
}