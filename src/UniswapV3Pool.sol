// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.8.14;

import "./lib/Tick.sol";
import "./lib/Position.sol";
import "./interfaces/IERC20.sol";
import "src/interfaces/IUniswapV3MintCallback.sol";
import "src/interfaces/IUniswapV3SwapCallback.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";
import "./lib/Math.sol";
import "./lib/SwapMath.sol";
import "./lib/LiquidityMath.sol";
import "src/interfaces/IUniswapV3FlashCallback.sol";
import "./UniswapV3Factory.sol";
import "src/interfaces/IUniswapV3PoolDeployer.sol";
import "./lib/Oracle.sol";

contract UniswapV3Pool {
    error InvalidTick();
    error InsufficientInputAmount();
    error ZeroLiquidity();
    error InvalidPriceLimit();
    error AlreadyInitialized();
    error NotEnoughLiquidity();
    error FlashLoanNotPaid();

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Burn(
        address indexed owner,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint128 amount,
        uint256 amount0,
        uint256 amount1
    );

    event Collect(
        address indexed owner,
        address recipient,
        int24 indexed tickLower,
        int24 indexed tickUpper,
        uint256 amount0,
        uint256 amount1
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    event IncreaseObservationCardinalityNext(
        uint16 observationCardinalityNextOld, uint16 observationCardinalityNextNew
    );

    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);

    using Tick for mapping(int24 => Tick.Info);
    using TickBitmap for mapping(int16 => uint256);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using Position for mapping(bytes32 => Position.Info);
    using Oracle for Oracle.Observation[65535];

    mapping(int24 => Tick.Info) public ticks;
    mapping(bytes32 => Position.Info) public positions;
    mapping(int16 => uint256) public tickBitmap;
    Oracle.Observation[65535] public observations;

    // Pool parameters
    address public immutable token0;
    address public immutable token1;
    address public immutable factory;
    uint24 public immutable tickSpacing;

    int24 internal constant MIN_TICK = -87272;
    int24 internal constant MAX_TICK = -MIN_TICK;
    uint128 public liquidity;
    Slot0 public slot0;
    // 池子中累积交易费用。为此我们要添加两个全局费用累积的变量
    uint24 public immutable fee;
    uint256 public feeGrowthGlobal0X128;
    uint256 public feeGrowthGlobal1X128;

    struct Slot0 {
        // Current sqrt(P)
        uint160 sqrtPriceX96;
        // Current tick
        int24 tick;
        // Most recent observation index
        // 记录最新的观测的编号
        uint16 observationIndex;
        // Maximum number of observations
        // 记录活跃的观测数量
        uint16 observationCardinality;
        // Next maximum number of observations
        // 记录观测数组能够扩展到的下一个基数的大小。
        uint16 observationCardinalityNext;
    }

    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    struct SwapState {
        uint256 amountSpecifiedRemaining;
        uint256 amountCalculated;
        uint160 sqrtPriceX96;
        int24 tick;
        uint256 feeGrowthGlobalX128;
        uint128 liquidity;
    }

    struct StepState {
        uint160 sqrtPriceStartX96;
        int24 nextTick;
        bool initialized;
        uint160 sqrtPriceNextX96;
        uint256 amountIn;
        uint256 amountOut;
        uint256 feeAmount;
    }

    constructor() {
        (factory, token0, token1, tickSpacing, fee) = IUniswapV3PoolDeployer(msg.sender).parameters();
    }

    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();

        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);

        (uint16 cardinality, uint16 cardinalityNext) = observations.initialize(_blockTimestamp());

        slot0 = Slot0({
            sqrtPriceX96: sqrtPriceX96,
            tick: tick,
            observationIndex: 0,
            observationCardinality: cardinality,
            observationCardinalityNext: cardinalityNext
        });
    }

    struct ModifyPositionParams {
        address owner;
        int24 lowerTick;
        int24 upperTick;
        int128 liquidityDelta;
    }

    function _modifyPosition(ModifyPositionParams memory params)
        internal
        returns (Position.Info storage position, int256 amount0, int256 amount1)
    {
        // —— 1. 缓存当前全局状态 到内存，减少后续多次 SLOAD
        Slot0 memory slot0_ = slot0; // 当前价格、tick、…等
        uint256 feeGrowthGlobal0X128_ = feeGrowthGlobal0X128; // 全局 token0 手续费累计
        uint256 feeGrowthGlobal1X128_ = feeGrowthGlobal1X128; // 全局 token1 手续费累计

        // —— 2. 拿到或创建用户仓位对象
        position = positions.get(params.owner, params.lowerTick, params.upperTick);
        // —— 3. 在下界 tick 上按 liquidityDelta 更新该 tick 的流动性状况
        //    返回值 flippedLower 表示该 tick 的 “已初始化” 状态是否发生了翻转
        bool flippedLower = ticks.update(
            params.lowerTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            false // false 表示这是下界
        );

        // —— 4. 在上界 tick 上按同样方式更新
        bool flippedUpper = ticks.update(
            params.upperTick,
            slot0_.tick,
            int128(params.liquidityDelta),
            feeGrowthGlobal0X128_,
            feeGrowthGlobal1X128_,
            true // true 表示这是上界
        );

        // —— 5. 如果某个 tick 的 initialized 状态翻转，就在 bitmap 中翻转对应位
        if (flippedLower) {
            tickBitmap.flipTick(params.lowerTick, int24(tickSpacing));
        }

        if (flippedUpper) {
            tickBitmap.flipTick(params.upperTick, int24(tickSpacing));
        }

        // —— 6. 取区间内累积手续费增量，用于随后给仓位结算
        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) = ticks.getFeeGrowthInside(
            params.lowerTick, params.upperTick, slot0_.tick, feeGrowthGlobal0X128_, feeGrowthGlobal1X128_
        );

        // —— 7. 用上述手续费增量和传入的 liquidityDelta 更新用户仓位对象
        position.update(params.liquidityDelta, feeGrowthInside0X128, feeGrowthInside1X128);

        // 当价格并未达到你选择的流动性区间，或者说是当你的token0在流动性区间内被全部兑换成token1，此时你只会拥有其中一种token
        // 锁仓token数量会被公式计算
        // —— 8. 根据当前价格 slot0_.tick 相对区间 [lowerTick, upperTick]，
        // 计算实际要转入/转出的 token0 与 token1 数量
        if (slot0_.tick < params.lowerTick) {
            // 价格在区间左侧，全仓为 token0
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        } else if (slot0_.tick < params.upperTick) {
            // 价格在区间内部，同时持有两种 token
            amount0 = Math.calcAmount0Delta(
                slot0_.sqrtPriceX96, TickMath.getSqrtRatioAtTick(params.upperTick), params.liquidityDelta
            );

            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick), slot0_.sqrtPriceX96, params.liquidityDelta
            );

            // 同时更新全池的活跃流动性
            liquidity = LiquidityMath.addLiquidity(liquidity, params.liquidityDelta);
        } else {
            // 价格在区间右侧，全仓为 token1
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(params.lowerTick),
                TickMath.getSqrtRatioAtTick(params.upperTick),
                params.liquidityDelta
            );
        }
    }

    function mint(
        int24 upperTick, // 用户指定的价格区间上限（tick 索引）
        int24 lowerTick, // 用户指定的价格区间下限（tick 索引）
        address owner, // 该头寸的所有者地址
        uint128 amount, // 要增加的流动性数量（liquidity delta）
        bytes calldata data // 回调时透传的任意数据
    ) external returns (uint256 amount0, uint256 amount1) {
        // 校验：上限必须大于等于下限，且上下限都要在预定义范围内
        if (
            upperTick < lowerTick // 上限 < 下限，则无效
                || upperTick > MAX_TICK // 上限超过最大允许值
                || lowerTick < MIN_TICK // 下限低于最小允许值
        ) {
            revert InvalidTick(); // 抛出“价格刻度无效”错误
        }

        // 校验：流动性数量不能为 0，否则没有意义
        if (amount == 0) revert ZeroLiquidity(); // 抛出“流动性为零”错误

        // 核心：修改（新增）头寸，调用内部通用逻辑
        // ModifyPositionParams 是一个结构体，封装了所有参数
        (, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: owner,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: int128(amount) // 转为有符号整数，支持正增/负减
            })
        );
        // _modifyPosition 会返回三项：新头寸的流动性、此操作需支付的 token0 数量（int256）、token1 数量

        // 将内部使用的有符号整数转换为外部暴露的无符号整数
        amount0 = uint256(amount0Int); // 支付给池子的 token0 数量
        amount1 = uint256(amount1Int); // 支付给池子的 token1 数量

        // 记录调用 mint 之前，合约中 token0/token1 的余额
        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0(); // 只有需要支付 token0 时才读
        if (amount1 > 0) balance1Before = balance1(); // 只有需要支付 token1 时才读

        // 触发回调，要求调用方按照 amount0/amount1 数量将代币转入本合约
        // 并可通过 data 传递任意额外信息
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);

        // 校验回调后，合约余额已增加至少 amount0
        // 否则视为用户支付不足
        if (amount0 > 0 && balance0Before + amount0 > balance0()) {
            revert InsufficientInputAmount(); // 抛出“输入代币不足”错误
        }
        // 同理，校验 token1 是否支付足够
        if (amount1 > 0 && balance1Before + amount1 > balance1()) {
            revert InsufficientInputAmount();
        }

        // 事件：记录本次 mint 操作
        emit Mint(
            msg.sender, // 调用者（通常是一个合约或钱包地址）
            owner, // 最终头寸所有者
            lowerTick, // 价格区间下限
            upperTick, // 价格区间上限
            amount, // 增加的流动性数量
            amount0, // 实际支付的 token0 数量
            amount1 // 实际支付的 token1 数量
        );
    }

    function burn(int24 lowerTick, int24 upperTick, uint128 amount) public returns (uint256 amount0, uint256 amount1) {
        // 调用 _modifyPosition，传入负的 liquidityDelta
        (Position.Info storage position, int256 amount0Int, int256 amount1Int) = _modifyPosition(
            ModifyPositionParams({
                owner: msg.sender,
                lowerTick: lowerTick,
                upperTick: upperTick,
                liquidityDelta: -(int128(amount))
            })
        );

        // 将内部算出的负数 int 变为正的 uint，作为实际返给用户的 token 数
        amount0 = uint256(-amount0Int);
        amount1 = uint256(-amount1Int);

        if (amount0 > 0 || amount1 > 0) {
            // 如果返还量大于 0，则记录到仓位的待领取中（包括手续费 + 赎回量）
            // 为适应 position 中的参数类型，amount0(amount1) 类型要转化为 uint256
            // 那原先amount0(amount1) 为 uint256 是为适应 ERC20等代币协议参数，适配外部接口，比如其中的transferf方法
            (position.tokenOwed0, position.tokenOwed1) =
                (position.tokenOwed0 + uint128(amount0), position.tokenOwed1 + uint128(amount1));
        }
        emit Burn(msg.sender, lowerTick, upperTick, amount, amount0, amount1);
    }

    function collect(
        address recipient,
        int24 lowerTick,
        int24 upperTick,
        uint128 amount0Requested,
        uint128 amount1Requested
    ) public returns (uint128 amount0, uint128 amount1) {
        // 1. 读取调用者在该区间的仓位信息（内存副本，不会修改链上）
        Position.Info memory position = positions.get(msg.sender, lowerTick, upperTick);
        // 2. 计算本次实际可提取的 token0 数量：
        // 如果请求量 > 仓位里欠的量，就只提欠的量；否则就按请求量提取
        amount0 = amount0Requested > position.tokenOwed0 ? position.tokenOwed0 : amount0Requested;
        // 等价于：amount0 = min(amount0Requested, position.tokensOwed0)
        amount1 = amount1Requested > position.tokenOwed1 ? position.tokenOwed1 : amount1Requested;
        // Solidity 会在调用 transfer 函数时，将 uint128 值扩展为 uint256，高位填充 0
        // 这种隐式转换是安全的，因为从较小的无符号整数类型（uint128）转换为较大的无符号整数类型（uint256）不会导致数据丢失或溢出。
        if (amount0 > 0) {
            position.tokenOwed0 -= amount0;
            IERC20(token0).transfer(recipient, amount0);
        }

        if (amount1 > 0) {
            position.tokenOwed1 -= amount1;
            IERC20(token1).transfer(recipient, amount1);
        }

        emit Collect(msg.sender, recipient, lowerTick, upperTick, amount0, amount1);
    }

    function swap(
        address recipient, // 接收方地址：最终接收被换出的 token
        bool zeroForOne, // 交易方向：true 表示用 token0 换 token1，false 表示用 token1 换 token0
        uint256 amountSpecified, // 用户指定交换的 token 数量：当 zeroForOne=true 时是 token0 数量，否则是 token1 数量
        uint160 sqrtPriceLimitX96, // √价格限制：防止滑点过大，设置价格边界
        bytes calldata data // 回调数据：传递给 swap 回调以收取输入 token
    ) public returns (int256 amount0, int256 amount1) {
        // 缓存 slot0 以节省 gas：包括当前 √价格和 tick
        Slot0 memory slot0_ = slot0;
        // 缓存全局流动性
        uint128 liquidity_ = liquidity;

        // 验证用户传入的 sqrtPriceLimitX96 合理性，防止价格超出用户设定边界或协议允许范围
        if (
            zeroForOne // 如果是卖出 token0 换 token1，价格下降，sqrtPriceLimitX96 必须在 [MIN_SQRT_RATIO, 当前价格) 之间
                ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 || sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO // 如果是卖出 token1 换 token0，价格上升，sqrtPriceLimitX96 必须在 (当前价格, MAX_SQRT_RATIO] 之间
                : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 || sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();

        // 初始化内部状态，用于循环计算每一步的交换
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified, // 剩余待交换数量
            amountCalculated: 0, // 累计已换出的对侧 token 数量
            sqrtPriceX96: slot0_.sqrtPriceX96, // 当前 √价格
            tick: slot0_.tick, // 当前 tick
            feeGrowthGlobalX128: zeroForOne // 根据方向选择对应代币的全局手续费累积
                ? feeGrowthGlobal1X128
                : feeGrowthGlobal0X128,
            liquidity: liquidity_ // 当前全局活跃流动性
        });
        // 主循环：当还有剩余待交换数量，且价格未达到用户限制时，继续执行步骤
        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepState memory step; // 本次子步骤状态
            // 记录步开始时的 √价格
            step.sqrtPriceStartX96 = state.sqrtPriceX96;
            // 找到下一个激活的 tick（最近的价格边界），并获取其是否已初始化
            (step.nextTick, step.initialized) =
                tickBitmap.nextInitializedTickWithinOneWord(state.tick, int24(tickSpacing), zeroForOne);
            // 根据该 tick 计算对应的 √价格
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);
            // 计算本次子步骤能吃进多少输入、产出多少输出，以及承担多少手续费
            (
                state.sqrtPriceX96, // 本次子步骤结束的 √价格
                step.amountIn, // 本次吃进多少输入 token
                step.amountOut, // 本次产出多少输出 token
                step.feeAmount // 本次产生多少手续费
            ) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                //选择下一 √价格的上限：若会越过用户设定的价格限制，则用限制价，否则用下一个 tick 的 √价格
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity, // 本次可用流动性
                state.amountSpecifiedRemaining, // 剩余待交换数量
                fee // 池子手续费费率
            );
            // 扣减已吃进的输入 + 手续费
            state.amountSpecifiedRemaining -= step.amountIn + step.feeAmount;
            // 累计已产出的输出 token
            state.amountCalculated += step.amountOut;

            // step 描述的是一次子步骤（price tick → next tick）里会消耗多少，在这一步里并不改变流动性本身（流动性只在跨 tick 时由 ticks.cross 修改
            // 真正意义上的“当前流动性”，始终是 state.liquidity，也就是整个池子在这一价格区间内可用的 总 流动性
            if (state.liquidity > 0) {
                state.feeGrowthGlobalX128 += PRBMath.mulDiv(step.feeAmount, FixedPoint128.Q128, state.liquidity);
            }
            // 如果价格正好达到了下一个 tick 的价格，说明跨越了 tick 边界
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                if (step.initialized) {
                    int128 liquidityDelta = ticks.cross(
                        step.nextTick,
                        (
                            zeroForOne
                                ? state.feeGrowthGlobalX128 // 如果是卖 token0 → token1：跨入时，token0 的手续费增长值
                                : feeGrowthGlobal0X128
                        ), // 否则 token0 全局手续费不更新，因为 token1 -> token0 收取的手续费是 token1,跟 token0 没有关系
                        (zeroForOne ? feeGrowthGlobal1X128 : state.feeGrowthGlobalX128)
                    );
                    // token0 -> token1,价格下降，tick穿过上界tick,原区间的流动性需要移除，所以liquidityDelta为负数
                    // 如果是穿过下界tick，则流动性激活。
                    // 首先明白一个区别，就是在流动性外，挂单的token都是单一以一种token存在，当进入用户选择的流动性区间的时候，才会激活，这时候token0(token1) 会转换一部分,利用公式算出用户的LPtoken
                    if (zeroForOne) liquidityDelta = -liquidityDelta;

                    state.liquidity = LiquidityMath.addLiquidity(state.liquidity, liquidityDelta);

                    if (state.liquidity == 0) revert NotEnoughLiquidity();
                }
                // 因为 Uniswap V3 里 “价格落在某个 tick 的精确边界” 时，按默认的 floor 规则它会被算作上一个区间的右端点，也就是 tick = nextTick
                // 当 token0 -> token1 (true): 价格下降，此时tick值为边界tick，只有 -1，才会被认为到了下一个区间。
                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96);
            }
        }
        // 循环完成后，如果 tick 发生了变化，则写入新的观察值
        if (state.tick != slot0_.tick) {
            (uint16 observationIndex, uint16 observationCardinality) = observations.write(
                slot0_.observationIndex,
                _blockTimestamp(),
                slot0_.tick,
                slot0_.observationCardinality,
                slot0_.observationCardinalityNext
            );

            (slot0.sqrtPriceX96, slot0.tick, slot0.observationIndex, slot0.observationCardinality) =
                (state.sqrtPriceX96, state.tick, observationIndex, observationCardinality);
        } else {
            slot0.sqrtPriceX96 = state.sqrtPriceX96;
        }
        // 如果流动性有变化，同步写回到存储
        if (liquidity_ != state.liquidity) liquidity = state.liquidity;
        // 同步手续费累积到存储
        if (zeroForOne) {
            feeGrowthGlobal0X128 = state.feeGrowthGlobalX128;
        } else {
            feeGrowthGlobal1X128 = state.feeGrowthGlobalX128;
        }

        // 最终计算输出给用户的 amount0 和 amount1
        (amount0, amount1) = zeroForOne
            ? (int256(amountSpecified - state.amountSpecifiedRemaining), -int256(state.amountCalculated))
            : (-int256(state.amountCalculated), int256(amountSpecified - state.amountSpecifiedRemaining));
        // 处理跨合约 token 转账和回调：按方向分别处理
        if (zeroForOne) {
            // 先把 token1 发给接收者
            IERC20(token1).transfer(recipient, uint256(-amount1));
            // 记录 token0 的余额以便回调后校验
            uint256 balance0Before = balance0();
            // 回调用户合约，要求其支付 token0
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            // 校验回调是否真的支付了足够的 token0
            if (balance0Before + uint256(amount0) > balance0()) {
                revert InsufficientInputAmount();
            }
        } else {
            // 先把 token0 发给接收者
            IERC20(token0).transfer(recipient, uint256(-amount0));
            // 记录 token1 的余额
            uint256 balance1Before = balance1();
            // 回调用户合约，要求其支付 token1
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            // 校验回调是否真的支付了足够的 token1
            if (balance1Before + uint256(amount1) > balance1()) {
                revert InsufficientInputAmount();
            }
        }
        // 触发 Swap 事件，记录交易各项参数
        emit Swap(msg.sender, recipient, amount0, amount1, slot0.sqrtPriceX96, liquidity, slot0.tick);
    }

    function flash(uint256 amount0, uint256 amount1, bytes calldata data) public {
        uint256 fee0 = Math.mulDivRoundingUp(amount0, fee, 1e6);
        uint256 fee1 = Math.mulDivRoundingUp(amount1, fee, 1e6);

        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 1) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(fee0, fee1, data);

        if (IERC20(token0).balanceOf(address(this)) < balance0Before + fee0) {
            revert FlashLoanNotPaid();
        }

        if (IERC20(token1).balanceOf(address(this)) < balance1Before + fee1) {
            revert FlashLoanNotPaid();
        }

        emit Flash(msg.sender, amount0, amount1);
    }

    /**
     * @notice 增加下一个观测记录的容量（cardinality）
     * @param observationCardinalityNext 用户传入的期望容量
     */
    function increaseObservationCardinalityNext(
        uint16 observationCardinalityNext // 传入一个新的期望值 observationCardinalityNext；如果该值 ≤ 当前的 slot0.observationCardinalityNext，函数不会做任何操作
    ) public {
        // 读取当前的 observationCardinalityNext，并保存在局部变量 observationCardinalityNextOld 中
        uint16 observationCardinalityNextOld = slot0.observationCardinalityNext;

        // 调用 observations.grow 方法尝试将容量从旧值增长到用户指定的新值
        // 如果新值小于或等于旧值，grow 会直接返回旧值；否则会扩大观测数组并返回新的容量
        uint16 observationCardinalityNextNew =
            observations.grow(observationCardinalityNextOld, observationCardinalityNext);

        // 仅当实际增长后的容量与旧容量不同时，才更新 slot0 的记录并触发事件
        if (observationCardinalityNextNew != observationCardinalityNextOld) {
            // 将 slot0.observationCardinalityNext 更新为用户传入的新期望值
            slot0.observationCardinalityNext = observationCardinalityNext;

            // 触发事件，告知外界容量已从旧值增长到新值
            emit IncreaseObservationCardinalityNext(observationCardinalityNextOld, observationCardinalityNextNew);
        }
    }

    ////////////////////////////////////////////////////////////////////////////
    //
    // INTERNAL
    //
    ////////////////////////////////////////////////////////////////////////////
    function balance0() internal returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }

    function _blockTimestamp() internal view returns (uint32 timestamp) {
        timestamp = uint32(block.timestamp);
    }
}
