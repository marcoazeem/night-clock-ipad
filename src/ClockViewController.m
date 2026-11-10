#import "NC.h"
#import "Panel.h"
#import "Energy.h"
#import "Lux.h"

// The dimmer runs in two stages, as on the phone: the top of the range
// walks the backlight down to its floor, the bottom fades the pixels.
static const CGFloat kPanelFloor = 0.4;
static const CGFloat kMinOpacity = 0.12;

@interface NCClockViewController () <UIGestureRecognizerDelegate>
@end

/// Tells its owner about every touch, before anything handles it — for the
/// walk back to this iPad's own room.
@interface NCTouchView : UIView
@property (nonatomic, copy) void (^onTouch)(void);
@end

@implementation NCTouchView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
  if (event.type == UIEventTypeTouches && self.onTouch) self.onTouch();
  return [super hitTest:point withEvent:event];
}
@end

/// Back to this iPad's own room after this long untouched.
static const NSTimeInterval kIdleReturn = 120;
/// Standby after this long untouched (the user asked, Nov 2026): the
/// picture's clip stops where it is and the backlight drops to
/// kStandbyBrightness — an LCD doesn't care about black, so it's the
/// backlight and the idle GPU that spare the battery. Everything stays
/// usable; the first touch brings it all back.
static const NSTimeInterval kStandbyAfter = 15;
static const CGFloat kStandbyBrightness = 0.12;
/// The backlight never goes above this (the user asked for ~40%, Nov 2026:
/// the iPad lives in a bedroom and the backlight is most of what it
/// draws); the press-and-hold dimmer still takes it lower.
static const CGFloat kMaxBrightness = 0.4;

@implementation NCClockViewController {
  NCEnergyTracker *_energy;  // the house-wide poll, always running
  NSArray<NCRoom *> *_rooms;
  NSMutableDictionary<NSNumber *, NCPanelView *> *_pages;  // built on first visit
  NCHomeView *_home;
  UIView<NCPanelPage> *_panel;  // the page on screen
  NSInteger _homeRoom, _room;   // _room -1: the home page
  NSInteger _tab;               // the room whose tab is lit (-1: HOME)
  NSTimer *_idle, *_standbyTimer;
  BOOL _standby;
  BOOL _active;
  NCTouchView *_content;  // everything, faded by the pixel stage of the dimmer
  NCTopBar *_top;
  NCTabBar *_tabs;
  NCFaceView *_face;
  NCSkyView *_sky;        // the picture in the clock column
  NCEnergyStrip *_strip;
  UIScrollView *_scroll;  // holds the page
  UILabel *_hint;
  UIView *_dimBadge;
  UILabel *_dimLabel;
  NCWeather *_weather;
  NSTimer *_tick, *_weatherTimer;
  CGFloat _dim, _dimFrom;
  BOOL _adjusting;
  CGFloat _systemBrightness;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.blackColor;

  _content = [[NCTouchView alloc] initWithFrame:self.view.bounds];
  __weak NCClockViewController *weakSelf = self;
  _content.onTouch = ^{ [weakSelf touched]; };
  _content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  _content.backgroundColor = UIColor.blackColor;
  [self.view addSubview:_content];

  _sky = [NCSkyView new];
  [_content addSubview:_sky];
  _face = [[NCFaceView alloc] initWithFrame:CGRectZero];
  [_content addSubview:_face];

  _rooms = NCConfiguredRooms();
  _energy = [[NCEnergyTracker alloc] initWithRooms:_rooms];
  _strip = [NCEnergyStrip new];
  _strip.energy = _energy;
  [_content addSubview:_strip];
  [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(energyUpdated)
                                             name:NCEnergyUpdatedNotification object:nil];

  _top = [NCTopBar new];
  _top.onScene = ^(BOOL gn) { [weakSelf runScene:gn]; };
  [_content addSubview:_top];

  _scroll = [UIScrollView new];
  _scroll.delaysContentTouches = NO;
  _scroll.showsVerticalScrollIndicator = NO;
  _scroll.showsHorizontalScrollIndicator = NO;
  _scroll.alwaysBounceVertical = NO;
  _scroll.backgroundColor = UIColor.clearColor;
  [_content addSubview:_scroll];

  if (_rooms.count > 1) {
    _tabs = [NCTabBar new];
    NSMutableArray *titles = [NSMutableArray arrayWithObject:@"Home"];
    for (NCRoom *r in _rooms) [titles addObject:r.name ?: @"Room"];
    _tabs.titles = titles;
    _tabs.onSelect = ^(NSInteger i) { [weakSelf selectTab:i]; };
    [_content addSubview:_tabs];
  }

  _pages = [NSMutableDictionary dictionary];
  _homeRoom = 0;
  NSString *start = [@START_ROOM stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  for (NSUInteger i = 0; i < _rooms.count; i++)
    if (_rooms[i].name && [_rooms[i].name caseInsensitiveCompare:start] == NSOrderedSame) _homeRoom = i;

  _hint = [UILabel new];
  _hint.attributedText = [[NSAttributedString alloc] initWithString:@"PRESS & HOLD, THEN SLIDE UP / DOWN TO DIM"
                                                         attributes:NCLuxLabel(9.5, 2.5, NCLuxMuted())];
  _hint.textAlignment = NSTextAlignmentCenter;
  _hint.userInteractionEnabled = NO;
  [_content addSubview:_hint];
  [self showRoom:_homeRoom];

  _dimBadge = [UIView new];
  _dimBadge.backgroundColor = UIColor.blackColor;
  _dimBadge.layer.cornerRadius = 22;
  _dimBadge.layer.borderWidth = 1;
  _dimBadge.layer.borderColor = NCRGBA(kLuxIvory, 0.2).CGColor;
  _dimBadge.hidden = YES;
  _dimLabel = [UILabel new];
  _dimLabel.textColor = NCRGB(kLuxIvory);
  _dimLabel.font = NCLuxFont(@"Jost-Light", 22);
  _dimLabel.textAlignment = NSTextAlignmentCenter;
  [_dimBadge addSubview:_dimLabel];
  [_content addSubview:_dimBadge];

  UILongPressGestureRecognizer *press =
      [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(onPress:)];
  press.minimumPressDuration = 0.4;
  press.delegate = self;
  [self.view addGestureRecognizer:press];

  NSNumber *saved = [[NSUserDefaults standardUserDefaults] objectForKey:@"dim"];
  _dim = saved ? MAX(0, MIN(1, saved.doubleValue)) : 0.55;
  _systemBrightness = UIScreen.mainScreen.brightness;

  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [UIView animateWithDuration:1 animations:^{ self->_hint.alpha = 0; }];
  });
}

- (BOOL)hasPanel { return _rooms.count > 1 || !_rooms.firstObject.isEmpty; }

/// A tab: 0 is HOME, then the rooms.
- (void)selectTab:(NSInteger)i {
  if (i == 0) [self showRoom:-1];
  else [self openRoom:i - 1];
}

/// Shows room [index], or the home page for -1.
- (void)showRoom:(NSInteger)index {
  if (![self hasPanel]) return;
  UIView<NCPanelPage> *page;
  if (index < 0) {
    if (!_home) {
      _home = [[NCHomeView alloc] initWithRooms:_rooms here:_homeRoom];
      _home.energy = _energy;
      __weak NCClockViewController *weak = self;
      _home.onOpen = ^(NSInteger i) { [weak openRoom:i]; };
    }
    _home.dim = NCIsDark([NSDate date]);
    page = _home;
  } else {
    page = _pages[@(index)];
    if (!page) {
      NCPanelView *p = [[NCPanelView alloc] initWithRoom:_rooms[index]];
      __weak NCClockViewController *weak = self;
      p.onSceneChange = ^{ [weak sceneChanged]; };
      _pages[@(index)] = p;
      page = p;
    }
  }
  _room = index;
  _tab = index;
  _strip.room = index;
  [self present:page title:index < 0 ? @"Home" : _rooms[index].name];
}

/// Swaps [page] into the right column, fading it in.
- (void)present:(UIView<NCPanelPage> *)page title:(NSString *)title {
  _top.title = title ?: @"";
  _tabs.active = _tab + 1;
  NCPanelView *room = [page isKindOfClass:NCPanelView.class] ? (NCPanelView *)page : nil;
  _top.showScenes = room.hasScenes;
  _top.running = room.running;
  if (page != _panel) {
    [_panel stopPolling];
    [_panel removeFromSuperview];
    _panel = page;
    _panel.night = NCIsNight([NSDate date]);
    _panel.standby = _standby;
    [_scroll addSubview:_panel];
    _scroll.contentOffset = CGPointZero;
    _panel.alpha = 0;
    [UIView animateWithDuration:0.25 animations:^{ self->_panel.alpha = 1; }];
    if (_active) [_panel startPolling];
  }
  [self.view setNeedsLayout];
  [self.view layoutIfNeeded];
}

- (void)runScene:(BOOL)gn {
  if ([_panel isKindOfClass:NCPanelView.class]) [(NCPanelView *)_panel runScene:gn];
}

- (void)sceneChanged {
  if ([_panel isKindOfClass:NCPanelView.class]) _top.running = ((NCPanelView *)_panel).running;
}

/// A room from a tab or the house: a locked room (ROOM_PINS) asks for its
/// passcode first, in the panel's place; this iPad's own room never does.
- (void)openRoom:(NSInteger)index {
  NCRoom *room = _rooms[index];
  if (!room.pin.length || index == _homeRoom) {
    [self showRoom:index];
    return;
  }
  NCPinView *pin = [[NCPinView alloc] initWithRoom:room];
  __weak NCClockViewController *weak = self;
  pin.onUnlock = ^{ [weak showRoom:index]; };
  _room = -1;  // still "on the home page" for the idle walk back
  _tab = index;
  _strip.room = -1;
  [self present:pin title:room.name];
}

/// Any touch restarts the count to standby (and ends it), and the walk
/// back to this iPad's own room.
- (void)touched {
  [_standbyTimer invalidate];
  _standbyTimer = [NSTimer scheduledTimerWithTimeInterval:kStandbyAfter target:self
                                                 selector:@selector(enterStandby) userInfo:nil repeats:NO];
  if (_standby) [self setStandby:NO];
  if (_rooms.count < 2) return;
  [_idle invalidate];
  _idle = [NSTimer scheduledTimerWithTimeInterval:kIdleReturn target:self
                                         selector:@selector(goHomeRoom) userInfo:nil repeats:NO];
}

- (void)goHomeRoom {
  if (_room != _homeRoom || _tab != _homeRoom) [self showRoom:_homeRoom];
}

- (void)enterStandby { [self setStandby:YES]; }

- (void)setStandby:(BOOL)on {
  if (on == _standby) return;
  _standby = on;
  _sky.standby = on;
  _face.standby = on;
  _panel.standby = on;
  [self applyDim];
}

/// The luxury layout (1024 × 768 on its side): the top bar; the clock
/// column (450 wide) with the time, the picture and the energy strip; the
/// controls column right of it, scrolling if it must; the tabs at the foot.
/// Standing, the clock column goes on top and the controls under it.
- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  CGSize size = self.view.bounds.size;
  CGFloat W = size.width, H = size.height, pad = 36;
  BOOL landscape = W > H;
  CGFloat tabsH = _tabs ? 60 : 24;
  _top.frame = CGRectMake(pad, 26, W - 2 * pad, 26);
  _tabs.frame = CGRectMake(0, H - 60, W, 60);
  CGFloat top = 52 + 26, bottom = H - tabsH;
  CGFloat faceH = [NCFaceView height], stripH = [NCEnergyStrip height];
  BOOL strip = _strip.room >= 0;
  _strip.hidden = !strip;
  CGRect scroll;
  if (landscape) {
    CGFloat colW = MIN(450, floor(W * 0.44));
    _face.frame = CGRectMake(pad, top, colW - pad, faceH);
    CGFloat picTop = top + faceH + 10, picBottom = strip ? bottom - stripH : bottom;
    _strip.frame = CGRectMake(pad, bottom - stripH, colW - pad, stripH);
    _sky.frame = CGRectMake(0, picTop, colW, MAX(0, picBottom - picTop));
    scroll = CGRectMake(colW + pad, top, W - pad - (colW + pad), bottom - top);
  } else {
    CGFloat fw = MIN(414, W - 2 * pad);
    _face.frame = CGRectMake((W - fw) / 2, top, fw, faceH);
    CGFloat picTop = top + faceH + 10, picH = 190;
    _sky.frame = CGRectMake(0, picTop, W, picH);
    CGFloat y = picTop + picH;
    if (strip) {
      _strip.frame = CGRectMake(pad, y, W - 2 * pad, stripH);
      y += stripH;
    }
    scroll = CGRectMake(pad, y + 26, W - 2 * pad, bottom - y - 26);
  }
  _scroll.frame = scroll;
  if (_panel) {
    CGFloat w = scroll.size.width, h = [_panel heightForWidth:w];
    _panel.frame = CGRectMake(0, 0, w, h);
    [_panel layoutForWidth:w];
    _scroll.contentSize = CGSizeMake(w, h);
    _scroll.alwaysBounceVertical = h > scroll.size.height;
  }
  _hint.frame = CGRectMake(0, 56, W, 18);
  _dimBadge.frame = CGRectMake(W / 2 - 70, MIN(W, H) * 0.08, 140, 44);
  _dimLabel.frame = _dimBadge.bounds;
}

// ── Lifecycle ────────────────────────────────────────────────────────────

- (void)appDidBecomeActive {
  [UIApplication sharedApplication].idleTimerDisabled = YES;
  _systemBrightness = UIScreen.mainScreen.brightness;
  [self refreshNow];
  [self scheduleTick];
  [self refreshWeather];
  [_weatherTimer invalidate];
  _weatherTimer = [NSTimer scheduledTimerWithTimeInterval:15 * 60 target:self
                                                 selector:@selector(refreshWeather) userInfo:nil repeats:YES];
  [_sky resume];
  _active = YES;
  [_panel startPolling];
  [_energy start];
  [self applyDim];
  [self touched];  // Coming back counts as a touch: full look, new count.
}

- (void)appWillResignActive {
  [_tick invalidate];
  [_weatherTimer invalidate];
  [_standbyTimer invalidate];
  [_sky pause];
  _active = NO;
  [_panel stopPolling];
  [_energy stop];
  // Give the iPad its own brightness back.
  UIScreen.mainScreen.brightness = _systemBrightness;
}

/// Redraw at the next minute boundary — once a minute.
- (void)scheduleTick {
  [_tick invalidate];
  NSDate *now = [NSDate date];
  NSTimeInterval t = now.timeIntervalSinceReferenceDate;
  NSTimeInterval wait = 60 - fmod(t, 60) + 0.05;
  _tick = [NSTimer scheduledTimerWithTimeInterval:wait target:self
                                         selector:@selector(onTick) userInfo:nil repeats:NO];
}

- (void)onTick {
  [self refreshNow];
  [self scheduleTick];
}

- (void)refreshNow {
  NSDate *now = [NSDate date];
  _face.now = now;
  BOOL night = NCIsNight(now);
  _panel.night = night;
  _top.night = night;
  _tabs.night = night;
  _strip.night = night;
  [_strip setNeedsDisplay];
  _home.dim = NCIsDark(now);
  [_sky updateForNow:now raining:_weather.raining];
}

- (void)energyUpdated { [_strip setNeedsDisplay]; }

- (void)refreshWeather {
  // Holidays ride along: fetched at most every 12 h.
  [NCHolidays refresh:^{ [self->_face setNeedsDisplay]; }];
  [NCWeather fetch:^(NCWeather *w) {
    if (!w) return;  // Offline: keep the last reading.
    self->_weather = w;
    self->_face.weather = w;
    [self->_sky updateForNow:[NSDate date] raining:w.raining];
  }];
}

// ── Dimmer ───────────────────────────────────────────────────────────────

/// Press-and-hold dims anywhere except on a colour bulb's tile, which
/// opens its colour temperature instead.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)touch {
  return ![_panel isDialAt:[touch locationInView:_panel]];
}

- (void)applyDim {
  CGFloat panel = _dim <= kPanelFloor ? 0 : (_dim - kPanelFloor) / (1 - kPanelFloor);
  CGFloat pixels = _dim >= kPanelFloor ? 1 : kMinOpacity + (_dim / kPanelFloor) * (1 - kMinOpacity);
  UIScreen.mainScreen.brightness = MIN(panel, _standby ? kStandbyBrightness : kMaxBrightness);
  _content.alpha = pixels;
}

- (void)onPress:(UILongPressGestureRecognizer *)g {
  static CGFloat startY;
  CGPoint p = [g locationInView:self.view];
  switch (g.state) {
    case UIGestureRecognizerStateBegan:
      _dimFrom = _dim;
      startY = p.y;
      _dimBadge.hidden = NO;
      break;
    case UIGestureRecognizerStateChanged:
      _dim = MAX(0, MIN(1, _dimFrom - (p.y - startY) / 400));
      [self applyDim];
      break;
    default:
      _dimBadge.hidden = YES;
      [[NSUserDefaults standardUserDefaults] setDouble:_dim forKey:@"dim"];
      return;
  }
  _dimLabel.text = [NSString stringWithFormat:@"%ld%%", lround(_dim * 100)];
}

@end
