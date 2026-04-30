# 🦄 Uniswap V2 아키텍처 정리

> Uniswap V2의 Core / Periphery 구조와 핵심 설계 결정을 학습하며 정리한 문서입니다.

---

## 목차

1. [Core](#1-core)
   - [Factory](#11-factory)
   - [Pair](#12-pair)
2. [Periphery](#2-periphery)
   - [Library](#21-library)
   - [Router](#22-router)
3. [핵심 설계](#3-핵심-설계)
   - [토큰 전송 방식](#31-토큰-전송-방식)
   - [ETH 대신 WETH 사용](#32-eth-대신-weth-사용)
   - [최소 유동성 소각](#33-최소-유동성-소각)
4. [기타](#4-기타)
   - [비원자적 스왑 실행](#41-비원자적-스왑-실행)
   - [swap 파라미터가 출력량인 이유](#42-swap-파라미터가-출력량인-이유)
5. [실습](#5-실습)
   - [Smart Contract Getting Started](#51-smart-contract-getting-started)

---

## 1 Core

### 1.1 Factory

**딱 하나만 존재하는 싱글턴 형태**
- 메인넷에 이미 배포된 Factory 주소에 접근해서 사용해야 함
- Factory가 하나이기 때문에 내부 장부에서 관리하는 데이터(Pair)들의 중복 관리가 용이

**역할은 두 가지**
- 토큰 쌍마다 Pair 컨트랙트를 딱 하나만 배포
- 프로토콜 수수료를 켜고 끄는 스위치 관리
  - 스왑 금액은 항상 **0.3% 수수료**가 붙음
  - 프로토콜 수수료 **OFF** → 0.3% 전액이 LP에게 감
    - 수수료는 풀 안에 그냥 쌓여 풀의 잔액을 키우고, LP가 이후 유동성을 회수할 때 더 많은 토큰을 받아가는 구조
    - 프로토콜 수수료 **ON** → 0.25%는 LP에게, 0.05%는 Uniswap 거버넌스 금고(`feeTo`)로 감

</br>

### 1.2 Pair

**Factory가 생성하는 컨트랙트** (`createPair()`)
**역할은 세 가지**

#### AMM 로직 실행

| 함수 | 역할 |
|------|------|
| `swap()` | 핵심 AMM. 토큰 교환 |
| `mint()` | 유동성 추가. LP 토큰 발행 |
| `burn()` | 유동성 제거. LP 토큰 소각 |
| `_mintFee()` | 프로토콜 수수료 정산 |
| `skim()` | 초과 잔액 강제 제거 |
| `sync()` | 풀 보유량을 실잔액에 강제 동기화 |

#### 두 토큰의 잔액 추적

- storage 상태변수로 풀의 Token0/1 잔액 스냅샷과 마지막 업데이트 블록 시각을 저장
- `getReserves()` : `reserve0`, `reserve1`, `timestamp` 반환
- `_update()` : reserve 갱신 + 오라클 누적값 계산

#### 탈중앙화 가격 오라클 데이터 노출

- `price0/1CumulativeLast` : Token0/1 기준 누적 가격 (공개 변수)
- 현재 가격을 오라클 데이터로 활용하면 공격자가 대량 매수로 가격을 조작한 다음 차익 실현 후 원복할 수 있기 때문에 **시간에 걸친 평균가(TWAP)** 를 사용
- 평균가 계산은 오라클 데이터를 읽는 쪽에서 하고, Pair는 누적값만 노출

```
TWAP = (price0CumulativeLast_T2 - price0CumulativeLast_T1) / (T2 - T1)
```

---

## 2 Periphery

### 2.1 Library

- 가격 계산, 최적 경로 찾기 등 **편의 함수 모음**
- 주요 함수: `sortTokens()`, `pairFor()`, `getReserves()`, `getAmountOut()`, `getAmountsOut()` 등

</br>

### 2.2 Router

- Library를 사용하며, **역할은 세 가지**

#### X → Y → Z 같은 멀티-홉 스왑 지원

- Pair는 항상 두 토큰 사이에만 존재하는데, 세상에는 직접 페어가 없는 조합이 많음
- Router는 중간 토큰이 유저 지갑을 거치지 않고 **Pair → Pair로 직접 이동**하도록 함
- 중간에 유저 지갑을 거치는 과정이 생략되어 → **가스 절약 + 원자적 실행** 보장

```
DAI → ETH → LINK (2홉)

유저 지갑                 DAI/ETH Pair           ETH/LINK Pair
   │                          │                       │
   │── DAI 전송 ──────────────▶│                       │
   │                          │── ETH 직접 전송 ──────▶│
   │◀──────────────────────────────── LINK 수령 ───────│
```

#### ETH를 자동으로 WETH로 감싸주기

- V2부터 유니스왑 Core는 **Native ETH를 다루지 않음**
- 하지만 사용자는 ETH로 거래하기 때문에 자동으로 ERC-20으로 변환해서 내부에서 사용

```
ETH → Token:  Router가 ETH 수신 → deposit()으로 WETH 변환 → Pair로 전송
Token → ETH:  Pair에서 WETH 수령 → Router가 withdraw()로 ETH 변환 → 유저에게 전달
```

#### 유동성 제거를 위한 메타 트랜잭션 지원

- LP가 유동성을 제거하면 Pair는 해당 LP 토큰을 자신의 권한으로 소각하고, 지분만큼의 금액을 반환
  - → 즉, `burn()` 함수에서 소각하고자 하는 LP의 **권한을 위임받은 상태**여야 함
- 토큰 전송 시에는?
  - Uniswap V2의 `swap()`은 Router가 `transfer()`를 스왑하고자 하는 양만큼 Pair에 하면 Pair가 직전/후 보유량 잔액 차이만큼 스왑해주는 형태이기 때문에 **메타 트랜잭션 필요 없음**

```
일반 방식:      approve TX + removeLiquidity TX  =  트랜잭션 2개
메타 트랜잭션:  오프체인 서명 + removeLiquidityWithPermit TX  =  트랜잭션 1개
```

---

## 3 핵심 설계

### 3.1 토큰 전송 방식

- 일반적인 DeFi 컨트랙트는 `approve → transferFrom` 순으로 토큰을 전송
- **V2 Pair는 `transfer` 1번으로 처리:**

```
1. Router가 토큰을 Pair 주소로 전송 (transfer)
2. Router가 Pair의 swap() 함수를 호출
3. Pair가 이전 잔액과 현재 잔액의 차이를 계산하여 입력량 파악
```

- **보안 및 가스 효율** 측면에서 유리
- 부산물로 **Flash Swap** 가능 (출력 먼저 받고 나중에 갚는 구조)

| 방식 | 트랜잭션 | 보안 | Flash Swap |
|------|---------|------|-----------|
| approve → transferFrom | 2단계 | allowance 노출 | 불가 |
| transfer + 잔액차분 | 1단계 | allowance 없음 | 가능 |

</br>

### 3.2 ETH 대신 WETH 사용

- V1은 ETH를 직접 지원하기 때문에 Core 코드에 ETH 특수처리가 곳곳에 섞여 있음
- V2는 **Core에서 ETH 코드를 완전히 제거**
- ETH는 Router에서 자동으로 WETH ↔ ETH로 변환되기 때문에 **UX는 유지하면서 Core는 단순화**

```
V1: Core 안에 ETH 특수처리 코드 존재 → 복잡, 버그 위험
V2: Core는 ERC-20만 처리 / ETH 변환은 Periphery(Router)가 전담
```

> 💡 WETH는 "ETH를 ERC-20 세계로 입장시키는 어댑터"

---

### 3.3 최소 유동성 소각

- 최초로 유동성을 공급할 때 `MINIMUM_LIQUIDITY`(= 1000) 만큼의 LP 토큰을 **영구 소각**

```solidity
uint public constant MINIMUM_LIQUIDITY = 10**3; // 1000

if (_totalSupply == 0) {
    liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
    _mint(address(0), MINIMUM_LIQUIDITY); // 영구 소각
}
```

**해결하는 문제 두 가지:**

- 반올림 오류 공격 방지 : </br>
공격자가 아주 적은 양으로 최초 공급 후 직접 대량 기부로 LP 1개당 가치를 극단적으로 올리면, 이후 일반 유저가 유동성을 공급해도 LP 토큰을 0개 받게 되는 공격이 가능했음. </br>
`MINIMUM_LIQUIDITY` 소각으로 최초 공급 시 의미 있는 금액이 강제되어 공격 비용이 극단적으로 높아짐.

- totalSupply가 0이 되는 것 방지: </br>
LP 토큰이 전부 소각되면 `totalSupply = 0`이 되어 이후 LP 토큰 계산식의 분모가 0이 되는 문제 발생.</br>
1000개가 영구 잠금되므로 `totalSupply`는 항상 최소 1000 이상 유지.

---

## 4 기타

### 4.1 비원자적 스왑 실행

`transfer + swap`은 **하나의 트랜잭션으로 원자성을 가지고** 이루어져야 함.

```
❌ 위험한 시나리오:

TX 1: 유저가 USDC 1000개를 Pair로 전송 (블록에 포함됨)
         ↓
      다음 블록 대기 중...
         ↓
TX 2: 유저가 swap() 호출 예정

이 사이에 봇이 개입:
→ Pair에 USDC가 쌓인 걸 감지
→ 봇이 먼저 swap() 호출
→ 유저 돈으로 봇이 스왑 이익 챙김
→ 유저 TX 2는 실패 (이미 잔액 소진)
```

같은 트랜잭션 내에서 `transfer → swap`이 연속 실행되면 위와 같은 상황 발생하지 않음.

</br>

### 4.2 swap 파라미터가 출력량인 이유

```solidity
function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data)
```

- **입력량을 파라미터로 받지 않는 이유:**
  - 잔액 차분 방식에서 Pair는 reserve 스냅샷을 통해 얼마가 들어왔는지 직접 계산 → 입력량은 파라미터 불필요

- **출력량을 파라미터로 받는 이유:**
  - 출력량은 Pair가 직접 결정할 수 없음
  - `swap()` 호출자가 "나는 Token B를 이만큼 받고 싶다"라고 명시해야만 Pair가 그만큼 출력하고 k값으로 검증 가능

---

## 5 실습

### 5.1 Smart Contract Getting Started

**목적:** LP 토큰 지분 가치 계산기 컨트랙트 구현. 주어진 LP 수량으로 돌려받을 토큰A/B 수량 계산

#### 개발 스택

| 항목 | 내용 |
|------|------|
| 언어 | Solidity (^0.6.6) |
| 컴파일 / 테스트 / 배포 | Foundry (최신 버전) |
| 패키지 매니저 | npm (≥ 6.x) |
| 런타임 | Node.js (≥ v12.x) |
| Uniswap 패키지 | @uniswap/v2-core, @uniswap/v2-periphery |
| EVM 실행 환경 | Foundry 로컬 체인 (forge test 내장) |

---

#### Step 1. Foundry 설치 확인 및 프로젝트 초기화

Foundry가 설치되어 있어야 하므로, 설치되지 않았다면 foundry.sh 공식 스크립트로 설치.
`forge init` 이후 `src/`, `test/`, `script/`, `foundry.toml` 파일이 자동 생성됨.

```bash
# Foundry 설치 확인
forge --version
cast --version
anvil --version

# Foundry 설치 (최초 1회)
curl -L https://foundry.paradigm.xyz | bash
foundryup

# 프로젝트 폴더 생성 및 초기화
mkdir uniswap-v2-demo
cd uniswap-v2-demo
forge init .
```

---

#### Step 2. npm 초기화 및 Uniswap 패키지 설치

Foundry는 기본적으로 git submodule로 의존성을 관리하지만, Uniswap V2는 npm 패키지로 배포되어 있음.
`npm init`으로 `package.json`을 만들고, v2-core와 v2-periphery를 설치.

```bash
# npm 초기화 (전부 Enter로 기본값 수락)
npm init -y

# Uniswap V2 패키지 설치
npm i --save @uniswap/v2-core
npm i --save @uniswap/v2-periphery

# 설치 확인
ls node_modules/@uniswap/v2-core/contracts
ls node_modules/@uniswap/v2-periphery/contracts
```

Foundry가 `node_modules`를 import 경로로 인식하게 하려면 `foundry.toml`에 `libs = ["node_modules"]`를 추가해야 함.

```toml
# foundry.toml
[profile.default]
src = "contracts"
out = "out"
libs = ["node_modules", "lib"]
auto_detect_solc = true

fs_permissions = [
    { access = "read", path = "./" }
]
```

---

#### Step 3. 프로젝트 디렉토리 구조 생성

```bash
mkdir -p contracts/interfaces
touch contracts/interfaces/ILiquidityValueCalculator.sol
touch contracts/LiquidityValueCalculator.sol
```

```
uniswap-v2-demo/
│
├── contracts/                         ← 내가 작성하는 폴더
│   ├── interfaces/
│   │   └── ILiquidityValueCalculator.sol
│   └── LiquidityValueCalculator.sol
│
├── test/                              ← 테스트 파일 폴더
│   ├── UniswapV2Factory.bin           ← 사전 컴파일 바이트코드
│   └── LiquidityValueCalculator.t.sol
│
├── node_modules/                      ← npm 패키지 폴더
│   └── @uniswap/
│       ├── v2-core/
│       │   └── contracts/
│       │       ├── UniswapV2Factory.sol
│       │       ├── UniswapV2Pair.sol
│       │       └── interfaces/
│       └── v2-periphery/
│           └── contracts/
│               ├── UniswapV2Router02.sol
│               └── libraries/
│                   └── UniswapV2Library.sol
│
├── foundry.toml
└── package.json
```

---

#### Step 4. 인터페이스 작성

구현체가 반드시 지켜야 할 함수 시그니처를 인터페이스로 먼저 정의.
LP 토큰 수량과 토큰 주소 두 개를 받아서 각 토큰의 환급 예상량을 반환.

```solidity
pragma solidity ^0.6.6;

interface ILiquidityValueCalculator {
    function computeLiquidityShareValue(
        uint liquidity,
        address tokenA,
        address tokenB
    ) external returns (uint tokenAAmount, uint tokenBAmount);
}
```

---

#### Step 5. 구현체 작성

Factory 주소를 constructor로 받아 저장하고, `pairInfo()`로 reserve와 totalSupply를 조회한 후, LP 지분 비율로 각 토큰 환급량을 계산.
LP 지분에 대한 토큰 환급량 계산 로직은 `burn()` 함수와 동일한 로직으로 구성.

```solidity
// 핵심 계산식
tokenAAmount = reserveA * liquidity / totalSupply;
tokenBAmount = reserveB * liquidity / totalSupply;
```

---

#### Step 6. 테스트 작성

`forge test`는 자동으로 로컬 EVM(testnet)을 띄움. 따라서 로컬 체인에 Factory, ERC20, Pair, 새로 생성한 컨트랙트를 배포해야 함.

> ⚠️ **주의: Factory는 반드시 바이트코드로 배포해야 함**
>
> Uniswap에서 이미 Pair 배포용 바이트코드를 Factory 내에 하드코딩해두었는데, 소스에서 직접 컴파일하면 소스 경로가 달라 바이트코드 해시가 달라지고 `pairFor()` 내에서 오류 발생.

```bash
# 바이트코드 추출 (최초 1회)
python3 -c "
import json
with open('node_modules/@uniswap/v2-core/build/UniswapV2Factory.json') as f:
    data = json.load(f)
with open('test/UniswapV2Factory.bin', 'wb') as f:
    f.write(bytes.fromhex(data['bytecode'].replace('0x', '')))
print('완료')
"
```

**테스트 순서:**

1. **testnet 실행** : `forge test` 명령 시 자동으로 실행됨
2. **Factory 배포**
   - 사전 컴파일된 `UniswapV2Factory.bin` 바이트코드 추출 (`vm.readFileBinary`)
   - `LiquidityValueCalculatorTest` 주소를 `feeToSetter`로 전달
   - `assembly { create(...) }`로 배포 후 `IUniswapV2Factory` 타입으로 감싸기
3. **ERC20 배포** : 커스텀 MockERC20으로 tokenA / tokenB 배포
4. **Pair 생성**
   - `createPair()`로 두 ERC20을 담는 Pair 생성
   - `IUniswapV2Pair` 타입으로 감싸기
   - `transfer() → mint()` 순서로 유동성 공급
     - Uniswap V2에서는 Router가 미리 Pair에 `transfer()`로 토큰을 전송하고, `mint()`를 호출하면 Pair가 잔액 차분을 계산해서 LP 토큰을 자동 발행
5. **Calculator 배포** : Factory 주소를 생성자 파라미터로 전달
6. **LP 토큰 수량 검증** : `mint()`로 LP 토큰을 받았으니 0보다 커야 함
7. **`computeLiquidityShareValue()` 결과 검증**
   - 토큰을 `transfer()`하고 `mint()`로 LP 토큰을 받았으니 결과가 0이 되면 안 됨
   - `MINIMUM_LIQUIDITY`(최초 공급 시 LP 토큰 1000개 영구 소각)로 인해 결과값이 원래 transfer한 양보다 적어야 함
   - 토큰을 1000:500 = 2:1 비율로 공급했으니 결과 비율도 2:1이어야 함

---

#### Step 7. 테스트 실행

```bash
# 전체 테스트 실행
forge test

# 상세 로그
forge test -vvvv

# 특정 테스트만 실행
forge test --match-test test_computeLiquidityShareValue -vvvv

# 캐시 초기화 후 재실행
forge clean && forge test -vvvv
```

---

#### 트레이스 분석

```
# ① Factory 배포 — 사전 컴파일 바이트코드로 배포했기 때문에 init code hash 일치
[0] VM::readFileBinary("test/UniswapV2Factory.bin")
└─ [Return] 0x608060405234...  ← 바이너리 바이트코드 로드

→ new <unknown>@0xc7183455a4C133Ae270771860664b6B7ec320bB1
└─ [Return] 13859 bytes of code  ← Factory 배포 성공

# ② ERC20 A/B 배포
→ new MockERC20@0xa0Cb889707d426A7A386870A03bc70d1b0697598
└─ [Return] 919 bytes of code  ← tokenA 배포

→ new MockERC20@0x1d1499e622D69689cdf9004d05Ec547d650Ff211
└─ [Return] 919 bytes of code  ← tokenB 배포

# ③ Factory로 Pair 생성
0xc7183455...::createPair(tokenA: 0xa0Cb..., tokenB: 0x1d14...)
│
├─ → new <unknown>@0x95856a7904561e59F8A7D59DAFc40144df90efFa
│   └─ [Return] 11293 bytes of code  ← Pair 컨트랙트 배포
│
├─ 0x9585...::initialize(
│       token0: 0x1d14...(tokenB),  ← 주소 크기 비교로 자동 정렬 (sortTokens)
│       token1: 0xa0Cb...(tokenA)   ← tokenA/B 순서가 뒤집힘
│   )
│
└─ emit PairCreated(token0: 0x1d14..., token1: 0xa0Cb..., pair: 0x9585...)

# ④ Pair 주소 조회
0xc7183455...::getPair(tokenA: 0xa0Cb..., tokenB: 0x1d14...)
└─ [Return] 0x95856a7904561e59F8A7D59DAFc40144df90efFa

# ⑤-1 Pair에 토큰 전송 (transfer)
MockERC20::transfer(to: 0x9585..., amount: 1000000000000000000000)  ← tokenA 1000개
└─ [Return] true

MockERC20::transfer(to: 0x9585..., amount: 500000000000000000000)   ← tokenB 500개
└─ [Return] true

# ⑤-2 mint() 호출 — LP 토큰 발행
0x9585...::mint(to: LiquidityValueCalculatorTest)
│
├─ balanceOf(0x9585...) → 500e18   ← tokenB 잔액 (잔액 차분으로 입금량 파악)
├─ balanceOf(0x9585...) → 1000e18  ← tokenA 잔액
│
├─ feeTo() → 0x000...0  ← 프로토콜 수수료 OFF 확인
│
├─ emit Transfer(from: 0x0, to: 0x0, value: 1000)
│       ← MINIMUM_LIQUIDITY 1000개 address(0)으로 영구 소각
│
├─ emit Transfer(from: 0x0, to: LiquidityValueCalculatorTest,
│       value: 707106781186547523400)
│       ← sqrt(1000e18 × 500e18) - 1000 개 발행
│
└─ emit Sync(reserve0: 500e18, reserve1: 1000e18)

# MINIMUM_LIQUIDITY 소각 수식
전체 LP = sqrt(1000e18 × 500e18) = 707106781186547524400
소각분  = 1000
내 LP   = 707106781186547524400 - 1000 = 707106781186547523400 ✅

# ⑦ computeLiquidityShareValue 실행
LiquidityValueCalculator::computeLiquidityShareValue(
    liquidity: 707106781186547523400,
    tokenA: 0xa0Cb..., tokenB: 0x1d14...
)
│
├─ totalSupply() → 707106781186547524400  ← 소각 1000개 포함한 전체
├─ getReserves() → 500e18, 1000e18, 1    ← reserve0(tokenB), reserve1(tokenA)
├─ token0() → 0x1d14...(tokenB)          ← 정렬 보정 확인용
│
└─ [Return]
       tokenAAmount: 999999999999999998585  ← 1000개보다 조금 적음 (MINIMUM_LIQUIDITY 반영)
       tokenBAmount: 499999999999999999292  ← 500개보다 조금 적음
```

---

## 참고 자료

- [Uniswap V2 공식 문서](https://developers.uniswap.org/docs/protocols/v2/overview)
- [Uniswap V2 Whitepaper](https://app.uniswap.org/whitepaper.pdf)
- [uniswap-v2-core](https://github.com/Uniswap/uniswap-v2-core)
- [uniswap-v2-periphery](https://github.com/Uniswap/uniswap-v2-periphery)
- [Foundry 공식 문서](https://book.getfoundry.sh)
