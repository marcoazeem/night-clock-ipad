// The house's electricity estimate (port of lib/energy.dart): what's on,
// each device's typical draw, a baseline for everything unseen, added up
// per day and per billing period, and the bill worked out on STELCO's
// tariff. Past bills come from BILLS in lights.json (gitignored).

#import <Foundation/Foundation.h>

@class NCRoom;

@interface NCBill : NSObject
@property (nonatomic, strong) NSDate *date;
@property (nonatomic) NSInteger kwh, days;
@end

/// What a bill for [kwh] over [days] comes to, in MVR.
double NCBillMvr(double kwh, NSInteger days);

/// Polls every device in the house every 15 s (whatever's on screen) for
/// the home page's counts and the energy estimate; posts
/// NCEnergyUpdatedNotification on the main thread after each round.
@interface NCEnergyTracker : NSObject
- (instancetype)initWithRooms:(NSArray<NCRoom *> *)rooms;
- (void)start;
- (void)stop;
@property (nonatomic, readonly) NSArray<NCBill *> *bills;
/// -1 until the first round.
@property (nonatomic, readonly) NSInteger lightsOn, cooling, screensOn;
/// Watts now, by kind; total < 0 until the first round.
@property (nonatomic, readonly) double acWatts, lightWatts, screenWatts, otherWatts, totalWatts;
@property (nonatomic, readonly) double dayKwh, periodKwh;
@property (nonatomic, readonly) NSDate *periodStart, *periodEnd;
- (double)projectedKwh;
- (NSInteger)periodDays;
@end

extern NSString *const NCEnergyUpdatedNotification;
