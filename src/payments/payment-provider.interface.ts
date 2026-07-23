export interface CreatedOrder {
  orderId: string;
  amountPaise: number;
  currency: string;
  providerKeyId: string; // for the client checkout SDK
}

export interface FetchedPayment {
  paymentId: string;
  orderId: string;
  amountPaise: number;
  status: 'created' | 'authorized' | 'captured' | 'refunded' | 'failed';
}

export interface PayoutResult {
  payoutId: string;
  status: 'queued' | 'processing' | 'processed' | 'reversed' | 'failed';
}

/**
 * Abstracts the payment gateway so a second provider (Stripe for global) slots
 * in without touching the wallet domain. Razorpay is the India implementation.
 */
export abstract class PaymentProvider {
  /** Create a checkout order for `amountPaise` (money IN). */
  abstract createOrder(amountPaise: number, receipt: string, notes?: Record<string, string>): Promise<CreatedOrder>;

  /** HMAC-verify a raw inbound webhook body against the signature header. */
  abstract verifyWebhookSignature(rawBody: Buffer, signature: string): boolean;

  /** Cross-check a payment with the provider's API (never trust the client). */
  abstract fetchPayment(paymentId: string): Promise<FetchedPayment>;

  /** Money OUT — partner payout (RazorpayX). */
  abstract createPayout(amountPaise: number, methodRef: string, reference: string): Promise<PayoutResult>;
}
