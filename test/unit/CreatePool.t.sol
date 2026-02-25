// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "./Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {FixedPointMathLib} from "@vectorized/solady/src/utils/FixedPointMathLib.sol";
import {ZeroAddress, SameToken, PoolAlreadyExists, ZeroAmountNotAllowed, InsufficientOutputAmount} from "src/Errors.sol";

contract CreatePoolTest is Base {
    uint256 internal constant MIN_LIQUIDITY = 1e3;
    address internal constant DEAD_ADDRESS = address(0xdead);
    uint256 internal constant POOL_AMOUNT = 1e18;

    function setUp() public override {
        super.setUp();
    }

    /* ───── Happy Path ───── */

    function test_createPool_setsReserves() public {
        bytes32 poolId = _createPool(alice);

        PoolManager.Pool memory pool = pm.getPool(poolId);
        assertEq(pool.s_reserve0, POOL_AMOUNT);
        assertEq(pool.s_reserve1, POOL_AMOUNT);
        assertEq(pool.s_kLast, POOL_AMOUNT * POOL_AMOUNT);
    }

    function test_createPool_storesTokens() public {
        bytes32 poolId = _createPool(alice);

        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);

        assertTrue(t0 < t1);
        assertTrue(
            (t0 == address(tokenA) && t1 == address(tokenB))
                || (t0 == address(tokenB) && t1 == address(tokenA))
        );
    }

    function test_createPool_mintsLpToDeadAddress() public {
        bytes32 poolId = _createPool(alice);

        uint256 deadBalance = pm.balanceOf(DEAD_ADDRESS, uint256(poolId));
        assertEq(deadBalance, MIN_LIQUIDITY);
    }

    function test_createPool_mintsLpToCreator() public {
        uint256 expectedTotal = FixedPointMathLib.sqrt(POOL_AMOUNT * POOL_AMOUNT);
        uint256 expectedLp = expectedTotal - MIN_LIQUIDITY;

        vm.prank(alice);
        (bytes32 poolId, uint256 lp) = pm.createPool(address(tokenA), address(tokenB), POOL_AMOUNT, POOL_AMOUNT, block.timestamp);

        assertEq(lp, expectedLp);
        assertEq(pm.balanceOf(alice, uint256(poolId)), expectedLp);
    }

    function test_createPool_totalSharesEqualsSqrt() public {
        uint256 a0 = 4e18;
        uint256 a1 = 9e18;
        uint256 expectedTotal = FixedPointMathLib.sqrt(a0 * a1);

        vm.prank(alice);
        (bytes32 poolId,) = pm.createPool(address(tokenA), address(tokenB), a0, a1, block.timestamp);

        PoolManager.Pool memory pool = pm.getPool(poolId);
        assertEq(pool.s_totalShares, expectedTotal);
    }

    function test_createPool_transfersTokensFromCaller() public {
        uint256 balA_before = tokenA.balanceOf(alice);
        uint256 balB_before = tokenB.balanceOf(alice);

        _createPool(alice);

        assertEq(tokenA.balanceOf(alice), balA_before - POOL_AMOUNT);
        assertEq(tokenB.balanceOf(alice), balB_before - POOL_AMOUNT);
    }

    function test_createPool_emitsPoolCreated() public {
        vm.expectEmit(false, true, true, true, address(pm));
        emit PoolManager.PoolCreated(bytes32(0), address(tokenA), address(tokenB));

        vm.prank(alice);
        pm.createPool(address(tokenA), address(tokenB), POOL_AMOUNT, POOL_AMOUNT, block.timestamp);
    }

    /* ───── Revert Conditions ───── */

    function test_revertIf_token0IsZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        pm.createPool(address(0), address(tokenB), POOL_AMOUNT, POOL_AMOUNT, block.timestamp);
    }

    function test_revertIf_token1IsZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAddress.selector);
        pm.createPool(address(tokenA), address(0), POOL_AMOUNT, POOL_AMOUNT, block.timestamp);
    }

    function test_revertIf_sameToken() public {
        vm.prank(alice);
        vm.expectRevert(SameToken.selector);
        pm.createPool(address(tokenA), address(tokenA), POOL_AMOUNT, POOL_AMOUNT, block.timestamp);
    }

    function test_revertIf_zeroAmount0() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmountNotAllowed.selector);
        pm.createPool(address(tokenA), address(tokenB), 0, POOL_AMOUNT, block.timestamp);
    }

    function test_revertIf_zeroAmount1() public {
        vm.prank(alice);
        vm.expectRevert(ZeroAmountNotAllowed.selector);
        pm.createPool(address(tokenA), address(tokenB), POOL_AMOUNT, 0, block.timestamp);
    }

    function test_revertIf_tooSmallForMinLiquidity() public {
        vm.prank(alice);
        vm.expectRevert(InsufficientOutputAmount.selector);
        pm.createPool(address(tokenA), address(tokenB), 100, 100, block.timestamp);
    }

    function test_revertIf_poolAlreadyExists() public {
        _createPool(alice);

        vm.prank(bob);
        vm.expectRevert(PoolAlreadyExists.selector);
        pm.createPool(address(tokenA), address(tokenB), POOL_AMOUNT, POOL_AMOUNT, block.timestamp);
    }

    /* ───── Getters ───── */

    function test_uri_returnsEmptyString() public view {
        bytes32 poolId = keccak256("any");
        string memory result = pm.uri(uint256(poolId));
        assertEq(bytes(result).length, 0);
    }

    /* ───── Edge Cases ───── */

    function test_createPool_reversedTokenOrder_succeeds() public {
        MockERC20 tokenX = new MockERC20("Token X", "TKX", 18);
        MockERC20 tokenY = new MockERC20("Token Y", "TKY", 18);
        pm.setSupportedToken(address(tokenX), true);
        pm.setSupportedToken(address(tokenY), true);

        (address first, address second) =
            address(tokenX) > address(tokenY) ? (address(tokenX), address(tokenY)) : (address(tokenY), address(tokenX));

        tokenX.mint(alice, INITIAL_BALANCE);
        tokenY.mint(alice, INITIAL_BALANCE);
        vm.startPrank(alice);
        tokenX.approve(address(pm), type(uint256).max);
        tokenY.approve(address(pm), type(uint256).max);

        (bytes32 poolId,) = pm.createPool(first, second, POOL_AMOUNT, POOL_AMOUNT, block.timestamp);
        vm.stopPrank();

        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);
        assertEq(t0, second);
        assertEq(t1, first);
        assertTrue(first > second);
    }

    function test_createPool_reversedTokenOrder_samePoolId() public {
        bytes32 poolId1 = _createPool(alice);

        vm.prank(bob);
        vm.expectRevert(PoolAlreadyExists.selector);
        pm.createPool(address(tokenB), address(tokenA), POOL_AMOUNT, POOL_AMOUNT, block.timestamp);

        address t0 = pm.getToken0(poolId1);
        address t1 = pm.getToken1(poolId1);
        assertTrue(t0 < t1);
    }
}
