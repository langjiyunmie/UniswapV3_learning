// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.14;

import "./UniswapV3Pool.sol";
import "./interfaces/IERC20.sol";
import "../src/interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3Manage.sol";
import "./lib/Path.sol";
import "./lib/PoolAddress.sol";
import "./lib/TickMath.sol";

contract UniswapV3Manager is IUniswapV3Manager {
    error TooLittleReceived(uint256 amountOut);
    error SlippageCheckFailed(uint256 amount0, uint256 amount1);

    using Path for bytes;

    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    function getPosition(GetPositionParams calldata params)
        public
        view
        returns (
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwe0,
            uint128 tokensOwe1
        )
    {
        IUniswapV3Pool pool = getPool(params.tokenA, params.tokenB, params.fee);

        (liquidity, feeGrowthInside0LastX128, feeGrowthInside1LastX128, tokensOwe0, tokensOwe1) =
            pool.positions(keccak256(abi.encodePacked(params.owner, params.lowerTick, params.upperTick)));
    }

    function mint(
        MintParams memory params // 接收一个结构体，包含铸币所需的所有参数
    ) public returns (uint256 amount0, uint256 amount1) {
        // 根据 tokenA、tokenB、fee 三个参数，从工厂合约获取对应的 Uniswap V3 池子实例
        IUniswapV3Pool pool = getPool(params.tokenA, params.tokenB, params.fee);

        // 读取当前池子的 slot0，解构出当前的 √价格 (sqrtPriceX96)，其余返回值此处忽略
        (uint160 sqrtPriceX96,,,,) = pool.slot0();

        // 计算下限 tick 对应的 √价格
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(params.lowerTick);

        // 计算上限 tick 对应的 √价格
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(params.upperTick);

        // 根据当前 √价格、上下限 √价格，以及用户期望存入的 amount0/amount1，
        // 计算出在该价格区间内可获得的最大流动性值 liquidity
        uint128 liquidity = LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, params.amount0Desired, params.amount1Desired
        );

        // 调用池子的原生 mint 接口，传入：
        //  1. 铸币者（msg.sender）作为 head 的 payer
        //  2. 下限 tick
        //  3. 上限 tick
        //  4. 计算出的流动性值
        //  5. 回调数据：指定 token0、token1 合约地址，以及 payer（此处为 msg.sender）
        (amount0, amount1) = pool.mint(
            msg.sender,
            params.lowerTick,
            params.upperTick,
            liquidity,
            abi.encode(IUniswapV3Pool.CallbackData({token0: pool.token0(), token1: pool.token1(), payer: msg.sender}))
        );

        // 铸币后做滑点检查：如果实际扣款少于用户设置的最小值，则回退
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert SlippageCheckFailed(amount0, amount1);
        }
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata data) public {
        UniswapV3Pool.CallbackData memory extra = abi.decode(data, (UniswapV3Pool.CallbackData));

        IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
        IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata data_) public {
        SwapCallbackData memory data = abi.decode(data_, (SwapCallbackData));
        (address tokenIn, address tokenOut,) = data.path.decodeFirstPool();

        bool zeroForOne = tokenIn < tokenOut;

        int256 amount = zeroForOne ? amount0 : amount1;

        if (data.payer == address(this)) {
            IERC20(tokenIn).transfer(msg.sender, uint256(amount));
        } else {
            IERC20(tokenIn).transferFrom(data.payer, msg.sender, uint256(amount));
        }
    }

    /// @notice 按路径依次交换多池或单池代币
    function swap(SwapParams memory params) public returns (uint256 amountOut) {
        address payer = msg.sender; // 初始支付者为调用者
        bool hasMultiplePools; // 标记路径上是否还有多余的池子

        // 无限循环，直到路径耗尽
        while (true) {
            hasMultiplePools = params.path.hasMultiplePools(); // 检查当前路径是否包含多个池

            // 调用内部 _swap，执行一次池子内的交换
            // 如果还有后续池，则本次输出发送到本合约，下一轮再兑换
            // 否则把输出直接转给最终接收者
            params.amountIn = _swap(
                params.amountIn, // 本轮输入数量
                hasMultiplePools ? address(this) : params.recipient, // 接收者
                0, // 多池时不限制 √价格边界
                SwapCallbackData({
                    path: params.path.getFirstPool(), // 当前处理的第一段路径（tokenIn/fee/tokenOut）
                    payer: payer // 当前支付者
                })
            );

            if (hasMultiplePools) {
                // 如果还有后续池，更新支付者为本合约，裁剪路径继续
                payer = address(this);
                params.path = params.path.skipToken(); // 跳过已经使用的 tokenOut，继续下一池
            } else {
                // 路径耗尽，最终输出即本轮输出
                amountOut = params.amountIn;
                break;
            }
        }

        // 最后做最小输出检查，若不满足则回退
        if (amountOut < params.minAmountOut) {
            revert TooLittleReceived(amountOut);
        }
    }

    /// @notice 单池交换接口，直接指定 tokenIn/tokenOut/fee
    function swapSingle(SwapSingleParams calldata params) public returns (uint256 amountOut) {
        // 调用内部 _swap，接收者为 msg.sender，设定 √价格边界
        amountOut = _swap(
            params.amountIn, // 输入数量
            msg.sender, // 输出接收者
            params.sqrtPriceLimitX96, // √价格边界限制
            SwapCallbackData({
                // 将单池路径打包成 abi 路径格式
                path: abi.encodePacked(params.tokenIn, params.fee, params.tokenOut),
                payer: msg.sender // 支付者
            })
        );
    }

    /// @dev 内部核心交换逻辑，调用 UniswapV3Pool.swap
    function _swap(
        uint256 amountIn, // 本次输入数量
        address recipient, // 本次输出接收者
        uint160 sqrtPriceLimitX96, // √价格边界（若为 0 则取默认极限）
        SwapCallbackData memory data // 回调数据：包含当前池路径与支付者
    ) internal returns (uint256 amountOut) {
        // 解码当前池的三个信息：tokenIn、tokenOut、fee（tickSpacing）
        (address tokenIn, address tokenOut, uint24 tickSpacing) = data.path.decodeFirstPool();

        // 判断交易方向：tokenIn < tokenOut 则从 0→1，否则从 1→0
        bool zeroForOne = tokenIn < tokenOut;

        // 调用对应池子的 swap 方法
        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, tickSpacing).swap(
            recipient, // 输出接收地址
            zeroForOne, // 方向标志
            amountIn, // 输入数量
            sqrtPriceLimitX96 == 0 // 如果没传边界，则取极限值
                ? (
                    zeroForOne
                        ? TickMath.MIN_SQRT_RATIO + 1 // 向上限制为最小 √价格+1 （防止越界）
                        : TickMath.MAX_SQRT_RATIO - 1
                ) // 或向下限制为最大 √价格−1
                : sqrtPriceLimitX96, // 否则使用用户传入的边界
            abi.encode(data) // 回调编码数据
        );

        // 根据方向取负值转换成正数返回（输出量）
        // 如果 zeroForOne，则 amount1 为负的输出量；否则 amount0 为负
        amountOut = uint256(-(zeroForOne ? amount1 : amount0));
    }

    function getPool(address token0, address token1, uint24 tickSpacing) internal view returns (IUniswapV3Pool pool) {
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);

        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, token0, token1, tickSpacing));
    }
}
