// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IPoolManager {
    // pool
    function createPool(address token0, address token1, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        returns (bytes32 poolId, uint256 lp);

    // liquidity
    function addLiquidity(
        bytes32 poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 lp);
    function removeLiquidity(bytes32 poolId, uint256 lp, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        returns (uint256 amount0, uint256 amount1);

    // swap
    function swap(bytes32 poolId, address tokenToSwap, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        returns (uint256 amountOut);
}
