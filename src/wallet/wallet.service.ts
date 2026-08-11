import { BadRequestException, Injectable, Logger } from '@nestjs/common';
import { sql } from 'drizzle-orm';
import { DatabaseService } from '../db/database.service';
import { PaymentProvider } from '../payments/payment-provider.interface';

/** Razorpay dispute event -> our dispute_status enum. Anything unmapped is
 *  recorded as OPEN so a new provider event type surfaces for a human rather
 *  than being silently dropped. */
const DISPUTE_STATUS: Record<string, string> = {
  'payment.dispute.created': 'OPEN',
  'payment.dispute.under_review': 'UNDER_REVIEW',
  'payment.dispute.won': 'WON',
  'payment.dispute.lost': 'LOST',
  'payment.dispute.closed': 'CLOSED',
};

/**
 * Wallet — the money core. Upholds INVARIANTS.md:
 *  · integer paise · idempotent (order id keyed) · HMAC-verified inbound
 *  · cross-checked against the provider · append-only double-entry ledger
 *  · no double-spend (all settlement via the DB primitive post_transaction).
 * The service ORCHESTRATES; the DB RPCs GUARANTEE. Money never moves outside a
 * DB RPC, so idempotency/overdraft/balanced-legs are enforced by the database.
 */
@Injectable()
export class WalletService {
  private readonly log = new Logger(WalletService.name);

  constructor(
    private readonly db: DatabaseService,
    private readonly payments: PaymentProvider,
  ) {}

  /**
   * Fan initiates a top-up: create the Razorpay order, record the pending order.
   *
   * Deliberately THREE phases, not one transaction:
   *
   *  1. read settings + cheap validation,
   *  2. the Razorpay call, with NO transaction open,
   *  3. one short transaction that takes the ceiling decision and records it.
   *
   * Phase 2 used to sit inside the transaction opened in phase 1. The pool is
   * only 20 connections, so every slow gateway response pinned a connection
   * AND an open transaction — enough concurrent top-ups against a degraded
   * Razorpay would starve the pool for the whole API, not just for payments.
   *
   * Phase 3 holds a per-user advisory lock (not SELECT ... FOR UPDATE: wallets
   * has only a SELECT policy, so FOR UPDATE cannot be granted under RLS) and
   * counts already-reserved PENDING orders. Without both, two simultaneous
   * top-ups each read the same pre-top-up balance, each saw room under the cap,
   * and together they breached the prepaid ceiling.
   *
   * Reserved orders are only counted for 30 minutes. A crash between phases 2
   * and 3, or an order the fan simply abandons, must not hold a reservation
   * against them forever — unpaid Razorpay orders expire on their side too.
   */
  async createTopup(userId: string, creditPaise: number) {
    if (!Number.isInteger(creditPaise) || creditPaise <= 0) {
      throw new BadRequestException('creditPaise must be a positive integer');
    }

    // ── Phase 1 · settings + per-transaction limits ────────────────────────
    const settings = await this.db.runAs(userId, async (tx) => {
      const [row] = (await tx.execute(sql`
        select gst_rate, min_wallet_topup_paise, max_wallet_topup_paise, max_wallet_balance_paise
        from public.platform_settings where id = 1
      `)) as unknown as Array<{
        gst_rate: string; min_wallet_topup_paise: number;
        max_wallet_topup_paise: number; max_wallet_balance_paise: number | null;
      }>;
      return row;
    });

    const gstRate = Number(settings?.gst_rate ?? 0.18);
    const gstPaise = Math.round(creditPaise * gstRate);
    const amountPaise = creditPaise + gstPaise;

    if (settings?.min_wallet_topup_paise && creditPaise < settings.min_wallet_topup_paise) {
      throw new BadRequestException('BELOW_MIN_TOPUP');
    }
    if (settings?.max_wallet_topup_paise && creditPaise > settings.max_wallet_topup_paise) {
      throw new BadRequestException('ABOVE_MAX_TOPUP');
    }

    // ── Phase 2 · external call, no transaction, no connection held ────────
    const order = await this.payments.createOrder(amountPaise, `topup_${userId.slice(0, 8)}_${Date.now()}`, {
      profile_id: userId,
    });

    // ── Phase 3 · authoritative ceiling check + record, serialised per user ─
    return this.db.runAs(userId, async (tx) => {
      if (settings?.max_wallet_balance_paise) {
        await tx.execute(sql`select pg_advisory_xact_lock(hashtext('zudue:topup'), hashtext(${userId}))`);

        const [w] = (await tx.execute(sql`
          select balance_paise from public.wallets where profile_id = ${userId}
        `)) as unknown as Array<{ balance_paise: number }>;
        const [r] = (await tx.execute(sql`
          select coalesce(sum(credit_paise), 0) as reserved from public.topup_orders
          where profile_id = ${userId} and status = 'PENDING'
            and created_at > now() - interval '30 minutes'
        `)) as unknown as Array<{ reserved: number }>;

        const projected = Number(w?.balance_paise ?? 0) + Number(r?.reserved ?? 0) + creditPaise;
        if (projected > settings.max_wallet_balance_paise) {
          // The order created in phase 2 is simply never paid and expires at
          // Razorpay. No money has moved, so there is nothing to refund —
          // which is the whole reason the ceiling is enforced before capture.
          throw new BadRequestException('WALLET_BALANCE_CAP_EXCEEDED');
        }
      }

      // Fan self-inserts their own pending order (RLS: topup_self_insert).
      await tx.execute(sql`
        insert into public.topup_orders
          (profile_id, credit_paise, gst_paise, amount_paise, razorpay_order_id, status)
        values (${userId}, ${creditPaise}, ${gstPaise}, ${amountPaise}, ${order.orderId}, 'PENDING')
      `);

      return {
        orderId: order.orderId,
        amountPaise,
        creditPaise,
        gstPaise,
        currency: order.currency,
        keyId: order.providerKeyId,
      };
    });
  }

  /**
   * Inbound Razorpay webhook. HMAC-verified, logged idempotently, cross-checked
   * with the provider, then settled via rpc_verify_topup (itself idempotent).
   * Runs as the trusted service role — never a client identity.
   */
  async handleWebhook(rawBody: Buffer, signature: string) {
    if (!this.payments.verifyWebhookSignature(rawBody, signature)) {
      throw new BadRequestException('INVALID_SIGNATURE');
    }
    // A payload that passes HMAC verification is still just bytes — a
    // malformed body threw an uncaught SyntaxError here, which Nest renders
    // as a 500. Razorpay retries on 5xx, so a single bad delivery could loop.
    let event: any;
    try {
      event = JSON.parse(rawBody.toString('utf8'));
    } catch {
      throw new BadRequestException('MALFORMED_PAYLOAD');
    }
    const eventId: string = event.id ?? event.payload?.payment?.entity?.id;

    return this.db.runAsService(async (tx) => {
      // Idempotent inbound log — replay-safe by unique (provider, event_id).
      const inserted = (await tx.execute(sql`
        insert into public.webhook_events (provider, event_id, event_type, payload, status)
        values ('razorpay', ${eventId}, ${event.event ?? 'unknown'}, ${JSON.stringify(event)}::jsonb, 'RECEIVED')
        on conflict (provider, event_id) do nothing
        returning id
      `)) as unknown as Array<{ id: string }>;
      if (inserted.length === 0) {
        this.log.log(`webhook ${eventId} already processed — skipping`);
        return { replayed: true };
      }

      if (event.event === 'payment.captured' || event.event === 'order.paid') {
        const entity = event.payload?.payment?.entity ?? event.payload?.order?.entity;
        const paymentId: string = entity?.id;
        const orderId: string = entity?.order_id ?? entity?.id;

        // Cross-check with Razorpay's API — do not trust the webhook body alone.
        const fetched = await this.payments.fetchPayment(paymentId);
        if (fetched.status !== 'captured' || fetched.orderId !== orderId) {
          await tx.execute(sql`update public.webhook_events set status='FAILED', processed_at=now() where id=${inserted[0].id}`);
          throw new BadRequestException('PAYMENT_CROSS_CHECK_FAILED');
        }

        const res = await this.db.rpc(tx, 'rpc_verify_topup', [orderId, paymentId]);
        await tx.execute(sql`update public.webhook_events set status='PROCESSED', processed_at=now() where id=${inserted[0].id}`);
        return { processed: true, transaction: res?.transaction_id ?? null };
      }

      // Chargebacks. Razorpay emits payment.dispute.{created,under_review,won,
      // lost,closed}; every one of these previously fell through to `ignored`,
      // which is why the admin Disputes queue could never populate. The RPC is
      // idempotent on the dispute id, so lifecycle events update one row.
      if (event.event?.startsWith('payment.dispute.')) {
        const d = event.payload?.dispute?.entity;
        const paymentId: string = d?.payment_id ?? event.payload?.payment?.entity?.id;
        const status = DISPUTE_STATUS[event.event] ?? 'OPEN';
        const res = await this.db.rpc(tx, 'rpc_record_dispute', [
          d?.id ?? eventId,
          paymentId ?? null,
          Number(d?.amount ?? 0),
          d?.reason_code ?? d?.reason_description ?? null,
          sql`${status}::public.dispute_status` as any,
        ]);
        await tx.execute(sql`update public.webhook_events set status='PROCESSED', processed_at=now() where id=${inserted[0].id}`);
        this.log.warn(`chargeback ${event.event} recorded — dispute ${res?.dispute_id}`);
        return { processed: true, dispute: res?.dispute_id ?? null };
      }

      await tx.execute(sql`update public.webhook_events set status='PROCESSED', processed_at=now() where id=${inserted[0].id}`);
      return { ignored: event.event };
    });
  }

  async getBalance(userId: string) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select balance_paise, bonus_balance_paise from public.wallets where profile_id = ${userId}
      `)) as unknown as Array<{ balance_paise: number; bonus_balance_paise: number }>;
      const w = rows[0] ?? { balance_paise: 0, bonus_balance_paise: 0 };
      return { balancePaise: w.balance_paise, bonusPaise: w.bonus_balance_paise };
    });
  }

  /** Fan's own money history (RLS: txn_owner_read scopes to their wallet). */
  async getHistory(userId: string, limit = 50) {
    return this.db.runAs(userId, async (tx) => {
      const rows = (await tx.execute(sql`
        select t.id, t.type, t.status, t.amount_paise, t.created_at,
               le.delta_paise as wallet_delta
        from public.transactions t
        join public.ledger_entries le on le.transaction_id = t.id
        join public.wallets w on w.id = le.wallet_id and w.profile_id = ${userId}
        order by t.created_at desc
        limit ${limit}
      `)) as unknown as Array<any>;
      return rows;
    });
  }
}
