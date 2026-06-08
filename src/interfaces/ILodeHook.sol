// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

interface ILodeHook {
    event PoolConfigured(
        PoolId indexed poolId, uint24 premiumBps, address splitter, address operator, uint256 minAuctionInput
    );
    event AuctionFilled(
        PoolId indexed poolId,
        uint256 indexed blockNumber,
        Currency currency,
        uint256 premium,
        address sender
    );
    event AuctionSkipped(PoolId indexed poolId, uint256 indexed blockNumber, uint256 swapAmount, string reason);

    struct PoolConfig {
        bool active;
        uint24 premiumBps;
        address splitter;
        address operator;
        uint128 minAuctionInputSize;
    }

    function MAX_PREMIUM_BPS() external view returns (uint24);
    function configurePool(
        PoolKey calldata key,
        uint24 premiumBps,
        address splitter,
        address operator,
        uint128 minAuctionInputSize
    ) external;
    function deactivatePool(PoolKey calldata key) external;
    function deactivatePoolById(PoolId id) external;
    function poolConfig(PoolId id) external view returns (PoolConfig memory);
    function lastAuctionBlock(PoolId id) external view returns (uint256);
}