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

  async onModuleInit() {
    this.connection = new IORedis(this.config.getOrThrow('REDIS_URL'), { maxRetriesPerRequest: null });
    this.queue = new Queue('lifecycle', { connection: this.connection });

    const every = async (name: string, pattern: string) =>
      this.queue.add(name, {}, { repeat: { pattern }, jobId: name, removeOnComplete: 100, removeOnFail: 500 });
    await every('settle', '*/15 * * * *');
    await every('stalled-calls', '* * * * *');
    await every('expire-windows', '*/15 * * * *');
    await every('purge-deletions', '0 3 * * *');
    await every('monthly-payouts', '0 6 * * *');

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
      case 'monthly-payouts': return this.monthlyPayouts();
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
        this.log.error(`${label} failed for ${id}: ${(e as Error).message}`);
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
    const bookings = await this.ids(sql`
      select id from public.bookings
      where status in ('COMPLETED_SUCCESSFUL','EXPIRED_FAN_NO_JOIN') and settle_at <= now()
        and not exists (select 1 from public.partner_earnings e where e.service_id = bookings.id)
      limit 200`);
    const b = await this.forEachId(bookings, 'settle-booking', 'rpc_settle_booking');

    const windows = await this.ids(sql`
      select id from public.conversation_windows
      where kind='PAID' and status='ANSWERED' and settle_at <= now()
        and not exists (select 1 from public.partner_earnings e where e.service_id = conversation_windows.id)
      limit 200`);
    const w = await this.forEachId(windows, 'settle-window', 'rpc_settle_window');

    // Fixed: shout-outs now actually settle (rpc_settle_shoutout, migration 0036).
    const shoutouts = await this.ids(sql`
      select id from public.shout_out_requests
      where status='VIDEO_DELIVERED_TO_FAN' and settle_at <= now()
        and not exists (select 1 from public.partner_earnings e where e.service_id = shout_out_requests.id)
      limit 200`);
    const s = await this.forEachId(shoutouts, 'settle-shoutout', 'rpc_settle_shoutout');

    this.log.log(`settle — bookings ${b.ok}/${b.ok + b.failed}, windows ${w.ok}/${w.ok + w.failed}, shoutouts ${s.ok}/${s.ok + s.failed}`);
    if (b.failed || w.failed || s.failed) this.log.error(`settle had failures: bookings=${b.failed} windows=${w.failed} shoutouts=${s.failed}`);
  }

  /** IN_PROGRESS past deadline → auto-complete; stale heartbeat → drop. */
  private async stalledCalls() {
    const past = await this.ids(sql`
      select id from public.calls where attempt_status='IN_PROGRESS' and deadline_at <= now() limit 200`);
    const c = await this.forEachId(past, 'complete-call', 'rpc_complete_call', [true]);

    const stale = await this.ids(sql`
      select id from public.calls where attempt_status='IN_PROGRESS'
        and greatest(coalesce(fan_last_heartbeat_at,started_at), coalesce(partner_last_heartbeat_at,started_at)) < now() - interval '60 seconds'
      limit 200`);
    const d = await this.forEachId(stale, 'drop-call', 'rpc_mark_call_missed', ['DROPPED_TECHNICAL_ISSUE']);

    if (c.ok || c.failed || d.ok || d.failed) this.log.log(`calls — completed ${c.ok}/${c.ok + c.failed}, dropped ${d.ok}/${d.ok + d.failed}`);
  }

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

  /** Monthly: create a payout batch per partner with pending earnings + a verified primary method. */
  private async monthlyPayouts() {
    const [settings] = (await this.db.runAsService((tx) =>
      tx.execute(sql`select payout_day_of_month from public.platform_settings where id=1`))) as unknown as Array<{ payout_day_of_month: number | null }>;
    // Day-of-month compared in IST (the business timezone), not the server's.
    const istDay = Number(new Intl.DateTimeFormat('en-GB', { timeZone: 'Asia/Kolkata', day: 'numeric' }).format(new Date()));
    if (settings?.payout_day_of_month && istDay !== settings.payout_day_of_month) return;

    const partners = await this.db.runAsService(async (tx) =>
      (await tx.execute(sql`
        select distinct e.partner_id, pm.id as method_id
        from public.partner_earnings e
        join public.payout_methods pm on pm.partner_id = e.partner_id and pm.is_verified and pm.is_primary
        where e.status='PENDING_PAYOUT' limit 500`)) as unknown as Array<{ partner_id: string; method_id: string }>);

    let ok = 0;
    let failed = 0;
    for (const p of partners) {
      try {
        await this.db.runAsService((tx) => this.db.rpc(tx, 'rpc_create_payout_batch', [p.partner_id, p.method_id]));
        ok++;
      } catch (e) {
        failed++;
        this.log.error(`payout-batch failed for ${p.partner_id}: ${(e as Error).message}`);
      }
    }
    if (ok || failed) this.log.log(`monthly-payouts — batched ${ok}/${ok + failed}`);
  }

  async onModuleDestroy() {
    await this.worker?.close();
    await this.queue?.close();
    await this.connection?.quit();
  }
}

@Module({ providers: [JobsService] })
export class JobsModule {}
