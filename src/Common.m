#import "NC.h"

UIColor *NCHue(uint32_t argb, BOOL night) {
  if (!night) return NCRGB(argb);
  // Colour.lerp(c, _nightRed 0xFFFF4A3D, 0.8)
  CGFloat t = 0.8;
  CGFloat r = ((argb >> 16) & 0xFF), g = ((argb >> 8) & 0xFF), b = (argb & 0xFF);
  CGFloat a = ((argb >> 24) & 0xFF);
  r += (0xFF - r) * t; g += (0x4A - g) * t; b += (0x3D - b) * t; a += (0xFF - a) * t;
  return [UIColor colorWithRed:r / 255 green:g / 255 blue:b / 255 alpha:a / 255];
}

NSInteger NCHour(NSDate *t) {
  return [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:t];
}

BOOL NCIsNight(NSDate *t) {
#if FORCE_NIGHT
  return YES;
#elif FORCE_MORNING
  return NO;
#else
  NSInteger h = NCHour(t);
  return h >= 23 || h < 6;
#endif
}

BOOL NCIsDark(NSDate *t) {
#if FORCE_MORNING
  return NO;
#else
  NSInteger h = NCHour(t);
  return h >= 19 || h < 6;
#endif
}

BOOL NCIsMorning(NSDate *t) {
#if FORCE_MORNING
  return YES;
#else
  NSInteger h = NCHour(t);
  return h >= 6 && h < 11;
#endif
}

NSString *NCClockPalette(NSDate *now, BOOL raining) {
#if FORCE_RAIN
  raining = YES;
#endif
#if FORCE_CLEAR
  raining = NO;
#endif
  if (NCIsNight(now)) return @"night";
  if (NCIsDark(now)) return raining ? @"darkrain" : @"dark";
  if (raining) return @"rain";
  if (NCIsMorning(now)) return @"morning";
  NSInteger h = NCHour(now);
  if (h >= 17 && h < 19) return @"evening";
  return @"day";
}

UIColor *NCClockColor(NSDate *now, BOOL raining) {
  // Sunrise amber, sunny yellow, sunset coral, steel blue in the rain;
  // after dark moonlit lavender (deep blue in the rain), slate in red
  // night mode — the fills of the old Bungee Tint palettes.
  NSString *p = NCClockPalette(now, raining);
  if ([p isEqualToString:@"night"]) return NCRGB(0xFF56617C);
  if ([p isEqualToString:@"dark"]) return NCRGB(0xFFB4C2FF);
  if ([p isEqualToString:@"darkrain"]) return NCRGB(0xFF6E9BD0);
  if ([p isEqualToString:@"rain"]) return NCRGB(0xFF8EC5F0);
  if ([p isEqualToString:@"morning"]) return NCRGB(0xFFFFB547);
  if ([p isEqualToString:@"evening"]) return NCRGB(0xFFFF8A6B);
  return NCRGB(0xFFFFD23F);
}

// ── NCGlyphs ──────────────────────────────────────────────────────────────

@implementation NCGlyphs {
  NSCache *_images;
}

+ (instancetype)shared {
  static NCGlyphs *s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{ s = [NCGlyphs new]; });
  return s;
}

- (instancetype)init {
  if ((self = [super init])) _images = [NSCache new];
  return self;
}

- (void)drawIcon:(NSString *)name in:(CGRect)rect color:(UIColor *)color {
  NSString *key = [@"icon_" stringByAppendingString:name];
  UIImage *img = [_images objectForKey:key];
  if (!img) {
    img = [UIImage imageWithContentsOfFile:[[NSBundle mainBundle] pathForResource:key ofType:@"png"]];
    if (!img) return;
    [_images setObject:img forKey:key];
  }
  CGContextRef ctx = UIGraphicsGetCurrentContext();
  // Draw the white shape, then paint the colour only where it is.
  CGContextSaveGState(ctx);
  CGContextBeginTransparencyLayerWithRect(ctx, rect, NULL);
  [img drawInRect:rect];
  CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
  [color setFill];
  CGContextFillRect(ctx, rect);
  CGContextEndTransparencyLayer(ctx);
  CGContextRestoreGState(ctx);
}

@end

// ── NCWeather ────────────────────────────────────────────────────────────

@implementation NCWeather

- (NSString *)icon {
  NSString *dn = self.isDay ? @"day" : @"night";
  NSInteger c = self.code;
  if (FORCE_RAIN) return @"rain";
  if (FORCE_CLEAR) return [@"clear-" stringByAppendingString:dn];
  if (c >= 95) return @"thunderstorms-rain";
  if (c >= 85 || (c >= 71 && c <= 77)) return @"snow";
  if (c >= 80) return [NSString stringWithFormat:@"partly-cloudy-%@-rain", dn];
  if (c >= 61) return @"rain";
  if (c >= 51) return @"drizzle";
  if (self.raining) return @"rain";
  if (c >= 45) return [@"fog-" stringByAppendingString:dn];
  if (c == 3) return @"overcast";
  if (c == 2) return [@"partly-cloudy-" stringByAppendingString:dn];
  return [@"clear-" stringByAppendingString:dn];
}

+ (void)fetch:(void (^)(NCWeather *))done {
  NSArray *parts = [@WEATHER_AT componentsSeparatedByString:@","];
  if (parts.count != 2) { done(nil); return; }
  NSString *url = [NSString stringWithFormat:
      @"https://api.open-meteo.com/v1/forecast?latitude=%@&longitude=%@"
      @"&current=temperature_2m,precipitation,weather_code,is_day"
      @"&daily=temperature_2m_min,temperature_2m_max&forecast_days=1&timezone=auto",
      [parts[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet],
      [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]];
  NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  cfg.timeoutIntervalForRequest = 15;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
  [[session dataTaskWithURL:[NSURL URLWithString:url]
          completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
    // No @try: 32-bit exception unwinding isn't in the old SDK, so check
    // every type instead.
    NCWeather *w = nil;
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSDictionary *cur = [json isKindOfClass:NSDictionary.class] ? json[@"current"] : nil;
    NSDictionary *daily = [json isKindOfClass:NSDictionary.class] ? json[@"daily"] : nil;
    if ([cur isKindOfClass:NSDictionary.class] && [daily isKindOfClass:NSDictionary.class]) {
      NSArray *lo = daily[@"temperature_2m_min"], *hi = daily[@"temperature_2m_max"];
      NSNumber *t = cur[@"temperature_2m"];
      if ([lo isKindOfClass:NSArray.class] && [hi isKindOfClass:NSArray.class] && lo.count && hi.count &&
          [t isKindOfClass:NSNumber.class]) {
        w = [NCWeather new];
        NSInteger code = [cur[@"weather_code"] isKindOfClass:NSNumber.class] ? [cur[@"weather_code"] integerValue] : 0;
        double rain = [cur[@"precipitation"] isKindOfClass:NSNumber.class] ? [cur[@"precipitation"] doubleValue] : 0;
        // WMO 51 and up: drizzle, rain, showers, thunderstorms.
        w.raining = code >= 51 || rain > 0.1;
        w.code = code;
        w.isDay = ![cur[@"is_day"] isKindOfClass:NSNumber.class] || [cur[@"is_day"] integerValue] != 0;
        w.temp = lround(t.doubleValue);
        w.low = lround([lo.firstObject doubleValue]);
        w.high = lround([hi.firstObject doubleValue]);
      }
    }
    [session finishTasksAndInvalidate];
    dispatch_async(dispatch_get_main_queue(), ^{ done(w); });
  }] resume];
}

@end

// ── NCHolidays ───────────────────────────────────────────────────────────

static NSString *const kHolidaysKey = @"holidays", *const kHolidaysAtKey = @"holidaysAt";
/// How far ahead the face shows a holiday (the user asked, 10 Nov 2026).
static const NSInteger kHolidayDays = 15;

@implementation NCHolidays

/// "yyyyMMdd=Name" lines out of an iCalendar file, sorted by date.
+ (NSArray<NSString *> *)parse:(NSString *)ics {
  // Unfold: a line starting with a space continues the one before.
  ics = [[ics stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
      stringByReplacingOccurrencesOfString:@"\n " withString:@""];
  NSMutableArray *out = [NSMutableArray array];
  NSString *date = nil, *name = nil;
  for (NSString *line in [ics componentsSeparatedByString:@"\n"]) {
    if ([line hasPrefix:@"BEGIN:VEVENT"]) { date = nil; name = nil; }
    else if ([line hasPrefix:@"DTSTART"]) {
      NSString *v = [line componentsSeparatedByString:@":"].lastObject;
      if (v.length >= 8) date = [v substringToIndex:8];
    } else if ([line hasPrefix:@"SUMMARY:"]) {
      name = [line substringFromIndex:8];
      name = [name stringByReplacingOccurrencesOfString:@"\\," withString:@","];
      name = [name stringByReplacingOccurrencesOfString:@"\;" withString:@";"];
      name = [name stringByReplacingOccurrencesOfString:@" (tentative)" withString:@""];
    } else if ([line hasPrefix:@"END:VEVENT"] && date && name.length) {
      [out addObject:[NSString stringWithFormat:@"%@=%@", date, name]];
    }
  }
  [out sortUsingSelector:@selector(compare:)];
  return out;
}

+ (void)refresh:(void (^)(void))done {
  NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
  NSDate *at = [d objectForKey:kHolidaysAtKey];
  if ([at isKindOfClass:NSDate.class] && -at.timeIntervalSinceNow < 12 * 3600 && [d arrayForKey:kHolidaysKey].count) return;
  NSURL *url = [NSURL URLWithString:
      @"https://calendar.google.com/calendar/ical/en.mv%23holiday%40group.v.calendar.google.com/public/basic.ics"];
  NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
  cfg.timeoutIntervalForRequest = 20;
  NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];
  [[session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
    NSString *ics = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
    NSArray *list = [ics hasPrefix:@"BEGIN:VCALENDAR"] ? [self parse:ics] : nil;
    [session finishTasksAndInvalidate];
    if (!list.count) return;  // Offline: keep the last copy.
    dispatch_async(dispatch_get_main_queue(), ^{
      [d setObject:list forKey:kHolidaysKey];
      [d setObject:[NSDate date] forKey:kHolidaysAtKey];
      done();
    });
  }] resume];
}

+ (NSString *)lineFor:(NSDate *)now {
  NSArray *list = [NSUserDefaults.standardUserDefaults arrayForKey:kHolidaysKey];
  if (!list.count || !now) return nil;
  NSCalendar *cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
  NSDateFormatter *f = [NSDateFormatter new];
  f.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  f.calendar = cal;
  f.dateFormat = @"yyyyMMdd";
  NSString *today = [f stringFromDate:now];
  NSDate *day0 = [f dateFromString:today];
  for (NSString *entry in list) {
    if (![entry isKindOfClass:NSString.class] || entry.length < 10) continue;
    NSString *ymd = [entry substringToIndex:8];
    if ([ymd compare:today] == NSOrderedAscending) continue;
    NSDate *day = [f dateFromString:ymd];
    if (!day || !day0) return nil;
    NSInteger n = [cal components:NSCalendarUnitDay fromDate:day0 toDate:day options:0].day;
    if (n > kHolidayDays) return nil;
    NSString *when = n == 0 ? @"today" : n == 1 ? @"tomorrow" : [NSString stringWithFormat:@"in %ld days", (long)n];
    return [[NSString stringWithFormat:@"%@  ·  %@", [entry substringFromIndex:9], when] uppercaseString];
  }
  return nil;
}

@end
