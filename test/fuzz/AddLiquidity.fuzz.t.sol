// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "../unit/Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract AddLiquidityFuzzTest is Base {
    bytes32 internal poolId;

    uint256 internal constant MIN_LIQUIDITY = 1e3;
    uint256 internal constant MAX_AMOUNT = 100e18;

    function setUp() public override {
        super.setUp();
        (poolId,) = _createPoolAndAddLiquidity(alice, 100e18, 100e18);
    }

    function _skewPool(uint256 swapAmount) internal {
        swapAmount = bound(swapAmount, 1e15, 30e18);
        address t0 = pm.getToken0(poolId);
        vm.prank(alice);
        pm.swap(poolId, t0, swapAmount, 0, block.timestamp);
    }

    function testFuzz_addLiquidity_ratioInvariant(uint256 swapAmount, uint256 amount0Desired, uint256 amount1Desired)
        public
    {
        _skewPool(swapAmount);

        amount0Desired = bound(amount0Desired, 1e15, MAX_AMOUNT);
        amount1Desired = bound(amount1Desired, 1e15, MAX_AMOUNT);

        PoolManager.Pool memory pre = pm.getPool(poolId);
        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);

        uint256 bal0Before = MockERC20(t0).balanceOf(bob);
        uint256 bal1Before = MockERC20(t1).balanceOf(bob);

        _mintAndApprove(bob, amount0Desired, amount1Desired);

        vm.prank(bob);
        uint256 shares = pm.addLiquidity(poolId, amount0Desired, amount1Desired, 0, 0, block.timestamp);

        uint256 amount0Used = bal0Before + amount0Desired - MockERC20(t0).balanceOf(bob);
        uint256 amount1Used = bal1Before + amount1Desired - MockERC20(t1).balanceOf(bob);

        assertLe(amount0Used, amount0Desired, "took more token0 than desired");
        assertLe(amount1Used, amount1Desired, "took more token1 than desired");

        assertTrue(amount0Used == amount0Desired || amount1Used == amount1Desired, "neither desired amount fully used");

        uint256 lhs = amount0Used * pre.s_reserve1;
        uint256 rhs = amount1Used * pre.s_reserve0;
        uint256 diff = lhs > rhs ? lhs - rhs : rhs - lhs;
        uint256 maxReserve = pre.s_reserve0 > pre.s_reserve1 ? pre.s_reserve0 : pre.s_reserve1;
        assertLe(diff, maxReserve, "ratio not preserved");

        PoolManager.Pool memory post = pm.getPool(poolId);
        assertGe(post.s_reserve0 * post.s_reserve1, pre.s_kLast, "k decreased");
        assertEq(post.s_kLast, post.s_reserve0 * post.s_reserve1, "kLast stale");

        uint256 shares0 = amount0Used * pre.s_totalShares / pre.s_reserve0;
        uint256 shares1 = amount1Used * pre.s_totalShares / pre.s_reserve1;
        uint256 expectedShares = shares0 < shares1 ? shares0 : shares1;
        assertEq(shares, expectedShares, "shares not proportional");

        assertEq(post.s_reserve0, pre.s_reserve0 + amount0Used, "reserve0 mismatch");
        assertEq(post.s_reserve1, pre.s_reserve1 + amount1Used, "reserve1 mismatch");
    }

    function _mintAndApprove(address actor, uint256 a0, uint256 a1) internal {
        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);
        MockERC20(t0).mint(actor, a0);
        MockERC20(t1).mint(actor, a1);
    }
}
