// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "src/PoolManager.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

abstract contract Base is Test {
    PoolManager public pm;
    MockERC20 public tokenA;
    MockERC20 public tokenB;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    uint256 internal constant INITIAL_BALANCE = 1000e18;

    function setUp() public virtual {
        tokenA = new MockERC20("Token A", "TKA", 18);
        tokenB = new MockERC20("Token B", "TKB", 18);
        pm = new PoolManager(address(this));
        // Add supported tokens
        pm.setSupportedToken(address(tokenA), true);
        pm.setSupportedToken(address(tokenB), true);

        _fundActor(alice);
        _fundActor(bob);
    }

    /* ───── Helpers ───── */

    function _fundActor(address actor) internal {
        tokenA.mint(actor, INITIAL_BALANCE);
        tokenB.mint(actor, INITIAL_BALANCE);
        vm.startPrank(actor);
        tokenA.approve(address(pm), type(uint256).max);
        tokenB.approve(address(pm), type(uint256).max);
        vm.stopPrank();
    }

    function _createPool(address actor) internal returns (bytes32 poolId) {
        vm.prank(actor);
        (poolId,) = pm.createPool(address(tokenA), address(tokenB), 1e18, 1e18, block.timestamp);
    }

    function _createPoolAndAddLiquidity(address actor, uint256 amount0, uint256 amount1)
        internal
        returns (bytes32 poolId, uint256 lp)
    {
        vm.prank(actor);
        (poolId, lp) = pm.createPool(address(tokenA), address(tokenB), amount0, amount1, block.timestamp);
    }
}
