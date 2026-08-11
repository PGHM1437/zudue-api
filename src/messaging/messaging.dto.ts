import { IsString, IsUUID, MaxLength, MinLength } from 'class-validator';

/**
 * Request shapes for MessagingController. Every id here is bound against a uuid
 * column inside an RPC, so an unparseable value raised 22P02 and reached the
 * client as a bare 500 rather than a 400.
 *
 * The length bound is a guard against unbounded bodies, not a product rule —
 * the real limits (window state, free-follow-up counts, block/report gating)
 * live in rpc_ask_question / rpc_partner_answer and stay there.
 */
export class AskQuestionDto {
  @IsUUID() partnerId!: string;
  @IsString() @MinLength(1) @MaxLength(4000) text!: string;
}

export class AnswerDto {
  @IsUUID() conversationId!: string;
  @IsString() @MinLength(1) @MaxLength(4000) text!: string;
}

export class FollowupDto {
  @IsUUID() fanId!: string;
  @IsString() @MinLength(1) @MaxLength(4000) text!: string;
}
