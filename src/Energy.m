#import "Energy.h"

#import "Config.h"
#import "Devices.h"
#import "Panel.h"
#import "TV.h"

NSString *const NCEnergyUpdatedNotification = @"NCEnergyUpdated";

@implementation NCBill
@end

// ── Tariff (STELCO domestic): 100-unit bands per 30 days, then the rest ──

double NCBillMvr(double kwh, NSInteger days) {
  static const double bands[] = {1.25, 1.50, 1.50, 1.50, 2.66, 3.20};
  double width = 100.0 * days / 30, left = kwh, total = 0;
  for (int i = 0; i < 6; i++) {
    double q = MIN(left, width);
    total += q * bands[i];
    left -= q;
  }
  total += MAX(0, left) * 3.83;
  return total - 0.12 * kwh + 150;  // fuel discount, WAMCO
}

static NSDate *day(NSInteger y, NSInteger m, NSInteger d) {
  NSDateComponents *c = [NSDateComponents new];
  c.year = y;
  c.month = m;
  c.day = d;
  return [NSCalendar.currentCalendar dateFromComponents:c];
}

// ── Draw ─────────────────────────────────────────────────────────────────

/// About 1.1 kW per 12,000 BTU cooling hard; an inverter works harder the
/// further the room is from the setpoint (~45% holding it).
static double acWatts(NSInteger btu, NCAcState *s) {
  if (!s.on) return 0;
  if (s.mode == 3) return 45;
  double rated = btu / 12000.0 * 1100;
  double off = s.roomTemp == NSNotFound ? 2 : (s.mode == 4 ? s.setTemp - s.roomTemp : s.roomTemp - s.setTemp);
  return rated * MAX(0.3, MIN(1.0, 0.45 + 0.11 * off));
}

@implementation NCRoomState

- (instancetype)init {
  if ((self = [super init])) _level = -1;
  return self;
}

- (BOOL)quiet { return !self.lightsOn && !self.cooling && !self.screensOn; }

- (NSString *)line {
  NSMutableArray *parts = [NSMutableArray array];
  if (self.lightsOn)
    [parts addObject:[NSString stringWithFormat:@"%ld light%@ on", (long)self.lightsOn, self.lightsOn == 1 ? @"" : @"s"]];
  if (self.cooling) [parts addObject:@"cooling"];
  if (self.screensOn)
    [parts addObject:self.screensOn == 1 ? @"TV on" : [NSString stringWithFormat:@"%ld TVs on", (long)self.screensOn]];
  return parts.count ? [parts componentsJoinedByString:@" · "] : nil;
}

@end

@implementation NCEnergyTracker {
  NSArray<NCRoom *> *_rooms;
  NSDictionary<NSString *, NSNumber *> *_btu;
  NSInteger _billDay;
  double _baseline;
  NSTimer *_timer;
  BOOL _polling;
  NSDate *_lastAt;
  double _lastWatts;
  NSString *_dayKey;
}

- (instancetype)initWithRooms:(NSArray<NCRoom *> *)rooms {
  if ((self = [super init])) {
    _rooms = rooms;
    _lightsOn = _cooling = _screensOn = -1;
    _totalWatts = -1;
    NSMutableArray *bills = [NSMutableArray array];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:
        @"(\\d{4})-(\\d\\d)-(\\d\\d)\\s*=\\s*(\\d+)\\s*/\\s*(\\d+)" options:0 error:nil];
    for (NSString *part in [@BILLS componentsSeparatedByString:@","]) {
      NSTextCheckingResult *m = [re firstMatchInString:part options:0 range:NSMakeRange(0, part.length)];
      if (!m) continue;
      NSInteger (^g)(int) = ^NSInteger(int i) { return [[part substringWithRange:[m rangeAtIndex:i]] integerValue]; };
      NCBill *b = [NCBill new];
      b.date = day(g(1), g(2), g(3));
      b.kwh = g(4);
      b.days = g(5);
      [bills addObject:b];
    }
    [bills sortUsingComparator:^NSComparisonResult(NCBill *a, NCBill *b) { return [a.date compare:b.date]; }];
    _bills = bills;
    NSMutableDictionary *btu = [NSMutableDictionary dictionary];
    for (NSArray *e in NCEntries(@AC_BTU)) btu[[e[0] lowercaseString]] = @([e[1] integerValue] ?: 12000);
    _btu = btu;
    _billDay = [@BILL_DAY integerValue] ?: 20;
    _baseline = [@ENERGY_BASELINE_W doubleValue] ?: 400;
    [self load];
  }
  return self;
}

// ── Saved state ─────────────────────────────────────────────────────────

- (void)load {
  NSDictionary *j = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"energy"];
  if (!j) return;
  _periodStart = j[@"periodStart"];
  _lastAt = j[@"lastAt"];
  _dayKey = j[@"dayKey"];
  _periodKwh = [j[@"periodKwh"] doubleValue];
  _dayKwh = [j[@"dayKwh"] doubleValue];
  _lastWatts = [j[@"lastWatts"] doubleValue];
}

- (void)save {
  if (!_periodStart || !_lastAt) return;
  [NSUserDefaults.standardUserDefaults setObject:@{
    @"periodStart": _periodStart, @"lastAt": _lastAt, @"dayKey": _dayKey ?: @"",
    @"periodKwh": @(_periodKwh), @"dayKwh": @(_dayKwh), @"lastWatts": @(_lastWatts),
  } forKey:@"energy"];
}

// ── Periods and pace ────────────────────────────────────────────────────

- (void)period:(NSDate *)now start:(NSDate **)start end:(NSDate **)end {
  NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:now];
  NSDate *s = day(c.year, c.month, _billDay);
  if ([s compare:now] == NSOrderedDescending) s = day(c.year, c.month - 1, _billDay);
  NSDateComponents *sc = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth fromDate:s];
  *start = s;
  *end = day(sc.year, sc.month + 1, _billDay);
}

- (NSDate *)periodEnd {
  NSDate *s, *e;
  [self period:[NSDate date] start:&s end:&e];
  return e;
}

- (NSInteger)periodDays {
  NSDate *s, *e;
  [self period:[NSDate date] start:&s end:&e];
  return lround([e timeIntervalSinceDate:s] / 86400);
}

/// kWh a day in the bill that covered the same dates a year ago, else the
/// average over all bills.
- (double)historicalPerDay:(NSDate *)at {
  if (!_bills.count) return 28;
  NSDate *lastYear = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitYear value:-1 toDate:at options:0];
  double kwh = 0, days = 0;
  for (NCBill *b in _bills) {
    NSDate *from = [b.date dateByAddingTimeInterval:-86400.0 * b.days];
    if ([lastYear compare:from] != NSOrderedAscending && [lastYear compare:b.date] != NSOrderedDescending)
      return (double)b.kwh / b.days;
    kwh += b.kwh;
    days += b.days;
  }
  return kwh / days;
}

- (double)projectedKwh {
  NSDate *now = [NSDate date], *s, *e;
  [self period:now start:&s end:&e];
  double days = [e timeIntervalSinceDate:s] / 86400, elapsed = MAX(0.25, [now timeIntervalSinceDate:s] / 86400);
  double w = MIN(1.0, elapsed / 7);
  double pace = w * (_periodKwh / elapsed) + (1 - w) * [self historicalPerDay:now];
  return _periodKwh + MAX(0, days - elapsed) * pace;
}

/// Adds the energy since the last round (a gap: the last draw for up to two
/// hours, then the baseline) and rolls days and periods over.
- (void)addAt:(NSDate *)now watts:(double)watts {
  NSDate *s, *e;
  [self period:now start:&s end:&e];
  if (!_periodStart || ![_periodStart isEqualToDate:s]) {
    BOOL first = _periodStart == nil;
    _periodStart = s;
    _periodKwh = first ? [now timeIntervalSinceDate:s] / 86400 * [self historicalPerDay:now] : 0;
  }
  if (_lastAt && [now compare:_lastAt] == NSOrderedDescending) {
    double secs = [now timeIntervalSinceDate:_lastAt], atLast = MIN(secs, 7200);
    double kwh = (_lastWatts * atLast + _baseline * (secs - atLast)) / 3.6e6;
    _periodKwh += kwh;
    _dayKwh += kwh;
  }
  NSDateComponents *c = [NSCalendar.currentCalendar components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay fromDate:now];
  NSString *key = [NSString stringWithFormat:@"%ld-%ld-%ld", (long)c.year, (long)c.month, (long)c.day];
  if (![key isEqualToString:_dayKey]) {
    _dayKey = key;
    _dayKwh = 0;
  }
  _lastAt = now;
  _lastWatts = watts;
  [self save];
}

// ── Polling ─────────────────────────────────────────────────────────────

- (void)start {
  [_timer invalidate];
  [self poll];
  _timer = [NSTimer scheduledTimerWithTimeInterval:15 target:self selector:@selector(poll) userInfo:nil repeats:YES];
}

- (void)stop {
  [_timer invalidate];
  _timer = nil;
}

/// Asks every device at once, each on its own queue; no answer is off.
- (void)poll {
  if (_polling) return;
  _polling = YES;
  NSMutableOrderedSet *lights = [NSMutableOrderedSet orderedSet], *acs = [NSMutableOrderedSet orderedSet];
  NSMutableOrderedSet *tvs = [NSMutableOrderedSet orderedSet], *boxes = [NSMutableOrderedSet orderedSet];
  for (NCRoom *r in _rooms) {
    [lights addObjectsFromArray:r.lights];
    [acs addObjectsFromArray:r.acs];
    [tvs addObjectsFromArray:r.tvs];
    [boxes addObjectsFromArray:r.boxes];
  }
  // Touched on the main queue only. What each device answered, by the
  // device itself, so the rooms can be tallied afterwards.
  __block NSInteger nl = 0, nc = 0, nt = 0, nb = 0;
  __block double acW = 0, lightW = 0;
  NSMapTable *lightLevel = [NSMapTable strongToStrongObjectsMapTable];  // light → level while on
  NSMapTable *cooling = [NSMapTable strongToStrongObjectsMapTable];     // AC → @YES while cooling
  NSMapTable *screenOn = [NSMapTable strongToStrongObjectsMapTable];    // TV or box → @YES while on
  dispatch_group_t g = dispatch_group_create();
  void (^main)(dispatch_block_t) = ^(dispatch_block_t b) {
    dispatch_async(dispatch_get_main_queue(), ^{
      b();
      dispatch_group_leave(g);
    });
  };
  for (NCLight *l in lights) {
    dispatch_group_enter(g);
    dispatch_async(l.queue, ^{
      BOOL on = NO;
      NSInteger level = -1;
      BOOL ok = [l readOn:&on brightness:&level] && on;
      main(^{
        if (!ok) return;
        nl++;
        lightW += MAX(1.5, 9.0 * (level >= 0 ? level : 100) / 100);
        [lightLevel setObject:@(level >= 0 ? level : 100) forKey:l];
      });
    });
  }
  for (NCGreeAc *a in acs) {
    dispatch_group_enter(g);
    dispatch_async(a.queue, ^{
      NCAcState *st = [a state];
      main(^{
        if (!st) return;
        if (st.on && st.mode <= 2) {  // cooling: cool, dry or auto
          nc++;
          [cooling setObject:@YES forKey:a];
        }
        acW += acWatts([self->_btu[a.name.lowercaseString] integerValue] ?: 12000, st);
      });
    });
  }
  for (NCHisenseTv *t in tvs) {
    dispatch_group_enter(g);
    dispatch_async(t.queue, ^{
      BOOL on = [t isOn];
      main(^{
        if (!on) return;
        nt++;
        [screenOn setObject:@YES forKey:t];
      });
    });
  }
  for (NCTvBox *b in boxes) {
    dispatch_group_enter(g);
    dispatch_async(b.queue, ^{
      BOOL on = NO;
      BOOL ok = [b readOn:&on] == NCBoxOk && on;
      main(^{
        if (!ok) return;
        nb++;
        [screenOn setObject:@YES forKey:b];
      });
    });
  }
  dispatch_group_notify(g, dispatch_get_main_queue(), ^{
    self->_polling = NO;
    self->_lightsOn = nl;
    self->_cooling = nc;
    self->_screensOn = nt + nb;
    NSMutableArray *states = [NSMutableArray array];
    for (NCRoom *r in self->_rooms) {
      NCRoomState *st = [NCRoomState new];
      for (NCLight *l in r.lights) {
        NSNumber *level = [lightLevel objectForKey:l];
        if (!level) continue;
        st.lightsOn++;
        st.level = MAX(st.level, level.integerValue);
      }
      for (NCGreeAc *a in r.acs) st.cooling += [cooling objectForKey:a] != nil;
      for (NCHisenseTv *t in r.tvs) st.screensOn += [screenOn objectForKey:t] != nil;
      for (NCTvBox *b in r.boxes) st.screensOn += [screenOn objectForKey:b] != nil;
      [states addObject:st];
    }
    self->_roomStates = states;
    self->_acWatts = acW;
    self->_lightWatts = lightW;
    self->_screenWatts = nt * 100.0 + nb * 12.0;
    self->_otherWatts = self->_baseline;
    self->_totalWatts = acW + lightW + self->_screenWatts + self->_baseline;
    [self addAt:[NSDate date] watts:self->_totalWatts];
    [NSNotificationCenter.defaultCenter postNotificationName:NCEnergyUpdatedNotification object:self];
  });
}

@end
