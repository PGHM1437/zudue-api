import { Injectable, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import * as crypto from 'crypto';
import Razorpay from 'razorpay';
import {
  CreatedOrder, FetchedPayment, PayoutResult, PaymentProvider,
} from './payment-provider.interface';

@Injectable()
export class RazorpayProvider extends PaymentProvider {
  private readonly log = new Logger(RazorpayProvider.name);
  private readonly client: Razorpay;
  private readonly keyId: string;
  private readonly webhookSecret: string;

  constructor(config: ConfigService) {
    super();
    this.keyId = config.get('RAZORPAY_KEY_ID') ?? '';
    this.webhookSecret = config.get('RAZORPAY_WEBHOOK_SECRET') ?? '';
    this.client = new Razorpay({
      key_id: this.keyId,
      key_secret: config.get('RAZORPAY_KEY_SECRET') ?? '',
    });
  }

  async createOrder(amountPaise: number, receipt: string, notes?: Record<string, string>): Promise<CreatedOrder> {
    const order = await this.client.orders.create({
      amount: amountPaise, // Razorpay amount IS in paise
      currency: 'INR',
      receipt,
      notes,
      payment_capture: true,
    });
    return {
      orderId: order.id,
      amountPaise: Number(order.amount),
      currency: order.currency,
      providerKeyId: this.keyId,
    };
  }

  /** Constant-time HMAC-SHA256 verification of the webhook body. */
  verifyWebhookSignature(rawBody: Buffer, signature: string): boolean {
    if (!this.webhookSecret || !signature) return false;
    const expected = crypto
      .createHmac('sha256', this.webhookSecret)
      .update(rawBody)
      .digest('hex');
    const a = Buffer.from(expected);
    const b = Buffer.from(signature);
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  }

  async fetchPayment(paymentId: string): Promise<FetchedPayment> {
    const p: any = await this.client.payments.fetch(paymentId);
    return {
      paymentId: p.id,
      orderId: p.order_id,
      amountPaise: Number(p.amount),
      status: p.status,
    };
  }

  async createPayout(amountPaise: number, methodRef: string, reference: string): Promise<PayoutResult> {
    // RazorpayX fund-account payout. Requires RAZORPAYX_ACCOUNT_NUMBER + a
    // fund_account_id (methodRef). Left as a typed integration point.
    this.log.warn(`createPayout(${reference}) — wire RazorpayX fund account ${methodRef}`);
    throw new Error('RAZORPAYX_PAYOUT_NOT_CONFIGURED');
  }
}
