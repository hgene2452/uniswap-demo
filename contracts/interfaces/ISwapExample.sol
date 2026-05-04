// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.6.6;

/**
 * @title ISwapExample
 * @dev ERC20 토큰을 ETH로 스왑하는 컨트랙트 인터페이스
 */
interface ISwapExample {

    /**
     * @dev ERC20 토큰을 ETH로 스왑
     * @notice 호출 전 반드시 스왑할 토큰을 이 컨트랙트 주소로 approve 해야 함
     * @notice amountOutMin은 외부 오라클 기반으로 계산해야 프론트런 공격 방어가 가능해짐
     * @param amountIn 스왑할 ERC20 토큰의 양
     * @param amountOutMin 최소로 받을 ETH의 양 (이보다 적게 받으면 트랜잭션 revert)
     * @param token 스왑할 ERC20 토큰의 주소
     */
    function swapTokenForETH(
        uint amountIn,
        uint amountOutMin,
        address token
    ) external;
}