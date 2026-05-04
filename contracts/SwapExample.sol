// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.6.6;

import './interfaces/ISwapExample.sol';
import '@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol';
import '@uniswap/v2-core/contracts/interfaces/IERC20.sol';

/**
 * @title SwapExample
 * @dev Uniswap V2 Router를 통해 ERC20 토큰을 ETH로 스왑하는 컨트랙트
 * @dev 스왑 흐름 : 
 *      사용자 EOA -> 컨트랙트(SwapExample) approve
 *      사용자 EOA -> 컨트랙트(SwapExample) transferFrom
 *      컨트랙트(SwapExample) -> Uniswap Router approve
 *      컨트랙트(SwapExample) -> Uniswap Pair transferFrom
 *      Uniswap Pair swap
 */
contract SwapExample is ISwapExample {

    // @dev Uniswap V2 Router 주소
    IUniswapV2Router02 public immutable router;

    /**
     * @dev Router 주소를 생성자에서 주입받아 저장
     * @param _router Uniswap V2 Router02 컨트랙트 주소
     */
    constructor(address _router) public {
        router = IUniswapV2Router02(_router);
    }

    // @dev ETH 수신을 위한 receive 함수
    receive() external payable {}

    /**
     * @dev ERC20 토큰을 ETH로 스왑
     * @notice 호출 전 유저가 반드시 이 컨트랙트 주소로 amountIn 만큼의 토큰을 approve 해야 함
     * @param amountIn 스왑할 토큰 양
     * @param amountOutMin 최소 수령할 ETH 양
     * @param token 스왑할 토큰 주소
     */
    function swapTokenForETH(
        uint amountIn,
        uint amountOutMin,
        address token
    ) external override {

        // @dev 사용자로부터 토큰을 컨트랙트로 전송받기 위해 IERC20 인터페이스 사용
        IERC20 tokenContract = IERC20(token);

        // @dev (1) 사용자 EOA로부터 토큰을 컨트랙트로 전송받기 위해 transferFrom 호출
        require(
            tokenContract.transferFrom(msg.sender, address(this), amountIn),
            "Token transfer failed"
        );

        // @dev (2) 컨트랙트가 Uniswap Router에 approve 권한을 부여하여 Pair 컨트랙트로 스왑 수행 가능하도록 설정
        require(
            tokenContract.approve(address(router), amountIn),
            "Token approval failed" 
        );

        // @dev (3) 스왑 경로 설정 - 토큰 -> WETH
        address[] memory path = new address[](2);
        path[0] = token;
        path[1] = router.WETH();

        // @dev (4) Uniswap Router의 swapExactTokensForETH 함수를 호출하여 스왑 수행
        router.swapExactTokensForETH(
            amountIn,           // 스왑할 토큰 양
            amountOutMin,       // 최소 수령할 ETH 양 (이보다 적으면 트랜잭션 실패)
            path,               // 스왑 경로 (토큰 -> WETH)
            msg.sender,         // 스왑된 ETH를 받을 주소 (사용자 EOA)
            block.timestamp     // 트랜잭션 유효 시간 (현재 블록 타임스탬프 기준)
        );
    }
}