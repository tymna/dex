// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ERC1155} from "@vectorized/solady/src/tokens/ERC1155.sol";
import {Ownable} from "@vectorized/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "@vectorized/solady/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "@vectorized/solady/src/utils/FixedPointMathLib.sol";
import {ReentrancyGuard} from "@vectorized/solady/src/utils/ReentrancyGuard.sol";

import {
    ZeroAddress,
    SameToken,
    PoolAlreadyExists,
    ZeroAmountNotAllowed,
    PoolDoesNotExists,
    InsufficientLiquidity,
    InvalidToken,
    TokenNotSupported,
    SlippageExceeded,
    InsufficientOutputAmount,
    DeadlineExceeded,
    InvariantViolation
} from "./Errors.sol";
// reserve0 * reserve1 >= k

contract PoolManager is ERC1155, Ownable, ReentrancyGuard {
    // ---- TYPES ---- //
    struct Pool {
        uint256 s_reserve0;
        uint256 s_reserve1;
        uint256 s_totalShares;
        uint256 s_kLast;
    }

    mapping(bytes32 => Pool) private s_pools;
    mapping(bytes32 => address) private s_poolToken0;
    mapping(bytes32 => address) private s_poolToken1;
    mapping(address => bool) private s_supportedToken;

    // ---- STATE VARIABLES ---- //
    uint256 public constant MIN_LIQUIDITY = 1e3;
    address public constant DEAD_ADDRESS = address(0xdead);
    uint256 public constant FEE = 1;
    uint256 public constant FEE_BASE = 100;

    // ---- EVENTS ---- //
    event PoolCreated(bytes32 indexed poolId, address indexed token0, address indexed token1);
    event LiquidityAdded(
        bytes32 indexed poolId, address indexed provider, uint256 amount0, uint256 amount1, uint256 sharesMinted
    );
    event LiquidityRemoved(
        bytes32 indexed poolId, address indexed provider, uint256 amount0, uint256 amount1, uint256 sharesBurned
    );
    event Swap(
        bytes32 indexed poolId,
        address indexed swapper,
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOut
    );

    // ---- FUNCTIONS ---- //

    constructor(address owner) {
        _initializeOwner(owner);
    }

    function uri(uint256 id) public view override returns (string memory) {
        // implementation
    }

    // ---- EXTERNAL ---- //

    // pool - new id of erc1155
    function createPool(address token0, address token1, uint256 amount0, uint256 amount1, uint256 deadline)
        external
        nonReentrant
        returns (bytes32 poolId, uint256 lp)
    {
        // -- F:
        if (block.timestamp > deadline) revert DeadlineExceeded();
        if (token0 == address(0) || token1 == address(0)) revert ZeroAddress();
        if (!s_supportedToken[token0] || !s_supportedToken[token1]) revert TokenNotSupported();
        if (token0 == token1) revert SameToken();
        if (amount0 == 0 || amount1 == 0) revert ZeroAmountNotAllowed();

        poolId = _getPoolId(token0, token1);
        if (s_pools[poolId].s_reserve0 != 0) revert PoolAlreadyExists();

        // -- E:
        (address sorted0, address sorted1, uint256 sortedAmount0, uint256 sortedAmount1) =
            token0 < token1 ? (token0, token1, amount0, amount1) : (token1, token0, amount1, amount0);

        uint256 totalShares = FixedPointMathLib.sqrt(sortedAmount0 * sortedAmount1);
        if (totalShares <= MIN_LIQUIDITY) revert InsufficientOutputAmount();
        lp = totalShares - MIN_LIQUIDITY;

        // -- I:
        SafeTransferLib.safeTransferFrom(sorted0, msg.sender, address(this), sortedAmount0);
        SafeTransferLib.safeTransferFrom(sorted1, msg.sender, address(this), sortedAmount1);

        uint256 balance0 = SafeTransferLib.balanceOf(sorted0, address(this));
        uint256 balance1 = SafeTransferLib.balanceOf(sorted1, address(this));

        s_pools[poolId] = Pool({
            s_reserve0: balance0, s_reserve1: balance1, s_totalShares: totalShares, s_kLast: balance0 * balance1
        });

        s_poolToken0[poolId] = sorted0;
        s_poolToken1[poolId] = sorted1;

        _mint(DEAD_ADDRESS, uint256(poolId), MIN_LIQUIDITY, "");
        _mint(msg.sender, uint256(poolId), lp, "");

        emit PoolCreated(poolId, token0, token1);
    }

    function addLiquidity(
        bytes32 poolId,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external nonReentrant returns (uint256 lp) {
        Pool storage pool = s_pools[poolId];
        address token0Addr = s_poolToken0[poolId];
        address token1Addr = s_poolToken1[poolId];

        uint256 balance0 = SafeTransferLib.balanceOf(token0Addr, address(this));
        uint256 balance1 = SafeTransferLib.balanceOf(token1Addr, address(this));

        pool.s_reserve0 = balance0;
        pool.s_reserve1 = balance1;
        uint256 reserve0 = balance0;

        // -- F:
        if (block.timestamp > deadline) revert DeadlineExceeded();
        if (reserve0 == 0) revert PoolDoesNotExists();
        if (amount0Desired == 0 || amount1Desired == 0) revert ZeroAmountNotAllowed();

        // -- E:
        // dy/dx = y/x
        // dy = dx * y / x
        uint256 amount0;
        uint256 amount1;

        uint256 reserve1 = balance1;
        uint256 amount1Optimal = amount0Desired * reserve1 / reserve0;

        if (amount1Optimal <= amount1Desired) {
            amount0 = amount0Desired;
            amount1 = amount1Optimal;
        } else {
            uint256 amount0Optimal = amount1Desired * reserve0 / reserve1;
            amount0 = amount0Optimal;
            amount1 = amount1Desired;
        }
        if (amount0 == 0 || amount1 == 0) revert InsufficientOutputAmount();
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        uint256 totalShares = pool.s_totalShares;
        uint256 shares0 = amount0 * totalShares / reserve0;
        uint256 shares1 = amount1 * totalShares / reserve1;
        // S = min(dx/x, dy/y) * T — prevents overminting
        uint256 sharesToMint = shares0 < shares1 ? shares0 : shares1;
        if (sharesToMint == 0) revert InsufficientOutputAmount();

        // -- I:
        address token0 = s_poolToken0[poolId];
        address token1 = s_poolToken1[poolId];
        SafeTransferLib.safeTransferFrom(token0, msg.sender, address(this), amount0);
        SafeTransferLib.safeTransferFrom(token1, msg.sender, address(this), amount1);

        pool.s_reserve0 += amount0;
        pool.s_reserve1 += amount1;
        pool.s_totalShares += sharesToMint;
        lp = sharesToMint;
        _mint(msg.sender, uint256(poolId), sharesToMint, "");

        // -- PI:
        if (pool.s_reserve0 * pool.s_reserve1 < pool.s_kLast) revert InvariantViolation();
        pool.s_kLast = pool.s_reserve0 * pool.s_reserve1;

        emit LiquidityAdded(poolId, msg.sender, amount0, amount1, sharesToMint);
    }

    function removeLiquidity(bytes32 poolId, uint256 lp, uint256 amount0Min, uint256 amount1Min, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        Pool storage pool = s_pools[poolId];
        address token0Addr = s_poolToken0[poolId];
        address token1Addr = s_poolToken1[poolId];

        uint256 balance0 = SafeTransferLib.balanceOf(token0Addr, address(this));
        uint256 balance1 = SafeTransferLib.balanceOf(token1Addr, address(this));

        pool.s_reserve0 = balance0;
        pool.s_reserve1 = balance1;

        // -- F:
        if (block.timestamp > deadline) revert DeadlineExceeded();

        // S / T = dx / x
        // dx = S * x / T
        // dy = S * y / T
        uint256 reserve0 = balance0;
        if (reserve0 == 0) revert PoolDoesNotExists();
        if (lp == 0) revert ZeroAmountNotAllowed();
        if (balanceOf(msg.sender, uint256(poolId)) < lp) revert InsufficientLiquidity();

        uint256 totalShares = pool.s_totalShares;
        amount0 = lp * reserve0 / totalShares;
        amount1 = lp * pool.s_reserve1 / totalShares;
        if (amount0 == 0 || amount1 == 0) revert InsufficientOutputAmount();
        if (amount0 < amount0Min || amount1 < amount1Min) revert SlippageExceeded();

        pool.s_reserve0 -= amount0;
        pool.s_reserve1 -= amount1;
        pool.s_totalShares -= lp;

        _burn(msg.sender, uint256(poolId), lp);
        SafeTransferLib.safeTransfer(s_poolToken0[poolId], msg.sender, amount0);
        SafeTransferLib.safeTransfer(s_poolToken1[poolId], msg.sender, amount1);

        // -- PI:
        if (pool.s_reserve0 * pool.s_reserve1 > pool.s_kLast) revert InvariantViolation();
        pool.s_kLast = pool.s_reserve0 * pool.s_reserve1;

        emit LiquidityRemoved(poolId, msg.sender, amount0, amount1, lp);
    }

    function swap(bytes32 poolId, address tokenToSwap, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        Pool storage pool = s_pools[poolId];
        address token0Addr = s_poolToken0[poolId];
        address token1Addr = s_poolToken1[poolId];

        uint256 balance0 = SafeTransferLib.balanceOf(token0Addr, address(this));
        uint256 balance1 = SafeTransferLib.balanceOf(token1Addr, address(this));

        pool.s_reserve0 = balance0;
        pool.s_reserve1 = balance1;

        // -- F:
        if (block.timestamp > deadline) revert DeadlineExceeded();

        uint256 reserve0 = balance0;
        uint256 reserve1 = balance1;
        address token0 = s_poolToken0[poolId];
        address token1 = s_poolToken1[poolId];

        if (reserve0 == 0) revert PoolDoesNotExists();
        if (amountIn == 0) revert ZeroAmountNotAllowed();
        if (tokenToSwap != token0 && tokenToSwap != token1) revert InvalidToken();

        bool isToken0 = tokenToSwap == token0;
        address tokenOut = isToken0 ? token1 : token0;

        (uint256 reserveIn, uint256 reserveOut) = isToken0 ? (reserve0, reserve1) : (reserve1, reserve0);

        // dy = y * dx * (1 - f) / (x + dx * (1 - f))
        uint256 amountInAfterFee = amountIn * (FEE_BASE - FEE);
        amountOut = (amountInAfterFee * reserveOut) / ((reserveIn * FEE_BASE) + amountInAfterFee);
        if (amountOut == 0) revert InsufficientOutputAmount();
        if (amountOut < minAmountOut) revert SlippageExceeded();

        if (isToken0) {
            pool.s_reserve0 += amountIn;
            pool.s_reserve1 -= amountOut;
        } else {
            pool.s_reserve1 += amountIn;
            pool.s_reserve0 -= amountOut;
        }

        SafeTransferLib.safeTransferFrom(tokenToSwap, msg.sender, address(this), amountIn);
        SafeTransferLib.safeTransfer(tokenOut, msg.sender, amountOut);

        // -- PI:
        if (pool.s_reserve0 * pool.s_reserve1 < pool.s_kLast) revert InvariantViolation();
        pool.s_kLast = pool.s_reserve0 * pool.s_reserve1;

        emit Swap(poolId, msg.sender, tokenToSwap, amountIn, tokenOut, amountOut);
    }

    function setSupportedToken(address token, bool supported) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        s_supportedToken[token] = supported;
    }

    // ---- INTERNAL ---- //
    function _getPoolId(address token0, address token1) internal pure returns (bytes32 poolId) {
        assembly {
            let t0 := token0
            let t1 := token1
            // sort
            if gt(t0, t1) {
                t0 := token1
                t1 := token0
            }
            mstore(0x00, shl(96, t0)) // 32 bytes, address = 20 bytes, shift for 12 * 8 to get address without zeros
            mstore(0x14, shl(96, t1))
            poolId := keccak256(0x00, 0x28)
        }
    }

    // ---- GETTERS ---- //
    function getPool(bytes32 poolId) external view returns (Pool memory) {
        return s_pools[poolId];
    }

    function getToken0(bytes32 poolId) external view returns (address) {
        return s_poolToken0[poolId];
    }

    function getToken1(bytes32 poolId) external view returns (address) {
        return s_poolToken1[poolId];
    }
}

