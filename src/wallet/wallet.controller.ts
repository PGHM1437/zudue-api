import {
  Body, Controller, Get, Headers, Post, Query, RawBodyRequest, Req, UseGuards,
} from '@nestjs/common';
import { Request } from 'express';
import { JwtGuard } from '../auth/jwt.guard';
import { CurrentUser, AuthUser } from '../auth/current-user.decorator';
import { WalletService } from './wallet.service';

@Controller('wallet')
export class WalletController {
  constructor(private readonly wallet: WalletService) {}

  @UseGuards(JwtGuard)
  @Get('balance')
  balance(@CurrentUser() user: AuthUser) {
    return this.wallet.getBalance(user.id);
  }

  @UseGuards(JwtGuard)
  @Get('history')
  history(@CurrentUser() user: AuthUser, @Query('limit') limit?: string) {
    return this.wallet.getHistory(user.id, limit ? Number(limit) : undefined);
  }

  @UseGuards(JwtGuard)
  @Post('topup')
  topup(@CurrentUser() user: AuthUser, @Body('creditPaise') creditPaise: number) {
    return this.wallet.createTopup(user.id, creditPaise);
  }

  /** Razorpay webhook — NO auth guard; secured by HMAC signature instead. */
  @Post('webhook/razorpay')
  webhook(
    @Req() req: RawBodyRequest<Request>,
    @Headers('x-razorpay-signature') signature: string,
  ) {
    return this.wallet.handleWebhook(req.rawBody as Buffer, signature);
  }
}
