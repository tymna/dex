// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "./Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ZeroAmountNotAllowed, PoolDoesNotExists} from "src/Errors.sol";

contract AddLiquidityTest is Base {
    bytes32 internal poolId;

    uint256 internal constant MIN_LIQUIDITY = 1e3;

    function setUp() public override {
        super.setUp();
        poolId = _createPool(alice);
    }

    /* ───── Revert Conditions ───── */

    function test_revertIf_poolDoesNotExist() public {
        bytes32 bogusId = keccak256("bogus");
        vm.prank(alice);
        vm.expectRevert(PoolDoesNotExists.selector);
        pm.addLiquidity(bogusId, 1e18, 1e18, 0, 0, block.timestamp);
    }

    function test_revertIf_amount0IsZero() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmountNotAllowed.selector);
        pm.addLiquidity(poolId, 0, 1e18, 0, 0, block.timestamp);
    }

    function test_revertIf_amount1IsZero() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmountNotAllowed.selector);
        pm.addLiquidity(poolId, 1e18, 0, 0, 0, block.timestamp);
    }

    /* ───── Happy Path ───── */

    function test_addLiquidity_increasesReserves() public {
        uint256 amount0 = 10e18;
        uint256 amount1 = 10e18;

        PoolManager.Pool memory before_ = pm.getPool(poolId);

        vm.prank(alice);
        pm.addLiquidity(poolId, amount0, amount1, 0, 0, block.timestamp);

        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertEq(after_.s_reserve0, before_.s_reserve0 + amount0);
        assertEq(after_.s_reserve1, before_.s_reserve1 + amount1);
    }

    function test_addLiquidity_mintsLpToCaller() public {
        uint256 amount0 = 10e18;
        uint256 amount1 = 10e18;

        uint256 lpBefore = pm.balanceOf(alice, uint256(poolId));

        // sharesToMint = amount0 * totalShares / reserve0 = 10e18 * 1e3 / 1e3 = 10e18
        uint256 expectedShares = amount0 * MIN_LIQUIDITY / MIN_LIQUIDITY;

        vm.prank(alice);
        uint256 lp = pm.addLiquidity(poolId, amount0, amount1, 0, 0, block.timestamp);

        assertEq(lp, expectedShares);
        assertEq(pm.balanceOf(alice, uint256(poolId)), lpBefore + expectedShares);
    }

    function test_addLiquidity_transfersTokensFromCaller() public {
        uint256 amount0 = 10e18;
        uint256 amount1 = 10e18;

        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);

        uint256 bal0Before = MockERC20(t0).balanceOf(alice);
        uint256 bal1Before = MockERC20(t1).balanceOf(alice);

        vm.prank(alice);
        pm.addLiquidity(poolId, amount0, amount1, 0, 0, block.timestamp);

        assertEq(MockERC20(t0).balanceOf(alice), bal0Before - amount0);
        assertEq(MockERC20(t1).balanceOf(alice), bal1Before - amount1);
    }

    function test_addLiquidity_updatesKLast() public {
        vm.prank(alice);
        pm.addLiquidity(poolId, 10e18, 10e18, 0, 0, block.timestamp);

        PoolManager.Pool memory pool = pm.getPool(poolId);
        assertEq(pool.s_kLast, pool.s_reserve0 * pool.s_reserve1);
    }

    function test_addLiquidity_emitsLiquidityAdded() public {
        uint256 amount0 = 10e18;
        uint256 amount1 = 10e18;
        uint256 expectedShares = amount0 * MIN_LIQUIDITY / MIN_LIQUIDITY;

        vm.expectEmit(true, true, false, true, address(pm));
        emit PoolManager.LiquidityAdded(poolId, alice, amount0, amount1, expectedShares);

        vm.prank(alice);
        pm.addLiquidity(poolId, amount0, amount1, 0, 0, block.timestamp);
    }

    /* ───── Ratio Adjustment ───── */

    function test_addLiquidity_adjustsAmount1Down() public {
        // Pool starts 1:1. Provide excess amount1.
        // amount1Optimal = 5e18 * reserve1 / reserve0 = 5e18 (1:1 ratio)
        // 5e18 <= 20e18 → uses full amount0Desired, adjusts amount1 to 5e18
        uint256 amount0Desired = 5e18;
        uint256 amount1Desired = 20e18;

        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);
        uint256 bal0Before = MockERC20(t0).balanceOf(alice);
        uint256 bal1Before = MockERC20(t1).balanceOf(alice);

        vm.prank(alice);
        pm.addLiquidity(poolId, amount0Desired, amount1Desired, 0, 0, block.timestamp);

        uint256 amount0Used = bal0Before - MockERC20(t0).balanceOf(alice);
        uint256 amount1Used = bal1Before - MockERC20(t1).balanceOf(alice);

        assertEq(amount0Used, amount0Desired);
        assertEq(amount1Used, amount0Desired); // 1:1 ratio → optimal amount1 == amount0
    }

    function test_addLiquidity_adjustsAmount0Down() public {
        // Pool starts 1:1. Provide excess amount0.
        // amount1Optimal = 20e18 * reserve1 / reserve0 = 20e18
        // 20e18 > 5e18 → enters else branch
        // amount0Optimal = 5e18 * reserve0 / reserve1 = 5e18
        uint256 amount0Desired = 20e18;
        uint256 amount1Desired = 5e18;

        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);
        uint256 bal0Before = MockERC20(t0).balanceOf(alice);
        uint256 bal1Before = MockERC20(t1).balanceOf(alice);

        vm.prank(alice);
        pm.addLiquidity(poolId, amount0Desired, amount1Desired, 0, 0, block.timestamp);

        uint256 amount0Used = bal0Before - MockERC20(t0).balanceOf(alice);
        uint256 amount1Used = bal1Before - MockERC20(t1).balanceOf(alice);

        assertEq(amount0Used, amount1Desired); // 1:1 ratio → optimal amount0 == amount1
        assertEq(amount1Used, amount1Desired);
    }

    function test_addLiquidity_adjustsAmount0Down_skewedPool() public {
        // First skew the pool ratio via a swap so reserve0 != reserve1
        address t0 = pm.getToken0(poolId);

        vm.prank(alice);
        pm.addLiquidity(poolId, 50e18, 50e18, 0, 0, block.timestamp);

        // Swap token0 → token1 to make reserve0 > reserve1
        vm.prank(bob);
        pm.swap(poolId, t0, 20e18, 0, block.timestamp);

        PoolManager.Pool memory pool = pm.getPool(poolId);
        // Now reserve0 > reserve1 (skewed ratio)
        assertGt(pool.s_reserve0, pool.s_reserve1);

        // Provide amounts where amount1Optimal > amount1Desired
        // to force the else branch (amount0Optimal path)
        // amount1Optimal = amount0Desired * reserve1 / reserve0
        // With reserve0 > reserve1: amount1Optimal < amount0Desired
        // But we need amount1Optimal > amount1Desired
        // So provide large amount0 with small amount1
        uint256 amount0Desired = 30e18;
        // amount1Optimal = 30e18 * reserve1 / reserve0
        uint256 amount1Optimal = amount0Desired * pool.s_reserve1 / pool.s_reserve0;
        // Set amount1Desired below optimal → forces else branch
        uint256 amount1Desired = amount1Optimal / 2;

        address t1 = pm.getToken1(poolId);
        uint256 bal0Before = MockERC20(t0).balanceOf(alice);
        uint256 bal1Before = MockERC20(t1).balanceOf(alice);

        vm.prank(alice);
        pm.addLiquidity(poolId, amount0Desired, amount1Desired, 0, 0, block.timestamp);

        uint256 amount0Used = bal0Before - MockERC20(t0).balanceOf(alice);
        uint256 amount1Used = bal1Before - MockERC20(t1).balanceOf(alice);

        // amount0 should be adjusted down, amount1 should be fully used
        assertLt(amount0Used, amount0Desired);
        assertEq(amount1Used, amount1Desired);
    }

    /* ───── Edge Cases ───── */

    function test_addLiquidity_multipleProviders() public {
        uint256 aliceBalBefore = pm.balanceOf(alice, uint256(poolId));

        // Alice adds first
        vm.prank(alice);
        uint256 lpAlice = pm.addLiquidity(poolId, 10e18, 10e18, 0, 0, block.timestamp);

        // Bob adds equal amount at same ratio
        vm.prank(bob);
        uint256 lpBob = pm.addLiquidity(poolId, 10e18, 10e18, 0, 0, block.timestamp);

        assertGt(lpAlice, 0);
        assertGt(lpBob, 0);
        assertEq(pm.balanceOf(alice, uint256(poolId)), aliceBalBefore + lpAlice);
        assertEq(pm.balanceOf(bob, uint256(poolId)), lpBob);

        // Same ratio, same deposit → same shares
        assertEq(lpAlice, lpBob);
    }

    function test_addLiquidity_sharesProportionalToDeposit() public {
        PoolManager.Pool memory pre = pm.getPool(poolId);

        vm.prank(alice);
        uint256 lp = pm.addLiquidity(poolId, 10e18, 10e18, 0, 0, block.timestamp);

        // lp = amount0 * totalSharesBefore / reserve0Before
        assertEq(lp * pre.s_reserve0, 10e18 * pre.s_totalShares);

        // Verify total shares consistency
        PoolManager.Pool memory post = pm.getPool(poolId);
        assertEq(post.s_totalShares, pre.s_totalShares + lp);
    }
}
