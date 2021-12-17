---
title: "UniswapV2源码分析"
date: 2021-12-17
lastmod: 2021-12-17
draft: false
tags: ["合约", "Blockchain", "Solidity"]

toc: true

---

# UniSwap-v2 源码阅读

## 源码分布
- [v2-core](https://github.com/Uniswap/v2-core)
- [v2-periphery](https://github.com/Uniswap/v2-periphery)

## 规则
使用A*B这个固定数值进行计算

## 入口
入口在v2-periphery处，可以先看看简单的一些方法

### addLiquidity
- 添加流动性方法
```
function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint amountA, uint amountB, uint liquidity) {
        (amountA, amountB) = _addLiquidity(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin);
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        TransferHelper.safeTransferFrom(tokenA, msg.sender, pair, amountA);
        TransferHelper.safeTransferFrom(tokenB, msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(to);
    }
```
流程说明
1. 调用私有方法_addLiquidity计算要添加的tokenA和tokenB的amount
   1. 通过`factory合约`获取pair是否存在，不存在则通过createPair创建一个lp
      1. 对交易对排序
      2. 通过UniswapV2Pair.createionCode来创建合约
      3. 计算合约的地址
      4. 调用创建的合约的initialize方法
      5. `factory合约`保存交易对到getPair
      6. `factory合约`保存创建的合约地址到allPairs
   2. 获取pair的余额（reserveA, reserveB)
   3. 通过quote计算需要的数量
      1. needB = giveA*reserveB/reserveA,
      2. 如果needB小于giveB，则使用needB替代giveB
      3. 如果needB大于giveB, 则计算 needA = giveB*reserveA/reserveB
         1. 如果needA小于giveA，则使用needA替换giveA，否则失败
2. 获取tokenA/tokenB的LP的合约地址
   1. 这里是通过abi直接计算的，而不是通过调用方法，可以借鉴一下
3. 将计算出来的tokenA的amount转到LP合约里
4. 将计算出来的tokenB的amount转到LP合约里
5. 调用LP合约的mint方法
   1. 获取LP当前的pool（reserve0，reserve1）
   2. 获取LP的token0和token1 的余额
   3. 用token的余额-pool的余额，计算amount0 和 amount1
      1. PS：这里没有判断是不是由这个地址转进合约的，所以是不是存在一个可能，让其他人转币进去，然后我们自己调用mint，to填写自己的地址，这样就相当于我们的lp。但是必须在同一个交易里实现这个操作。
      2. PS：通过钓鱼或者flashloan去完成？可以看一下flashloan的代码，比如还款的时候调用一下
   4. 计算手续费 _mintFee
      1. 获取手续费地址
      2. 获取Klast（klast=reserve0*reserver1）
      3. todo
   5. 获取totalSupply
      1. 如果是0
         1. lp = sqrt(amount0*amount1).sub(10**3)
         2. _mint(address(0), 10**3)
            1. 记录balance和totalSupply
      2. 如果不是0
         1. lp = min(amount0*totalSupply/reserve0, amount1*totalSupply/reserve1)
   6. _mint(to, lp), 将lp转到to地址下
   7. _update更新
      1. 记录 blockTimestamp
      2. 记录 reserve0
      3. 记录 reserve1
      4. 发送 sync事件 📧️
   8. 发送 mint事件 📧️

### removeLiquidity
- 移除流动性
```
function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) public virtual override ensure(deadline) returns (uint amountA, uint amountB) {
        address pair = UniswapV2Library.pairFor(factory, tokenA, tokenB);
        IUniswapV2Pair(pair).transferFrom(msg.sender, pair, liquidity); // send liquidity to pair
        (uint amount0, uint amount1) = IUniswapV2Pair(pair).burn(to);
        (address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'UniswapV2Router: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'UniswapV2Router: INSUFFICIENT_B_AMOUNT');
    }
```
流程说明
1. 获取lp的地址
2. 将liquidity转回pair
3. 调用pari的burn方法
   1. 获取reserve0, reserve1
   2. 获取balance0, balance1
   3. 获取当前地址的liquidity
   4. 计算手续费 _mintFee
   5. amount0 = liquidity*balance0/totalSupply
   6. amount1 = liquidity*balance1/totalSupply
   7. _burn liquidity
      1. totalSupply 减少, 然后address的balance减少
   8. 将token0 转到to
   9. 将token1 转到to
   10. 调用 _update方法更新reserve0 和 reserve1
       1. 发送 sync事件 📧️
   11. 发送 burn事件 📧️


### swapExactTokensForTokens
- 用A换B
```
function swapExactTokensForTokens(
        uint amountIn,
        uint amountOutMin,
        address[] calldata path, // 这里的path是tokenA和tokenB
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, 'UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
```
流程说明
1. getAmountOut 计算可以换出多少币
   1. 获取 reserveIn, reserveOut
      1. 通过getAmount 计算兑换
         1. fee是 3/1000
         2. 不计算手续费的公式为 A*B = (A+a)*(B-x)， 简化一下就是 x=(B*a)/(A+a)
2. 将币转到lp地址
3. 调用_swap方法
   1. 调用pair的swap方法
      1. 获取当前的reserve0 和 reserve1
      2. transfer token0
      3. transfer token1
      4. 如果存在calldata，则调用calldata
         1. PS：这里的calldata开启了flashloan的功能
      5. 重新更新 balance0Adjusted, balance1Adjusted
      6. _update
         1. 发送 sync事件 📧️
      7. 发送Swap事件 📧️

### swapTokensForExactTokens
- 同上，用B换A
```
function swapTokensForExactTokens(
        uint amountOut,
        uint amountInMax,
        address[] calldata path,
        address to,
        uint deadline
    ) external virtual override ensure(deadline) returns (uint[] memory amounts) {
        amounts = UniswapV2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, 'UniswapV2Router: EXCESSIVE_INPUT_AMOUNT');
        TransferHelper.safeTransferFrom(
            path[0], msg.sender, UniswapV2Library.pairFor(factory, path[0], path[1]), amounts[0]
        );
        _swap(amounts, path, to);
    }
```

## 总结
Uniswap的代码还是史无前例的，特别是swap时的支持的call，是一种很hack的方法。