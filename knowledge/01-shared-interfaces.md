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

