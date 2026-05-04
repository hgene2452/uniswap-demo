// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import "@uniswap/v2-core/contracts/interfaces/IERC20.sol";
import "../contracts/SwapExample.sol";

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
    mapping(address => mapping(address => uint)) public allowance;

    constructor(string memory _name, string memory _symbol) public {
        name = _name;
        symbol = _symbol;
        _mint(msg.sender, 1_000_000 ether);
    }

    function transfer(address to, uint amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "BALANCE_TOO_LOW");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    // approve/transferFrom이 필요한 이유:
    // SwapExample이 유저 지갑에서 토큰을 가져올 때 transferFrom 사용
    // → 유저가 먼저 SwapExample에게 approve 해줘야 함
    function approve(address spender, uint amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transferFrom(address from, address to, uint amount) external returns (bool) {
        require(balanceOf[from] >= amount, "BALANCE_TOO_LOW");
        require(allowance[from][msg.sender] >= amount, "ALLOWANCE_TOO_LOW");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function _mint(address to, uint amount) internal {
        balanceOf[to] += amount;
        totalSupply += amount;
    }
}

contract SwapExampleTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    IUniswapV2Factory factory;
    IWETH weth;
    IUniswapV2Router02 router;
    MockERC20 DAI;
    IUniswapV2Pair pair;
    SwapExample swapExample;

    receive() external payable {}

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

        bytes memory wethBytecode = vm.readFileBinary("test/WETH9.bin");
        address wethAddr;
        assembly {
            wethAddr := create(0, add(wethBytecode, 0x20), mload(wethBytecode))
        }
        require(wethAddr != address(0), "WETH_DEPLOY_FAILED");
        weth = IWETH(wethAddr);

        bytes memory routerBytecode = vm.readFileBinary("test/UniswapV2Router02.bin");
        bytes memory routerCreationCode = abi.encodePacked(
            routerBytecode,
            abi.encode(address(factory), address(weth))
        );
        address routerAddr;
        assembly {
            routerAddr := create(0, add(routerCreationCode, 0x20), mload(routerCreationCode))
        }
        require(routerAddr != address(0), "ROUTER_DEPLOY_FAILED");
        router = IUniswapV2Router02(routerAddr);

        DAI = new MockERC20("DAI Stablecoin", "DAI");

        factory.createPair(address(DAI), address(weth));
        address pairAddr = factory.getPair(address(DAI), address(weth));
        require(pairAddr != address(0), "PAIR_NOT_CREATED");
        pair = IUniswapV2Pair(pairAddr);

        uint daiAmount = 1_000 * 10**18;
        uint ethAmount = 1 ether;

        // DAI를 Pair로 전송
        DAI.transfer(pairAddr, daiAmount);

        weth.deposit{value: ethAmount}();
        weth.transfer(pairAddr, ethAmount);

        // mint: 잔액 차분으로 입금 확인 후 LP 토큰 발행
        pair.mint(address(this));

        // 6. SwapExample 컨트랙트 배포 — Router 주소 주입
        swapExample = new SwapExample(address(router));
    }

    function test_swapTokenForETH() public {
        // 테스트 컨트랙트가 보유한 DAI 50개를 스왑
        uint amountIn = 50 * 10**18;

        // ① 유저(테스트 컨트랙트)가 SwapExample에게 approve
        //    SwapExample이 transferFrom으로 DAI를 가져가려면 반드시 필요
        DAI.approve(address(swapExample), amountIn);

        // amountOutMin 계산: Pair의 현재 reserve로 예상 출력량 계산 후 1% 슬리피지 허용
        // 실제 프로덕션에서는 Chainlink 같은 외부 오라클 사용 필수
        (uint reserve0, uint reserve1,) = pair.getReserves();

        // token0이 DAI인지 WETH인지 확인 후 reserve 방향 설정
        (uint reserveDAI, uint reserveWETH) = pair.token0() == address(DAI)
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // x*y=k 수식으로 예상 출력량 계산 (수수료 0.3% 적용)
        uint amountInWithFee = amountIn * 997;
        uint numerator = amountInWithFee * reserveWETH;
        uint denominator = reserveDAI * 1000 + amountInWithFee;
        uint expectedOut = numerator / denominator;

        // 1% 슬리피지 허용
        uint amountOutMin = expectedOut * 99 / 100;

        // 스왑 전 ETH 잔액 기록
        uint ethBefore = address(this).balance;

        // ② 스왑 실행
        //    내부 흐름: SwapExample이 DAI transferFrom → Router approve → Router가 Pair로 전송 → ETH 수령
        swapExample.swapTokenForETH(amountIn, amountOutMin, address(DAI));

        // 검증 1: ETH를 받았는지
        require(address(this).balance > ethBefore, "ETH_NOT_RECEIVED");

        // 검증 2: 최소 수령량 이상 받았는지
        require(address(this).balance - ethBefore >= amountOutMin, "SLIPPAGE_TOO_HIGH");

        // 검증 3: DAI 50개가 차감됐는지
        //         초기 보유량 1,000,000 DAI - 유동성 공급 1,000 DAI - 스왑 50 DAI = 998,950 DAI
        require(DAI.balanceOf(address(this)) == (1_000_000 ether - 1_000 ether - amountIn), "DAI_NOT_SPENT");
    }

    function test_revertIfAmountOutMinTooHigh() public {
        uint amountIn = 50 * 10**18;
        DAI.approve(address(swapExample), amountIn);

        // amountOutMin을 말도 안 되게 높게 설정 → revert 발생해야 함
        // 이 테스트로 amountOutMin 안전장치가 실제로 동작하는지 검증
        uint amountOutMin = 999 ether;

        (bool success,) = address(swapExample).call(
            abi.encodeWithSignature(
                "swapTokenForETH(uint256,uint256,address)",
                amountIn,
                amountOutMin,
                address(DAI)
            )
        );
        require(!success, "SHOULD_HAVE_REVERTED");
    }
}