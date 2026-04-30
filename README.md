# 🦄 Uniswap V2 아키텍처 정리

> Uniswap V2의 Core / Periphery 구조와 핵심 설계 결정을 학습하며 정리한 문서입니다.

<img width="1440" height="1080" alt="image" src="https://github.com/user-attachments/assets/5495e03d-5150-43de-b0f7-6fdd6eaf934a" />

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
  - Uniswap V2의 `swap()`은 Router가 그냥 `transfer()`를 스왑하고자 하는 양만큼 Pair에 하면 Pair가 직전/후 보유량 잔액 차이만큼 스왑해주는 형태이기 때문에 **메타 트랜잭션 필요 없음**

```
일반 방식: approve TX + removeLiquidity TX = 트랜잭션 2개
메타 트랜잭션: 오프체인 서명 + removeLiquidityWithPermit TX = 트랜잭션 1개
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

> WETH는 "ETH를 ERC-20 세계로 입장시키는 어댑터"

</br>

### 3.3 최소 유동성 소각

- 최초로 유동성을 공급할 때 `MINIMUM_LIQUIDITY`(= 1000) 만큼의 LP 토큰을 **영구 소각**

```solidity
uint public constant MINIMUM_LIQUIDITY = 10**3; // 1000

if (_totalSupply == 0) {
    liquidity = Math.sqrt(amount0.mul(amount1)).sub(MINIMUM_LIQUIDITY);
    _mint(address(0), MINIMUM_LIQUIDITY); // 영구 소각
}
```

- **해결하는 문제 두 가지:**

#### 반올림 오류 공격 방지

공격자가 아주 적은 양으로 최초 공급 후 직접 대량 기부로 LP 1개당 가치를 극단적으로 올리면, 이후 일반 유저가 유동성을 공급해도 LP 토큰을 0개 받게 되는 공격이 가능했음.

`MINIMUM_LIQUIDITY` 소각으로 최초 공급 시 의미 있는 금액이 강제되어 공격 비용이 극단적으로 높아짐.

#### totalSupply가 0이 되는 것 방지

LP 토큰이 전부 소각되면 `totalSupply = 0`이 되어 이후 LP 토큰 계산식의 분모가 0이 되는 문제 발생.

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

### 4.2 swap() 파라미터가 출력량인 이유

```solidity
function swap(uint amount0Out, uint amount1Out, address to, bytes calldata data)
```

- **입력량을 파라미터로 받지 않는 이유:**
  - 잔액 차분 방식에서 Pair는 reserve 스냅샷을 통해 얼마가 들어왔는지 직접 계산 → 입력량은 파라미터 불필요

- **출력량을 파라미터로 받는 이유:**
  - 출력량은 Pair가 직접 결정할 수 없음
  - `swap()` 호출자가 "나는 Token B를 이만큼 받고 싶다"라고 명시해야만 Pair가 그만큼 출력하고 k값으로 검증 가능

---

## 참고 자료

- [Uniswap V2 공식 문서](https://developers.uniswap.org/docs/protocols/v2/overview)
- [Uniswap V2 Whitepaper](https://app.uniswap.org/whitepaper.pdf)
- [uniswap-v2-core](https://github.com/Uniswap/uniswap-v2-core)
- [uniswap-v2-periphery](https://github.com/Uniswap/uniswap-v2-periphery)
