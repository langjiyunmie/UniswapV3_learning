// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3Pool.sol";
import "./lib/Path.sol";
import "./lib/PoolAddress.sol";
import "./lib/TickMath.sol";

contract UniswapV3Quoter {
    using Path for bytes;

    // 用于传递单个池子报价参数的结构体
    struct QuoteSingleParams {
        address tokenIn; // 输入代币地址
        address tokenOut; // 输出代币地址
        uint24 fee; // 池子手续费等级
        uint256 amountIn; // 输入数量
        uint160 sqrtPriceLimitX96; // 最终 √价格限制（0 表示无）
    }

    address public immutable factory; // Uniswap V3 Factory 合约地址

    constructor(address factory_) {
        factory = factory_; // 部署时设置工厂地址
    }

    /// @notice 跨多池路径报价，返回最终 amountOut 及每池的价格变化
    function quote(bytes memory path, uint256 amountIn)
        public
        returns (
            uint256 amountOut, // 最终输出数量
            uint160[] memory sqrtPriceX96AfterList, // 每个池子 swap 后的 √价格
            int24[] memory tickAfterList // 每个池子 swap 后的 tick
        )
    {
        // 根据路径中包含的池子数量，初始化返回数组
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        tickAfterList = new int24[](path.numPools());

        uint256 i = 0;
        // 循环遍历路径中的每个池子
        while (true) {
            // 解码当前池子的 tokenIn、tokenOut、fee
            (address tokenIn, address tokenOut, uint24 fee) = path.decodeFirstPool();

            // 调用单池报价
            (
                uint256 amountOut_, // 当前池 swap 后的输出量
                uint160 sqrtPriceX96After, // 当前池 swap 后的 √价格
                int24 tickAfter // 当前池 swap 后的 tick
            ) = quoteSingle(
                QuoteSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    fee: fee,
                    amountIn: amountIn, // 本池的输入量
                    sqrtPriceLimitX96: 0 // 不限制 √价格边界
                })
            );

            // 存储本池结果
            sqrtPriceX96AfterList[i] = sqrtPriceX96After;
            tickAfterList[i] = tickAfter;
            // 将本池输出作为下一池的输入
            amountIn = amountOut_;
            i++;

            // 如果还有后续池，截断路径继续；否则结束循环
            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                amountOut = amountIn; // 最终输出
                break;
            }
        }
    }

    /// @notice 单池报价，借助 pool.swap 回退机制捕捉结果
    function quoteSingle(QuoteSingleParams memory params)
        public
        returns (
            uint256 amountOut, // 本池输出量
            uint160 sqrtPriceX96After, // 本池 swap 后 √价格
            int24 tickAfter // 本池 swap 后 tick
        )
    {
        // 根据 tokenIn、tokenOut、fee 获取池子实例
        IUniswapV3Pool pool = getPool(params.tokenIn, params.tokenOut, params.fee);

        // 判断 swap 方向：tokenIn < tokenOut 则 zeroForOne=true
        bool zeroForOne = params.tokenIn < params.tokenOut;

        // 调用 pool.swap，借助 try/catch 在回退时拿到报价数据
        try pool.swap(
            address(this), // 本合约接收输出
            zeroForOne, // 交换方向
            params.amountIn, // 输入量
            params.sqrtPriceLimitX96 == 0 // √价格限制
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(address(pool)) // 回调时透传池子地址
        ) {} catch (bytes memory reason) {
            // 回退时 data 即为 (amountOut, sqrtPriceX96After, tickAfter)
            return abi.decode(reason, (uint256, uint160, int24));
        }
    }

    /// @notice pool.swap 回调：捕获 swap 输出并强制回退携带数据
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory data) external view {
        // 解码传入的池子地址
        address pool = abi.decode(data, (address));

        // 计算输出量：token0 delta >0 则输出为 -amount1Delta，否则为 -amount0Delta
        uint256 amountOut = amount0Delta > 0 ? uint256(-amount1Delta) : uint256(-amount0Delta);

        // 读取 swap 后的 slot0 中 √价格和 tick
        (uint160 sqrtPriceX96After, int24 tickAfter,,,) = IUniswapV3Pool(pool).slot0();

        // 用 assembly 将结果打包到 revert 数据里，长度 96 字节
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, amountOut)
            mstore(add(ptr, 0x20), sqrtPriceX96After)
            mstore(add(ptr, 0x40), tickAfter)
            revert(ptr, 96)
        }
    }

    /// @notice 根据代币对和 fee 计算并返回池子地址
    function getPool(address token0, address token1, uint24 fee) internal view returns (IUniswapV3Pool pool) {
        // 确保 token0 < token1 排序一致
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        // 计算合约地址并返回接口
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, token0, token1, fee));
    }
}
