import { Global, Module } from '@nestjs/common';
import { PaymentProvider } from './payment-provider.interface';
import { RazorpayProvider } from './razorpay.provider';

@Global()
@Module({
  providers: [{ provide: PaymentProvider, useClass: RazorpayProvider }],
  exports: [PaymentProvider],
})
export class PaymentsModule {}
