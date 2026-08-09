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

/**
 * Abstracts the payment gateway so a second provider (Stripe for global) slots
 * in without touching the wallet domain. Razorpay is the India implementation.
 *
 * Money OUT (partner payouts) is deliberately NOT part of this interface:
 * payouts are on-demand and processed offline (admin sends the bank/UPI
 * transfer by hand, then records the UTR via rpc_process_payout) — there is
 * no automated payout gateway integration by design.
 */
export abstract class PaymentProvider {
  /** Create a checkout order for `amountPaise` (money IN). */
  abstract createOrder(amountPaise: number, receipt: string, notes?: Record<string, string>): Promise<CreatedOrder>;

  /** HMAC-verify a raw inbound webhook body against the signature header. */
  abstract verifyWebhookSignature(rawBody: Buffer, signature: string): boolean;

  /** Cross-check a payment with the provider's API (never trust the client). */
  abstract fetchPayment(paymentId: string): Promise<FetchedPayment>;
}
