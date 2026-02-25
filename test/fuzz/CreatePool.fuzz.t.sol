// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Base} from "../unit/Base.t.sol";
import {PoolManager} from "src/PoolManager.sol";

contract CreatePoolFuzzTest is Base {
    function setUp() public override {
        super.setUp();
    }

    function testFuzz_poolId_isCommutative(address a, address b) public pure {
        vm.assume(a != address(0) && b != address(0));
        vm.assume(a != b);

        bytes32 id1 = _computePoolId(a, b);
        bytes32 id2 = _computePoolId(b, a);

        assertEq(id1, id2);
    }

    function testFuzz_poolId_noCollision(address a, address b, address c) public pure {
        vm.assume(a != address(0) && b != address(0) && c != address(0));
        vm.assume(a != b && a != c && b != c);

        bytes32 id_ab = _computePoolId(a, b);
        bytes32 id_ac = _computePoolId(a, c);

        assertTrue(id_ab != id_ac);
    }

    function _computePoolId(address token0, address token1) internal pure returns (bytes32 poolId) {
        assembly {
            let t0 := token0
            let t1 := token1
            if gt(t0, t1) {
                t0 := token1
                t1 := token0
            }
            mstore(0x00, shl(96, t0))
            mstore(0x14, shl(96, t1))
            poolId := keccak256(0x00, 0x28)
        }
    }
}
