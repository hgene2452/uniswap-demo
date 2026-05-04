pragma solidity ^0.6.6;

interface ILiquidityExample {

    /**
     * @dev ERC20/ERC20 페어에 유동성 공급
     * @dev 호출 전 tokenA, tokenB 모두 이 컨트랙트에 approve 필요
     * @param tokenA 첫 번째 토큰 주소
     * @param tokenB 두 번째 토큰 주소
     * @param amountADesired 공급하려는 tokenA 수량
     * @param amountBDesired 공급하려는 tokenB 수량 (현재 비율 기준으로 계산)
     * @param amountAMin 슬리피지 허용 후 최소 공급 tokenA 수량
     * @param amountBMin 슬리피지 허용 후 최소 공급 tokenB 수량
     */
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin
    ) external returns (uint amountA, uint amountB, uint liquidity);

    /**
     * @dev ETH/ERC20 페어에 유동성 공급
     * @dev 호출 전 token을 이 컨트랙트에 approve 필요, ETH는 msg.value로 전송
     * @param token ERC20 토큰 주소
     * @param amountTokenDesired 공급하려는 토큰 수량
     * @param amountTokenMin 슬리피지 허용 후 최소 공급 토큰 수량
     * @param amountETHMin 슬리피지 허용 후 최소 공급 ETH 수량
     */
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}