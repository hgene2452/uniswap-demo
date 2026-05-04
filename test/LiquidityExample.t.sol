// SPDX-License-Identifier: SEE LICENSE IN LICENSE
pragma solidity ^0.6.6;
pragma experimental ABIEncoderV2;

import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IWETH.sol";
import "@uniswap/v2-core/contracts/interfaces/IERC20.sol";
import "../contracts/LiquidityExample.sol";

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

// ── 테스트 컨트랙트 ─────────────────────────────────────────────────
contract LiquidityExampleTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    IUniswapV2Factory factory;
    IWETH weth;
    IUniswapV2Router02 router;
    MockERC20 DAI;
    IUniswapV2Pair pair;
    LiquidityExample liquidityExample;

    // 초기 DAI 보유량 추적용 (검증에 사용)
    uint initialDAI;

    // ETH 수신을 위해 필요
    receive() external payable {}

    function setUp() public {
        // 1. Factory 배포 — 사전 컴파일된 바이트코드 사용
        bytes memory factoryBytecode = vm.readFileBinary("test/UniswapV2Factory.bin");
        bytes memory factoryCreationCode = abi.encodePacked(
            factoryBytecode,
            abi.encode(address(this))
        );
        address factoryAddr;
        assembly {
            factoryAddr := create(0, add(factoryCreationCode, 0x20), mload(factoryCreationCode))
        }
        require(factoryAddr != address(0), "FACTORY_DEPLOY_FAILED");
        factory = IUniswapV2Factory(factoryAddr);

        // 2. WETH 배포 — Router 생성자에 필요
        bytes memory wethBytecode = vm.readFileBinary("test/WETH9.bin");
        address wethAddr;
        assembly {
            wethAddr := create(0, add(wethBytecode, 0x20), mload(wethBytecode))
        }
        require(wethAddr != address(0), "WETH_DEPLOY_FAILED");
        weth = IWETH(wethAddr);

        // 3. Router 배포 — factory + WETH 주소 전달
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

        // 4. DAI 토큰 배포
        DAI = new MockERC20("DAI Stablecoin", "DAI");

        // 5. 초기 DAI/WETH 유동성 풀 생성
        //    DAI 200개 + ETH 1개 → 초기 가격 200 DAI/ETH 설정
        factory.createPair(address(DAI), address(weth));
        address pairAddr = factory.getPair(address(DAI), address(weth));
        require(pairAddr != address(0), "PAIR_NOT_CREATED");
        pair = IUniswapV2Pair(pairAddr);

        uint initialDAILiquidity = 200 * 10**18;
        uint initialETHLiquidity = 1 ether;

        // DAI를 Pair로 직접 전송
        DAI.transfer(pairAddr, initialDAILiquidity);

        // ETH → WETH 변환 후 Pair로 전송
        // Pair는 ERC20만 처리하므로 ETH는 반드시 WETH로 변환
        weth.deposit{value: initialETHLiquidity}();
        weth.transfer(pairAddr, initialETHLiquidity);

        // mint: 잔액 차분으로 입금 확인 후 LP 토큰 발행
        pair.mint(address(this));

        // 6. LiquidityExample 컨트랙트 배포 — Router 주소 주입
        liquidityExample = new LiquidityExample(address(router));

        // 초기 DAI 잔액 기록 (검증용)
        // 초기 1,000,000 DAI - 유동성 공급 200 DAI = 999,800 DAI
        initialDAI = DAI.balanceOf(address(this));
    }

    function test_addLiquidityETH() public {
        setUp();

        uint ethAmount = 0.5 ether;

        // 현재 reserve 비율로 DAI 수량 계산
        // Pair의 token0/token1 정렬에 따라 reserve 방향 보정 필요
        (uint reserve0, uint reserve1,) = pair.getReserves();
        (uint reserveDAI, uint reserveETH) = pair.token0() == address(DAI)
            ? (reserve0, reserve1)
            : (reserve1, reserve0);

        // quote: ethAmount 기준으로 비율에 맞는 DAI 수량 계산
        // ethAmount * reserveDAI / reserveETH = 0.5 * 200 / 1 = 100 DAI
        uint daiAmount = ethAmount * reserveDAI / reserveETH;

        // 1% 슬리피지 허용
        // 실제 공급량이 이보다 적으면 Router가 revert
        uint daiMin = daiAmount * 99 / 100;
        uint ethMin = ethAmount * 99 / 100;

        // 유저(테스트 컨트랙트)가 LiquidityExample에게 DAI approve
        // LiquidityExample이 transferFrom으로 DAI를 가져가려면 반드시 필요
        DAI.approve(address(liquidityExample), daiAmount);

        // 공급 전 LP 잔액 기록
        uint lpBefore = pair.balanceOf(address(this));

        // 유동성 공급 실행
        // ETH는 msg.value로 전송, DAI는 내부적으로 transferFrom
        liquidityExample.addLiquidityETH{value: ethAmount}(
            address(DAI),
            daiAmount,
            daiMin,
            ethMin
        );

        // 검증 1: LP 토큰을 받았는지
        // addLiquidityETH에서 to = msg.sender이므로 테스트 컨트랙트가 받음
        require(
            pair.balanceOf(address(this)) > lpBefore,
            "LP_NOT_RECEIVED"
        );

        // 검증 2: DAI가 차감됐는지
        require(
            DAI.balanceOf(address(this)) < initialDAI,
            "DAI_NOT_SPENT"
        );

        // 검증 3: 받은 LP 토큰 수량이 0보다 큰지
        uint lpReceived = pair.balanceOf(address(this)) - lpBefore;
        require(lpReceived > 0, "LP_AMOUNT_ZERO");
    }

    function test_addLiquidityETH_slippageTooHigh() public {
        setUp();

        uint ethAmount = 0.5 ether;
        uint daiAmount = 100 * 10**18;

        DAI.approve(address(liquidityExample), daiAmount);

        // amountMin을 말도 안 되게 높게 설정 → revert 발생해야 함
        // amountOutMin 안전장치 검증과 동일한 원리
        uint daiMin = 999 * 10**18;  // 실제로 받을 수 있는 양보다 훨씬 큼
        uint ethMin = 999 ether;

        (bool success,) = address(liquidityExample).call{value: ethAmount}(
            abi.encodeWithSignature(
                "addLiquidityETH(address,uint256,uint256,uint256)",
                address(DAI),
                daiAmount,
                daiMin,
                ethMin
            )
        );
        require(!success, "SHOULD_HAVE_REVERTED");
    }
}