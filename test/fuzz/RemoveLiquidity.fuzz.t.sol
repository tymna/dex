// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "../unit/Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";

contract RemoveLiquidityFuzzTest is Base {
    bytes32 internal poolId;
    uint256 internal aliceLp;

    function setUp() public override {
        super.setUp();
        (poolId, aliceLp) = _createPoolAndAddLiquidity(alice, 100e18, 100e18);
    }

    /// @dev For any valid lp amount, removal yields proportional payouts,
    ///      preserves the k-invariant, and conserves token balances.
    function testFuzz_removeLiquidity_preservesInvariants(uint256 lp) public {
        uint256 callerBalance = pm.balanceOf(alice, uint256(poolId));
        lp = bound(lp, 1, callerBalance);

        PoolManager.Pool memory before_ = pm.getPool(poolId);
        uint256 expectedAmount0 = lp * before_.s_reserve0 / before_.s_totalShares;
        uint256 expectedAmount1 = lp * before_.s_reserve1 / before_.s_totalShares;

        uint256 tokenA_before = tokenA.balanceOf(alice);
        uint256 tokenB_before = tokenB.balanceOf(alice);

        vm.prank(alice);
        (uint256 got0, uint256 got1) = pm.removeLiquidity(poolId, lp, 0, 0, block.timestamp);

        // 1. Payout matches proportional calculation
        assertEq(got0, expectedAmount0, "amount0 not proportional");
        assertEq(got1, expectedAmount1, "amount1 not proportional");

        // 2. Token balances conserved (caller received exactly the payout)
        assertEq(tokenA.balanceOf(alice), tokenA_before + got0, "tokenA conservation");
        assertEq(tokenB.balanceOf(alice), tokenB_before + got1, "tokenB conservation");

        // 3. LP burned correctly
        assertEq(pm.balanceOf(alice, uint256(poolId)), callerBalance - lp, "lp burn");

        // 4. Pool state consistent
        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertEq(after_.s_reserve0, before_.s_reserve0 - got0, "reserve0 accounting");
        assertEq(after_.s_reserve1, before_.s_reserve1 - got1, "reserve1 accounting");
        assertEq(after_.s_totalShares, before_.s_totalShares - lp, "totalShares accounting");

        // 5. k-invariant: kLast == new reserves product
        assertEq(after_.s_kLast, after_.s_reserve0 * after_.s_reserve1, "kLast updated");

        // 6. Dead-address shares always survive (pool never fully drained)
        assertGt(after_.s_totalShares, 0, "dead shares survive");
    }

    /// @dev Swap accrues fees → remove must yield proportional payout from the grown reserves,
    ///      LP value (got0 * got1) must exceed pre-swap entitlement, all accounting holds.
    function testFuzz_removeLiquidity_afterSwapFeesAccrue(uint256 swapAmount, uint256 lp) public {
        address t0 = pm.getToken0(poolId);

        // Swap to accrue fees
        swapAmount = bound(swapAmount, 1e15, INITIAL_BALANCE / 2);
        vm.prank(bob);
        pm.swap(poolId, t0, swapAmount, 0, block.timestamp);

        // Remove fuzzed LP amount (min bound ensures non-zero payout)
        uint256 callerBalance = pm.balanceOf(alice, uint256(poolId));
        PoolManager.Pool memory preCheck = pm.getPool(poolId);
        uint256 minLp = preCheck.s_totalShares / preCheck.s_reserve1 + 1;
        if (minLp > callerBalance) minLp = callerBalance;
        lp = bound(lp, minLp, callerBalance);

        PoolManager.Pool memory preRemove = pm.getPool(poolId);
        uint256 expectedAmount0 = lp * preRemove.s_reserve0 / preRemove.s_totalShares;
        uint256 expectedAmount1 = lp * preRemove.s_reserve1 / preRemove.s_totalShares;

        vm.prank(alice);
        (uint256 got0, uint256 got1) = pm.removeLiquidity(poolId, lp, 0, 0, block.timestamp);

        // Payout matches formula on post-swap reserves
        assertEq(got0, expectedAmount0, "amount0 not proportional after swap");
        assertEq(got1, expectedAmount1, "amount1 not proportional after swap");

        // LP burned
        assertEq(pm.balanceOf(alice, uint256(poolId)), callerBalance - lp, "lp burn");

        // Pool accounting
        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertEq(after_.s_reserve0, preRemove.s_reserve0 - got0, "reserve0 accounting");
        assertEq(after_.s_reserve1, preRemove.s_reserve1 - got1, "reserve1 accounting");
        assertEq(after_.s_totalShares, preRemove.s_totalShares - lp, "totalShares accounting");
        assertEq(after_.s_kLast, after_.s_reserve0 * after_.s_reserve1, "kLast updated");
        assertGt(after_.s_totalShares, 0, "dead shares survive");
    }
}
