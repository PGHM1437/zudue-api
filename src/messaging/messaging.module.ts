import { Body, Controller, Get, Injectable, Module, Param, Post, UseGuards } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { JwtGuard } from '../auth/jwt.guard';
import { AuthUser, CurrentUser } from '../auth/current-user.decorator';

/**
 * Messaging — bold domain. First-question-free, 5-msg free window, paid windows
 * with a 48h deadline (auto-refund via BullMQ), partner free follow-up. All
 * money/state via RPCs; block/report gating enforced in the DB.
 */
@Injectable()
class MessagingService {
  constructor(private readonly db: DatabaseService) {}

  ask(userId: string, partnerId: string, text: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_ask_question', [userId, partnerId, text]));
  }
  answer(userId: string, conversationId: string, text: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_partner_answer', [userId, conversationId, text]));
  }
  followup(userId: string, fanId: string, text: string) {
    return this.db.runAs(userId, (tx) => this.db.rpc(tx, 'rpc_partner_send_followup', [fanId, text]));
  }

  conversations(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select c.id, c.fan_id, c.partner_id, c.last_activity_at,
               fp.full_name as fan_name, pp.display_name as partner_name
        from public.conversations c
        left join public.profiles fp on fp.id = c.fan_id
        left join public.partner_profiles pp on pp.profile_id = c.partner_id
        where c.fan_id = ${userId} or c.partner_id = ${userId}
        order by c.last_activity_at desc nulls last
      `)) as unknown as any[]);
  }

  /** Open (unanswered) windows on this partner's conversations — the DM
   *  equivalent of the call queue / incoming shout-outs: what needs a reply now. */
  pendingQuestions(userId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select c.id as conversation_id, c.fan_id, p.full_name as fan_name, w.opened_at,
               (select body from public.messages m2 where m2.window_id = w.id order by m2.created_at desc limit 1) as last_message
        from public.conversation_windows w
        join public.conversations c on c.id = w.conversation_id
        join public.profiles p on p.id = c.fan_id
        where c.partner_id = ${userId} and w.status = 'OPEN'
        order by w.opened_at asc
      `)) as unknown as any[]);
  }

  messages(userId: string, conversationId: string) {
    return this.db.runAs(userId, async (tx) =>
      (await tx.execute(sql`
        select m.id, m.window_id, m.sender, m.body, m.created_at, w.kind, w.status
        from public.messages m
        join public.conversation_windows w on w.id = m.window_id
        where w.conversation_id = ${conversationId}
        order by m.created_at
      `)) as unknown as any[]);
  }
}

@Controller('messaging')
class MessagingController {
  constructor(private readonly svc: MessagingService) {}
  @UseGuards(JwtGuard) @Get('conversations') convos(@CurrentUser() u: AuthUser) { return this.svc.conversations(u.id); }
  @UseGuards(JwtGuard) @Get('pending') pending(@CurrentUser() u: AuthUser) { return this.svc.pendingQuestions(u.id); }
  @UseGuards(JwtGuard) @Get('conversations/:id/messages') msgs(@CurrentUser() u: AuthUser, @Param('id') id: string) { return this.svc.messages(u.id, id); }
  @UseGuards(JwtGuard) @Post('ask') ask(@CurrentUser() u: AuthUser, @Body() b: { partnerId: string; text: string }) { return this.svc.ask(u.id, b.partnerId, b.text); }
  @UseGuards(JwtGuard) @Post('answer') answer(@CurrentUser() u: AuthUser, @Body() b: { conversationId: string; text: string }) { return this.svc.answer(u.id, b.conversationId, b.text); }
  @UseGuards(JwtGuard) @Post('followup') follow(@CurrentUser() u: AuthUser, @Body() b: { fanId: string; text: string }) { return this.svc.followup(u.id, b.fanId, b.text); }
}

@Module({ controllers: [MessagingController], providers: [MessagingService] })
export class MessagingModule {}
