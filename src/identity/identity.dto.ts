import { Type } from 'class-transformer';
import {
  IsArray, IsBoolean, IsEmail, IsIn, IsInt, IsObject, IsOptional, IsString,
  MaxLength, Max, Min,
} from 'class-validator';

/**
 * Request shapes for IdentityController.
 *
 * NOTE the casing split, which is load-bearing: POST /me takes camelCase
 * (fullName), PUT /me takes snake_case (full_name) because its setter map is
 * keyed by column name. ValidationPipe runs with `whitelist: true`, so a
 * property spelled differently here than the client sends is silently STRIPPED,
 * not rejected — these names were verified against the live callers
 * (register_screen.dart, edit_profile_screen.dart), not assumed.
 *
 * `role` is deliberately absent from CreateProfileDto: self-registration is
 * always FAN and the value is no longer read from the body at all (see
 * IdentityService.createProfile and migration 0064).
 */
export class CreateProfileDto {
  @IsString() @MaxLength(120) fullName!: string;
  @IsOptional() @IsEmail() email?: string;
  @IsOptional() @IsString() @MaxLength(20) mobileNumber?: string;
}

/** gender_enum, verified live: MALE · FEMALE · OTHER · PREFER_NOT_TO_SAY. */
export const GENDERS = ['MALE', 'FEMALE', 'OTHER', 'PREFER_NOT_TO_SAY'] as const;

export class UpdateProfileDto {
  @IsOptional() @IsString() @MaxLength(120) full_name?: string;
  @IsOptional() @IsString() @MaxLength(20) mobile_number?: string;

  /** Matches the DB floor added in migration 0074 (profiles_age_range CHECK,
   *  13-120, COPPA-aligned). Keep these in lock-step: a lower value here than
   *  the DB allows just means users get a raw constraint-violation 500
   *  instead of a clean 400 for ages 1-12. */
  @IsOptional() @Type(() => Number) @IsInt() @Min(13) @Max(120) age?: number;

  /** Cast to ::gender_enum at the bind site — an unknown value raised 22P02. */
  @IsOptional() @IsIn(GENDERS as unknown as string[]) gender?: string;

  @IsOptional() @IsObject() notification_prefs?: Record<string, unknown>;
}

export class UpdatePartnerProfileDto {
  @IsOptional() @IsString() @MaxLength(80) display_name?: string;
  @IsOptional() @IsString() @MaxLength(2000) bio?: string;
  @IsOptional() @IsString() @MaxLength(512) profile_image_path?: string;
  @IsOptional() @IsBoolean() vacation_mode?: boolean;
  @IsOptional() @IsBoolean() profile_complete?: boolean;
  @IsOptional() @IsArray() @IsString({ each: true }) languages?: string[];
}

export class SubmitKycDto {
  @IsArray() documents!: unknown[];
}

export class SubmitApplicationDto {
  @IsString() @MaxLength(120) applicantFullName!: string;
  @IsEmail() email!: string;
  @IsString() @MaxLength(20) mobileNumber!: string;
  @IsOptional() @IsString() @MaxLength(512) primarySocialLink?: string;
  @IsOptional() @IsString() @MaxLength(2000) expertiseDescription?: string;
}
