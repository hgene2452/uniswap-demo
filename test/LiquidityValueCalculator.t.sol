// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "../contracts/LiquidityValueCalculator.sol";

interface Vm {
    function readFile(string calldata path) external returns (string memory);
    function readFileBinary(string calldata path) external returns (bytes memory);
    function parseJson(string calldata json, string calldata key) external returns (bytes memory);
    function getCode(string calldata path) external returns (bytes memory);
}

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint public totalSupply;
    mapping(address => uint) public balanceOf;

    constructor(string memory name_, string memory symbol_) public {
        name = name_;
        symbol = symbol_;
        _mint(msg.sender, 1_000_000 ether);
    }

    function transfer(address to, uint amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BALANCE_TOO_LOW");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function _mint(address to, uint amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract LiquidityValueCalculatorTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    IUniswapV2Factory factory;
    MockERC20 tokenA;
    MockERC20 tokenB;
    IUniswapV2Pair pair;
    LiquidityValueCalculator calculator;

    function setUp() public {
        // .bin 파일은 순수 바이너리 → 파싱 불필요, 그대로 바이트코드로 사용
        bytes memory factoryBytecode = vm.readFileBinary(
            "test/UniswapV2Factory.bin"
        );
        require(factoryBytecode.length > 0, "BYTECODE_EMPTY");

        bytes memory creationCode = abi.encodePacked(
            factoryBytecode,
            abi.encode(address(this))
        );

        address factoryAddr;
        assembly {
            factoryAddr := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        require(factoryAddr != address(0), "FACTORY_DEPLOY_FAILED");
        factory = IUniswapV2Factory(factoryAddr);

        tokenA = new MockERC20("TokenA", "TKA");
        tokenB = new MockERC20("TokenB", "TKB");

        factory.createPair(address(tokenA), address(tokenB));
        address pairAddress = factory.getPair(address(tokenA), address(tokenB));
        require(pairAddress != address(0), "PAIR_NOT_CREATED");
        pair = IUniswapV2Pair(pairAddress);

        tokenA.transfer(pairAddress, 1000 * 10**18);
        tokenB.transfer(pairAddress, 500  * 10**18);
        pair.mint(address(this));

        calculator = new LiquidityValueCalculator(address(factory));
    }

    function test_computeLiquidityShareValue() public {
        setUp();

        uint lpBalance = pair.balanceOf(address(this));
        require(lpBalance > 0, "NO_LP_BALANCE");

        (uint tokenAAmount, uint tokenBAmount) = calculator.computeLiquidityShareValue(
            lpBalance,
            address(tokenA),
            address(tokenB)
        );

        require(tokenAAmount > 0, "TOKEN_A_ZERO");
        require(tokenBAmount > 0, "TOKEN_B_ZERO");
        require(tokenAAmount < 1000 * 10**18, "TOKEN_A_TOO_HIGH");
        require(tokenBAmount < 500  * 10**18, "TOKEN_B_TOO_HIGH");

        // 정수 나눗셈으로 2:1 비율 검증
        require(tokenAAmount / tokenBAmount == 2, "INVALID_RATIO");
    }

    function test_zeroLiquidity() public {
        setUp();

        (uint amountA, uint amountB) = calculator.computeLiquidityShareValue(
            0,
            address(tokenA),
            address(tokenB)
        );
        require(amountA == 0, "AMOUNT_A_NOT_ZERO");
        require(amountB == 0, "AMOUNT_B_NOT_ZERO");
    }
}