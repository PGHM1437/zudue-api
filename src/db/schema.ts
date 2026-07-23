/**
 * Drizzle schema — type-safe view over the certified DDL.
 *
 * The canonical schema is the 34 SQL migrations in ../../migrations (already
 * certified + deployed). This file mirrors the core tables the domain services
 * read/write directly. State-changing money/call/message writes go through the
 * DB RPCs (via DatabaseService.rpc), not raw inserts — so only the columns the
 * API reads or filters on need to be modelled precisely here.
 */
import {
  pgTable, uuid, text, boolean, integer, bigint, timestamp, date, jsonb, numeric,
} from 'drizzle-orm/pg-core';

const paise = (name: string) => bigint(name, { mode: 'number' });

export const profiles = pgTable('profiles', {
  id: uuid('id').primaryKey(),
  role: text('role').notNull(),
  email: text('email'),
  fullName: text('full_name'),
  mobileNumber: text('mobile_number'),
  age: integer('age'),
  gender: text('gender'),
  verificationStatus: text('verification_status').notNull(),
  kycSubmittedAt: timestamp('kyc_submitted_at', { withTimezone: true }),
  referralCode: text('referral_code'),
  notificationPrefs: jsonb('notification_prefs'),
  accountStatus: text('account_status').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
});

export const partnerProfiles = pgTable('partner_profiles', {
  profileId: uuid('profile_id').primaryKey(),
  displayName: text('display_name'),
  bio: text('bio'),
  profileImagePath: text('profile_image_path'),
  status: text('status').notNull(),
  isActive: boolean('is_active').notNull(),
  vacationMode: boolean('vacation_mode').notNull(),
  isPremium: boolean('is_premium').notNull(),
  isFeatured: boolean('is_featured').notNull(),
  profileComplete: boolean('profile_complete').notNull(),
  commissionRate: numeric('commission_rate'),
});

export const wallets = pgTable('wallets', {
  id: uuid('id').primaryKey(),
  profileId: uuid('profile_id').notNull(),
  balancePaise: paise('balance_paise').notNull(),
  bonusBalancePaise: paise('bonus_balance_paise').notNull(),
});

export const transactions = pgTable('transactions', {
  id: uuid('id').primaryKey(),
  type: text('type').notNull(),
  status: text('status').notNull(),
  amountPaise: paise('amount_paise').notNull(),
  idempotencyKey: text('idempotency_key'),
  externalRef: text('external_ref'),
  refundReason: text('refund_reason'),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
});

export const ledgerEntries = pgTable('ledger_entries', {
  id: uuid('id').primaryKey(),
  transactionId: uuid('transaction_id').notNull(),
  walletId: uuid('wallet_id'),
  account: text('account').notNull(),
  deltaPaise: paise('delta_paise').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
});

export const topupOrders = pgTable('topup_orders', {
  id: uuid('id').primaryKey(),
  profileId: uuid('profile_id').notNull(),
  creditPaise: paise('credit_paise').notNull(),
  gstPaise: paise('gst_paise').notNull(),
  amountPaise: paise('amount_paise').notNull(),
  razorpayOrderId: text('razorpay_order_id'),
  razorpayPaymentId: text('razorpay_payment_id'),
  status: text('status').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
});

export const partnerServices = pgTable('partner_services', {
  id: uuid('id').primaryKey(),
  partnerId: uuid('partner_id').notNull(),
  serviceType: text('service_type').notNull(),
  duration: text('duration'),
  pricePaise: paise('price_paise').notNull(),
  isActive: boolean('is_active').notNull(),
});

export const availability = pgTable('availability', {
  id: uuid('id').primaryKey(),
  partnerId: uuid('partner_id').notNull(),
  date: date('date').notNull(),
  isAvailable: boolean('is_available').notNull(),
  thresholdMinutes: integer('threshold_minutes').notNull(),
  bookedMinutes: integer('booked_minutes').notNull(),
});

export const bookings = pgTable('bookings', {
  id: uuid('id').primaryKey(),
  fanId: uuid('fan_id').notNull(),
  partnerId: uuid('partner_id').notNull(),
  scheduledDate: date('scheduled_date').notNull(),
  selectedDuration: text('selected_duration').notNull(),
  pricePaise: paise('price_paise').notNull(),
  status: text('status').notNull(),
  fanReadyAt: timestamp('fan_ready_at', { withTimezone: true }),
  meetingId: text('meeting_id'),
  settleAt: timestamp('settle_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
});

export const calls = pgTable('calls', {
  id: uuid('id').primaryKey(),
  bookingId: uuid('booking_id').notNull(),
  fanId: uuid('fan_id').notNull(),
  partnerId: uuid('partner_id').notNull(),
  attemptStatus: text('attempt_status').notNull(),
  meetingId: text('meeting_id'),
  startedAt: timestamp('started_at', { withTimezone: true }),
  deadlineAt: timestamp('deadline_at', { withTimezone: true }),
  endedAt: timestamp('ended_at', { withTimezone: true }),
});

export const conversations = pgTable('conversations', {
  id: uuid('id').primaryKey(),
  fanId: uuid('fan_id').notNull(),
  partnerId: uuid('partner_id').notNull(),
  lastActivityAt: timestamp('last_activity_at', { withTimezone: true }),
});

export const conversationWindows = pgTable('conversation_windows', {
  id: uuid('id').primaryKey(),
  conversationId: uuid('conversation_id').notNull(),
  kind: text('kind').notNull(),
  chargePaise: paise('charge_paise').notNull(),
  status: text('status').notNull(),
  responseDeadline: timestamp('response_deadline', { withTimezone: true }),
  settleAt: timestamp('settle_at', { withTimezone: true }),
  openedAt: timestamp('opened_at', { withTimezone: true }).notNull(),
});

export const messages = pgTable('messages', {
  id: uuid('id').primaryKey(),
  windowId: uuid('window_id').notNull(),
  sender: text('sender').notNull(),
  body: text('body').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
});

export const shoutOutRequests = pgTable('shout_out_requests', {
  id: uuid('id').primaryKey(),
  fanId: uuid('fan_id').notNull(),
  partnerId: uuid('partner_id').notNull(),
  recipientName: text('recipient_name'),
  pricePaise: paise('price_paise').notNull(),
  status: text('status').notNull(),
  deliveredVideoLink: text('delivered_video_link'),
  settleAt: timestamp('settle_at', { withTimezone: true }),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
});

export const partnerEarnings = pgTable('partner_earnings', {
  id: uuid('id').primaryKey(),
  partnerId: uuid('partner_id').notNull(),
  serviceType: text('service_type').notNull(),
  amountPaise: paise('amount_paise').notNull(),
  status: text('status').notNull(),
  payoutId: uuid('payout_id'),
});

export const payoutMethods = pgTable('payout_methods', {
  id: uuid('id').primaryKey(),
  partnerId: uuid('partner_id').notNull(),
  methodType: text('method_type').notNull(),
  isVerified: boolean('is_verified').notNull(),
  isPrimary: boolean('is_primary').notNull(),
});

export const partnerPayouts = pgTable('partner_payouts', {
  id: uuid('id').primaryKey(),
  partnerId: uuid('partner_id').notNull(),
  amountPaise: paise('amount_paise').notNull(),
  status: text('status').notNull(),
  utr: text('utr'),
});

export const categories = pgTable('categories', {
  id: uuid('id').primaryKey(),
  slug: text('slug').notNull(),
  name: text('name').notNull(),
  sortOrder: integer('sort_order'),
});

export const notifications = pgTable('notifications', {
  id: uuid('id').primaryKey(),
  recipientId: uuid('recipient_id').notNull(),
  eventType: text('event_type').notNull(),
  title: text('title'),
  message: text('message'),
  isRead: boolean('is_read').notNull(),
  createdAt: timestamp('created_at', { withTimezone: true }).notNull(),
});
