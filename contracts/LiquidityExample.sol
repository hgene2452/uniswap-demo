pragma solidity ^0.6.6;

import './interfaces/ILiquidityExample.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import '@uniswap/v2-core/contracts/interfaces/IERC20.sol';

contract LiquidityExample is ILiquidityExample {

    // Router 주소 (배포 후 변경 불가)
    IUniswapV2Router02 public immutable router;

    constructor(address _router) public {
        router = IUniswapV2Router02(_router);
    }

    // ETH 잔액 반환을 위해 receive 필요
    receive() external payable {}

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) external override returns (uint amountA, uint amountB, uint liquidity) {

        // ① 유저 → 컨트랙트로 두 토큰 모두 가져오기
        IERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);

        // ② Router가 두 토큰을 가져갈 수 있도록 approve
        IERC20(tokenA).approve(address(router), amountADesired);
        IERC20(tokenB).approve(address(router), amountBDesired);

        // ③ 유동성 공급 실행
        //    Router가 현재 비율에 맞게 두 토큰을 조정해서 Pair로 전송
        //    amountAMin/amountBMin 범위 벗어나면 revert
        //    LP 토큰은 msg.sender(유저)에게 직접 발행
        (amountA, amountB, liquidity) = router.addLiquidity(
            tokenA,
            tokenB,
            amountADesired,   // 최대한 이만큼 공급하고 싶음
            amountBDesired,   // 최대한 이만큼 공급하고 싶음
            amountAMin,       // 슬리피지 허용 최소치 (이보다 적으면 revert)
            amountBMin,       // 슬리피지 허용 최소치
            msg.sender,       // LP 토큰 수신자 = 유저
            block.timestamp   // deadline
        );

        // ④ Router가 사용하고 남은 토큰 유저에게 반환
        //    Router는 비율에 맞게 조정 후 남는 토큰을 컨트랙트로 돌려보냄
        uint remainA = IERC20(tokenA).balanceOf(address(this));
        uint remainB = IERC20(tokenB).balanceOf(address(this));
        if (remainA > 0) IERC20(tokenA).transfer(msg.sender, remainA);
        if (remainB > 0) IERC20(tokenB).transfer(msg.sender, remainB);
    }

    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin
    ) external payable override returns (uint amountToken, uint amountETH, uint liquidity) {

        // ① 유저 → 컨트랙트로 토큰 가져오기 (ETH는 msg.value로 이미 수신)
        IERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);

        // ② Router에게 토큰 approve (ETH는 approve 불필요)
        IERC20(token).approve(address(router), amountTokenDesired);

        // ③ ETH/ERC20 유동성 공급
        //    Router가 ETH를 자동으로 WETH로 변환해서 Pair로 전송
        //    LP 토큰은 msg.sender에게 발행
        (amountToken, amountETH, liquidity) = router.addLiquidityETH{value: msg.value}(
            token,
            amountTokenDesired,
            amountTokenMin,
            amountETHMin,
            msg.sender,       // LP 토큰 수신자 = 유저
            block.timestamp
        );

        // ④ 남은 토큰/ETH 유저에게 반환
        uint remainToken = IERC20(token).balanceOf(address(this));
        if (remainToken > 0) IERC20(token).transfer(msg.sender, remainToken);
        if (address(this).balance > 0) msg.sender.transfer(address(this).balance);
    }
}