# Plum WebRTC 시그널링 시퀀스 가이드

> 출처: `apps/frontend/src/mediasoup/*`, `apps/backend/src/mediasoup/*` 코드 분석.
> Plum은 mediasoup 기반 SFU 아키텍처를 사용한다. 이 문서는 프론트엔드 개발자가
> 강의실 입장 ~ 미디어 송수신 ~ 퇴장까지 어떤 소켓 이벤트가 어떤 순서로 오가는지
> 단계별로 정리한 것이다.

## 0. 큰 그림

```
[FE: MediaConnectionService]  <—— Socket.IO ——>  [BE: NestJS Gateway → MediasoupService]
        │                                                   │
        ├── MediasoupClient (Device, Transport, Producer/Consumer 상태 보관)
        └── MediasoupService (소켓 emit 래퍼)                ├── Worker × CPU 코어 수
                                                            ├── Router × 강의실
                                                            └── Transport / Producer / Consumer Map
```

용어:

- **Device**: 브라우저 미디어 기능 추상화. 한 탭당 1회 초기화.
- **Transport**: 브라우저 ↔ 서버 간 WebRTC 통로. `send` / `recv` 두 개를 만든다.
- **Producer**: 내가 송출 중인 미디어. `audio` / `video` / `screen` 별로 1개씩.
- **Consumer**: 다른 참가자에게서 받는 미디어. `producerId` 당 1개.

## 1. 강의실 입장 시퀀스

```
FE                                          BE
 │  REST POST /room/:id/enter               │
 ├──────────────────────────────────────────▶│
 │  ◀── EnterRoomResponse                   │
 │      { participantId, RoomInfo }         │
 │                                          │
 │  socket.connect()                        │
 ├──────────────────────────────────────────▶│
 │                                          │
 │  emit('join_room', { roomId, participantId })
 ├──────────────────────────────────────────▶│
 │  ◀── JoinRoomResponse {                  │
 │       success, role,                     │
 │       mediasoup: {                       │
 │         routerRtpCapabilities,           │
 │         existingProducers: [...]         │
 │       }, participants: [...]             │
 │     }                                    │
```

여기서 받은 `routerRtpCapabilities`로 다음 단계의 Device 초기화가 시작된다.
`existingProducers` 목록은 이미 방에 있는 다른 참가자의 미디어이므로,
입장 직후 이걸 순회하며 `consume`을 걸어야 한다.

## 2. Device 및 Transport 준비

```
1) Device 초기화 (MediasoupClient.initDevice)
   - Device.factory() → device.load({ routerRtpCapabilities })
   - device.canProduce('audio'/'video') 검증
   - 미지원 브라우저면 UnsupportedError

2) Transport 2개 동시 생성 (Promise.all)
   - direction: 'send' (내 미디어 송출용)
   - direction: 'recv' (다른 참가자 미디어 수신용)
```

각 방향별 emit 시퀀스:

```
FE                                          BE
 │  emit('create_transport', { direction }) │
 ├──────────────────────────────────────────▶│
 │  ◀── CreateTransportResponse {           │
 │       id, iceParameters,                 │
 │       iceCandidates, dtlsParameters }    │
 │                                          │
 │  device.createSendTransport(data)        │
 │  (또는 createRecvTransport)              │
 │  → mediasoup-client가 내부적으로         │
 │    'connect' 이벤트를 발생시키면         │
 │                                          │
 │  emit('connect_transport', {             │
 │     transportId, dtlsParameters })       │
 ├──────────────────────────────────────────▶│
 │  ◀── ConnectTransportResponse {success}  │
```

> ⚠️ `connect_transport`는 직접 호출하지 않는다. `device.createSendTransport()`로 만든
> Transport에 `transport.on('connect', ...)` 핸들러를 바인딩해두면 mediasoup-client가
> 첫 produce/consume 시점에 자동으로 발화한다. (FE: `bindTransportEvents`)

## 3. 내 미디어 송출 (Producing)

```
FE                                          BE
 │  getUserMedia() → MediaStreamTrack       │
 │                                          │
 │  sendTransport.produce({ track,          │
 │       appData: { type } })               │
 │  → 내부적으로 'produce' 이벤트 발화      │
 │                                          │
 │  emit('produce', {                       │
 │     transportId, rtpParameters,          │
 │     type: 'audio'|'video'|'screen' })    │
 ├──────────────────────────────────────────▶│
 │  ◀── ProduceResponse {                   │
 │       success, producerId, kind, type }  │
 │                                          │
 │  callback({ id: producerId })            │
 │  → Producer 객체 반환                    │
```

**서버는 새 Producer가 생기면 같은 방의 다른 참가자에게 브로드캐스트:**

```
BE → 다른 FE
 emit('new_producer', NewProducerPayload {
   producerId, participantId, kind, type, participantRole
 })
```

각 클라이언트는 이걸 받으면 `startConsuming(producerId)`를 호출해야 한다.

## 4. 다른 참가자 미디어 수신 (Consuming)

```
FE                                          BE
 │  emit('consume', {                       │
 │     transportId,                         │
 │     producerId,                          │
 │     rtpCapabilities })                   │
 ├──────────────────────────────────────────▶│
 │  ◀── ConsumeResponse {                   │
 │       success, consumerId, producerId,   │
 │       kind, type, rtpParameters,         │
 │       producerPaused }                   │
 │                                          │
 │  recvTransport.consume(payload)          │
 │  → Consumer 객체, MediaStream 생성       │
 │                                          │
 │  emit('consume_resume', { consumerId })  │
 ├──────────────────────────────────────────▶│
 │  ◀── ConsumeResumeResponse { success }   │
```

> `consume`은 일시정지 상태로 응답을 받기 때문에 반드시 `consume_resume`까지 보내야
> 실제 트랙이 흘러온다.

## 5. 미디어 토글 (마이크 뮤트 / 카메라 끄기)

```
FE                                          BE
 │  로컬 producer.pause() / resume()        │
 │  emit('toggle_media', {                  │
 │     producerId, type, action })          │
 │  action: 'pause' | 'resume'              │
 ├──────────────────────────────────────────▶│
 │  ◀── ToggleMediaResponse { success }     │
 │                                          │
 │  서버 실패 시 FE에서 로컬 상태 롤백      │
 │  (toggleProducerLocally(type, !pause))   │
```

서버는 다른 참가자에게 브로드캐스트:

```
BE → 다른 FE
 emit('media_state_changed', {
   producerId, participantId, kind, type, action
 })
```

## 6. Producer / Consumer 종료

| 상황 | FE 호출 | 서버 emit | 다른 FE 수신 이벤트 |
| ---- | ------- | --------- | ------------------- |
| 내 송출 중단 | `closeProducer({producerId})` | — | `producer_closed` |
| 내 수신 중단 | `closeConsumer({consumerId})` | — | (해당 클라이언트만) |
| 상대가 송출 중단 | (없음) | — | `producer_closed` → `removeConsumer(consumerId)` |
| 방 퇴장 | `cleanup()` + `leave_room` | `leave_room` | `user_left` |

## 7. 강의실 퇴장 시퀀스

```
1) MediasoupService.removeEventHandlers()
2) MediaConnectionService.stopAllProducers()
   → 모든 audio/video/screen producer를 closeProducer로 정리
3) MediaConnectionService.stopAllConsumers()
4) MediasoupClient.cleanup() — Transport / Device 해제
5) emit('leave_room', cb) → LeaveRoomResponse
6) socket.disconnect()
```

## 8. 자주 나오는 실수 / 디버깅 체크리스트

- ❌ `consume` 후 `consume_resume`을 빼먹어서 트랙이 안 흐름
- ❌ Transport `connect` 이벤트 핸들러를 등록 안 해서 첫 produce에서 hang
- ❌ `existingProducers`를 순회하지 않아 다른 참가자 미디어가 안 보임
- ❌ `cleanup()` 미호출로 방 재입장 시 Device 중복 로드 에러
- ❌ `toggle_media`만 보내고 로컬 producer.pause/resume을 안 해서 상태 불일치
- ❌ FE에서 `appData.type`을 `'audio'`로 보냈는데 BE가 `kind`만 보고 분기 → screen 미디어가 audio로 잘못 분류

## 9. 이벤트 빠른 참조

**FE → BE (요청, 응답 콜백 있음)**

`join_room`, `create_transport`, `connect_transport`, `produce`, `consume`,
`consume_resume`, `close_producer`, `close_consumer`, `toggle_media`,
`get_producer`, `leave_room`, `break_room`, `action_gesture`

**BE → FE (브로드캐스트)**

`user_joined`, `user_left`, `new_producer`, `producer_closed`,
`consumer_closed`, `media_state_changed`, `update_gesture_status`,
`room_end`, `speaker_detected`

전체 페이로드 타입은 `01-shared-interfaces.md`의 `socket.ts` 섹션 참조.
# Plum 에러 처리 / 재연결 가이드

> 출처: `apps/frontend/src/mediasoup/`, `packages/shared-interfaces/src/socket.ts`,
> `apps/backend/src/mediasoup/mediasoup.service.ts` 분석.

## 1. 응답 페이로드 표준 형식

모든 소켓 요청 응답은 `BaseResponse`를 상속한다:

```typescript
export interface BaseResponse {
  success: boolean;
  error?: string;
}
```

성공 시에만 추가 필드(`producerId`, `iceParameters` 등)가 채워진다.
**FE는 항상 `success === true` 분기 후에 추가 필드에 접근해야 한다.**

```typescript
const res = await SocketClient.emitWithAck('produce', payload);
if (!res.success) {
  // res.error 사용 가능
  return;
}
// 여기부터 res.producerId 사용 가능 (TypeScript 타입 좁히기)
```

## 2. FE 단의 주요 실패 케이스

| 상황 | 트리거 위치 | 처리 방식 |
| --- | --- | --- |
| Device 미초기화 상태에서 Transport 생성 시도 | `MediasoupClient.getRequiredDevice()` | `Error('[Device] 미디어 장치가 초기화되지 않음')` throw |
| 브라우저가 audio/video 둘 다 미지원 | `loadDevice()` | `'[Device] 브라우저가 오디오/비디오 송출 기능을 지원하지 않음'` |
| `UnsupportedError` (코덱 호환 X) | `Device.load()` | 메시지를 `'[Device] 오디오/비디오 송출을 지원하지 않음'`으로 표준화 |
| `connect_transport` 실패 | `bindTransportEvents().on('connect')` | mediasoup-client `errback(error)` 호출 → produce/consume이 실패로 이어짐 |
| `produce` 실패 | `bindTransportEvents().on('produce')` | 동일하게 errback. 호출자 측에서 catch 필요 |
| `toggleMedia` 서버 통신 실패 | `MediaConnectionService.toggleProducer()` | **로컬 상태 롤백** (`toggleProducerLocally(type, !pause)`) 후 throw |
| 미디어 연결 초기화 실패 | `MediaConnectionService.initialize()` | `cleanup()` 호출 후 throw |

## 3. 재시도 / 재연결 패턴

- 채팅 전송은 `SendChatResponse`에 `retryable?: boolean` 플래그가 있다. `false`라면 재시도 금지(중복 방지).
- 미디어 토글 실패는 자동 롤백되므로 사용자 입력만 다시 받으면 된다.
- 소켓 자체가 끊긴 경우 Socket.IO의 자동 재연결을 사용하되, **재연결 후에는
  `join_room`부터 다시 보내야 서버 상태가 복구된다.** 기존 Producer/Consumer는
  서버에서 정리되었을 가능성이 있으므로 `existingProducers`를 다시 받아서 재구축.

## 4. 서버 측 종료 트리거

서버가 클라이언트로 보내는 종료/오류 이벤트:

| 이벤트 | 의미 | 클라이언트 권장 액션 |
| ---- | ---- | -------------------- |
| `producer_closed` | 다른 참가자 송출 중단/퇴장 | 해당 consumer 정리, UI에서 비디오 칸 제거 |
| `consumer_closed` | 내 consumer가 서버 측에서 닫힘 | 로컬 consumer 제거, 필요 시 새 producerId로 재시도 |
| `user_left` | 참가자 퇴장 | 참가자 목록에서 제거 |
| `room_end` | 강의실 종료 | UI 알림 + cleanup + 라우팅 |

## 5. Worker 사망 처리 (서버)

`apps/backend/src/mediasoup/mediasoup.service.ts`에서:

```typescript
worker.on('died', () => {
  this.logger.error(`Mediasoup Worker (PID: ${worker.pid})가 죽었습니다.`);
  process.exit(1);  // PM2/Docker가 재시작
});
```

→ FE 입장에서는 소켓이 갑자기 끊긴 것처럼 보임. Socket.IO 재연결로 복구하되
참가자 목록과 미디어 상태를 다시 받아야 한다.

## 6. 발화 감지 / 점수 등 부가 이벤트의 신뢰성

- `speaker_detected`, `score_update`, `rank_update`는 **단순 통보**이므로 누락되어도
  치명적이지 않다. 누락 시 재요청 메커니즘은 없으며 다음 이벤트가 올 때까지 대기.
- 점수 정보를 한꺼번에 가져오려면 `get_activity_score_rank` 요청을 사용한다.

## 7. 검증 / 입력 에러 (REST)

`packages/shared-interfaces/src/api.ts`의 `ErrorResponse`:

```typescript
export interface ErrorResponse {
  message: string;
  error: string;
  statusCode: number;
}
```

강의실 생성/입장 폼은 zod 스키마로 검증되며 (`createLectureSchema`,
`enterLectureSchema`), 닉네임 길이는 `NICKNAME_CONSTRAINT`(2~16자)를 따른다.

## 8. 디버깅 시 먼저 확인할 것

1. **소켓 연결 상태**: `socket.connected === true` 인지
2. **join_room 응답에 `success: true` + `mediasoup.routerRtpCapabilities` 존재** 확인
3. **Device 초기화 완료 후에 createTransport 호출**됐는지
4. **Transport `connect` / `produce` 핸들러가 1번이라도 발화**했는지 (DTLS 시작 신호)
5. **`new_producer` 이벤트를 수신하는 핸들러가 등록**되어 있는지 (`setupEventHandlers`)
6. **`consume` 후 `consume_resume`을 빼먹지 않았는지**
# Plum 공통 타입 / 시그널링 인터페이스

> 출처: `packages/shared-interfaces/src` — 빌드 스크립트가 자동 생성. 수정 금지.

## api.ts

```typescript
import { z } from 'zod';
import { createLectureSchema, enterLectureSchema } from './room.js';
import { nicknameValidate, ParticipantRole } from './participant.js';
import { RoomInfo } from './shared.js';

/**
 * 강의실 생성 요청
 */
export type CreateRoomRequest = z.infer<typeof createLectureSchema>;

export interface ErrorResponse {
  message: string;
  error: string;
  statusCode: number;
}

/**
 * 강의실 생성 응답
 */
export interface CreateRoomResponse extends RoomInfo {
  roomId: string;
  host: {
    id: string;
    name: string;
    role: ParticipantRole;
  };
}

export type EnterLectureRequestBody = z.infer<typeof enterLectureSchema>;

/**
 * 강의실 입장 요청
 */
export interface EnterRoomRequest {
  uri: {
    id: string;
  };
  body: EnterLectureRequestBody;
}

/**
 * 강의실 입장 응답
 */
export interface EnterRoomResponse extends RoomInfo {
  participantId: string;
  name: string;
  role: ParticipantRole;
}

/**
 * 강의실 정보 조회 응답
 */
export interface RoomValidationResponse {
  name: string;
}

/*
 * 강의실 id 검증 request
 */
export interface RoomValidationRequest {
  uri: {
    id: string;
  };
}

/**
 * 강의실 참여자 id 검증 request body
 */

export type NicknameValidationRequestQueryParam = z.infer<typeof nicknameValidate>;

/**
 * 강의실 참여자 id 검증 request
 */
export interface NicknameValidationRequest {
  uri: {
    id: string;
  };
  query: NicknameValidationRequestQueryParam;
}

/**
 * 강의실 참여자 id 검증 response
 */
export interface NicknameValidationResponse {
  available: boolean;
}
```

## chat.ts

```typescript
import { z } from 'zod';

/**
 * 채팅 메시지 검증 스키마
 * - 1-60자 제한
 * - trim 적용 (공백 제거)
 */
export const chatMessageSchema = z.object({
  text: z
    .string()
    .trim()
    .min(1, '메시지는 1자 이상이어야 합니다.')
    .max(60, '메시지는 60자를 초과할 수 없습니다.'),
});

export type SendChatRequest = z.infer<typeof chatMessageSchema>;

/**
 * 채팅 메시지 구조
 * messageId: {timestamp}-{senderId}-{random} 형식으로 서버에서 생성
 * timestamp: 서버 시간 (밀리초), 순서 보장에 사용
 */
export interface ChatMessage {
  messageId: string;
  senderId: string;
  senderName: string;
  text: string;
  timestamp: number;
}

/**
 * 재연결 시 동기화 요청
 * lastMessageId: 클라이언트가 마지막으로 받은 메시지 ID
 * 소켓이 불안정할때 재연결시에 순서지킴이
 * 서버는 이 ID 이후의 메시지만 반환
 */
export interface SyncChatRequest {
  lastMessageId: string;
}

export const CHAT_POLICY = {
  LIMIT: {
    WINDOW_MS: 3 * 1000,
    MAX_MESSAGES: 5,
  },
  SYNC_LIMIT: {
    WINDOW_MS: 30 * 1000,
    MAX_REQUESTS: 10,
  },
  PENALTY: {
    DEDUCTION_PER_VIOLATION: 50,
    BAN_THRESHOLD: 3,
  },
};
```

## file.ts

```typescript
import { z } from 'zod';

/**
 * TODO: 최대 크기 논의하기
 * 발표 자료 최대 파일 크기: 50MB
 */
export const FILE_MAX_SIZE_MB = 50;
export const FILE_MAX_SIZE_BYTES = FILE_MAX_SIZE_MB * 1024 * 1024;

/**
 * 허용되는 파일 형식과 MIME 타입
 */
const FILE_FORMATS = [
  { accept: '.pdf', mime: 'application/pdf' },
  { accept: '.ppt', mime: 'application/vnd.ms-powerpoint' },
  {
    accept: '.pptx',
    mime: 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  },
] as const;

/**
 * 허용되는 파일 형식
 */
export const ALLOWED_FILE_MIME_TYPES = FILE_FORMATS.map((type) => type.mime);

/**
 * 허용되는 파일 확장자 문자열
 */
export const ALLOWED_FILE_EXTENSIONS_STRING = FILE_FORMATS.map((type) => type.accept).join(', ');

export const fileSchema = z.custom<any>(
  (val) => {
    if (!val || typeof val !== 'object') return false;

    // 브라우저의 File 객체이거나, 서버의 Multer 객체인 특징이 있는지 확인
    // 브라우저: 'name' 속성 존재 / 서버: 'originalname' 속성 존재
    const isBrowserFile = 'name' in val && 'size' in val;
    const isServerFile = 'originalname' in val && 'size' in val;

    return isBrowserFile || isServerFile;
  },
  {
    message: '유효한 파일 형식이 아닙니다.',
  },
);

export interface FileInfo {
  url: string;
  size: number;
}
```

## index.ts

```typescript
// 공통 타입/인터페이스 정의
// 추후 분리해서 인터페이스 넣어도 되고..
export * from './shared.js';
export * from './poll.js';
export * from './qna.js';
export * from './participant.js';
export * from './file.js';
export * from './score.js';
export * from './room.js';
export * from './socket.js';
export * from './api.js';
export * from './chat.js';
```

## participant.ts

```typescript
import { z } from 'zod';

export type ParticipantRole = 'presenter' | 'audience';

export const NICKNAME_CONSTRAINT = { MIN: 2, MAX: 16 };

export interface Participant {
  id: string;
  roomId: string;
  currentRoomId: string;
  name: string;
  role: ParticipantRole;
  cameraEnable: boolean;
  micEnable: boolean;
  screenEnable: boolean;
  transports: string[];
  producers: {
    audio: string;
    video: string;
    screen: string;
  };
  consumers: string[];
  joinedAt: string;
}

export interface ParticipantPayload {
  id: string;
  name: string;
  role: string;
  joinedAt: Date;
}

export const nicknameValidate = z.object({
  nickname: z
    .string()
    .trim()
    .min(NICKNAME_CONSTRAINT.MIN, `닉네임은 ${NICKNAME_CONSTRAINT.MIN}자 이상이어야 합니다.`)
    .max(NICKNAME_CONSTRAINT.MAX, `닉네임은 ${NICKNAME_CONSTRAINT.MAX}자 이하여야 합니다.`),
});
```

## poll.ts

```typescript
import { z } from 'zod';
import { Status } from './shared.js';

/**
 * 투표 선택지 개수 제한
 */
export const MIN_POLL_OPTIONS = 2;
export const MAX_POLL_OPTIONS = 4;

/**
 * 투표 폼 유효성 검사 제약 조건
 */
export const POLL_VALIDATION_CONSTRAINTS = {
  TITLE: {
    MAX_LENGTH: 50,
  },
  OPTIONS: {
    MIN_COUNT: 2,
    MAX_COUNT: 5,
    MAX_OPTION_LENGTH: 50,
  },
  TIME_LIMIT: {
    MIN_VALUE: 0,
    MAX_VALUE: 600,
  },
} as const;

/**
 * 투표 선택지 스키마
 */
const pollOptionSchema = z.object({
  value: z
    .string()
    .trim()
    .min(1, '선택지를 입력해주세요')
    .max(
      POLL_VALIDATION_CONSTRAINTS.OPTIONS.MAX_OPTION_LENGTH,
      `각 선택지는 ${POLL_VALIDATION_CONSTRAINTS.OPTIONS.MAX_OPTION_LENGTH}자 이하여야 합니다`,
    ),
});

/**
 * 투표 폼 스키마
 */
export const pollFormSchema = z.object({
  title: z
    .string()
    .trim()
    .min(1, '투표 제목을 입력해주세요')
    .max(
      POLL_VALIDATION_CONSTRAINTS.TITLE.MAX_LENGTH,
      `투표 제목은 ${POLL_VALIDATION_CONSTRAINTS.TITLE.MAX_LENGTH}자 이하여야 합니다`,
    ),
  options: z
    .array(pollOptionSchema)
    .min(
      POLL_VALIDATION_CONSTRAINTS.OPTIONS.MIN_COUNT,
      `최소 ${POLL_VALIDATION_CONSTRAINTS.OPTIONS.MIN_COUNT}개 이상의 선택지가 필요합니다`,
    )
    .max(
      POLL_VALIDATION_CONSTRAINTS.OPTIONS.MAX_COUNT,
      `최대 ${POLL_VALIDATION_CONSTRAINTS.OPTIONS.MAX_COUNT}개 까지 선택지를 추가할 수 있습니다`,
    ),
  timeLimit: z
    .number()
    .min(
      POLL_VALIDATION_CONSTRAINTS.TIME_LIMIT.MIN_VALUE,
      `제한 시간은 ${POLL_VALIDATION_CONSTRAINTS.TIME_LIMIT.MIN_VALUE} 이상이어야 합니다`,
    )
    .max(
      POLL_VALIDATION_CONSTRAINTS.TIME_LIMIT.MAX_VALUE,
      `제한 시간은 ${POLL_VALIDATION_CONSTRAINTS.TIME_LIMIT.MAX_VALUE}초 이하여야 합니다`,
    ),
});

export interface Voter {
  id: string;
  name: string;
}

export interface PollOption {
  id: number;
  value: string;
  count: number;
  voters: Voter[];
}

export interface Poll {
  id: string;
  roomId: string;
  status: Status;
  title: string;
  options: PollOption[];
  timeLimit: number;
  createdAt: string;
  updatedAt: string;
  startedAt: string;
  endedAt: string;
}

export interface PollPayload {
  id: string;
  title: string;
  options: PollOption[];
  timeLimit: number;
  startedAt: string;
  endedAt: string;
}
```

## qna.ts

```typescript
import { z } from 'zod';
import { type Status } from './shared.js';

/**
 * QnA 폼 유효성 검사 제약 조건
 */
export const QNA_VALIDATION_CONSTRAINTS = {
  TITLE: {
    MAX_LENGTH: 50,
  },
  TIME_LIMIT: {
    MIN_VALUE: 0,
    MAX_VALUE: 600,
  },
} as const;

/**
 * Answer 폼 유효성 검사 제약 조건
 */
export const ANSWER_VALIDATION_CONSTRAINTS = {
  TEXT: {
    MAX_LENGTH: 300,
  },
} as const;

/**
 * QnA 폼 스키마
 */
export const qnaFormSchema = z.object({
  title: z
    .string()
    .trim()
    .min(1, 'QnA 제목을 입력해주세요')
    .max(
      QNA_VALIDATION_CONSTRAINTS.TITLE.MAX_LENGTH,
      `QnA 제목은 ${QNA_VALIDATION_CONSTRAINTS.TITLE.MAX_LENGTH}자 이하여야 합니다`,
    ),
  timeLimit: z
    .number()
    .min(
      QNA_VALIDATION_CONSTRAINTS.TIME_LIMIT.MIN_VALUE,
      `제한 시간은 ${QNA_VALIDATION_CONSTRAINTS.TIME_LIMIT.MIN_VALUE} 이상이어야 합니다`,
    )
    .max(
      QNA_VALIDATION_CONSTRAINTS.TIME_LIMIT.MAX_VALUE,
      `제한 시간은 ${QNA_VALIDATION_CONSTRAINTS.TIME_LIMIT.MAX_VALUE}초 이하여야 합니다`,
    ),
  isPublic: z.boolean(),
});

export const answerFromSchema = z.object({
  text: z
    .string()
    .trim()
    .min(1, '응답 내용을 적어주세요')
    .max(
      ANSWER_VALIDATION_CONSTRAINTS.TEXT.MAX_LENGTH,
      `응답 내용은 ${ANSWER_VALIDATION_CONSTRAINTS.TEXT.MAX_LENGTH}자 이하여야 합니다`,
    ),
});

export interface Qna {
  id: string;
  roomId: string;
  status: Status;
  title: string;
  timeLimit: number;
  isPublic: boolean; // true = 익명 false = 비공개
  createdAt: string;
  updatedAt: string;
  startedAt: string;
  endedAt: string;
  answers: Answer[];
}

export interface QnaPayload {
  id: string;
  title: string;
  timeLimit: number;
  startedAt: string;
  endedAt: string;
}

export interface Answer {
  participantId: string;
  participantName: string;
  text: string;
}
```

## room.ts

```typescript
import { z } from 'zod';
import { Poll, pollFormSchema } from './poll.js';
import { Qna, qnaFormSchema } from './qna.js';
import { type Status } from './shared.js';
import { FileInfo, fileSchema } from './file.js';
import { NICKNAME_CONSTRAINT } from './participant.js';
import { ActivityStatistics } from './score.js';

/**
 * 강의 생성 폼의 제약 조건
 */
export const LECTURE_CONSTRAINTS = {
  NAME: { MIN: 5, MAX: 30 },
  HOST: NICKNAME_CONSTRAINT,
  FILES: { MAX: 5 },
} as const;

/**
 * 강의 생성 폼 스키마
 */
export const createLectureSchema = z.object({
  name: z
    .string()
    .trim()
    .min(
      LECTURE_CONSTRAINTS.NAME.MIN,
      `강의실 이름은 ${LECTURE_CONSTRAINTS.NAME.MIN}자 이상이어야 합니다.`,
    )
    .max(
      LECTURE_CONSTRAINTS.NAME.MAX,
      `강의실 이름은 ${LECTURE_CONSTRAINTS.NAME.MAX}자 이하여야 합니다.`,
    ),
  hostName: z
    .string()
    .trim()
    .min(
      LECTURE_CONSTRAINTS.HOST.MIN,
      `호스트 이름은 ${LECTURE_CONSTRAINTS.HOST.MIN}자 이상이어야 합니다.`,
    )
    .max(
      LECTURE_CONSTRAINTS.HOST.MAX,
      `호스트 이름은 ${LECTURE_CONSTRAINTS.HOST.MAX}자 이하여야 합니다.`,
    ),
  isAgreed: z.boolean().refine((val) => val === true, {
    message: '데이터 수집에 동의해야 강의실을 생성할 수 있습니다.',
  }),

  polls: z.array(pollFormSchema),
  qnas: z.array(qnaFormSchema),
  presentationFiles: z
    .array(fileSchema)
    .max(
      LECTURE_CONSTRAINTS.FILES.MAX,
      `파일은 최대 ${LECTURE_CONSTRAINTS.FILES.MAX}개까지 업로드 가능합니다.`,
    )
    .optional(),
});

export const enterLectureSchema = z.object({
  name: z.string(),
  nickname: z
    .string()
    .trim()
    .min(NICKNAME_CONSTRAINT.MIN, `닉네임은 ${NICKNAME_CONSTRAINT.MIN}자 이상이어야 합니다.`)
    .max(NICKNAME_CONSTRAINT.MAX, `닉네임은 ${NICKNAME_CONSTRAINT.MAX}자 이하여야 합니다.`),
  isAgreed: z.boolean().refine((val) => val === true, {
    message: '데이터 수집에 동의해야 강의실을 입장할 수 있습니다.',
  }),
  isAudioOn: z.boolean(),
  isVideoOn: z.boolean(),
});

export interface Room {
  id: string;
  name: string;
  presenter: string;
  status: Status;
  createdAt: string;
  startedAt: string;
  endedAt: string;
  files: FileInfo[];
}

export interface RoomSummary extends AiSummary {
  name: string;
  roomId: string;
  polls: Poll[];
  qnas: Qna[];
  activityStatistics: ActivityStatistics;
  status: Status | 'none';
}

export interface AiSummary {
  summary: string;
  timelines: Timelines[];
  tags: string[];
}

export interface Timelines {
  startedAt: number;
  endedAt: number;
  content: string;
}
```

## score.ts

```typescript
export type ActivityType =
  | 'gesture' // 제스처 (+5)
  | 'chat' // 채팅 (+3)
  | 'vote' // 투표 (+5)
  | 'vote_gesture' // 제스처로 투표 (+8)
  | 'qna_answer'; // 질문 답변 (+10)

export interface RankItem {
  rank: number;
  participantId: string;
  name: string;
  score: number;
}

/**
 * Redis Hash에 저장되는 통계 정보
 */
export interface ParticipantStats {
  participationScore: number;
  gestureCount: number;
  chatCount: number;
  voteCount: number;
  answerCount: number;
  penaltyCount: number;
}

export interface ActivityStatistics {
  averageScore: number; // 평균 참여도 점수
  ranks: RankItem[];
  interactions: ParticipantStats;
}

export const RANK_LIMIT = 3;

export const PENALTY_LIMIT = 5;

export const SCORE_RULES: Record<ActivityType, number> = {
  gesture: 5,
  chat: 3,
  vote: 5,
  vote_gesture: 8,
  qna_answer: 10,
};
```

## shared.ts

```typescript
import { ParticipantPayload } from './participant.js';

export type Status = 'pending' | 'active' | 'ended';
export type MediaKind = 'audio' | 'video'; // mediasoup에서 사용하는 미디어 타입
export type MediaType = MediaKind | 'screen'; // 우리가 사용할 미디어 소스 타입
export type ToggleActionType = 'pause' | 'resume';

export interface RoomInfo {
  mediasoup: MediasoupRoomInfo;
  participants: ParticipantPayload[];
}

export interface MediasoupRoomInfo {
  routerRtpCapabilities: unknown;
  existingProducers: Array<MediasoupProducer>;
}

export interface MediasoupProducer {
  producerId: string;
  participantId: string;
  kind: MediaKind;
  type: MediaType;
}
```

## socket.ts

```typescript
import { z } from 'zod';

import { ParticipantPayload, ParticipantRole } from './participant.js';
import { MediaKind, MediasoupProducer, MediaType, RoomInfo, ToggleActionType } from './shared.js';
import { Poll, pollFormSchema, PollOption, PollPayload } from './poll.js';
import { Answer, Qna, qnaFormSchema, QnaPayload } from './qna.js';
import { FileInfo } from './file.js';
import { ChatMessage, SendChatRequest, SyncChatRequest } from './chat.js';
import { RankItem } from './score.js';

// 제스처 타입 정의
export type GestureType =
  | 'thumbs_up' // 👍 좋아요/이해했어요
  | 'thumbs_down' // 👎 모르겠어요
  | 'hand_raise' // ✋ 손들기/질문
  | 'ok_sign' // 👌 괜찮아요
  | 'x_sign' // ❌ 반대
  | 'o_sign' // 🙆 찬성
  | 'one' // ☝️ 1번 투표
  | 'two' // ✌️ 2번 투표
  | 'three' // 3번 투표
  | 'four'; // 4번 투표

// 클라이언트에서 보내는 데이터 페이로드

export interface JoinRoomRequest {
  roomId: string;
  participantId: string;
}

export interface CreateTransportRequest {
  direction: 'send' | 'recv';
}

export interface ConnectTransportRequest<T = any> {
  transportId: string;
  dtlsParameters: T; // mediasoup-client/node DtlsParameters
}

export interface ProduceRequest<T = any> {
  transportId: string;
  type: MediaType;
  rtpParameters: T; // RtpParameters
}

export interface GetProducerRequest {
  targetParticipantId: string;
  type: MediaType;
}

export interface CloseProducerRequest {
  producerId: string;
}

export interface ConsumeRequest<T = any> {
  transportId: string;
  producerId: string;
  rtpCapabilities: T; // RtpCapabilities
}

export interface ConsumeResumeRequest {
  consumerId: string;
}

export interface CloseConsumerRequest {
  consumerId: string;
}

export interface ToggleMediaRequest {
  producerId: string;
  action: ToggleActionType;
  type: MediaType;
}

// 제스처 요청 (클라이언트 -> 서버)
export interface ActionGestureRequest {
  gesture: GestureType;
}

export type CreatePollRequest = z.infer<typeof pollFormSchema>;

export type CreateQnaRequest = z.infer<typeof qnaFormSchema>;

export interface EmitPollRequest {
  pollId: string;
}

export interface EmitQnaRequest {
  qnaId: string;
}

export interface VoteRequest {
  pollId: string;
  optionId: number;
  isGesture: boolean;
}

export type AnswerRequest = {
  qnaId: string;
  text: string;
};

export interface BreakPollRequest {
  pollId: string;
}

export interface BreakQnaRequest {
  qnaId: string;
}

// 클라이언트에서 보낸 요청에 따라 발생하는 이벤트 페이로드

export interface BaseResponse {
  success: boolean;
  error?: string;
}

export type JoinRoomResponse =
  | (BaseResponse & { success: false })
  | ({
      success: true;
      participantId: string;
      participantName: string;
      role: ParticipantRole;
    } & RoomInfo);

export type CreateTransportResponse<T1 = any, T2 = any, T3 = any> =
  | (BaseResponse & { success: false })
  | {
      success: true;
      id: string;
      iceParameters: T1;
      iceCandidates: T2;
      dtlsParameters: T3;
    };

export type ConnectTransportResponse = BaseResponse;

export type ProduceResponse =
  | (BaseResponse & { success: false })
  | {
      success: true;
      producerId: string;
      kind: MediaKind;
      type: MediaType;
    };

export type GetProducerResponse =
  | (BaseResponse & { success: false })
  | {
      success: true;
      producerId?: string;
    };

export type CloseProducerResponse = BaseResponse;

export type ConsumeResponse<T = any> =
  | (BaseResponse & { success: false })
  | {
      success: true;
      producerId: string;
      consumerId: string;
      kind: MediaKind;
      type: MediaType;
      rtpParameters: T;
      producerPaused: boolean; // 추가된 필드
    };

export type ConsumeResumeResponse = BaseResponse;

export type CloseConsumerResponse = BaseResponse;

export type ToggleMediaResponse = BaseResponse;

export type LeaveRoomResponse = BaseResponse;

export type BreakRoomResponse = BaseResponse;

export type ActionGestureResponse = BaseResponse;

export type CreatePollResponse = BaseResponse;

export type CreateQnaResponse = BaseResponse;

export type GetPollResponse =
  | (BaseResponse & { success: false })
  | {
      success: true;
      polls: Poll[];
    };

export type GetActivePollResponse =
  | (BaseResponse & { success: false })
  | {
      success: true;
      poll: PollPayload | null;
      votedOptionId: number | null;
    };

export type GetQnaResponse =
  | (BaseResponse & { success: false })
  | {
      success: true;
      qnas: Qna[];
    };

export type GetActiveQnaResponse =
  | (BaseResponse & { success: false })
  | {
      success: true;
      qna: QnaPayload | null;
      answered?: boolean;
    };

export type EmitPollResponse =
  | (BaseResponse & { success: false })
  | ({ success: true } & Pick<PollPayload, 'startedAt' | 'endedAt'>);

export type EmitQnaResponse =
  | (BaseResponse & { success: false })
  | ({ success: true } & Pick<QnaPayload, 'startedAt' | 'endedAt'>);

export type VoteResponse = BaseResponse;

export type AnswerResponse = BaseResponse;

export type BreakPollResponse =
  | (BaseResponse & { success: false })
  | { success: true; options: PollOption[] };

export type BreakQnaResponse =
  | (BaseResponse & { success: false })
  | { success: true; answers: Answer[]; count: number };

export type GetPresentationResponse =
  | (BaseResponse & { success: false })
  | { success: true; files: FileInfo[] };

export type SendChatResponse =
  | (BaseResponse & { success: false; retryable?: boolean })
  | { success: true; messageId: string };

export type SyncChatResponse =
  | (BaseResponse & { success: false })
  | { success: true; messages: ChatMessage[] };

export type GetActivityScoreRank =
  | (BaseResponse & { success: false })
  | ({ success: true; score: number } & RankUpdatePayload)
  | ({ success: true } & PresenterScoreInfoPayload);

// 서버에서 보내는 브로드캐스트 페이로드
export type UserJoinedPayload = ParticipantPayload;

export interface UserLeftPayload {
  id: string;
  name: string;
  leavedAt: Date;
}

export interface NewProducerPayload extends MediasoupProducer {
  participantRole: ParticipantRole;
}

export interface ProducerClosedPayload {
  participantId: string;
  producerId: string;
  kind: MediaKind;
  type: MediaType;
}

export interface ConsumerClosedPayload {
  consumerId: string;
  producerId: string;
}

export type MediaStateChangedPayload = NewProducerPayload & {
  action: ToggleActionType;
};

// 제스처 상태 업데이트 페이로드
export interface UpdateGestureStatusPayload {
  participantId: string;
  participantName: string;
  gesture: GestureType;
}

export type StartPollPayload = PollPayload;

export type StartQnaPayload = QnaPayload;

export interface UpdatePollStatusFullPayload {
  pollId: string;
  options: Pick<PollOption, 'id' | 'count'>[];
  voter: {
    participantId: string;
    name: string;
    optionId: number;
  };
}

export type UpdatePollStatusSubPayload = Omit<UpdatePollStatusFullPayload, 'voter'>;

export type UpdateQnaFullPayload = Answer & {
  qnaId: string;
  count: number;
};

export type UpdateQnaSubPayload = {
  qnaId: string;
  count: number;
  text?: string;
};

export interface EndPollPayload {
  pollId: string;
  title: string;
  options: Omit<PollOption, 'voters'>[];
}

export interface EndPollDetailPayload {
  pollId: string;
  options: PollOption[];
}

export interface EndQnaDetailPayload {
  qnaId: string;
  title: string;
  count: number;
  answers: Answer[];
}

export type EndQnaPayload = {
  qnaId: string;
  title: string;
  count: number;
  text?: string[];
};

export interface ScoreUpdatePayload {
  score: number;
  penaltyCount: number;
  reason: string;
}

export interface RankUpdatePayload {
  top: RankItem[];
}

export interface PresenterScoreInfoPayload {
  top: RankItem[];
  lowest: RankItem | null;
}

// 발화 감지 이벤트 페이로드
export interface SpeakerDetectedPayload {
  participantId: string;
  participantName: string;
  detectedAt: number;
}

/**
 * 서버 -> 클라이언트 이벤트
 */
export interface ServerToClientEvents {
  user_joined: (data: UserJoinedPayload) => void;

  user_left: (data: UserLeftPayload) => void;

  new_producer: (data: NewProducerPayload) => void;

  producer_closed: (data: ProducerClosedPayload) => void;

  consumer_closed: (data: ConsumerClosedPayload) => void;

  media_state_changed: (data: MediaStateChangedPayload) => void;

  update_gesture_status: (data: UpdateGestureStatusPayload) => void;

  room_end: () => void;

  start_poll: (data: StartPollPayload) => void;

  start_qna: (data: StartQnaPayload) => void;

  update_poll: (data: UpdatePollStatusSubPayload) => void;

  update_poll_detail: (data: UpdatePollStatusFullPayload) => void;

  update_qna: (data: UpdateQnaSubPayload) => void;

  update_qna_detail: (data: UpdateQnaFullPayload) => void;

  poll_end: (data: EndPollPayload) => void;

  poll_end_detail: (data: EndPollDetailPayload) => void;

  qna_end: (data: EndQnaPayload) => void;

  qna_end_detail: (data: EndQnaDetailPayload) => void;

  new_chat: (data: ChatMessage) => void;

  score_update: (data: ScoreUpdatePayload) => void;

  rank_update: (data: RankUpdatePayload) => void;

  presenter_rank_update: (data: PresenterScoreInfoPayload) => void;

  speaker_detected: (data: SpeakerDetectedPayload) => void;
}

/**
 * 클라이언트 -> 서버 이벤트
 */
export interface ClientToServerEvents {
  join_room: (data: JoinRoomRequest, cb: (res: JoinRoomResponse) => void) => void;

  create_transport: (
    data: CreateTransportRequest,
    cb: (res: CreateTransportResponse) => void,
  ) => void;

  connect_transport: (
    data: ConnectTransportRequest,
    cb: (res: ConnectTransportResponse) => void,
  ) => void;

  produce: (data: ProduceRequest, cb: (res: ProduceResponse) => void) => void;

  close_producer: (data: CloseProducerRequest, cb: (res: CloseProducerResponse) => void) => void;

  consume: (data: ConsumeRequest, cb: (res: ConsumeResponse) => void) => void;

  consume_resume: (data: ConsumeResumeRequest, cb: (res: ConsumeResumeResponse) => void) => void;

  close_consumer: (data: CloseConsumerRequest, cb: (res: CloseConsumerResponse) => void) => void;

  toggle_media: (data: ToggleMediaRequest, cb: (res: ToggleMediaResponse) => void) => void;

  get_producer: (data: GetProducerRequest, cb: (res: GetProducerResponse) => void) => void;

  leave_room: (cb: (res: LeaveRoomResponse) => void) => void;

  action_gesture: (data: ActionGestureRequest, cb: (res: ActionGestureResponse) => void) => void;

  break_room: (cb: (res: BreakRoomResponse) => void) => void;

  create_poll: (data: CreatePollRequest, cb: (res: CreatePollResponse) => void) => void;

  create_qna: (data: CreateQnaRequest, cb: (res: CreateQnaResponse) => void) => void;

  get_poll: (cb: (res: GetPollResponse) => void) => void;

  get_active_poll: (cb: (res: GetActivePollResponse) => void) => void;

  get_qna: (cb: (res: GetQnaResponse) => void) => void;

  get_active_qna: (cb: (res: GetActiveQnaResponse) => void) => void;

  emit_poll: (data: EmitPollRequest, cb: (res: EmitPollResponse) => void) => void;

  emit_qna: (data: EmitQnaRequest, cb: (res: EmitQnaResponse) => void) => void;

  vote: (data: VoteRequest, cb: (res: VoteResponse) => void) => void;

  answer: (data: AnswerRequest, cb: (res: AnswerResponse) => void) => void;

  break_poll: (data: BreakPollRequest, cb: (res: BreakPollResponse) => void) => void;

  break_qna: (data: BreakQnaRequest, cb: (res: BreakQnaResponse) => void) => void;

  get_presentation: (cb: (res: GetPresentationResponse) => void) => void;

  send_chat: (data: SendChatRequest, cb: (res: SendChatResponse) => void) => void;

  sync_chat: (data: SyncChatRequest, cb: (res: SyncChatResponse) => void) => void;

  get_activity_score_rank: (cb: (res: GetActivityScoreRank) => void) => void;
}
```

