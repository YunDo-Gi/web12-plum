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
