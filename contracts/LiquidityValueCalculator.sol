// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.6.6;

import './interfaces/ILiquidityValueCalculator.sol';
import '@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol';
import '@uniswap/v2-periphery/contracts/libraries/UniswapV2Library.sol';

/**
 * @title LiquidityValueCalculator
 * @notice Uniswap V2 LP 토큰 지분에 해당하는 tokenA, tokenB 수량을 계산하는 컨트랙트
 * @dev 특정 Uniswap V2 Factory를 기준으로 Pair 주소를 계산하고, Pair의 reserve와 LP totalSupply를 조회하여 LP 지분 가치를 산출한다
 */
contract LiquidityValueCalculator is ILiquidityValueCalculator {
    
    /**
     * @dev immutable: 배포 후 불변, storage 읽기보다 가스 절약
     */
    address public immutable factory;

    /**
     * @notice 컨트랙트 생성 시 Uniswap Factory 주소를 설정한다
     * @dev Factory 주소는 Pair 주소 계산(pairFor)에 사용되며, 배포 후 변경되지 않는다
     * @param _factory Uniswap V2 Factory 컨트랙트 주소
     */
    constructor(address _factory) public {
        factory = _factory;
    }

    /**
     * @notice 주어진 tokenA, tokenB 페어의 reserve와 LP totalSupply를 조회한다
     * @dev UniswapV2Library를 사용해 Factory 상태 조회 없이 Pair 주소를 계산한다 (CREATE2)
     * @param tokenA 조회할 첫 번째 토큰 주소
     * @param tokenB 조회할 두 번째 토큰 주소
     * @return reserveA tokenA 기준 reserve 수량
     * @return reserveB tokenB 기준 reserve 수량
     * @return totalSupply 해당 Pair의 LP 토큰 총 발행량
     */
    function pairInfo(address tokenA, address tokenB) internal view returns (uint reserveA, uint reserveB, uint totalSupply) {

        /// @dev CREATE2 기반으로 Pair 주소를 계산하여 인터페이스로 캐스팅
        IUniswapV2Pair pair = IUniswapV2Pair(
            UniswapV2Library.pairFor(factory, tokenA, tokenB)
        );

        /// @dev LP 토큰 총 발행량 조회 (전체 유동성 지분)
        totalSupply = pair.totalSupply();

        /// @dev Pair는 token0/token1 정렬 순서로 reserve 반환
        (uint reserve0, uint reserve1,) = pair.getReserves();

        /// @dev tokenA/tokenB 순서에 맞게 reserve 재정렬
        (reserveA, reserveB) = tokenA == pair.token0() ? (reserve0, reserve1) : (reserve1, reserve0);
    }

    /**
     * @notice 사용자가 보유한 LP 토큰 수량에 해당하는 tokenA, tokenB 수량을 계산한다
     * @dev Pair의 reserve와 totalSupply를 기반으로 지분 비율을 계산하여 반환한다
     * @param liquidity 사용자가 보유한 LP 토큰 수량 (지분)
     * @param tokenA 페어를 구성하는 첫 번째 토큰 주소
     * @param tokenB 페어를 구성하는 두 번째 토큰 주소
     * @return tokenAAmount 해당 LP 지분으로 받을 수 있는 tokenA 수량
     * @return tokenBAmount 해당 LP 지분으로 받을 수 있는 tokenB 수량
     */
    function computeLiquidityShareValue(uint liquidity, address tokenA, address tokenB) external override returns (uint tokenAAmount, uint tokenBAmount) {
        
        /// @dev Pair의 reserve와 totalSupply 조회 (내부 헬퍼 함수)
        (uint reserveA, uint reserveB, uint totalSupply) = pairInfo(tokenA, tokenB);

        /// @dev totalSupply가 0이면 유동성이 없는 상태이므로 계산 불가
        require(totalSupply > 0, "LiquidityValueCalculator: Total supply is zero");

        /// @dev 핵심 계산 로직: 내 LP 비율 * 각 reserve = 받을 토큰
        tokenAAmount = liquidity * reserveA / totalSupply;
        tokenBAmount = liquidity * reserveB / totalSupply;

        /// @dev 반환값은 named return 변수(tokenAAmount, tokenBAmount)에 할당되었으므로 별도의 return 문 없이 자동 반환된다 (implicit return)
    }
}