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
