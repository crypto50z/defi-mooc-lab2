//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.7;

import "hardhat/console.sol";
import './IUniswapV2Router02.sol';
import "./SafeMath.sol";

// ----------------------INTERFACE------------------------------

// Aave
// https://docs.aave.com/developers/the-core-protocol/lendingpool/ilendingpool

interface ILendingPool {
    /**
     * Function to liquidate a non-healthy position collateral-wise, with Health Factor below 1
     * - The caller (liquidator) covers `debtToCover` amount of debt of the user getting liquidated, and receives
     *   a proportionally amount of the `collateralAsset` plus a bonus to cover market risk
     * @param collateralAsset The address of the underlying asset used as collateral, to receive as result of theliquidation
     * @param debtAsset The address of the underlying borrowed asset to be repaid with the liquidation
     * @param user The address of the borrower getting liquidated
     * @param debtToCover The debt amount of borrowed `asset` the liquidator wants to cover
     * @param receiveAToken `true` if the liquidators wants to receive the collateral aTokens, `false` if he wants
     * to receive the underlying collateral asset directly
     **/
    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveAToken
    ) external;

    /**
     * Returns the user account data across all the reserves
     * @param user The address of the user
     * @return totalCollateralETH the total collateral in ETH of the user
     * @return totalDebtETH the total debt in ETH of the user
     * @return availableBorrowsETH the borrowing power left of the user
     * @return currentLiquidationThreshold the liquidation threshold of the user
     * @return ltv the loan to value of the user
     * @return healthFactor the current health factor of the user
     **/
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );
}

// UniswapV2

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IERC20.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/Pair-ERC-20
interface IERC20 {
    // Returns the account balance of another account with address _owner.
    function balanceOf(address owner) external view returns (uint256);

    /**
     * Allows _spender to withdraw from your account multiple times, up to the _value amount.
     * If this function is called again it overwrites the current allowance with _value.
     * Lets msg.sender set their allowance for a spender.
     **/
    function approve(address spender, uint256 value) external; // return type is deleted to be compatible with USDT

    /**
     * Transfers _value amount of tokens to address _to, and MUST fire the Transfer event.
     * The function SHOULD throw if the message caller’s account balance does not have enough tokens to spend.
     * Lets msg.sender send pool tokens to an address.
     **/
    function transfer(address to, uint256 value) external returns (bool);
}

// https://github.com/Uniswap/v2-periphery/blob/master/contracts/interfaces/IWETH.sol
interface IWETH is IERC20 {
    // Convert the wrapped token back to Ether.
    function withdraw(uint256) external;
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Callee.sol
// The flash loan liquidator we plan to implement this time should be a UniswapV2 Callee
interface IUniswapV2Callee {
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata data
    ) external;
}


interface ILendingPoolAddressesProvider {
    function getLendingPoolCore() external view returns (address payable);
    function getLendingPool() external view returns (address);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Factory.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/factory
interface IUniswapV2Factory {
    // Returns the address of the pair for tokenA and tokenB, if it has been created, else address(0).
    function getPair(address tokenA, address tokenB)
        external
        view
        returns (address pair);
}

// https://github.com/Uniswap/v2-core/blob/master/contracts/interfaces/IUniswapV2Pair.sol
// https://docs.uniswap.org/protocol/V2/reference/smart-contracts/pair
interface IUniswapV2Pair {
    /**
     * Swaps tokens. For regular swaps, data.length must be 0.
     * Also see [Flash Swaps](https://docs.uniswap.org/protocol/V2/concepts/core-concepts/flash-swaps).
     **/
    function swap(
        uint256 amount0Out,
        uint256 amount1Out,
        address to,
        bytes calldata data
    ) external;

    function token0() external view returns (address);
    function token1() external view returns (address);

    /**
     * Returns the reserves of token0 and token1 used to price trades and distribute liquidity.
     * See Pricing[https://docs.uniswap.org/protocol/V2/concepts/advanced-topics/pricing].
     * Also returns the block.timestamp (mod 2**32) of the last block during which an interaction occured for the pair.
     **/
    function getReserves()
        external
        view
        returns (
            uint112 reserve0,
            uint112 reserve1,
            uint32 blockTimestampLast
        );
}

// ----------------------IMPLEMENTATION------------------------------

contract LiquidationOperator is IUniswapV2Callee {

    using SafeMath for uint256;
    uint8 public constant health_factor_decimals = 18;

    // TODO: define constants used in the contract including ERC-20 tokens, Uniswap Pairs, Aave lending pools, etc. */
    //    *** Your code here ***
    IWETH WETH = IWETH (0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2);

    address addrUSDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7; 
    address addrWBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; 
    address addrWETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;

    address internal constant UNISWAP_ROUTER_ADDRESS = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D ;
    IUniswapV2Router02 public uniswapRouter = IUniswapV2Router02(UNISWAP_ROUTER_ADDRESS);

    IUniswapV2Router02 sushiRouter = IUniswapV2Router02(0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F);

    // uint constant deadline = 500 days;

    //////////////////////////////////////////////////////////////////////
    address _token0 = 0xdAC17F958D2ee523a2206206994597C13D831ec7; // 0x00000000dac17f958d2ee523a2206206994597c13d831ec7; // _USDT;
    address _token1 = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599; // 0x000000002260fac5e5542a773aa44fbcfedf7c193bc2c599; // _WBTC;
    //////////////////////////////////////////////////////////////////////

    IUniswapV2Factory constant uniswapV2Factory = IUniswapV2Factory(0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f); // same for all networks
    address pairAddress = uniswapV2Factory.getPair(addrUSDT, addrWETH);
    ILendingPool lendingPool = ILendingPool(0x7d2768dE32b0b80b7a3454c06BdAc94A69DDc7A9); // what is the parameter's meaning

    // END TODO

    // some helper function, it is totally fine if you can finish the lab without using these function
    // https://github.com/Uniswap/v2-periphery/blob/master/contracts/libraries/UniswapV2Library.sol
    // given an input amount of an asset and pair reserves, returns the maximum output amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountOut(
        uint256 amountIn,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountOut) {
        require(amountIn > 0, "UniswapV2Library: INSUFFICIENT_INPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 amountInWithFee = amountIn * 997;
        uint256 numerator = amountInWithFee * reserveOut;
        uint256 denominator = reserveIn * 1000 + amountInWithFee;
        amountOut = numerator / denominator;
    }

    function safeGetAmountIn(uint256 amountOut, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, 'UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT');
        require(reserveIn > 0 && reserveOut > 0, 'UniswapV2Library: INSUFFICIENT_LIQUIDITY');
        uint numerator = reserveIn.mul(amountOut).mul(1000);
        uint denominator = reserveOut.sub(amountOut).mul(997);
        amountIn = (numerator / denominator).add(1);
    }

    // some helper function, it is totally fine if you can finish the lab without using these function
    // given an output amount of an asset and pair reserves, returns a required input amount of the other asset
    // safe mul is not necessary since https://docs.soliditylang.org/en/v0.8.9/080-breaking-changes.html
    function getAmountIn(
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal pure returns (uint256 amountIn) {
        require(amountOut > 0, "UniswapV2Library: INSUFFICIENT_OUTPUT_AMOUNT");
        require(
            reserveIn > 0 && reserveOut > 0,
            "UniswapV2Library: INSUFFICIENT_LIQUIDITY"
        );
        uint256 numerator = reserveIn * amountOut * 1000;
        uint256 denominator = (reserveOut - amountOut) * 997;
        amountIn = (numerator / denominator) + 1;
    }

    constructor() {
        // TODO: (optional) initialize your contract
        //   *** Your code here ***
        // END TODO
    }

    // TODO: add a `receive` function so that you can withdraw your WETH
    //   *** Your code here ***

    // function receive(uint256 amount) external payable {
    //     IWETH(addrWETH).withdraw(amount);
    // }

    receive() external payable {}
    // END TODO

    // required by the testing script, entry for your liquidation call
    function operate() external {
        // TODO: implement your liquidation logic

        // 0. security checks and initializing variables
        //    *** Your code here ***

        // 1. get the target user account data & make sure it is liquidatable
        //    *** Your code here ***

        // AZ: copied from swap
        // uint balance0 = IERC20(_token0).balanceOf(address(this));
        // uint balance1 = IERC20(_token1).balanceOf(address(this));
        
        uint balance0 = IERC20(addrUSDT).balanceOf(address(this));
        uint balance1 = IERC20(addrWETH).balanceOf(address(this));
        
        console.log("balance of USDT = %s, balance of WETH = %s", balance0, balance1);

        (uint112 r1, uint112 r2, ) = IUniswapV2Pair(pairAddress).getReserves();
        console.log("+++++++++++ RESERVE INFO ++++++++++++");
        console.log("Reserve1 of USDT is %s, Reserve2 of WETH is %s", r1, r2);
        uint256 K = uint256(r1) * uint256(r2);
        console.log("...... K = %s", K);
        console.log("+++++++++++ ++++++++++++ ++++++++++++");

        address tuser = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;

        (
            uint256 totalCollateralETH,
            uint256 totalDebtETH,
            uint256 availableBorrowsETH,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        ) = lendingPool.getUserAccountData(tuser);

        console.log("total collateral in ETH = %s ", totalCollateralETH);
        console.log("total Debt in ETH = %s ", totalDebtETH);
        console.log("available Borrows in ETH = %s ", availableBorrowsETH);
        console.log("current Liquidation Threshold = %s ", currentLiquidationThreshold);
        console.log("LTV = %s ", ltv);
        console.log("healthFactor = %s ", healthFactor);

        require(healthFactor < (1 * 10 ** 18), "Can't liquidate borrower HF >=1!");

        uint256 debt2repay = totalDebtETH / 2;
        console.log("Lets try liquidate %s first...", debt2repay);

        // 2. call flash swap to liquidate the target user
        // based on https://etherscan.io/tx/0xac7df37a43fab1b130318bbb761861b8357650db2e2c6493b73d6da3d9581077
        // we know that the target user borrowed USDT with WBTC as collateral
        // we should borrow USDT, liquidate the target user and get the WBTC, then swap WBTC to repay uniswap
        // (please feel free to develop other workflows as long as they liquidate the target user successfully)

        //    *** Your code here ***
        // address pairAddress = uniswapV2Factory.getPair(_tokenBorrow, tokenOther); // gas efficiency
        // require(pairAddress != address(0), "Requested _token is not available.");
        // address token0 = IUniswapV2Pair(pairAddress).token0();
        // address token1 = IUniswapV2Pair(pairAddress).token1();

        ////////////////////////////////////////////////////////////////////////////////////////
        // We want to borrow USDT, liquidate by paying USDT, and get back WBTC
        // And if profitable, payback the loan with part of the received WBTC,
        // and keep the left WBTC as profit.
        ////////////////////////////////////////////////////////////////////////////////////////

        uint amount0Out = 0; // or some other number that depends on the user's collateral value
        uint256 amount1Out = 2916378221684; // 3000000000000; // 100000000;

        bytes memory data = abi.encode(
            r1,
            r2
            // _userData
        ); // note _tokenBorrow == _tokenPay

        console.log("To call swap with amount0Out = %s, amount1Out = %s", amount0Out, amount1Out);
        IUniswapV2Pair(pairAddress).swap(amount0Out, amount1Out, address(this), data);


   
        uint256 balanceWETH = IERC20(addrWETH).balanceOf (address(this));
        // emit Log (abi.encodePacked(balanceWETH));
        console.log("After Flash Swap, WETH balance: %s", balanceWETH);
        
        // IWETH uniWETH = IWETH(router.WETH () );
        // console.log ("uni addr %s", address(uniWETH));
        WETH.withdraw (balanceWETH);

        payable(msg.sender).transfer (balanceWETH);

        // 3. Convert the profit into ETH and send back to sender
        //    *** Your code here ***

        // END TODO
    }

    function swapWBTC4WETH(uint amount0) internal returns (uint amntReceived) {
        // AZ: check the balances
        console.log("To swap WBTC of %s", amount0);
        uint balance0 = IERC20(addrWBTC).balanceOf(address(this));
        uint balance1 = IERC20(addrWETH).balanceOf(address(this));
        console.log("Before Swap, balance0 of WBTC = %s, balance1 of WETH = %s", balance0, balance1);

        // bool res = IERC20(addrWBTC).transfer (msg.sender, amount0/2);
        address wbtc2wethPair = uniswapV2Factory.getPair(addrWBTC, addrWETH);
        bool res = IERC20(addrWBTC).transfer (wbtc2wethPair, amount0);
        console.log("%s of WBTC is transferred to wbtc2wethPair -- %s", amount0, res);
        // IUniswapV2Pair(wbtc2wethPair).swap(0, amount0*100000000000, address(this), "");
        IUniswapV2Pair(wbtc2wethPair).swap(0, 1520965363370543592245, address(this), "");

        // AZ: check the balances
        balance0 = IERC20(addrWBTC).balanceOf(address(this));
        balance1 = IERC20(addrWETH).balanceOf(address(this));
        console.log("After SWAP, balance0 of WBTC = %s, balance1 of WETH = %s", balance0, balance1);
        amntReceived = balance1;
    }

    function paybackWETH(
        // uint256 amountIn,
        uint256 amountOut,
        uint256 reserveIn,
        uint256 reserveOut
    ) internal returns (uint256 amountToRepay) {

        console.log("To calculate how much WETH to payback -- reserveIn = %s, reserveOut = %s, amnt1=%s...", 
                reserveIn, reserveOut, amountOut);
        uint256 amountToRepay = getAmountIn(amountOut, reserveOut, reserveIn);
        console.log("...To payback %s WETH to make the pool even/same product", amountToRepay);

        // uint256 amountToRepay = safeGetAmountIn(amountOut, reserveIn, reserveOut);
        // uint256 amountToRepay = reserveIn * amountOut / (reserveOut - amountOut) * 1000 / 997 + 1;
        
        // uint256 amountToRepay = reserveIn * reserveOut / (reserveOut - amountOut) * 1000 / 997 
        //        - reserveIn + 1;
        
        //uint256 pairBalanceTokenBorrow = IERC20(addrUSDT).balanceOf(pairAddress);
        //uint256 pairBalanceTokenPay = IERC20(addrWETH).balanceOf(pairAddress);
        // console.log("pairBalanceTokenBorrow = %s, pairBalanceTokenPay = %s", 
        //        pairBalanceTokenBorrow, 
        //        pairBalanceTokenPay);
        //
        // uint256 amountToRepay = ((1000 * pairBalanceTokenPay * amountOut) / (997 * pairBalanceTokenBorrow)) + 1;
        // console.log("...To payback %s WETH to make the pool even/same product", amountToRepay);

        uint256 KK = (reserveIn + amountToRepay) * (reserveOut - amountOut);
        console.log("...... KK = %s", KK);

        // IERC20(addrWETH).approve(pairAddress, amountToRepay + 51686388048);
        IERC20(addrWETH).transfer(msg.sender, amountToRepay);
        // IWETH(addrWETH).deposit.value(amountToRepay)();
        
        uint balanceWETH = IERC20(addrWETH).balanceOf(address(this));
        uint balanceWBTC = IERC20(addrWBTC).balanceOf(address(this));
        uint balanceUSDT = IERC20(addrUSDT).balanceOf(address(this));
        console.log("balance of WETH = %s, balance of WBTC = %s, balance of USDT", 
                balanceWETH, 
                balanceWBTC,
                balanceUSDT);

        // uint256 K = (reserveIn + amountToRepay + 51686388048) * (reserveOut - amountOut);
        // (uint112 r1, uint112 r2, ) = IUniswapV2Pair(pairAddress).getReserves();
        // console.log("+++++++++++ RESERVE INFO ++++++++++++");
        // console.log("Reserve1 of USDT is %s, Reserve2 of WETH is %s", r1, r2);
        // uint256 K = uint256(r1) * uint256(r2);
        // console.log("...... K = %s", K);
        // console.log("+++++++++++ ++++++++++++ ++++++++++++");

    }

    function printReserve() internal {
        (uint112 r1, uint112 r2, ) = IUniswapV2Pair(pairAddress).getReserves();
        console.log("+++++++++++ RESERVE INFO ++++++++++++");
        console.log("Reserve1 of USDT is %s, Reserve2 of WETH is %s", r1, r2);
        uint256 K = uint256(r1) * uint256(r2);
        console.log("...... K = %s", K);
        console.log("+++++++++++ ++++++++++++ ++++++++++++");
    }

    // required by the swap
    function uniswapV2Call(
        address sender,
        uint256 amount0,
        uint256 amount1,
        bytes calldata _data
    ) external override {
        // TODO: implement your liquidation logic
        console.log("uniswapV2Call is being called: amount0 = %s, amount1 = %s", amount0, amount1);
        // 2.0. security checks and initializing variables
        //    *** Your code here ***

        address token0 = IUniswapV2Pair(msg.sender).token0(); // fetch the address of token0
        address token1 = IUniswapV2Pair(msg.sender).token1(); // fetch the address of token1
        assert(msg.sender == IUniswapV2Factory(uniswapV2Factory).getPair(token0, token1)); // ensure that msg.sender is a V2 pair

        console.log("Inside uniswapV2Call, token0 = %s, token1 = %s", token0, token1);
        printReserve();

        uint balanceWETH = IERC20(addrWETH).balanceOf(address(this));
        uint balanceWBTC = IERC20(addrWBTC).balanceOf(address(this));
        uint balanceUSDT = IERC20(addrUSDT).balanceOf(address(this));
        console.log("balance of WETH = %s, balance of WBTC = %s, balance of USDT", 
                balanceWETH, 
                balanceWBTC,
                balanceUSDT);
        /////////////////////////////////////////////////////////////////////////
        // If we hard-ccode everything,we don't have to 
        // transfer data in this way?
        //////////////////////////////////////////////////////////////////////////
        // decode data
        // (
        //    address _tokenBorrow,
        //    uint _amount,
        //    address _tokenPay,
        //    bool _isBorrowingEth,
        //    bool _isPayingEth,
        //    bytes memory _triangleData,
        //    bytes memory _userData
        // ) = abi.decode(_data, (address, uint, address, bool, bool, bytes, bytes));
        //////////////////////////////////////////////////////////////////////////////

        // decode data
        (
            uint112 r1,
            uint112 r2
        ) = abi.decode(_data, (uint112, uint112));

        // 2.1 liquidate the target user
        //    *** Your code here ***
        // address collateralAsset = _token1; // _WBTC;
        // address debtAsset = _token0; // _USDT;
        
        ////////////////////////////////////////////////////
        // AZ... replace collateralAsset with token0
        // AZ... replace debtAsset with token1
        ////////////////////////////////////////////////////
        //
        // address collateralAsset = token0; // _WBTC;
        // address debtAsset = token1; // _USDT;
        ////////////////////////////////////////////////////
        
        uint256 debtToCover = amount1; // amount0;

        console.log("My Balance of debtAsset is %s", IERC20(addrUSDT).balanceOf(address(this)));
        IERC20(addrUSDT).approve(address(lendingPool), debtToCover);
        // require(success, "Approval Failed");

        // require(IERC20(debtAsset).approve(address(lendingPool), debtToCover), "Approval error");        

        address tuser = 0x59CE4a2AC5bC3f5F225439B2993b86B42f6d3e9F;
        console.log("calling liquidationCall with a debToCover = %s", debtToCover);
        console.log("collateralAsset = %s", addrWBTC);
        console.log("debtAsset = %s", addrUSDT);
        
        // lendingPool.liquidationCall(token0, token1, tuser, debtToCover, false);
        lendingPool.liquidationCall(addrWBTC, addrUSDT, tuser, debtToCover, false);

        // AZ: check the balances
        uint balance0 = IERC20(addrWBTC).balanceOf(address(this));
        uint balance1 = IERC20(addrUSDT).balanceOf(address(this));
        console.log("After Liquidation, balance0 of WBTC = %s, balance1 of USDT = %s", balance0, balance1);

        // 2.2 swap WBTC for other things or repay directly
        //    *** Your code here ***

        uint amntWETH = swapWBTC4WETH(balance0);
        console.log("We GOT BACK %s WETH", amntWETH);

        paybackWETH(amount1, r2, r1);

        // IERC20(token0).transfer(sender, balance0);

        // address[] memory path = new address[](2);
        // path[0] = addrWBTC;
        // path[1] = uniswapRouter.WETH();

        // uint amountOutMin = 1000000;
        // IERC20(addrWBTC).approve(UNISWAP_ROUTER_ADDRESS, balance0);
        // uint[] memory amounts = uniswapRouter.swapExactTokensForETH(
        //        balance0,
        //        amountOutMin,
        //        path,
        //        msg.sender, 
        //        block.timestamp + 60);
        // uint amountReceived = amounts[1];
        // console.log("Thru UniswapV2Router02, we got back %s", amountReceived);

        //
        // uint amntToken = balance0 - amount0;
        // IERC20(addrWBTC).approve(address(sushiRouter), amntToken);
        // console.log("To approve %s TOKEN0 transfer", amntToken);
        // console.log("The block timestamp is %s", block.timestamp);
        // uint amountReceived = sushiRouter.swapExactTokensForTokens(
        //        amntToken,
        //        1000, path, msg.sender, block.timestamp + 60)[1];
        // console.log("Thru Sushi Swap, we got back %s", amountReceived);



        //////////////////////////////////////////////
        // 2.2.1 AZ: FIRST TRY......
        //////////////////////////////////////////////
        //////////////////////////////////////////////
        //
        // address[] memory path = new address[](2);
        // path[0] = token0;
        // path[1] = token1;
        //
        // uint amntToken = balance0 - amount0;
        // IERC20(token0).approve(address(sushiRouter), amntToken);
        // console.log("To approve %s TOKEN0 transfer", amntToken);
        // console.log("The block timestamp is %s", block.timestamp);
        // uint amountReceived = sushiRouter.swapExactTokensForTokens(
        //        amntToken,
        //        1000, path, msg.sender, block.timestamp + 60)[1];
        // console.log("Thru Sushi Swap, we got back %s", amountReceived);

        ///////////////////////////////////////////////////////////
        // AAZZZZZZZ
        //////////////////////////////////////////////////////////
        // uint256 amountToRepay = getAmountIn(5000000000, r1, r2);
        // console.log("To payback %s to make the pool even/same product", amountToRepay);
        // IERC20(token0).approve(pairAddress, amountToRepay);
        // IERC20(token0).transfer(pairAddress, amountToRepay);
        // 
        // balance0 = IERC20(token0).balanceOf(address(this));
        // balance1 = IERC20(token1).balanceOf(address(this));
        // console.log("balance10 = %s, balance11 = %s", balance0, balance1);
        // 
        // IERC20(token0).transfer(sender, balance0);

        ////////////////////////////////////////////////////////////
        // _data = abi.encode();
        // IUniswapV2Pair(pairAddress).swap(balance0 - amount0, 0, address(this), "");
        // AZ: copied from swap
        // balance0 = IERC20(token0).balanceOf(address(this));
        // balance1 = IERC20(token1).balanceOf(address(this));
        // console.log("balance10 = %s, balance11 = %s", balance0, balance1);
        ////////////////////////////////////////////////////////////

        // 2.3 repay
        //    *** Your code here ***

        // payback the loan
        // wrap the ETH if necessary
        // if (_isPayingEth) {
        //    IWETH(WETH).deposit.value(amountToRepay)();
        // }
        // IERC20(_tokenBorrow).transfer(_pairAddress, amountToRepay);
        
        // END TODO
    }


}
