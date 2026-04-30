// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.6.6;

/**
 * @title ILiquidityValueCalculator
 * @notice Uniswap V2 LP 토큰의 지분에 해당하는 tokenA, tokenB 수량을 계산하는 인터페이스
 * @dev 구현체는 Pair의 reserve와 totalSupply를 기반으로 비율 계산을 수행해야 함
 */
interface ILiquidityValueCalculator {
    
    /**
     * @notice LP 토큰 수량에 해당하는 tokenA, tokenB 수량을 계산한다
     * @dev tokenA/tokenB 순서는 입력 기준이며, 내부적으로 Pair의 token0/token1과 매핑되어야 함
     * @param liquidity 사용자가 보유한 LP 토큰 수량
     * @param tokenA tokenA 페어를 구성하는 첫 번째 토큰 주소
     * @param tokenB tokenB 페어를 구성하는 두 번째 토큰 주소
     * @return tokenAAmount tokenAAmount 해당 LP 지분으로 받을 수 있는 tokenA 수량
     * @return tokenBAmount tokenBAmount 해당 LP 지분으로 받을 수 있는 tokenB 수량
     */
    function computeLiquidityShareValue(
        uint liquidity,
        address tokenA,
        address tokenB
    ) external returns (uint tokenAAmount, uint tokenBAmount);
}