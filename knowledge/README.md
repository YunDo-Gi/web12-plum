# PlumDevBot — Plum 개발 협업 효율화를 위한 RAG 챗봇

> 화상회의 서비스 [Plum](../README.md) 개발 중, 프론트/백엔드 사이의
> mediasoup 시그널링 명세 확인 비용을 줄이기 위해 만든 사내용 RAG 챗봇.

## 1. 왜 만들었는가

Plum은 SFU 아키텍처(mediasoup)를 채택하면서 프론트엔드와 백엔드 사이에
복잡한 시그널링 시퀀스가 생겼다. Turborepo 모노레포의
`@plum/shared-interfaces` 패키지에 정의된 타입과 소켓 이벤트가 자주 바뀌면서,
슬랙에 다음과 같은 반복 질문이 끊임없이 발생했다.

- "오디오 Producer 생성 페이로드 타입이 어떻게 되나요?"
- "consume 이후 영상이 안 흘러오는데 뭐 빠뜨렸을까요?"
- "Transport `connect` 이벤트는 어떻게 처리해요?"
- "소켓 응답에 `success: false`일 때 `error` 필드 형식은?"

매번 노션 명세 → `socket.ts` → 코드 → 다시 노션을 왕복하면서
**컨텍스트 스위칭으로 인한 개발 집중도 저하**가 누적됐다.

## 2. 무엇을 만들었는가

**Dify 기반 RAG 챗봇.** 팀의 노션 명세서, `@plum/shared-interfaces` 의 TypeScript
타입 정의, 코드에서 추출한 시그널링 시퀀스 다이어그램을 단일 지식베이스로 통합한 뒤,
LLM이 항상 해당 컨텍스트를 참조해서 답하도록 묶었다.

### 아키텍처

```
[shared-interfaces .ts]      [코드 분석으로 추출한 시퀀스/에러 가이드]
              \                                  /
               └──────  build-knowledge.sh  ────┘
                              │
                              ▼
              knowledge/plum-knowledge-base.md  (1465 lines, 41KB)
                              │
                              ▼
                ┌───────────────────────────┐
                │  Dify Knowledge Base       │
                │  - 51 청크 (H2 단위)        │
                │  - text-embedding-3-small  │
                │  - 벡터 검색 / Top K = 5    │
                └───────────────────────────┘
                              │
                              ▼
                ┌───────────────────────────┐
                │  Dify Chatflow             │
                │  시작 → 지식 검색 → LLM →   │
                │  답변                      │
                │  LLM: Claude / Gemini      │
                └───────────────────────────┘
```

### 디렉토리 구성

```
knowledge/
├── README.md                       # 이 파일
├── plum-knowledge-base.md          # Dify 업로드용 통합 지식베이스
├── 01-shared-interfaces.md         # @plum/shared-interfaces 자동 추출
├── 02-signaling-sequence.md        # 입장→송출→수신→퇴장 시퀀스
└── 03-error-and-recovery.md        # 에러 처리 / 재연결 가이드

scripts/
└── build-knowledge.sh              # shared-interfaces 변경 시 재빌드
```

## 3. 어떻게 만들었는가

### 데이터 수집 / 전처리
- TypeScript 인터페이스 자동 추출: `scripts/build-knowledge.sh`로
  `packages/shared-interfaces/src/*.ts` 를 `## 파일명` 단위 마크다운으로 변환
- 시그널링 시퀀스: 실제 코드 (`MediaConnectionService`, `MediasoupService`,
  소켓 게이트웨이) 분석을 토대로 입장 → Device 초기화 → Transport 생성
  → produce/consume → cleanup 까지 단계별 다이어그램 작성
- 에러/재연결: `BaseResponse` 패턴, `toggleProducer` 롤백, Worker 사망 처리,
  `consume_resume` 누락 같은 흔한 실수들을 한 페이지로 정리

### Dify 설정
- 청킹 전략: H2 (`\n## `) 기준 분리 / 최대 1024자 / overlap 50자
- 임베딩: `text-embedding-3-small`
- 검색: 벡터 검색, Top K = 5
- 인덱싱 결과: 51개 청크, 평균 628자, 임베딩 8.33초 / 10,762 토큰

### 시스템 프롬프트
```text
너는 화상회의 서비스 'Plum'의 개발 지원 어시스턴트야.

[규칙]
1. 반드시 아래 [지식 컨텍스트]에 기반해서만 답변해.
2. 컨텍스트에 없는 내용은 추측하지 말고
   "현재 명세서에 해당 내용은 정의되어 있지 않습니다"라고 답변해.
3. 답변 시 프론트엔드 개발자가 즉시 사용할 수 있는 TypeScript
   코드 스니펫을 포함해줘.
4. 시퀀스 질문에는 번호를 매겨서 단계별로 설명해.
5. 출처가 되는 섹션 제목을 답변 끝에 짧게 인용해.

[지식 컨텍스트]
{{#context#}}
```

## 4. 검증

### 테스트 케이스 / 결과 요약

| # | 질문 | 기대 동작 | 결과 |
|---|------|----------|------|
| 1 | 오디오 Producer 페이로드 타입은? | `ProduceRequest` 타입 + 코드 스니펫 | ✅ 정확. `transportId / rtpParameters / type` 정확히 응답 |
| 2 | 강의실 입장~영상 보일 때까지 이벤트 순서? | 단계별 번호 + 페이로드 | ✅ join_room → create_transport → connect → consume → consume_resume |
| 3 | consume 응답은 받았는데 영상이 안 흘러와 | `consume_resume` 누락 진단 | ✅ 원인 정확히 짚고 해결 코드 제시 |
| 4 | toggle_media 실패 시 처리는? | 로컬 상태 롤백 | ✅ `toggleProducerLocally(type, !pause)` 패턴 응답 |
| 5 | Plum 결제 시스템 API 명세 | "정의되어 있지 않습니다" | ✅ 추측 거부, 컨텍스트 외 답변 안 함 |

5번에서 추측 답변을 거부한다는 점이 핵심: **컨텍스트 밖 질문에 그럴듯한
가짜 답을 만들지 않는다**는 RAG 챗봇의 가장 중요한 신뢰성 조건을 통과했다.

## 5. 회고

### 잘 한 것
- **노코드 도구로 스코프 압축**: 직접 LangChain/벡터 DB로 풀 스택을 짰다면
  하루~이틀 걸렸을 작업을 Dify로 한나절에 완성. "당장 작동하는 프로토타입"이
  목표였으므로 적절한 도구 선택.
- **자동 빌드 파이프라인**: `shared-interfaces`가 자주 바뀌므로
  `build-knowledge.sh`로 1초 만에 재빌드 → Dify에 재업로드만 하면
  지식이 신선하게 유지됨.
- **할루시네이션 방어**: 시스템 프롬프트의 "정의되어 있지 않다고 답하라" 규칙이
  실제로 작동함을 검증.

### 다음에 한다면
- 사용 로그(👍/👎 리액션) 수집해서 답변 정확도를 정량적으로 측정.
- 실패 케이스를 모아서 청킹 전략을 수정하는 루프 (예: 시퀀스 다이어그램이
  잘릴 경우 H2가 아닌 H1 단위로 다시 분할).
- Slack App 연동으로 슬랙 채널에서 `@PlumDevBot` 멘션만으로 호출 가능하게.

## 6. 재현 방법

1. Dify Cloud 가입 ([cloud.dify.ai](https://cloud.dify.ai))
2. Knowledge → Create → `plum-knowledge-base.md` 업로드
   - 청킹: Custom / Separator: `\n## ` / Max 1024 / Overlap 50
   - 인덱스 모드: 고품질 / 임베딩: `text-embedding-3-small`
   - 검색: 벡터 검색 / Top K = 5
3. Studio → Create App → **Chatflow**
4. 노드 구성: `시작 → 지식 검색 → LLM → 답변`
   - 지식 검색: 위에서 만든 KB 연결, Query = `시작/query`
   - LLM: 위 시스템 프롬프트, 컨텍스트 = `지식 검색/result`
5. 미리보기에서 [4. 검증] 표의 질문으로 테스트

`scripts/build-knowledge.sh`만 실행하면 `knowledge/01-shared-interfaces.md`가
최신 타입으로 자동 갱신된다. 시퀀스/에러 문서는 코드 변경에 따라 수동 업데이트.
