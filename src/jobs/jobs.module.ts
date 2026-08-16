import { Injectable, Logger, Module, OnModuleDestroy, OnModuleInit } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import { Queue, Worker } from 'bullmq';
import IORedis from 'ioredis';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';

/**
 * The money-lifecycle scheduler — replaces the legacy (unscheduled) pg_cron.
 * Repeatable BullMQ jobs; each processor drives the certified RPCs as the
 * trusted service role.
 *
 * CRITICAL invariant (fixed after audit): each item is settled in its OWN
 * transaction via a fresh runAsService call, NOT all-in-one. A single failing
 * item used to poison the shared transaction and silently abort every
 * remaining item in the run. Failures are now counted and logged loudly, not
 * swallowed into a `.catch(() => null)`.
 */
@Injectable()
export class JobsService implements OnModuleInit, OnModuleDestroy {
  private readonly log = new Logger(JobsService.name);
  private connection!: IORedis;
  private queue!: Queue;
  private worker!: Worker;

  constructor(private readonly db: DatabaseService, private readonly config: ConfigService) {}

  // ── Public methods for BullMQ monitoring ───────────────────────────────────
  isJobRunning(): boolean {
    return this.connection ? this.connection.status === 'ready' : false;
  }

  getJobs() {
    return {
      settle: { pattern: '*/15 * * * *' },
      'stalled-calls': { pattern: '* * * * *' },
      'expire-windows': { pattern: '*/15 * * * *' },
      'purge-deletions': { pattern: '0 3 * * *' },
      'cleanup-topups': { pattern: '30 2 * * *' },
    };
  }

  // ── OnModuleInit implementation ────────────────────────────────────────────
  async onModuleInit() {
    const redisUrl = this.config.get('REDIS_URL');
    if (!redisUrl) {
      this.log.warn('REDIS_URL not configured - background jobs will be disabled');
      return;
    }

    this.connection = new IORedis(redisUrl, { maxRetriesPerRequest: null });
    this.queue = new Queue('lifecycle', { connection: this.connection });

    const every = async (name: string, pattern: string) =>
      this.queue.add(name, {}, { repeat: { pattern }, jobId: name, removeOnComplete: 100, removeOnFail: 500 });
    await every('settle', '*/15 * * * *');
    await every('stalled-calls', '* * * * *');
    await every('expire-windows', '*/15 * * * *');
    await every('purge-deletions', '0 3 * * *');
    // Abandoned Razorpay checkouts (migration 0070) — daily, off-peak. Marks
    // PENDING topup_orders older than 24h as FAILED so they stop inflating
    // pending-balance reporting. UPDATE only, never DELETE: the row and its
    // razorpay_order_id stay for audit.
    await every('cleanup-topups', '30 2 * * *');
    // Payouts are on-demand and processed offline (admin transfers by hand,
    // then records the UTR) — no scheduled batching. Clean up old repeatable
    // job from Redis if it exists (harmless if already gone).
    try {
      await this.queue.removeRepeatableByKey('lifecycle:monthly-payouts::0 6 * * *');
    } catch {
      // Key format may vary; ignore if not found
    }

    this.worker = new Worker('lifecycle', (job) => this.run(job.name), { connection: this.connection, concurrency: 4 });
    this.worker.on('failed', (job, err) => this.log.error(`job ${job?.name} failed: ${err.message}`));
    this.log.log('lifecycle jobs scheduled');
  }

  private run(name: string) {
    switch (name) {
      case 'settle': return this.settle();
      case 'stalled-calls': return this.stalledCalls();
      case 'expire-windows': return this.expireWindows();
      case 'purge-deletions': return this.purgeDeletions();
      case 'cleanup-topups': return this.cleanupTopups();
      default: return Promise.resolve();
    }
  }

  /**
   * Runs one certified RPC per item, each in its own transaction. Returns
   * {ok, failed}. A thrown RPC aborts only that item's transaction; the others
   * are untouched. Failures are logged with the id, never silently dropped.
   */
  private async forEachId(ids: string[], label: string, rpc: string, extraArgs: unknown[] = []) {
    let ok = 0;
    let failed = 0;
    for (const id of ids) {
      try {
        await this.db.runAsService((tx) => this.db.rpc(tx, rpc, [id, ...extraArgs]));
        ok++;
      } catch (e) {
        failed++;
        const msg = (e as Error).message;
        this.log.error(`${label} failed for ${id}: ${msg}`);

        // H4: Persist settlement failures to audit_log so they survive
        // beyond the ephemeral Render console. Legacy's trigger was just
        // RAISE LOG (equally ephemeral) — neither system ever had this.
        try {
          await this.db.runAsService((tx) => tx.execute(sql`
            insert into public.audit_log (actor_id, actor_role, action, target_type, target_id, new_value)
            values (null, 'SYSTEM', 'SETTLE_FAILURE', ${label}, ${id},
                    ${JSON.stringify({ error: msg })}::jsonb)
          `));
        } catch (auditErr) {
          // If the audit insert itself fails, don't mask the original error
          this.log.error(`audit_log insert failed for ${label}/${id}: ${(auditErr as Error).message}`);
        }
      }
    }
    return { ok, failed };
  }

  /** Read a batch of ids in a single service-role read (cheap, no writes). */
  private ids(query: ReturnType<typeof sql>) {
    return this.db.runAsService(async (tx) =>
      ((await tx.execute(query)) as unknown as Array<{ id: string }>).map((r) => r.id));
  }

  /** Day-7 settle: fulfilled bookings + answered paid windows + delivered shout-outs. */
  private async settle() {
    // CRITICAL: expire overdue bookings FIRST so they reach the correct terminal
    // status before settlement runs. A booking stuck in 'BOOKED' past its
    // settle_at will never match the status filter below.
    const expiry = await this.db.runAsService((tx) => this.db.rpc(tx, 'process_end_of_day_expired_bookings', []));
    if (expiry && typeof expiry === 'object' && 'failed' in expiry && expiry.failed > 0) {
      this.log.error(`expire-bookings had ${expiry.failed} failures`);
    }

    // EXPIRED_FAN_NO_JOIN removed from this filter (0066): that status is
    // refund-only, resolved a few lines up inside
    // process_end_of_day_expired_bookings. It used to also match here and
    // get passed to rpc_settle_booking, which had no internal status check
    // — paying the partner in full on top of the fan's full refund, from
    // escrow that only ever received one payment. rpc_settle_booking is now
    // hardened to refuse non-COMPLETED_SUCCESSFUL bookings regardless of
    // what this query sends it; narrowing the query too just avoids wasted
    // attempts and false "settle had failures" log noise on every run.
    // Reported items are also excluded here for the same reason — the DB
    // layer already refuses them (REPORT_PENDING), this just keeps the
    // sweep's own success/failure counts honest.
    const bookings = await this.ids(sql`
      select id from public.bookings b
      where b.status = 'COMPLETED_SUCCESSFUL' and b.settle_at <= now()
        and not exists (select 1 from public.partner_earnings e where e.service_id = b.id)
        and not exists (
          select 1 from public.reports r join public.calls c on c.id = r.target_id
           where r.target_type = 'CALL' and c.booking_id = b.id and r.status in ('PENDING','REVIEWING')
        )
      limit 200`);
    const b = await this.forEachId(bookings, 'settle-booking', 'rpc_settle_booking');

    const windows = await this.ids(sql`
      select id from public.conversation_windows w
      where w.kind='PAID' and w.status='ANSWERED' and w.settle_at <= now()
        and not exists (select 1 from public.partner_earnings e where e.service_id = w.id)
        and not exists (
          select 1 from public.reports r
           where r.target_type = 'DM' and r.target_id = w.id and r.status in ('PENDING','REVIEWING')
        )
      limit 200`);
    const w = await this.forEachId(windows, 'settle-window', 'rpc_settle_window');

    // Fan-gated lifecycle (migration 0061): deliveries the fan never acted on
    // are auto-confirmed once their review window elapses — settlement is
    // still double-gated on fan_confirmed_at below.
    const dueConfirms = await this.ids(sql`
      select id from public.shout_out_requests
      where status='VIDEO_DELIVERED_TO_FAN' and fan_confirmed_at is null and review_deadline_at <= now()
      limit 200`);
    await this.forEachId(dueConfirms, 'auto-confirm-shoutout', 'rpc_auto_confirm_shoutout');

    // FIX 7 (migration 0066): Expire undelivered shoutouts past their deadline.
    // If partner never uploads video by settle_at, fan gets full refund.
    const overdueShoutouts = await this.ids(sql`
      select id from public.shout_out_requests
      where status='AWAITING_PARTNER_VIDEO' and settle_at <= now()
      limit 200`);
    const e = await this.forEachId(overdueShoutouts, 'expire-shoutout', 'rpc_expire_shoutout');

    // Fixed: shout-outs now actually settle (rpc_settle_shoutout, migration 0036).
    // fan_confirmed_at gate (0061): unconfirmed deliveries never settle by timer.
    // FIX 6 (migration 0066): Both manual and auto-confirm now trigger immediate
    // settlement (settle_at=now()), so this sweep picks them up within 15 minutes.
    const shoutouts = await this.ids(sql`
      select id from public.shout_out_requests
      where status='VIDEO_DELIVERED_TO_FAN' and settle_at <= now()
        and fan_confirmed_at is not null
        and not exists (select 1 from public.partner_earnings e where e.service_id = shout_out_requests.id)
      limit 200`);
    const s = await this.forEachId(shoutouts, 'settle-shoutout', 'rpc_settle_shoutout');

    this.log.log(`settle — bookings ${b.ok}/${b.ok + b.failed}, windows ${w.ok}/${w.ok + w.failed}, expired ${e.ok}/${e.ok + e.failed}, shoutouts ${s.ok}/${s.ok + s.failed}`);
    if (b.failed || w.failed || e.failed || s.failed) this.log.error(`settle had failures: bookings=${b.failed} windows=${w.failed} expired=${e.failed} shoutouts=${s.failed}`);
  }

  /** IN_PROGRESS past deadline → auto-complete; stale heartbeat → drop; PARTNER_INITIATED sweeper → DB function. */
  private async stalledCalls() {
    const past = await this.ids(sql`
      select id from public.calls where attempt_status='IN_PROGRESS' and deadline_at <= now() limit 200`);
    const c = await this.forEachId(past, 'complete-call', 'rpc_complete_call', [true]);

    const stale = await this.ids(sql`
      select id from public.calls where attempt_status='IN_PROGRESS'
        and greatest(coalesce(fan_last_heartbeat_at,started_at), coalesce(partner_last_heartbeat_at,started_at)) < now() - interval '60 seconds'
      limit 200`);
    const d = await this.forEachId(stale, 'drop-call', 'rpc_mark_call_missed', ['DROPPED_TECHNICAL_ISSUE']);

    // PARTNER_INITIATED sweeper: moved to DB function cleanup_stalled_calls() for
    // consistency with legacy architecture (all sweeping logic in one place).
    const sweep = await this.db.runAsService((tx) => this.db.rpc(tx, 'cleanup_stalled_calls', []));
    const m = { ok: sweep && typeof sweep === 'object' && 'missed_fan_no_join' in sweep ? sweep.missed_fan_no_join as number : 0,
                failed: sweep && typeof sweep === 'object' && 'failed' in sweep ? sweep.failed as number : 0 };

    if (c.ok || c.failed || d.ok || d.failed || m.ok || m.failed)
      this.log.log(`calls — completed ${c.ok}/${c.ok + c.failed}, dropped ${d.ok}/${d.ok + d.failed}, missed ${m.ok}/${m.ok + m.failed}`);
  }

  /**
   * The 7-day expiry orchestrator — checks bookings past their settle_at and
   * maps them to the correct EXPIRED_* or COMPLETED status based on call history.
   * Business logic (matches legacy process_end_of_day_expired_bookings):
   *  - Any call >= 3 min (180s) → COMPLETED_SUCCESSFUL (partner earned it).
   *  - No calls at all → EXPIRED_PARTNER_NO_SHOW (refund fan).
   *  - MISSED_FAN_NO_JOIN → EXPIRED_FAN_NO_JOIN (refund fan).
   *  - MISSED_FAN_DECLINED → EXPIRED_FAN_DECLINED (refund fan).
   *  - DROPPED_TECHNICAL_ISSUE → EXPIRED_TECHNICAL_ISSUE (refund fan).
   * For EXPIRED_* statuses: manually refunds via post_transaction + updates status.
   * For COMPLETED_SUCCESSFUL: just updates status (no refund).
   * Run BEFORE settle() so bookings reach terminal state before settlement.
   * 
   * MOVED TO DATABASE: This logic is now in migration 0062 as
   * process_end_of_day_expired_bookings() — called via RPC in settle() above.
   * Keeping this method signature for reference but it's no longer used.
   */

  /**
   * PAID windows unanswered past their 48h deadline → refund the fan.
   * Fixed: the refund + status flip are now ONE atomic transaction per window.
   * Previously the window was marked EXPIRED first and the refund ran with a
   * swallowed error — a failed refund left the fan charged with no retry
   * (next run's status='OPEN' filter no longer matched). Now a failed refund
   * rolls back the whole thing, so the window stays OPEN and is retried.
   */
  private async expireWindows() {
    const rows = await this.db.runAsService(async (tx) =>
      (await tx.execute(sql`
        select w.id, c.fan_id, w.charge_paise
        from public.conversation_windows w join public.conversations c on c.id = w.conversation_id
        where w.kind='PAID' and w.status='OPEN' and w.response_deadline <= now()
        limit 200`)) as unknown as Array<{ id: string; fan_id: string; charge_paise: number }>);

    let ok = 0;
    let failed = 0;
    for (const win of rows) {
      try {
        await this.db.runAsService(async (tx) => {
          await tx.execute(sql`
            select public.post_transaction('REFUND', ${win.charge_paise},
              'qq-expire-refund:'||${win.id}::text,
              jsonb_build_array(
                jsonb_build_object('account','booking_escrow','delta_paise', ${-win.charge_paise}),
                jsonb_build_object('wallet_id',(select id from public.wallets where profile_id=${win.fan_id}),'account','wallet','delta_paise',${win.charge_paise})))`);
          // Only reached if the refund above didn't throw — same transaction.
          await tx.execute(sql`update public.conversation_windows set status='EXPIRED' where id=${win.id}`);
          // runAsService does NOT bypass RLS on notifications (the policy has
          // no service-role clause) — this must go through the SECURITY
          // DEFINER RPC, same reason calls.module.ts does. Best-effort: a
          // notification failure must not undo an already-committed refund.
          await this.db.rpc(tx, 'rpc_create_notification', [
            win.fan_id,
            null,
            sql`'QUESTION_EXPIRED_NO_RESPONSE_FAN'::public.notification_event_type_enum` as any,
            'Question expired',
            'Your question went unanswered in time and you have been refunded.',
            sql`'question'::public.notification_related_entity_type_enum` as any,
            win.id,
            sql`'{}'::jsonb` as any,
          ]).catch(() => undefined);
        });
        ok++;
      } catch (e) {
        failed++;
        this.log.error(`expire-window refund failed for ${win.id} (left OPEN for retry): ${(e as Error).message}`);
      }
    }
    if (ok || failed) this.log.log(`expire-windows — refunded ${ok}/${ok + failed}`);
  }

  /** Anonymise PII for accounts past their grace period (fixed: was a no-op). */
  private async purgeDeletions() {
    const due = await this.db.runAsService(async (tx) =>
      (await tx.execute(sql`
        select id, profile_id from public.deletion_requests
        where status in ('REQUESTED','CONFIRMED') and scheduled_purge_at <= now() limit 100`)) as unknown as Array<{ id: string; profile_id: string }>);

    let ok = 0;
    let failed = 0;
    for (const d of due) {
      try {
        await this.db.runAsService(async (tx) => {
          await this.db.rpc(tx, 'rpc_purge_profile', [d.profile_id]);
          await tx.execute(sql`update public.deletion_requests set status='COMPLETED', completed_at=now() where id=${d.id}`);
        });
        ok++;
      } catch (e) {
        failed++;
        this.log.error(`purge failed for ${d.profile_id}: ${(e as Error).message}`);
      }
    }
    if (ok || failed) this.log.log(`purge — anonymised ${ok}/${ok + failed} accounts`);
  }

  /**
   * Abandoned Razorpay checkouts → FAILED (migration 0070).
   * The RPC does the whole batch in one statement and returns how many rows
   * it touched, so there's no per-item loop here — unlike settle(), a single
   * status flip has no per-row failure mode worth isolating.
   */
  private async cleanupTopups() {
    const res = await this.db.runAsService((tx) => this.db.rpc(tx, 'rpc_cleanup_abandoned_topups', []));
    const n = res && typeof res === 'object' && 'marked_failed' in res ? (res.marked_failed as number) : 0;
    if (n > 0) this.log.log(`cleanup-topups — marked ${n} abandoned top-up(s) FAILED`);
  }

  async onModuleDestroy() {
    if (this.connection) {
      await this.worker?.close();
      await this.queue?.close();
      await this.connection?.quit();
    }
  }
}

@Module({ providers: [JobsService], exports: [JobsService] })
export class JobsModule {}
