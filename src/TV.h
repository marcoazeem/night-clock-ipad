// The Hisense VIDAA TV (MQTT over TLS on 36669) and the Android TV box
// (network ADB on 5555) — ports of lib/tv.dart and lib/adb.dart. Calls
// BLOCK; run them on the device's queue.

#import <Foundation/Foundation.h>

@interface NCHisenseTv : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) dispatch_queue_t queue;
/// On = its remote broker is listening (it only runs while the TV is on).
- (BOOL)isOn;
/// On: Wake-on-LAN. Off: the power key.
- (BOOL)setPower:(BOOL)on;
/// One remote key, e.g. KEY_VOLUMEUP.
- (BOOL)sendKey:(NSString *)key;
@end

/// Why the box couldn't say whether it's on.
typedef NS_ENUM(NSInteger, NCBoxResult) { NCBoxOk, NCBoxNeedsApproval, NCBoxFailed };

@interface NCTvBox : NSObject
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, readonly) dispatch_queue_t queue;
@property (nonatomic, readonly) BOOL canWake;
/// Asleep, the box drops off the network: unreachable reads as off.
- (NCBoxResult)readOn:(BOOL *)on;
- (NCBoxResult)setPower:(BOOL)on;
/// One remote key over ADB, e.g. KEYCODE_VOLUME_UP.
- (NCBoxResult)sendKey:(NSString *)code;
@end

NSArray<NCHisenseTv *> *NCConfiguredTvs(void);
NSArray<NCTvBox *> *NCConfiguredBoxes(void);
