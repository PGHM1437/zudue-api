import {
  Body, Controller, Get, Headers, Post, Query, RawBodyRequest, Req, UseGuards,
} from '@nestjs/common';
import { Request } from 'express';
import { JwtGuard } from '../auth/jwt.guard';
import { CurrentUser, AuthUser } from '../auth/current-user.decorator';
import { WalletService } from './wallet.service';
import { CreateTopupDto, HistoryQueryDto } from './wallet.dto';
import { RateLimit } from '../throttle/throttle.guard';

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
  history(@CurrentUser() user: AuthUser, @Query() q: HistoryQueryDto) {
    return this.wallet.getHistory(user.id, q.limit);
  }

  @UseGuards(JwtGuard)
  @RateLimit({ limit: 10, windowSeconds: 60 }) // money-adjacent — tighter than the global default
  @Post('topup')
  topup(@CurrentUser() user: AuthUser, @Body() b: CreateTopupDto) {
    return this.wallet.createTopup(user.id, b.creditPaise);
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
