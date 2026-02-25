// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "../unit/Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

contract SwapFuzzTest is Base {
    bytes32 internal poolId;

    uint256 internal constant FEE = 1;
    uint256 internal constant FEE_BASE = 100;

    function setUp() public override {
        super.setUp();
        (poolId,) = _createPoolAndAddLiquidity(alice, 100e18, 100e18);
    }

    /// @dev For any valid amountIn swapping token0, k never decreases,
    ///      reserves update correctly, amountOut matches formula.
    function testFuzz_swap_token0PreservesKInvariant(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, INITIAL_BALANCE);
        address t0 = pm.getToken0(poolId);

        PoolManager.Pool memory before_ = pm.getPool(poolId);

        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t0, amountIn, 0, block.timestamp);

        _assertSwapInvariants(before_, amountIn, amountOut, true);
    }

    /// @dev Same invariant for the opposite direction (token1 → token0).
    function testFuzz_swap_token1PreservesKInvariant(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, INITIAL_BALANCE);
        address t1 = pm.getToken1(poolId);

        PoolManager.Pool memory before_ = pm.getPool(poolId);

        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t1, amountIn, 0, block.timestamp);

        _assertSwapInvariants(before_, amountIn, amountOut, false);
    }

    /// @dev Two consecutive swaps in the same direction: k grows monotonically,
    ///      second swap gets strictly less output (price impact).
    function testFuzz_swap_consecutiveKMonotonicallyGrows(uint256 amountIn1, uint256 amountIn2) public {
        amountIn1 = bound(amountIn1, 1e15, INITIAL_BALANCE / 2);
        amountIn2 = bound(amountIn2, 1e15, INITIAL_BALANCE / 2);
        address t0 = pm.getToken0(poolId);

        PoolManager.Pool memory snap0 = pm.getPool(poolId);

        vm.prank(bob);
        uint256 out1 = pm.swap(poolId, t0, amountIn1, 0, block.timestamp);

        PoolManager.Pool memory snap1 = pm.getPool(poolId);
        uint256 k1 = snap1.s_reserve0 * snap1.s_reserve1;
        assertGe(k1, snap0.s_reserve0 * snap0.s_reserve1, "k decreased after swap 1");

        _fundActor(bob);
        vm.prank(bob);
        uint256 out2 = pm.swap(poolId, t0, amountIn1, 0, block.timestamp);

        PoolManager.Pool memory snap2 = pm.getPool(poolId);
        uint256 k2 = snap2.s_reserve0 * snap2.s_reserve1;
        assertGe(k2, k1, "k decreased after swap 2");

        // Same amountIn, second gets less (price moved)
        assertLt(out2, out1, "second swap should get less output");
    }

    /// @dev Swap on a skewed pool (after a prior swap) still holds all invariants.
    function testFuzz_swap_skewedPoolPreservesInvariants(uint256 skewAmount, uint256 amountIn) public {
        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);

        // Skew the pool with a swap
        skewAmount = bound(skewAmount, 1e15, INITIAL_BALANCE / 2);
        vm.prank(bob);
        pm.swap(poolId, t0, skewAmount, 0, block.timestamp);

        // Now fuzz a swap in the opposite direction on skewed reserves
        PoolManager.Pool memory before_ = pm.getPool(poolId);
        amountIn = bound(amountIn, 1e15, INITIAL_BALANCE / 2);
        _fundActor(bob);

        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t1, amountIn, 0, block.timestamp);

        _assertSwapInvariants(before_, amountIn, amountOut, false);
    }

    /// @dev amountOut is always strictly less than reserveOut (can never drain the pool).
    function testFuzz_swap_neverDrainsReserve(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e15, type(uint128).max);
        address t0 = pm.getToken0(poolId);

        PoolManager.Pool memory before_ = pm.getPool(poolId);

        // Mint enough tokens for large swaps
        MockERC20(t0).mint(bob, amountIn);

        vm.prank(bob);
        uint256 amountOut = pm.swap(poolId, t0, amountIn, 0, block.timestamp);

        assertLt(amountOut, before_.s_reserve1, "drained full reserveOut");
        PoolManager.Pool memory after_ = pm.getPool(poolId);
        assertGt(after_.s_reserve1, 0, "reserve1 hit zero");
    }

    /* ───── Internal ───── */

    function _assertSwapInvariants(PoolManager.Pool memory before_, uint256 amountIn, uint256 amountOut, bool isToken0)
        internal
        view
    {
        PoolManager.Pool memory after_ = pm.getPool(poolId);

        // k never decreases
        assertGe(after_.s_reserve0 * after_.s_reserve1, before_.s_reserve0 * before_.s_reserve1, "k decreased");

        // kLast updated
        assertEq(after_.s_kLast, after_.s_reserve0 * after_.s_reserve1, "kLast stale");

        // Reserve accounting
        if (isToken0) {
            assertEq(after_.s_reserve0, before_.s_reserve0 + amountIn, "reserve0 in");
            assertEq(after_.s_reserve1, before_.s_reserve1 - amountOut, "reserve1 out");
        } else {
            assertEq(after_.s_reserve1, before_.s_reserve1 + amountIn, "reserve1 in");
            assertEq(after_.s_reserve0, before_.s_reserve0 - amountOut, "reserve0 out");
        }

        // amountOut matches formula
        (uint256 reserveIn, uint256 reserveOut) =
            isToken0 ? (before_.s_reserve0, before_.s_reserve1) : (before_.s_reserve1, before_.s_reserve0);

        uint256 amountInAfterFee = amountIn * (FEE_BASE - FEE);
        uint256 expectedOut = (amountInAfterFee * reserveOut) / (reserveIn * FEE_BASE + amountInAfterFee);
        assertEq(amountOut, expectedOut, "amountOut formula mismatch");
    }
}
