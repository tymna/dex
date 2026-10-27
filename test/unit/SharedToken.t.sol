// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "./Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Two pools share tokenA (A/B and A/C). Each pool must only price against its own reserves.
contract SharedTokenTest is Base {
    MockERC20 public tokenC;

    bytes32 internal poolAB;
    bytes32 internal poolAC;
    uint256 internal bobLp;
    uint256 internal aliceLp;

    function setUp() public override {
        super.setUp();
        tokenC = new MockERC20("Token C", "TKC", 18);
        pm.setSupportedToken(address(tokenC), true);
        tokenC.mint(alice, INITIAL_BALANCE);
        vm.prank(alice);
        tokenC.approve(address(pm), type(uint256).max);

        // deep A/C pool, shallow A/B pool
        vm.prank(alice);
        (poolAC, aliceLp) = pm.createPool(address(tokenA), address(tokenC), 100e18, 100e18, block.timestamp);
        vm.prank(bob);
        (poolAB, bobLp) = pm.createPool(address(tokenA), address(tokenB), 1e18, 1e18, block.timestamp);
    }

    /* ───── Isolation ───── */

    function test_sharedToken_reservesAreIsolated() public view {
        assertEq(_reserveOf(poolAC, address(tokenA)), 100e18);
        assertEq(_reserveOf(poolAB, address(tokenA)), 1e18);
        assertEq(tokenA.balanceOf(address(pm)), 101e18);
    }

    function test_sharedToken_swapCannotDrainOtherPool() public {
        PoolManager.Pool memory acBefore = pm.getPool(poolAC);
        uint256 abReserveA = _reserveOf(poolAB, address(tokenA));

        // dump all of bob's B into the shallow pool
        uint256 amountIn = tokenB.balanceOf(bob);
        vm.prank(bob);
        uint256 amountOut = pm.swap(poolAB, address(tokenB), amountIn, 0, block.timestamp);

        // output bounded by A/B's own reserve, not by contract balance
        assertLt(amountOut, abReserveA);

        // A/C untouched
        PoolManager.Pool memory acAfter = pm.getPool(poolAC);
        assertEq(acAfter.s_reserve0, acBefore.s_reserve0);
        assertEq(acAfter.s_reserve1, acBefore.s_reserve1);
        assertGe(
            tokenA.balanceOf(address(pm)), _reserveOf(poolAC, address(tokenA)) + _reserveOf(poolAB, address(tokenA))
        );

        // A/C LP can still withdraw everything they are owed
        PoolManager.Pool memory ac = pm.getPool(poolAC);
        uint256 expectedA = aliceLp * _reserveOf(poolAC, address(tokenA)) / ac.s_totalShares;
        uint256 balBefore = tokenA.balanceOf(alice);
        vm.prank(alice);
        pm.removeLiquidity(poolAC, aliceLp, 0, 0, block.timestamp);
        assertEq(tokenA.balanceOf(alice), balBefore + expectedA);
    }

    function test_sharedToken_removeLiquidityOnlyPaysOwnReserves() public {
        uint256 balBefore = tokenA.balanceOf(bob);

        vm.prank(bob);
        (uint256 amount0, uint256 amount1) = pm.removeLiquidity(poolAB, bobLp, 0, 0, block.timestamp);

        uint256 amountA = pm.getToken0(poolAB) == address(tokenA) ? amount0 : amount1;
        assertLt(amountA, 1e18);
        assertEq(tokenA.balanceOf(bob), balBefore + amountA);

        // A/C still fully backed
        assertEq(_reserveOf(poolAC, address(tokenA)), 100e18);
        assertGe(tokenA.balanceOf(address(pm)), 100e18 + _reserveOf(poolAB, address(tokenA)));
    }

    function test_sharedToken_donationDoesNotShiftPrice() public {
        PoolManager.Pool memory before_ = pm.getPool(poolAB);

        // direct transfer to the contract is not credited to any pool
        vm.prank(alice);
        tokenA.transfer(address(pm), 50e18);

        vm.prank(bob);
        pm.swap(poolAB, address(tokenB), 1e17, 0, block.timestamp);

        PoolManager.Pool memory after_ = pm.getPool(poolAB);
        address t0 = pm.getToken0(poolAB);
        (uint256 reserveA, uint256 reserveB) =
            t0 == address(tokenA) ? (before_.s_reserve0, before_.s_reserve1) : (before_.s_reserve1, before_.s_reserve0);
        uint256 expectedOut = (1e17 * 99 * reserveA) / (reserveB * 100 + 1e17 * 99);
        assertEq(_reserveOf(poolAB, address(tokenA)), reserveA - expectedOut);
        assertEq(after_.s_kLast, after_.s_reserve0 * after_.s_reserve1);
    }

    /* ───── Internal ───── */

    function _reserveOf(bytes32 poolId, address token) internal view returns (uint256) {
        PoolManager.Pool memory pool = pm.getPool(poolId);
        return pm.getToken0(poolId) == token ? pool.s_reserve0 : pool.s_reserve1;
    }
}
