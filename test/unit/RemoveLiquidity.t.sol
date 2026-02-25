// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "./Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";
import {PoolDoesNotExists, InsufficientLiquidity} from "src/Errors.sol";

contract RemoveLiquidityTest is Base {
    bytes32 internal poolId;
    uint256 internal aliceLp;

    function setUp() public override {
        super.setUp();
        (poolId, aliceLp) = _createPoolAndAddLiquidity(alice, 100e18, 100e18);
    }

    /* ───── Revert Conditions ───── */

    function test_revertIf_poolDoesNotExist() public {
        bytes32 bogusId = keccak256("bogus");
        vm.prank(alice);
        vm.expectRevert(PoolDoesNotExists.selector);
        pm.removeLiquidity(bogusId, 1e18, 0, 0, block.timestamp);
    }

    function test_revertIf_insufficientLiquidity() public {
        uint256 balance = pm.balanceOf(alice, uint256(poolId));
        vm.prank(alice);
        vm.expectRevert(InsufficientLiquidity.selector);
        pm.removeLiquidity(poolId, balance + 1, 0, 0, block.timestamp);
    }

    /* ───── Happy Path ───── */

    function test_removeLiquidity_decreasesReserves() public {
        PoolManager.Pool memory before_ = pm.getPool(poolId);

        uint256 lpToRemove = aliceLp / 2;
        uint256 expectedAmount0 = lpToRemove * before_.s_reserve0 / before_.s_totalShares;
        uint256 expectedAmount1 = lpToRemove * before_.s_reserve1 / before_.s_totalShares;

        vm.prank(alice);
        pm.removeLiquidity(poolId, lpToRemove, 0, 0, block.timestamp);

        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertEq(after_.s_reserve0, before_.s_reserve0 - expectedAmount0);
        assertEq(after_.s_reserve1, before_.s_reserve1 - expectedAmount1);
    }

    function test_removeLiquidity_burnsLpFromCaller() public {
        uint256 lpBefore = pm.balanceOf(alice, uint256(poolId));
        uint256 lpToRemove = aliceLp / 2;

        vm.prank(alice);
        pm.removeLiquidity(poolId, lpToRemove, 0, 0, block.timestamp);

        assertEq(pm.balanceOf(alice, uint256(poolId)), lpBefore - lpToRemove);
    }

    function test_removeLiquidity_transfersTokensToCaller() public {
        PoolManager.Pool memory before_ = pm.getPool(poolId);
        uint256 lpToRemove = aliceLp / 2;
        uint256 expectedAmount0 = lpToRemove * before_.s_reserve0 / before_.s_totalShares;
        uint256 expectedAmount1 = lpToRemove * before_.s_reserve1 / before_.s_totalShares;

        uint256 balA_before = tokenA.balanceOf(alice);
        uint256 balB_before = tokenB.balanceOf(alice);

        vm.prank(alice);
        pm.removeLiquidity(poolId, lpToRemove, 0, 0, block.timestamp);

        assertEq(tokenA.balanceOf(alice), balA_before + expectedAmount0);
        assertEq(tokenB.balanceOf(alice), balB_before + expectedAmount1);
    }

    function test_removeLiquidity_updatesKLast() public {
        vm.prank(alice);
        pm.removeLiquidity(poolId, aliceLp / 2, 0, 0, block.timestamp);

        PoolManager.Pool memory pool = pm.getPool(poolId);
        assertEq(pool.s_kLast, pool.s_reserve0 * pool.s_reserve1);
    }

    function test_removeLiquidity_emitsLiquidityRemoved() public {
        PoolManager.Pool memory before_ = pm.getPool(poolId);
        uint256 lpToRemove = aliceLp / 2;
        uint256 expectedAmount0 = lpToRemove * before_.s_reserve0 / before_.s_totalShares;
        uint256 expectedAmount1 = lpToRemove * before_.s_reserve1 / before_.s_totalShares;

        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit PoolManager.LiquidityRemoved(poolId, alice, expectedAmount0, expectedAmount1, lpToRemove);
        pm.removeLiquidity(poolId, lpToRemove, 0, 0, block.timestamp);
    }

    /* ───── Edge Cases ───── */

    function test_removeLiquidity_partialWithdraw() public {
        PoolManager.Pool memory before_ = pm.getPool(poolId);
        uint256 half = aliceLp / 2;

        uint256 expectedAmount0 = half * before_.s_reserve0 / before_.s_totalShares;
        uint256 expectedAmount1 = half * before_.s_reserve1 / before_.s_totalShares;

        vm.prank(alice);
        (uint256 got0, uint256 got1) = pm.removeLiquidity(poolId, half, 0, 0, block.timestamp);

        assertEq(got0, expectedAmount0);
        assertEq(got1, expectedAmount1);

        // Remaining reserves still hold the other portion
        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertGt(after_.s_reserve0, 0);
        assertGt(after_.s_reserve1, 0);
    }

    function test_removeLiquidity_fullWithdraw() public {
        PoolManager.Pool memory before_ = pm.getPool(poolId);

        uint256 expectedAmount0 = aliceLp * before_.s_reserve0 / before_.s_totalShares;
        uint256 expectedAmount1 = aliceLp * before_.s_reserve1 / before_.s_totalShares;

        vm.prank(alice);
        (uint256 got0, uint256 got1) = pm.removeLiquidity(poolId, aliceLp, 0, 0, block.timestamp);

        assertEq(got0, expectedAmount0);
        assertEq(got1, expectedAmount1);
        assertEq(pm.balanceOf(alice, uint256(poolId)), 0);

        // Dead-address liquidity (MIN_LIQUIDITY) remains in the pool
        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertGt(after_.s_totalShares, 0, "dead-address shares remain");
        assertGt(after_.s_reserve0, 0, "dead-address reserve0 remains");
        assertGt(after_.s_reserve1, 0, "dead-address reserve1 remains");
    }

    function test_removeLiquidity_afterSwapLPEarnsMore() public {
        PoolManager.Pool memory before_ = pm.getPool(poolId);
        uint256 reserveRatioBefore = before_.s_reserve0 * before_.s_reserve1;

        // Bob swaps — fee accrues to the pool, growing k
        address t0 = pm.getToken0(poolId);
        vm.prank(bob);
        pm.swap(poolId, t0, 10e18, 0, block.timestamp);

        PoolManager.Pool memory afterSwap = pm.getPool(poolId);
        assertGt(afterSwap.s_reserve0 * afterSwap.s_reserve1, reserveRatioBefore, "k grew from fee");

        // Alice removes all her LP — she should get more value than she deposited
        uint256 expectedAmount0 = aliceLp * afterSwap.s_reserve0 / afterSwap.s_totalShares;
        uint256 expectedAmount1 = aliceLp * afterSwap.s_reserve1 / afterSwap.s_totalShares;

        vm.prank(alice);
        (uint256 got0, uint256 got1) = pm.removeLiquidity(poolId, aliceLp, 0, 0, block.timestamp);

        assertEq(got0, expectedAmount0);
        assertEq(got1, expectedAmount1);

        // got0 * got1 > what alice's share of the original pool would have yielded
        // Original pool: alice's share entitled her to (aliceLp * before_.s_reserve0 / before_.s_totalShares)
        uint256 originalAmount0 = aliceLp * before_.s_reserve0 / before_.s_totalShares;
        uint256 originalAmount1 = aliceLp * before_.s_reserve1 / before_.s_totalShares;
        assertGt(got0 * got1, originalAmount0 * originalAmount1, "LP earned fees");
    }

    function test_removeLiquidity_burnAndPayoutAreConsistent() public {
        // Core invariant: burned shares reduce totalShares by exactly lp,
        // and amounts out == lp * reserve / totalShares (no rounding leak in either direction)
        PoolManager.Pool memory before_ = pm.getPool(poolId);
        uint256 lpToRemove = aliceLp / 3;

        uint256 expectedAmount0 = lpToRemove * before_.s_reserve0 / before_.s_totalShares;
        uint256 expectedAmount1 = lpToRemove * before_.s_reserve1 / before_.s_totalShares;

        uint256 lpBefore = pm.balanceOf(alice, uint256(poolId));
        uint256 pmBal0Before = tokenA.balanceOf(address(pm));
        uint256 pmBal1Before = tokenB.balanceOf(address(pm));

        vm.prank(alice);
        (uint256 got0, uint256 got1) = pm.removeLiquidity(poolId, lpToRemove, 0, 0, block.timestamp);

        // LP burned from caller
        assertEq(pm.balanceOf(alice, uint256(poolId)), lpBefore - lpToRemove, "lp burned from caller");

        // totalShares decremented by exactly lp
        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertEq(after_.s_totalShares, before_.s_totalShares - lpToRemove, "totalShares decremented");

        // Amounts match formula exactly
        assertEq(got0, expectedAmount0, "amount0 exact");
        assertEq(got1, expectedAmount1, "amount1 exact");

        // Contract token balances decreased by exactly the payout
        assertEq(tokenA.balanceOf(address(pm)), pmBal0Before - got0, "pm tokenA balance");
        assertEq(tokenB.balanceOf(address(pm)), pmBal1Before - got1, "pm tokenB balance");

        // Reserves match contract balances (no phantom reserves)
        assertEq(after_.s_reserve0, tokenA.balanceOf(address(pm)), "reserve0 == actual balance");
        assertEq(after_.s_reserve1, tokenB.balanceOf(address(pm)), "reserve1 == actual balance");
    }

    function test_removeLiquidity_multipleProviders() public {
        // Bob adds liquidity to the same pool
        vm.prank(bob);
        uint256 bobLp = pm.addLiquidity(poolId, 50e18, 50e18, 0, 0, block.timestamp);

        uint256 bobLpBefore = pm.balanceOf(bob, uint256(poolId));
        PoolManager.Pool memory before_ = pm.getPool(poolId);

        // Alice removes all her LP
        uint256 expectedAmount0 = aliceLp * before_.s_reserve0 / before_.s_totalShares;
        uint256 expectedAmount1 = aliceLp * before_.s_reserve1 / before_.s_totalShares;

        vm.prank(alice);
        (uint256 got0, uint256 got1) = pm.removeLiquidity(poolId, aliceLp, 0, 0, block.timestamp);

        assertEq(got0, expectedAmount0);
        assertEq(got1, expectedAmount1);
        assertEq(pm.balanceOf(alice, uint256(poolId)), 0);

        // Bob's LP untouched
        assertEq(pm.balanceOf(bob, uint256(poolId)), bobLpBefore);

        // Bob can still remove his share
        vm.prank(bob);
        pm.removeLiquidity(poolId, bobLp, 0, 0, block.timestamp);
        assertEq(pm.balanceOf(bob, uint256(poolId)), 0);
    }
}
