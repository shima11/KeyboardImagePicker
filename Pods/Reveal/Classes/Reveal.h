//
//  RevealSDK.h
//  RevealSDK
//
//  Created by Sean Doherty on 1/8/2015.
//  Copyright (c) 2015 StepLeader Digital. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreLocation/CoreLocation.h>
#import <UIKit/UIKit.h>

//! Project version number for Reveal9Plus.
FOUNDATION_EXPORT double RevealVersionNumber;

//! Project version string for Reveal9Plus.
FOUNDATION_EXPORT const unsigned char RevealVersionString[];

#ifndef INCLUDE_REVEAL_LOCATION_MANAGER
#define INCLUDE_REVEAL_LOCATION_MANAGER     1
#endif

#define USE_APPLE_SCAN

@class CLBeacon;
@class CLBeaconRegion;
@class CBPeripheral;
@class CLLocation;
@class RevealBluetoothObject;
@class RVLBeacon;
@class Reveal;
@class CurveFittedDistanceCalculator;
@class RVLGenericEvent;
@class RVLStatus;

#define RVL_IMMEDIATE_RADIUS                    3.0
#define RVL_NEAR_RADIUS                         15.0
#define RVL_FAR_RADIUS                          100.0
#define RVL_UNKNOWN_RADIUS                      99999999999.0

//TODO: decide if we need the <NSObject>... look at apple delegate examples
@protocol RVLBeaconDelegate <NSObject>
@optional
- (void) foundBeaconOfType:(NSString* _Nonnull) type identifier:(NSString* _Nonnull) identifier data:(NSDictionary* _Nullable) data;

@optional
- (void) leaveBeaconOfType:(NSString*  _Nonnull) type identifier:(NSString*  _Nonnull) identifier;

@optional
- (void) locationDidUpdatedTo:(CLLocation* _Nonnull) newLocation from: (CLLocation* _Nullable) oldLocation;
@end

@protocol RVLBeaconService <NSObject>

/**
 *  A delegate to receive callbacks when beacons are found
 */
@property (nonatomic, weak, nullable) id <RVLBeaconDelegate> delegate;

/**
 *  The time that you will wait before sending a beacon that is not "near"
 */
@property (nonatomic, assign) NSTimeInterval proximityTimeout;

- (NSDictionary * _Nonnull) beacons;

//TODO: finish refactoring to these interfaces
//- (void) startBeaconScanning:(NSArray *  _Nullable)targetBeacons;

//TODO: finish refactoring to these interfaces
- (void) stopBeaconScanning;

/**
 *  save all beacons to user defaults
 */
- (void)storeFoundBeacons;


@optional
- (void) processBeacon:(RVLBeacon* _Nonnull) beacon;

@optional
- (RevealBluetoothObject* _Nullable) blueToothObjectForKey: key;

/**
 Save a beacon that isn't ready to be sent yet

 @param beacon the beacon to send
 */
@optional   
- (void)saveIncompeteBeacon:(RVLBeacon* _Nonnull)beacon;

- (void) startScanner;
- (void)addBeacon:(NSString * _Nonnull) beaconID;

@end

@protocol RVLLocationService <NSObject>

/**
 *  The last known location for the current user
 */
@property (nonatomic, strong, nullable) CLLocation *userLocation;

/**
 *  The time the location time shuld be considered valid
 */
@property (nonatomic, assign) NSTimeInterval locationRetainTime;

/**
 block to be notified of location changes
 */
@property (nonatomic, copy, nullable) void (^locationUpdated)(CLLocation* _Nonnull newLocation, CLLocation* _Nullable oldLocation );

/**
 The requested change to trigger notification if not using signifigant change
 */
@property (nonatomic, assign) NSInteger distanceFilter;

/**
 Enable this to allow apple to manage the notifications
 */
@property (nonatomic, assign) BOOL useSignifigantChange;

/**
 Enable this to allow apple to manage the notifications
 */
@property (nonatomic, assign) BOOL useSignifigantChangeInBackground;

/**
 The desired location accuracy
 */
@property (nonatomic, assign) CLLocationAccuracy accuracy;

/**
 *  Start monitoring location services. If your bundle contains the
 *  NSLocationWhenInUseUsageDescription string then requestWhenInUseAuthorization
 *  will be called, otherwise if NSLocationAlwaysUsageDescription is provided
 *  then requestAlwaysAuthorization will be called. If neither string is present
 *  then location services will net be started.
 */
- (void) startLocationMonitoring;

/**
 *  stop monitoring location changes
 */
- (void) stopLocationMonitoring;

/**
 Setup location based on current state
 */
- (void) refreshLocationState;

/**
 *  Allows functions that need a valid location to wait for a valid location to be available (placemark if possible)
 *  If there is already a valid location available, then the callback returns immediately, otherwise, the callback waits until
 *  there is a valid location or a timeout, in which case the best location we can find will be used
 *
 *  @param callback The method to call when a valid location is available
 */
- (void) waitForValidLocation:( void (^ _Nullable)(void))  callback;

@end

/**
 *  Server selection
 */
typedef NS_ENUM(NSInteger, RVLServiceType) {
    /**
     *  Server for testing only
     */
    RVLServiceTypeSandbox,
    /**
     *  Server for real world use
     */
    RVLServiceTypeProduction
};

// The state of the event
typedef NS_ENUM(NSInteger, RVLState) {
    RVLStateOpen,           // item is still in range
    RVLStateClosed          // item is no longer visible
};

//  Location manager constants
typedef NS_ENUM(NSInteger, RVLLocationServiceType) {
    // Location disabled
    RVLLocationServiceTypeNone = 0,
    
    // While in use location detection selected
    RVLLocationServiceTypeInUse,
    
    //  Always location detection selected
    RVLLocationServiceTypeAlways
};

#pragma mark - Reveal Event -

typedef NS_ENUM(NSInteger, RVLEventType) {
    RVLEventTypeUnknown = 0,
    RVLEventTypeBeacon,
    RVLEventTypeEnter,
    RVLEventTypeDwell,
    RVLEventTypeExit,
    RVLEventTypeLocation,
    RVLEventTypeWiFiEnter,
    RVLEventTypeStart
};

typedef NS_ENUM(NSInteger, RVLDwellState ) {
    RVLDwellStateUnmanaged = 0,     // this event does not have a manager
    RVLDwellStateVisible,           // This event was visible in the last scan cycle
    RVLDwellStateLost,              // This event is no longer visible but has not been gone long enough to be complete
    RVLDwellStateComplete           // This event has been out of range long enough to report it as no longer visible
};

//@protocol RVLEvent <NSObject>
//
///**
// The type of event
// */
//@property (readonly) NSInteger eventType;
//
///**
// *  The time that the beacon was encountered
// */
//@property (nonatomic, strong, nullable)   NSDate   * discoveryTime;
//
///**
// *  unique id of an event
// */
//@optional
//@property (nonatomic, readonly, nonnull) NSString * rvlUniqString;
//
//@end

#pragma mark - Main Reveal object - 

@interface Reveal : NSObject

/**
 *  The server you wish to connect to, may be
 *  RVLServiceTypeProduction or RVLServiceTypeSandbox
 */
@property (assign,nonatomic) RVLServiceType serviceType;

/**
 *  Array of strings, each containing a UUID.  These UUIDs
 *  will override the list retrieved from the Reveal
 *  server.  This is useful to debug/verify that the SDK
 *  can detect a known iBeacon when testing.  This is a
 *  development feature and should not be used in production.
 *  In order to override the UUIDs from the server, this
 * property should be set before starting the service.
 */
@property (nonatomic, strong, nullable) NSArray <NSString*> *debugUUIDs;

/**
 *  Debug flag for the SDK.  If this value is YES, the SDK
 *  will log debugging information to the console.
 *  Default value is NO.
 *  This can be toggled during the lifetime of the SDK usage.
 */
@property (nonatomic, assign) BOOL debug;

/**
 *  An option to allow a developer to manually disable beacon scanning
 *  Default value is YES
 */
@property (nonatomic, assign) BOOL beaconScanningEnabled;

/**
 *  Accessor properties for the SDK.
 *  At any time, the client can access the list of errors
 *  and the list of personas.  Both are arrays of NSStrings.
 *  Values may be nil.
 */
@property (nonatomic, strong, nullable) NSArray <NSString*> *personas;

/**
 *  get the version of the SDK
 */
@property (nonatomic, strong, nonnull) NSString* version;

/**
 *  The location manager to use for retrieving the current location.
 */
@property (nonatomic, strong, nullable) id <RVLLocationService> locationManager;

/**
 *  The delegate is called whenever beacons are discovered or removed
 */
@property (nonatomic, weak, nullable) id <RVLBeaconDelegate> delegate;

/**
 *  The active beacon manager
 */
@property (nonatomic, strong, nullable) id <RVLBeaconService> beaconManager;

/**
 Send location events to the server
 */
@property (nonatomic, assign) BOOL sendLocationEvents;

@property (nonatomic, assign) BOOL sendAllEvents;

/**
 Send events while running in the background
 */
@property (nonatomic, assign) BOOL batchBackgroundSend;

/**
 Currently running in the background
 */
@property (nonatomic, assign) BOOL inBackground;

/**
 Time that the SDK started
 */
@property (nonatomic, strong, nullable) NSDate* startTime;


/**
 Ask the user for location permission at startup if none granted already
 */
@property (nonatomic, assign) BOOL canRequestLocationPermission;

@property (nonatomic, assign) NSTimeInterval incompleteBeaconSendTime;
@property (nonatomic, assign) NSInteger simulateMemoryWarning;

@property (readonly, nonnull) NSDictionary<NSString*, RVLStatus*>* statuses;

// intended for internal use only
@property (readonly, nullable) CurveFittedDistanceCalculator* distanceCalculator;
@property (nonatomic, assign) BOOL memoryWarningInprogress;
/**
 *  SDK singleton.  All SDK access should occur through this object.
 *
 *  @return the instance
 */
+ (Reveal* _Nonnull) sharedInstance;

/**
 *  Start the SDK with the specified SDK
 *
 *  @param key the API key
 *
 */
-(Reveal* _Nonnull) setupWithAPIKey:(NSString* _Nonnull) key;

/**
 *  Start the SDK with the specified SDK
 *
 *  @param key         the API key
 *  @param serviceType The type
 */
-(Reveal* _Nonnull) setupWithAPIKey:(NSString* _Nonnull) key andServiceType:(RVLServiceType) serviceType;

/**
 Method to be called when getting called via background fetch. You may pass 
 the call back provided by apple if you don't need to handle this event, or 
 you may create your own and use it to determine what to send back to the OS.

 @param completionHandler call back that will be called to indicate success
 */
- (void) backgroundFetchWithCompletionHandler:(void (^ _Nullable)(UIBackgroundFetchResult))completionHandler;

/**
 Update the base endpoint URL (only for specified installations, most installations 
 should never use this method and rely on the default
 
 @param apiEndpointBase the new base URL for the api endpoint
 */
- (void) updateAPIEndpointBase:(NSString * _Nonnull)apiEndpointBase;

/**
 Record a statistical event (currently only the count is retained) indicating 
 a successful operation

 @param eventName the event to be recorded
 */
- (void) recordSuccessEvent:(NSString * _Nonnull)eventName;

/**
 Record a statistical event (currently only the count is retained)
 
 @param eventName the event to be recorded
 @param success the event represents a success, false is a failure
 */
- (void) recordEvent:(NSString * _Nonnull)eventName success:(BOOL)success;

/**
 Record a statistical event (currently only the count is retained)
 
 @param eventName the event to be recorded
 @param success the event represents a success, false is a failure
 @param count the number of the events to record
 */
- (void) recordEvent:(NSString * _Nonnull)eventName success:(BOOL)success count:(NSInteger)count;

/**
 Get the statistical data recorded thus far in the form:
 
 [
    ["success":
        [
            [eventName : count],
            [eventName : count],
            ...
        ]
    ],
     ["failure":
         [
             [eventName : count],
             [eventName : count],
             ...
         ]
     ]
 ]

 @return a dictionary containing statistical dictionaries
 */
- (NSDictionary<NSString*,NSDictionary<NSString*, NSNumber*>*>* _Nonnull) statistics;

/**
 *  Start the SDK service.  The SDK will contact the API and retrieve
 *  further configuration info.  Background beacon scanning will begin
 *  and beacons will be logged via the API.
 */
-(void) start;

/**
 *   Notify the SDK that the app is restarting.  To be called in applicationDidBecomeActive
 */
-(void) restart;

- (void) memoryWarning;

- (void) stop;

/**
 *  list of beacons encountered for debugging only
 */
- (NSDictionary *  _Nullable) beacons;

/**
 *  list of bluetooth devices encountered for debugging if enabled
 */
- (NSDictionary *  _Nullable)devices;

/**
 *  The type of location service requested
 */
- (RVLLocationServiceType)locationServiceType;

/**
 *  Indicates whether the of beacons should be stopped when entering the 
 *  background, even if always is selected.
 */
- (BOOL) useManagedBackgroundMode;

/**
 Add a new event to the cache

 @param event the event to add
 */
- (void) addEvent:(RVLGenericEvent* _Nonnull) event;

// Bluetooth testing API should be treated as deprecated
@property (nonatomic) BOOL captureAllDevices;

// all discovered bluetooth devices (for debugging only)
@property (readonly, nullable) NSDictionary<NSString*, RevealBluetoothObject*>* bluetoothDevices;

// set the specified status
- (void) setStatus:(NSString* _Nonnull)name value:(NSInteger)value message:(NSString* _Nullable)message;

// set the specified status
- (void) setStatus:(RVLStatus* _Nonnull)status;

// get the specified status
- (RVLStatus* _Nullable) getStatus:(NSString* _Nonnull) name;

@end

#pragma mark - models -

#ifndef REVEAL_MODEL_DEFINED
#define REVEAL_MODEL_DEFINED

// known beacon verndor codes
#define BEACON_TYPE_GIMBAL              140
#define BEACON_TYPE_SWIRL               181

// extra beacon (Gimbal?)
#define BEACON_UNKNOWN_A                349

// known service types
#define BEACON_SERVICE_EDDYSTONE        0xfeaa
#define BEACON_SERVICE_EDDYSTONE_STRING @"FEAA"
#define BEACON_SERVICE_TILE_STRING      @"FEED"
#define BEACON_SERVICE_PEBBLEBEE_STRING @"8031"
#define BEACON_SERVICE_TRACKR_STRING    @"0F3E"
#define BEACON_SERVICE_IBEACON_STRING   @"180A"

#define BEACON_SERVICE_SECURECAST       0xfeeb
#define BEACON_SERVICE_UNKNOWN_A        0xfefd
#define BEACON_SERVICE_UNKNOWN_B        0x180f
#define BEACON_SERVICE_TILE             0xfeed
#define BEACON_SERVICE_ESTIMOTE         0x180a
#define BEACON_SERVICE_PEBBLEBEE        0x8031
#define BEACON_SERVICE_TRACKR           0x0f3e

#define RVLBeaconProximityUUID          @"proximityUUID"
#define RVLBeaconMajor                  @"major"            // iBeacon only
#define RVLBeaconMinor                  @"minor"            // iBeacon only
#define RVLBeaconProximity              @"proximity"
#define RVLBeaconProximityInteger       @"proximityInteger"
#define RVLBeaconAccuracy               @"accuracy"
#define RVLBeaconRSSI                   @"rssi"
#define RVLBeaconUniqString             @"identity"
#define RVLBeaconDiscoveryTime          @"discoveryTime"
#define RVLBeaconLastSeenTime           @"lastSeenTime"
#define RVLBeaconDwellTime              @"dwellTime"
#define RVLBeaconSentTime               @"sentTime"
#define RVLBeaconType                   @"type"
#define RVLBeaconPayload                @"payload"
#define RVLBeaconLocation               @"location"
#define RVLBeaconKey                    @"key"              // secure cast only
#define RVLBeaconLocal                  @"local"            // secure cast only
#define RVLBeaconAddress                @"address"
#define RVLBeaconNotes                  @"notes"
#define RVLManufacturer                 @"manufacturer"
#define RVLModel                        @"model"

@class RVLRawBeacon;
@class RevealPDU;

/**
 *
 */
@interface RevealBluetoothObject : NSObject

@property (nonatomic, strong, nullable) NSString* identifier;
@property (nonatomic, strong, nullable) CBPeripheral* peripheral;
@property (nonatomic, strong, nullable) NSDictionary* advertisement;
@property (nonatomic, strong, nullable) RVLRawBeacon* beacon;
@property (nonatomic, strong, nullable) NSDictionary* services;
@property (nonatomic, strong, nullable) NSDate* dateTime;
@property (nonatomic, strong, nullable) NSArray* uuids;
@property (nonatomic, assign) NSInteger count;
@property (nonatomic, strong, nullable) NSMutableDictionary* characteristics;
@property (nonatomic, strong, nullable) NSString* serviceUUID;
@property (nonatomic, strong, nullable) NSArray<RevealPDU*>* pdus;

@property (readonly) BOOL connectable;

@property (readonly, nullable) NSString* name;

+ (NSString*_Nullable) serviceName:(NSString* _Nullable)serviceName;
+ (NSString*_Nullable) data:(id _Nullable)data;

@end



#pragma mark - Dwell Manager -

/**
 The dwell manager will allow you to track the amount of time the device 
 (event) is in the seen by the user.
 
 The process will be pretty straight forward. Each time an event (device) is 
 encountered, it's lastSeen time will be updated. Periodically the list will be 
 traversed and any items that have not been seen for a period longer than the 
 lossDelay value for that type, the device will be reported via the readyToSend
 callback.
 
 This manager is designed to process all events, but any that do not require
 dwell time calculations to be performed may still be processed through the 
 dwell manager, but these event types (devices) may be set to a lossDelay of 0.0,
 and the callback will be called immediately (perhaps before the add has 
 returned), so make sure the calling code does not depend on the order of 
 operation.
 */
@interface RVLDwellManager : NSObject <NSCoding>

/**
 this callback is called when an event is ready to send to the server
 */
@property (nonatomic, copy, nullable) void (^readyToSend)(RVLGenericEvent* _Nonnull event);

/**
 The time the last manager was started
 */
@property (nonatomic, strong, nullable) NSDate* startupTime;

/**
 Get the shared default manager. You can usually use this class like a 
 singleton, unless you have some design need to maintain an independent pool

 @return The share instance
 */
+ (RVLDwellManager* _Nonnull) defaultManager;

/**
 Add an event and begin monitoring it for dwell times

 @param event The event to add
 
 @return true if the item was new fals if it was pre existing
 */
- (BOOL) addEvent:(RVLGenericEvent* _Nonnull)event;

/**
 Add a new event type to be managed by this manager.

 @param type The event type that represents this
 @param lossDelay The amount of time that will indicate a loss of the device
 */
- (void) addEventType:(RVLEventType)type withLossDelay:(NSTimeInterval)lossDelay;

/**
 Return a list of events matching the specified type that are currently 
 awaiting dwell time completion. This is primarily intended for debugging.

 @param type The type of events you are looking for
 
 @return an array of matching events
 */
- (NSArray<RVLGenericEvent*>* _Nullable) pendingEvents:(RVLEventType)type;

/**
 Look for events that have expired and may be returned to the delegate
 */
- (void) processPendingEvents;

- (NSArray<RVLGenericEvent*>* _Nullable) getOldEvents:(NSTimeInterval)olderThan;

/**
 Import new data from another dwell manager

 @param other the one to copy from
 */
- (void)import:(RVLDwellManager* _Nonnull)other;

/**
 Release all pending events as if they has expired
 */
- (void) releaseAll;

- (void) memoryWarning;
@end

@protocol JSONAble <NSObject>

@property (nullable, copy) NSDictionary<NSString*, id>* jsonDictionary;

@end

#pragma mark - Location -

@interface RVLCoordinate : NSObject <NSCoding, JSONAble>

- (_Nonnull id) initWithLocation:(CLLocation* _Nonnull)location;

@property (nonatomic, assign) double longitude;
@property (nonatomic, assign) double latitude;
@property (nonatomic, assign) NSInteger floor;
@property (nonatomic, assign) double speed;
@property (nonatomic, assign) double altitude;
@property (nonatomic, assign) double horizontalAccuracy;
@property (nonatomic, strong, nullable) NSDate* timestamp;

@end

#pragma mark - Generic event -

@interface RVLGenericEvent: NSObject <NSCoding, JSONAble>

/**
 The unique identifier for the device. This should be overridden by any subclasses to  
 */
@property (readonly, nonnull) NSString* identifier;

/**
 *  The time that the reveal server was notified of the location change
 */
@property (nonatomic, strong, nullable)   NSDate   *sentTime;

/**
 The type of event
 */
@property (readonly) RVLEventType eventType;

/**
 *  The time that the device was encountered
 */
@property (nonatomic, strong, nullable)   NSDate   * discoveryTime;

/**
 The time you last saw the device. Note that the time will be updated every 
 cycle that the device is detected, not a continuously updated timer so expect 
 the time to jump and even occasionially miss cycles
 */
@property (nonatomic, strong, nullable)   NSDate   * lastSeen;

@property (nonatomic, strong, nullable) NSDate* lastUpload;

@property (nonatomic, assign) NSInteger state;

/**
 The number of seconds that this device has been visible to the user. This will 
 be the same as lastSeen - discoveryTime. Note that the event will not be 
 reported until it the last seen time is well in the past, but the timeout will 
 NOT be included in the total.
 
 This value will be omitted if 0.0 when sending to the server.
 */
@property (readonly)   NSTimeInterval secondsVisible;

/**
 The manager that is handling the dwell state for this object
 */
@property (nonatomic, weak, nullable)     RVLDwellManager* currentDwellManager;

/**
 The current state of this object
 */
@property (readonly)                      RVLDwellState dwellState;

/**
 The location at the time the event occured
 */
@property (nonatomic, strong, nullable)   RVLCoordinate* location;


/**
 Notes about beacon discovory for use in debugging
 */
@property (nonatomic, strong, nullable)   NSString* notes;

+ (NSString* _Nonnull) eventType:(RVLEventType)type;

@end

#pragma mark - Startup event

@interface RVLStartupEvent : RVLGenericEvent

@end

#pragma mark - Reveal location -

@interface RVLLocationEvent : RVLGenericEvent

@end

#pragma mark - Reveal Beacon -

@interface RVLBeacon : RVLGenericEvent <NSCoding>

/**
 *  This is the identifying element for a group of iBeacons. Typically
 *  it identifies a group of beacons by a particular user. You then use
 *  the major and minor to identify a particular beacon
 */
@property (nonatomic, strong)   NSUUID   * _Nullable proximityUUID;

/**
 *  Used by iBeacons as an identifying element
 */
@property (nonatomic, strong)   NSString * _Nullable major;

/**
 *  Used by iBeacons as an identifying element
 */
@property (nonatomic, strong)   NSString * _Nullable minor;

/**
 *  Provides an estimation of how close you are to this beacon
 */
@property (readonly, nonnull)     NSString * proximity;

/**
 *  Provides an estimation of how close you are to this beacon as a 
 *  numeric enumeration
 */
@property (nonatomic, assign) NSInteger proximityInteger;

/**
 *  Provides an indication of how accurate the measurement is
 */
@property (nonatomic, strong)   NSNumber * _Nullable accuracy;

/**
 *  Signal strength
 */
@property (nonatomic, strong)   NSNumber * _Nullable rssi;

/**
 *  The type of beacon
 */
@property (readonly, nonnull)            NSString* type;

/**
 *  Indicates if the raw beacon was successfully encoded
 */
@property (readonly)            BOOL decoded;

/**
 A description of the devices payload
 
 @note Some beacons with payloads will return an empty string, this will only
 be present if the data can be decoded into descreete fields.
 */
@property (readonly, nonnull) NSString* decodedPayload;

/**
 *  The proximity represented as an numeric representation
 */
@property (readonly) double proximityInMeters;

/**
 Bluetooth information
 */
@property (nonatomic, strong, nullable) RevealBluetoothObject* bluetooth;

/**
 *  Build a unique string to identify this beacon
 *
 *  @param beacon the beacon you want to represent
 *
 *  @return string identifying this beacon
 */
+ (NSString* _Nonnull)rvlUniqStringWithBeacon:(RVLBeacon* _Nonnull) beacon;

- (instancetype _Nonnull) initWithBeacon:(CLBeacon * _Nonnull )beacon;
- (instancetype _Nonnull) initWithBeaconRegion:(CLBeaconRegion * _Nonnull)beaconRegion;
- (instancetype _Nonnull) initWithRawBeacon:(RVLRawBeacon * _Nonnull)beacon;

/**
 See if the beacon is ready to send now

 @return YES if the beacon is ready to go, NO if not
 */
- (BOOL) readyToSend;

/**
 Send the beacon to the server if it is ready, otherwise queue it to be sent 
 at a later time so we can wait for better accuracy or for a location to be 
 retrieved.

 @return true if the beacon was sent now, false if queued for later
 */
- (BOOL) saveWhenReady;


/**
 Determine if the time to wait for closer proximity has expired

 @return true if expired - false otherwise
 */
- (BOOL) timeoutWaitingToSend;

/**
 Combine the data from the new beacon with this one

 @param beacon The new beacon

 @return true if the new location is closer
 */
- (BOOL) combineWith:(RVLBeacon* _Nonnull)beacon;

/**
 Recalculate the distance from the beacon
 
 @note this is exposed for testing and will be removed from future versions 
       so don't rely on it.
 */
- (void) calculateDistance;

- (NSString * _Nonnull)descriptionDetails;

@end

#pragma mark - Raw beacon -

/**
 *  The raw beacon scanner builds this information about a given beacon.
 *
 *  NOTE: The items that are not documented may be temporary and should
 *        not be relied upon
 */
@interface RVLRawBeacon : RVLBeacon <NSCoding>

/**
 *  The name of the vendor if known
 */
@property (nonatomic, strong, nullable) NSString* vendorName;

/**
 *  The numeric code representing the vendor if known
 */
@property (nonatomic, assign) NSInteger vendorCode;
@property (nonatomic, assign) NSInteger key;

/**
 *  identifier for secure cast beacons
 */
@property (nonatomic, assign) NSInteger local;

/**
 *  The data for the beacon - this is usually the entire data packet
 *  in un-decoded form
 */
@property (nonatomic, strong, nullable) NSData* payload;

/**
 The bluetooth advertisement data
 */
@property (nonatomic, strong, nullable) NSDictionary* advertisement;

/**
 The bluetooth UUIDS
 */
@property (nonatomic, strong, nullable) NSArray* uuids;

/**
 The beacon payload information as a bas64 string, or nil if not available
 */
@property (readonly, nullable) NSString* payloadString;

/**
 The bluetooth identifier assigned by the the OS (This should not be used as a
 beacon ID because it is essentially a random number assigned when the device 
 is encountered, so will be different on each phone that sees it.
 */
@property (nonatomic, strong, nullable) NSUUID* bluetoothIdentifier;

/**
 the service UUIDs for the bluetooth services available
 */
@property (nonatomic, strong, nullable) NSMutableDictionary* services;

/**
 The bluetooth characteristics
 */
@property (nonatomic, strong, nullable) NSDictionary <NSString*, NSData*>* characteristics;

/**
 The extended data for a beacon, currenly only used by eddystone
 */
@property (nonatomic, strong, nullable) NSMutableDictionary* extendedData;
@property (readonly) NSTimeInterval age;

/**
 *  The URL associated with the beacon. Currently only useful
 *  with eddystone beacons.
 */
@property (nonatomic, strong, nullable) NSURL* url;

/**
 *  Indicates that the beacon has been completely received. This
 *  is used in multi part beacons to prevent a partial beacon
 *  from being reported. Currently only useful with eddystone
 *  beacons.
 */
@property (nonatomic, assign) BOOL complete;
@property (nonatomic, strong, nullable) NSString* vendorId;
@property (nonatomic, strong, nullable) NSMutableArray<RevealPDU*>* pdus;

- (NSString* _Nullable)ident:(NSInteger)index;

@end

#pragma mark - Eddystone object -

@interface RVLEddyStoneBeacon : RVLRawBeacon

@end

#pragma mark - Tile object -

@interface RVLTileBeacon : RVLRawBeacon

@end

#pragma mark - Pebblebee object -

@interface RVLPebblebeeBeacon : RVLRawBeacon

@end

#pragma mark - Surecast object -

@interface RVLSecurecastBeacon : RVLRawBeacon

@end

#pragma mark - TrackR object -

@interface RVLTrackRBeacon : RVLRawBeacon

@end

#endif

/**
 *  The Web Services class provides the interface to send beacon data to the Reveal server
 */
@interface RVLWebServices : NSObject

/**
 *  The API Key
 */
@property (nonatomic, strong, nullable) NSString* apiKey;

/**
 *  The URL for the server to send information to
 */
@property (nonatomic, strong, nullable) NSString* apiUrl;

/**
 *  provide a routine to perform logging functionality
 */
@property (nonatomic, assign, nullable) void (*log)( NSString* _Nonnull type, NSString * _Nonnull format, ...);

/**
 *  provide a routine to perform logging functionality, these logs will
 *  only be included if the verbose setting is selected.
 */
@property (nonatomic, assign, nullable) void (*logVerbose)( NSString* _Nonnull type, NSString * _Nonnull format, ...);

/**
 *  The git hash for the current build
 */
@property (nonatomic, strong, nullable) NSString* build;

/**
 *  Get the Web Service manager to communicate with the Reveal server
 *
 *  @return the shared instance of the Web Services class
 */
+ (RVLWebServices* _Nonnull) sharedWebServices;

/**
 *  register the device with reveal, sending the device information. it
 *  returns a dictionary containing scan durations as wells as persona's
 *  to update the client settings from.
 *
 *  Keys:
 *
 *      cache_ttl - time to keep location entries in the cache to prevent
 *                  duplication
 *      scan_interval - time to wait between scans
 *      scan_length - duration to scan for beacons on each pass
 *      discovery_enabled - beacon scanning is requested, if false the client
 *                   should not scan
 *      beacons - list of beacons to scan for
 *
 *  @param result callback to receive the response from the server
 */
- (void) registerDeviceWithResult:(void (^ _Nonnull)(BOOL success, NSDictionary* _Nullable result, NSError* _Nullable error))result;

- (void) sendInfo:(NSDictionary* _Nonnull)jsonableDictionary
           result:(void (^ _Nullable)(BOOL success, NSDictionary*  _Nonnull result, NSError*  _Nonnull error))result;


/**
 Send a batch of events to the server.

 @param events The list of events to send
 @param complete call back doe when the operation has been completed
 */
- (void)sendEvents:(NSArray<RVLGenericEvent*> * _Nonnull)events
            result:(void (^ _Nullable)(BOOL success, NSDictionary * _Nullable result, NSError * _Nullable error))complete;

/**
 *  Get the current IP address
 *
 *  @param preferIPv4 I want the old style
 *
 *  @return the best IP address available
 */
- (NSString * _Nullable)getIPAddress:(BOOL)preferIPv4;

/**
 *  Get all IP addresses
 *
 *  @return array of IP Addresses
 */
- (NSDictionary * _Nullable)getIPAddresses;

/**
 *  The version of the SDK
 */
- (NSString* _Nonnull) version;

/**
 Determine if we currently are connected via a wifi connection

 @return true if wifi, false otherwise
 */
- (BOOL)isWiFi;

- (NSString * _Nullable) baseUrl;

@end

@interface CurveFittedDistanceCalculator : NSObject

@property (nonatomic, assign) double mCoefficient1;
@property (nonatomic, assign) double mCoefficient2;
@property (nonatomic, assign) double mCoefficient3;
@property (nonatomic, assign) double scale;
@property (nonatomic, assign) int txPower;

- (double) calculateDistanceWithPower:(int)txPower andRSSI: (double) rssi;
- (double) calculateDistanceWithRSSI: (double) rssi;

@end

void RVLLog(NSString * _Nonnull format, ...) NS_FORMAT_FUNCTION(1,2);
void RVLLogWithType(NSString* _Nonnull type, NSString * _Nonnull format, ...) NS_FORMAT_FUNCTION(2,3);
void RVLLogVerbose(NSString* _Nonnull type, NSString * _Nonnull format, ...) NS_FORMAT_FUNCTION(2,3);

@interface RVLDebugLog : NSObject

/**
 *  Enable debugs
 */
@property (nonatomic, assign) BOOL enabled;

/**
 *  Include verbose logs
 */
@property (nonatomic, assign) BOOL verbose;

/**
 *  Enable the use of color in the logs - Requires the installation of
 *  XCodeColors: https://github.com/robbiehanson/XcodeColors
 *
 *  Available via Alcatraz http://alcatraz.io/
 */
@property (nonatomic, assign) BOOL useColor;

@property (nonatomic, copy, nullable) void (^logMirror)( NSString* _Nonnull type, NSString* _Nonnull message, UIColor* _Nonnull color );

+ (instancetype _Nonnull)sharedLog;

/**
 *  Log the specified string as type "DEBUG"
 *
 *  @param aString the string to log
 */
- (void) log:(NSString *  _Nonnull)aString;

/**
 *  Log the specified string to the console
 *
 *  @param aString the string to log
 *  @param type    the type of log
 */
- (void) log:(NSString *  _Nonnull)aString ofType:(NSString* _Nonnull)type;

/**
 *  Log the specified string only if verbose logging is enabled
 *
 *  @param aString the string to log
 *  @param type    the type of log
 */
- (void) logVerbose:(NSString * _Nonnull)aString ofType:(NSString* _Nonnull)type;

@end

@interface NSDictionary (DebugTools)

- (void) iterate:(NSString* _Nonnull)path withBlock:(void (^_Nonnull)(NSString* _Nonnull keyPath, id _Nonnull key, id _Nonnull data))callback;

@end

@interface NSArray (DebugTools)

- (void) iterate:(NSString* _Nonnull)path withBlock:(void (^_Nonnull)(NSString* _Nonnull keyPath, id _Nonnull key, id _Nonnull data))callback;

@end

#pragma mark - Status -

@interface RVLStatus : NSObject

@property (nonatomic, strong, nullable) NSString* name;
@property (nonatomic, assign) NSInteger value;
@property (nonatomic, strong, nullable) NSString* message;
@property (nonatomic, strong, nullable) NSArray* list;
@property (nonatomic, strong, nullable) NSDate* time;

- (id _Nonnull ) init: (NSString*_Nonnull)name;
- (id _Nonnull ) init: (NSString*_Nonnull)name
                value:(NSInteger)value;

// set a new state
- (void) updateValue:(NSInteger)value
             message:(NSString* _Nullable)message;

@end

#define REVEAL_PDU_TYPE_FLAGS                           0x01
#define REVEAL_PDU_TYPE_UUID16_INCOMPLETE               0x02
#define REVEAL_PDU_TYPE_UUID16                          0x03
#define REVEAL_PDU_TYPE_UUID32_INCOMPLETE               0x06
#define REVEAL_PDU_TYPE_UUID128                         0x07
#define REVEAL_PDU_TYPE_SHORT_NAME                      0x08
#define REVEAL_PDU_TYPE_COMPLETE_NAME                   0x09
#define REVEAL_PDU_TYPE_TX_POWER                        0x0a
#define REVEAL_PDU_TYPE_SERVICE_DATA                    0x16
#define REVEAL_PDU_TYPE_MANUFACTURER_SPECIFIC_DATA      0xff

#define STATUS_BLUETOOTH                                @"Bluetooth"
#define STATUS_NETWORK                                  @"Network"
#define STATUS_WEB                                      @"Web"
#define STATUS_LOCATION                                 @"Location"
#define STATUS_SCAN                                     @"scan"

#define STATUS_FAILED                                   0
#define STATUS_SUCCEED                                  1
#define STATUS_INPROGRESS                               2

#define STATUS_UPDATED_NOTIFICATION                     @"STATUS_UPDATED_NOTIFICATION"

@interface RevealPDU : NSObject

@property (assign) NSInteger type;
@property (assign) NSInteger length;
@property (strong, nonatomic, nullable) NSData* data;

- (instancetype _Nonnull) init;
- (instancetype _Nonnull) initWith:(id _Nonnull )data ofType:(NSInteger) type;

+ (NSArray<RevealPDU*>* _Nonnull) PDUList:(NSData* _Nonnull)data;
+ (NSArray<RevealPDU*>* _Nonnull) PDUListFromServiceData:(NSDictionary * _Nonnull)services;
+ (NSArray<RevealPDU*>* _Nonnull) PDUListFromAdvertisingData:(NSDictionary * _Nonnull)advertisement;
+ (NSArray<RevealPDU*>* _Nonnull) PDUListFromServiceData:(NSDictionary * _Nonnull)services andDavertisingData:(NSDictionary * _Nonnull)advertisement;

- (NSString* _Nonnull) typeName;
- (NSString* _Nonnull) manufacturerName:(NSInteger)index;

- (int) int8at:(NSInteger) index;
- (int) int16at:(NSInteger) index;
- (int) int16Flippedat:(NSInteger) index;

- (NSData* _Nonnull) dataAt:(NSInteger)start length:(NSInteger)length;

- (NSString* _Nonnull) string;
- (NSString* _Nonnull) stringAt:(NSInteger)start;
- (NSString* _Nonnull) stringAt:(NSInteger)start length:(NSInteger)length;

- (NSString* _Nonnull) hex;
- (NSString* _Nonnull) hexAt:(NSInteger)start;
- (NSString* _Nonnull) hexAt:(NSInteger)start length:(NSInteger)length;


- (NSNumber* _Nonnull)objectAtIndexedSubscript:(NSInteger)idx;

@end
