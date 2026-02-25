// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "./Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {PoolDoesNotExists, ZeroAmountNotAllowed, InvalidToken, SlippageExceeded} from "src/Errors.sol";

contract SwapTest is Base {
    bytes32 internal poolId;

    uint256 internal constant FEE = 1;
    uint256 internal constant FEE_BASE = 100;

    function setUp() public override {
        super.setUp();
        (poolId,) = _createPoolAndAddLiquidity(alice, 100e18, 100e18);
    }

    /* ───── Revert Conditions ───── */

    function test_revertIf_poolDoesNotExist() public {
        bytes32 bogusId = keccak256("bogus");
        vm.prank(bob);
        vm.expectRevert(PoolDoesNotExists.selector);
        pm.swap(bogusId, address(tokenA), 1e18, 0, block.timestamp);
    }

    function test_revertIf_zeroAmountIn() public {
        vm.prank(bob);
        vm.expectRevert(ZeroAmountNotAllowed.selector);
        pm.swap(poolId, address(tokenA), 0, 0, block.timestamp);
    }

    function test_revertIf_invalidToken() public {
        address random = makeAddr("random");
        vm.prank(bob);
        vm.expectRevert(InvalidToken.selector);
        pm.swap(poolId, random, 1e18, 0, block.timestamp);
    }

    function test_revertIf_slippageExceeded() public {
        vm.prank(bob);
        vm.expectRevert(SlippageExceeded.selector);
        pm.swap(poolId, address(tokenA), 1e18, type(uint256).max, block.timestamp);
    }

    /* ───── Happy Path ───── */

    function test_swap_token0ForToken1() public {
        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);
        PoolManager.Pool memory before_ = pm.getPool(poolId);

        uint256 amountIn = 10e18;
        uint256 amountInAfterFee = amountIn * (FEE_BASE - FEE);
        uint256 expectedOut =
            (amountInAfterFee * before_.s_reserve1) / (before_.s_reserve0 * FEE_BASE + amountInAfterFee);

        uint256 bal0Before = MockERC20(t0).balanceOf(bob);
        uint256 bal1Before = MockERC20(t1).balanceOf(bob);

        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t0, amountIn, 0, block.timestamp);

        assertEq(amountOut, expectedOut);

        // Reserves updated
        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertEq(after_.s_reserve0, before_.s_reserve0 + amountIn);
        assertEq(after_.s_reserve1, before_.s_reserve1 - amountOut);

        // Tokens transferred
        assertEq(MockERC20(t0).balanceOf(bob), bal0Before - amountIn);
        assertEq(MockERC20(t1).balanceOf(bob), bal1Before + amountOut);
    }

    function test_swap_token1ForToken0() public {
        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);
        PoolManager.Pool memory before_ = pm.getPool(poolId);

        uint256 amountIn = 10e18;
        uint256 amountInAfterFee = amountIn * (FEE_BASE - FEE);
        uint256 expectedOut =
            (amountInAfterFee * before_.s_reserve0) / (before_.s_reserve1 * FEE_BASE + amountInAfterFee);

        uint256 bal0Before = MockERC20(t0).balanceOf(bob);
        uint256 bal1Before = MockERC20(t1).balanceOf(bob);

        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t1, amountIn, 0, block.timestamp);

        assertEq(amountOut, expectedOut);

        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertEq(after_.s_reserve1, before_.s_reserve1 + amountIn);
        assertEq(after_.s_reserve0, before_.s_reserve0 - amountOut);

        assertEq(MockERC20(t0).balanceOf(bob), bal0Before + amountOut);
        assertEq(MockERC20(t1).balanceOf(bob), bal1Before - amountIn);
    }

    function test_swap_appliesFee() public {
        address t0 = pm.getToken0(poolId);
        PoolManager.Pool memory before_ = pm.getPool(poolId);
        // Equal reserves → without fee amountOut would equal amountIn (for small amounts relative to reserves)
        // With fee, amountOut < amountIn
        uint256 amountIn = 1e18;

        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t0, amountIn, 0, block.timestamp);

        assertLt(amountOut, amountIn);

        // Fee stays in pool: k grows
        PoolManager.Pool memory after_ = pm.getPool(poolId);
        uint256 kBefore = before_.s_reserve0 * before_.s_reserve1;
        uint256 kAfter = after_.s_reserve0 * after_.s_reserve1;
        assertGt(kAfter, kBefore);
    }

    function test_swap_updatesKLast() public {
        address t0 = pm.getToken0(poolId);
        PoolManager.Pool memory before_ = pm.getPool(poolId);
        uint256 kLastBefore = before_.s_kLast;

        vm.prank(bob);
        pm.swap(poolId, t0, 5e18, 0, block.timestamp);

        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertEq(after_.s_kLast, after_.s_reserve0 * after_.s_reserve1);
        assertGt(after_.s_kLast, kLastBefore);
    }

    function test_swap_emitsSwapEvent() public {
        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);
        PoolManager.Pool memory pool = pm.getPool(poolId);

        uint256 amountIn = 5e18;
        uint256 amountInAfterFee = amountIn * (FEE_BASE - FEE);
        uint256 expectedOut = (amountInAfterFee * pool.s_reserve1) / (pool.s_reserve0 * FEE_BASE + amountInAfterFee);

        vm.expectEmit(true, true, false, true, address(pm));
        emit PoolManager.Swap(poolId, bob, t0, amountIn, t1, expectedOut);

        vm.prank(bob);
        pm.swap(poolId, t0, amountIn, 0, block.timestamp);
    }

    /* ───── Edge Cases ───── */

    function test_swap_largeAmountApproachesReserve() public {
        address t0 = pm.getToken0(poolId);
        PoolManager.Pool memory pool = pm.getPool(poolId);

        // Swap a huge amount — output can never fully drain reserveOut
        uint256 amountIn = 1000e18;
        _fundActor(bob); // extra funds

        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t0, amountIn, 0, block.timestamp);

        assertLt(amountOut, pool.s_reserve1);
    }

    function test_swap_minAmountOutExactMatch() public {
        address t0 = pm.getToken0(poolId);
        PoolManager.Pool memory pool = pm.getPool(poolId);

        uint256 amountIn = 5e18;
        uint256 amountInAfterFee = amountIn * (FEE_BASE - FEE);
        uint256 expectedOut = (amountInAfterFee * pool.s_reserve1) / (pool.s_reserve0 * FEE_BASE + amountInAfterFee);

        // Exact match on minAmountOut — should not revert
        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t0, amountIn, expectedOut, block.timestamp);

        assertEq(amountOut, expectedOut);
    }

    function test_swap_consecutiveSwaps() public {
        address t0 = pm.getToken0(poolId);

        uint256 amountIn = 10e18;

        vm.prank(bob);
        uint256 out1 = pm.swap(poolId, t0, amountIn, 0, block.timestamp);

        // Second swap in same direction gets less output (price moved)
        _fundActor(bob); // ensure enough balance
        vm.prank(bob);
        uint256 out2 = pm.swap(poolId, t0, amountIn, 0, block.timestamp);

        assertLt(out2, out1);
    }
}
