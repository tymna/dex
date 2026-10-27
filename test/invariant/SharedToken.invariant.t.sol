// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "src/PoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Random swaps / adds / removes / donations across two pools sharing tokenA.
contract SharedTokenHandler is Test {
    PoolManager public pm;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    bytes32[2] public pools;
    address[2] public actors;

    // net tokens each pool received: in - out
    mapping(bytes32 => mapping(address => uint256)) public ghost_in;
    mapping(bytes32 => mapping(address => uint256)) public ghost_out;

    constructor(PoolManager pm_, MockERC20 a, MockERC20 b, MockERC20 c, bytes32 ab, bytes32 ac) {
        pm = pm_;
        tokenA = a;
        tokenB = b;
        tokenC = c;
        pools = [ab, ac];
        actors = [makeAddr("lp1"), makeAddr("lp2")];
        for (uint256 i; i < 2; i++) {
            vm.startPrank(actors[i]);
            a.approve(address(pm_), type(uint256).max);
            b.approve(address(pm_), type(uint256).max);
            c.approve(address(pm_), type(uint256).max);
            vm.stopPrank();
        }
    }

    function recordCreate(bytes32 poolId, uint256 amount0, uint256 amount1) external {
        ghost_in[poolId][pm.getToken0(poolId)] += amount0;
        ghost_in[poolId][pm.getToken1(poolId)] += amount1;
    }

    function swap(uint256 poolSeed, uint256 actorSeed, bool zeroForOne, uint256 amountIn) external {
        bytes32 poolId = pools[poolSeed % 2];
        address actor = actors[actorSeed % 2];
        amountIn = bound(amountIn, 1e6, 1000e18);
        (address tokenIn, address tokenOut) =
            zeroForOne ? (pm.getToken0(poolId), pm.getToken1(poolId)) : (pm.getToken1(poolId), pm.getToken0(poolId));
        MockERC20(tokenIn).mint(actor, amountIn);

        vm.prank(actor);
        try pm.swap(poolId, tokenIn, amountIn, 0, block.timestamp) returns (uint256 amountOut) {
            ghost_in[poolId][tokenIn] += amountIn;
            ghost_out[poolId][tokenOut] += amountOut;
        } catch {}
    }

    function addLiquidity(uint256 poolSeed, uint256 actorSeed, uint256 amount0, uint256 amount1) external {
        bytes32 poolId = pools[poolSeed % 2];
        address actor = actors[actorSeed % 2];
        amount0 = bound(amount0, 1e6, 500e18);
        amount1 = bound(amount1, 1e6, 500e18);
        MockERC20 t0 = MockERC20(pm.getToken0(poolId));
        MockERC20 t1 = MockERC20(pm.getToken1(poolId));
        t0.mint(actor, amount0);
        t1.mint(actor, amount1);
        uint256 bal0 = t0.balanceOf(actor);
        uint256 bal1 = t1.balanceOf(actor);

        vm.prank(actor);
        try pm.addLiquidity(poolId, amount0, amount1, 0, 0, block.timestamp) {
            ghost_in[poolId][address(t0)] += bal0 - t0.balanceOf(actor);
            ghost_in[poolId][address(t1)] += bal1 - t1.balanceOf(actor);
        } catch {}
    }

    function removeLiquidity(uint256 poolSeed, uint256 actorSeed, uint256 lp) external {
        bytes32 poolId = pools[poolSeed % 2];
        address actor = actors[actorSeed % 2];
        uint256 lpBalance = pm.balanceOf(actor, uint256(poolId));
        if (lpBalance == 0) return;
        lp = bound(lp, 1, lpBalance);

        vm.prank(actor);
        try pm.removeLiquidity(poolId, lp, 0, 0, block.timestamp) returns (uint256 amount0, uint256 amount1) {
            ghost_out[poolId][pm.getToken0(poolId)] += amount0;
            ghost_out[poolId][pm.getToken1(poolId)] += amount1;
        } catch {}
    }

    /// @dev direct transfer — must not be credited to any pool
    function donate(uint256 amount) external {
        amount = bound(amount, 1, 100e18);
        tokenA.mint(address(pm), amount);
    }
}

contract SharedTokenInvariantTest is Test {
    PoolManager public pm;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    MockERC20 public tokenC;
    SharedTokenHandler public handler;

    bytes32 internal poolAB;
    bytes32 internal poolAC;

    function setUp() public {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        tokenC = new MockERC20("Token C", "TKC", 18);
        pm = new PoolManager(address(this));
        pm.setSupportedToken(address(tokenA), true);
        pm.setSupportedToken(address(tokenB), true);
        pm.setSupportedToken(address(tokenC), true);

        // creator keeps its LP so pools never empty out
        address creator = makeAddr("creator");
        tokenA.mint(creator, 200e18);
        tokenB.mint(creator, 100e18);
        tokenC.mint(creator, 100e18);
        vm.startPrank(creator);
        tokenA.approve(address(pm), type(uint256).max);
        tokenB.approve(address(pm), type(uint256).max);
        tokenC.approve(address(pm), type(uint256).max);
        (poolAB,) = pm.createPool(address(tokenA), address(tokenB), 100e18, 100e18, block.timestamp);
        (poolAC,) = pm.createPool(address(tokenA), address(tokenC), 100e18, 100e18, block.timestamp);
        vm.stopPrank();

        handler = new SharedTokenHandler(pm, tokenA, tokenB, tokenC, poolAB, poolAC);
        handler.recordCreate(poolAB, 100e18, 100e18);
        handler.recordCreate(poolAC, 100e18, 100e18);

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = SharedTokenHandler.swap.selector;
        selectors[1] = SharedTokenHandler.addLiquidity.selector;
        selectors[2] = SharedTokenHandler.removeLiquidity.selector;
        selectors[3] = SharedTokenHandler.donate.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev each pool's stored reserves never exceed what was put in minus what was taken out
    function invariant_reservesLeOwed() public view {
        _assertReservesLeOwed(poolAB);
        _assertReservesLeOwed(poolAC);
    }

    /// @dev sum of all pools' reserves of a token is always backed by the contract balance
    function invariant_sumOfReservesLeBalance() public view {
        PoolManager.Pool memory ab = pm.getPool(poolAB);
        PoolManager.Pool memory ac = pm.getPool(poolAC);

        uint256 sumA = _reserveOf(poolAB, ab, address(tokenA)) + _reserveOf(poolAC, ac, address(tokenA));
        uint256 sumB = _reserveOf(poolAB, ab, address(tokenB));
        uint256 sumC = _reserveOf(poolAC, ac, address(tokenC));

        assertLe(sumA, tokenA.balanceOf(address(pm)), "tokenA under-backed");
        assertLe(sumB, tokenB.balanceOf(address(pm)), "tokenB under-backed");
        assertLe(sumC, tokenC.balanceOf(address(pm)), "tokenC under-backed");
    }

    function _assertReservesLeOwed(bytes32 poolId) internal view {
        PoolManager.Pool memory pool = pm.getPool(poolId);
        address t0 = pm.getToken0(poolId);
        address t1 = pm.getToken1(poolId);
        assertLe(pool.s_reserve0, handler.ghost_in(poolId, t0) - handler.ghost_out(poolId, t0), "reserve0 > owed");
        assertLe(pool.s_reserve1, handler.ghost_in(poolId, t1) - handler.ghost_out(poolId, t1), "reserve1 > owed");
    }

    function _reserveOf(bytes32 poolId, PoolManager.Pool memory pool, address token) internal view returns (uint256) {
        return pm.getToken0(poolId) == token ? pool.s_reserve0 : pool.s_reserve1;
    }
}
