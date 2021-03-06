//
//  iPhoneTrackingAppDelegate.m
//  iPhoneTracking
//
//  Created by Pete Warden on 4/15/11.
//

/***********************************************************************************
*
* All code (C) Pete Warden, 2011
*
*    This program is free software: you can redistribute it and/or modify
*    it under the terms of the GNU General Public License as published by
*    the Free Software Foundation, either version 3 of the License, or
*    (at your option) any later version.
*
*    This program is distributed in the hope that it will be useful,
*    but WITHOUT ANY WARRANTY; without even the implied warranty of
*    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
*
*    GNU General Public License for more details.
*
*    You should have received a copy of the GNU General Public License
*    along with this program.  If not, see <http://www.gnu.org/licenses/>.
*
************************************************************************************/

#import "iPhoneTrackingAppDelegate.h"
#import "fmdb/FMDatabase.h"
#import "parsembdb.h"

@interface iPhoneTrackingAppDelegate ()

-(NSString*) writeISO8601date:(NSDate*)date;
-(void)saveToGPX:(NSURL*)file;

@end

@implementation iPhoneTrackingAppDelegate

@synthesize window;
@synthesize webView;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
}

- displayErrorAndQuit:(NSString *)error
{
    [[NSAlert alertWithMessageText: @"Error"
      defaultButton:@"OK" alternateButton:nil otherButton:nil
      informativeTextWithFormat: error] runModal];
    exit(1);
}

- (void)awakeFromNib
{
  NSString* htmlString = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"index" ofType:@"html"]
      encoding:NSUTF8StringEncoding error:NULL];

 	[[webView mainFrame] loadHTMLString:htmlString baseURL:NULL];
  [webView setUIDelegate:self];
  [webView setFrameLoadDelegate:self]; 
  [webView setResourceLoadDelegate:self]; 
}

- (void)debugLog:(NSString *) message
{
  NSLog(@"%@", message);
}

+ (BOOL)isSelectorExcludedFromWebScript:(SEL)aSelector { return NO; }

- (void)webView:(WebView *)sender windowScriptObjectAvailable: (WebScriptObject *)windowScriptObject
{
  scriptObject = windowScriptObject;
}

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame
{
  [self loadLocationDB];
}

- (void)loadLocationDB
{
  NSString* backupPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/MobileSync/Backup/"];

  NSFileManager *fm = [NSFileManager defaultManager];
  NSError* error;
  NSArray* backupContents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:backupPath error:&error];

  NSMutableArray* fileInfoList = [NSMutableArray array];
  for (NSString *childName in backupContents) {
    NSString* childPath = [backupPath stringByAppendingPathComponent:childName];

    NSString *plistFile = [childPath   stringByAppendingPathComponent:@"Info.plist"];
      
    NSError* error;
    NSDictionary *childInfo = [fm attributesOfItemAtPath:childPath error:&error];

    NSDate* modificationDate = [childInfo objectForKey:@"NSFileModificationDate"];    

    NSDictionary* fileInfo = [NSDictionary dictionaryWithObjectsAndKeys: 
      childPath, @"fileName", 
      modificationDate, @"modificationDate", 
      plistFile, @"plistFile", 
      nil];
    [fileInfoList addObject: fileInfo];

  }
  
  NSSortDescriptor* sortDescriptor = [[[NSSortDescriptor alloc] initWithKey:@"modificationDate" ascending:NO] autorelease];
  [fileInfoList sortUsingDescriptors:[NSArray arrayWithObject:sortDescriptor]];

  BOOL loadWorked = NO;
  for (NSDictionary* fileInfo in fileInfoList) {
    @try {
      NSString* newestFolder = [fileInfo objectForKey:@"fileName"];
      NSString* plistFile = [fileInfo objectForKey:@"plistFile"];
      
      NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistFile];
      if (plist==nil) {
        NSLog(@"No plist file found at '%@'", plistFile);
        continue;
      }
      currentDeviceName = [[plist objectForKey:@"Device Name"] retain];
      NSLog(@"file = %@, device = %@", plistFile, currentDeviceName);  

      NSDictionary* mbdb = [ParseMBDB getFileListForPath: newestFolder];
      if (mbdb==nil) {
        NSLog(@"No MBDB file found at '%@'", newestFolder);
        continue;
      }

      NSString* wantedFileName = @"Library/Caches/locationd/consolidated.db";
      NSString* dbFileName = nil;
      for (NSNumber* offset in mbdb) {
        NSDictionary* fileInfo = [mbdb objectForKey:offset];
        NSString* fileName = [fileInfo objectForKey:@"filename"];
        if ([wantedFileName compare:fileName]==NSOrderedSame) {
          dbFileName = [fileInfo objectForKey:@"fileID"];
        }
      }

      if (dbFileName==nil) {
        NSLog(@"No consolidated.db file found in '%@'", newestFolder);
        continue;
      }

      locationFilePath = [[newestFolder stringByAppendingPathComponent:dbFileName] retain];

      loadWorked = [self tryToLoadLocationDB: locationFilePath forDevice:currentDeviceName];
      if (loadWorked) {
        break;
      }
    }
    @catch (NSException *exception) {
      NSLog(@"Exception: %@", [exception reason]);
    }
  }

  if (!loadWorked) {
    [self displayErrorAndQuit: [NSString stringWithFormat: @"Couldn't load consolidated.db file from '%@'", backupPath]];  
  }
}

- (BOOL)tryToLoadLocationDB:(NSString*) locationDBPath forDevice:(NSString*) deviceName withAction:(BOOL(^)(NSArray* points))action {
    [scriptObject setValue:self forKey:@"cocoaApp"];
    
    FMDatabase* database = [FMDatabase databaseWithPath: locationDBPath];
    [database setLogsErrors: YES];
    BOOL openWorked = [database open];
    if (!openWorked) {
        return NO;
    }
    
    NSMutableArray* points = [NSMutableArray arrayWithCapacity:5000];
    
    NSString* queries[] = {@"SELECT * FROM CellLocation ORDER BY timestamp;", @"SELECT * FROM WifiLocation ORDER BY timestamp;"};
    
    // Temporarily disabled WiFi location pulling, since it's so dodgy. Change to 
    for (int pass=0; pass<1; /*pass<2;*/ pass+=1) {
        
        FMResultSet* results = [database executeQuery:queries[pass]];
        
        while ([results next]) {
            NSDictionary* row = [results resultDict];
            
            NSNumber* latitude_number = [row objectForKey:@"latitude"];
            NSNumber* longitude_number = [row objectForKey:@"longitude"];
            NSNumber* timestamp_number = [row objectForKey:@"timestamp"];
            NSDate* timestamp_date = [NSDate dateWithTimeIntervalSince1970:[timestamp_number floatValue] + 31*365.25*24*60*60];
            
            // Don't bother with empty values
            if (([latitude_number floatValue]==0.0)&&([longitude_number floatValue]==0.0)) {
                continue;
            }

            [points addObject:[NSArray arrayWithObjects:latitude_number,longitude_number,timestamp_date, nil]];
        }
    }
    
    return action(points);
}

- (BOOL)tryToLoadLocationDB:(NSString*) locationDBPath forDevice:(NSString*) deviceName
{
    [self tryToLoadLocationDB:locationDBPath forDevice:deviceName withAction:^BOOL(NSArray *points) {
        // Put into buckets
        const float precision = 100;
        NSMutableDictionary* buckets = [NSMutableDictionary dictionary];
        for (NSArray* point in points) {
            const float latitude = [[point objectAtIndex:0] floatValue];
            const float longitude = [[point objectAtIndex:1] floatValue];
            const float unixTimestamp = [[point objectAtIndex:2] timeIntervalSince1970];
            
            
            const float weekInSeconds = (7*24*60*60);
            const float timeBucket = (floor(unixTimestamp/weekInSeconds)*weekInSeconds);
            
            NSDate* timeBucketDate = [NSDate dateWithTimeIntervalSince1970:timeBucket];
            
            NSString* timeBucketString = [timeBucketDate descriptionWithCalendarFormat:@"%Y-%m-%d" timeZone:nil locale:nil];
            
            const float latitude_index = (floor(latitude*precision)/precision);  
            const float longitude_index = (floor(longitude*precision)/precision);
            NSString* allKey = [NSString stringWithFormat:@"%f,%f,All Time", latitude_index, longitude_index];
            NSString* timeKey = [NSString stringWithFormat:@"%f,%f,%@", latitude_index, longitude_index, timeBucketString];
            
            [self incrementBuckets: buckets forKey: allKey];
            [self incrementBuckets: buckets forKey: timeKey];
        }
        
        // Process as before
        NSMutableArray* csvArray = [[[NSMutableArray alloc] init] autorelease];
        
        [csvArray addObject: @"lat,lon,value,time\n"];
        
        for (NSString* key in buckets) {
            NSNumber* count = [buckets objectForKey:key];
            
            NSArray* parts = [key componentsSeparatedByString:@","];
            NSString* latitude_string = [parts objectAtIndex:0];
            NSString* longitude_string = [parts objectAtIndex:1];
            NSString* time_string = [parts objectAtIndex:2];
            
            NSString* rowString = [NSString stringWithFormat:@"%@,%@,%@,%@\n", latitude_string, longitude_string, count, time_string];
            [csvArray addObject: rowString];
        }
        
        if ([csvArray count]<10) {
            return NO;
        }
        
        NSString* csvText = [csvArray componentsJoinedByString:@"\n"];
        
        id scriptResult = [scriptObject callWebScriptMethod: @"storeLocationData" withArguments:[NSArray arrayWithObjects:csvText,deviceName,nil]];
        if(![scriptResult isMemberOfClass:[WebUndefined class]]) {
            NSLog(@"scriptResult='%@'", scriptResult);
        }
        return YES;
    }];

   return YES;
}

- (void) incrementBuckets:(NSMutableDictionary*)buckets forKey:(NSString*)key
{
    NSNumber* existingValue = [buckets objectForKey:key];
    if (existingValue==nil) {
      existingValue = [NSNumber numberWithInteger:0];
    }
    NSNumber* newValue = [NSNumber numberWithInteger:([existingValue integerValue]+1)];

    [buckets setObject: newValue forKey: key];
}

-(NSString*) writeISO8601date:(NSDate*) date {
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    [df setDateStyle:NSDateFormatterFullStyle];
    [df setAMSymbol:@""];
    [df setPMSymbol:@""];
    [df setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss'Z'"];
    
    NSInteger offset = [[NSTimeZone systemTimeZone] secondsFromGMTForDate:date];
    NSDate* gmt = [date dateByAddingTimeInterval:-offset];
    
    NSString* out = [df stringFromDate:gmt];
    [df release];
    
    return out;
}

- (IBAction)exportGPX:(id)sender {
    NSSavePanel* savePanel = [NSSavePanel savePanel];
    [savePanel setAllowedFileTypes:[NSArray arrayWithObject:@"gpx"]];
    [savePanel beginSheetModalForWindow:self.window completionHandler:^(NSInteger button){
        switch (button) {
            case NSFileHandlingPanelOKButton:
                [self saveToGPX:[savePanel URL]];
                break;
            case NSFileHandlingPanelCancelButton:
                // Do nothing
                break;
        }
    }];
}

-(void)saveToGPX:(NSURL*)file {
    [self tryToLoadLocationDB:locationFilePath
                    forDevice:currentDeviceName
                   withAction:^BOOL(NSArray* points){
                       NSString *template = [NSString stringWithContentsOfFile:[[NSBundle mainBundle] pathForResource:@"GPX-Template"
                                                                                                               ofType:@"xml"]
                                                                      encoding:NSUTF8StringEncoding 
                                                                         error:NULL];
                       
                       NSString* trackpointTemplate = @"<trkpt lat=\"LATITUDE\" lon=\"LONGITUDE\"><time>TIMESTAMPT00:00:00Z</time></trkpt>\n";
                       NSMutableString* trackpoints = [[NSMutableString alloc] initWithCapacity:5000];
                       
                       NSDate* lastDate = nil;
                       for (NSArray* item in points) {
                           NSNumber* latitude = [item objectAtIndex:0];
                           NSNumber* longitude = [item objectAtIndex:1];
                           NSDate* timestamp = [item objectAtIndex:2];
                           
                           NSString* point = [trackpointTemplate stringByReplacingOccurrencesOfString:@"LATITUDE" withString:[latitude stringValue]];
                           point = [point stringByReplacingOccurrencesOfString:@"LONGITUDE" withString:[longitude stringValue]];
                           point = [point stringByReplacingOccurrencesOfString:@"TIMESTAMP" withString:[self writeISO8601date:timestamp]];
                           
                           // there seem to be lots of duplicate timestamps, so skip if we've seen the date before
                           if (! lastDate || ! [lastDate isEqualToDate:timestamp]) {
                               [trackpoints appendString:point];
                               lastDate = timestamp;
                           }
                       }
                       
                       template = [template stringByReplacingOccurrencesOfString:@"EXPORTNAME"
                                                                      withString:[NSString stringWithFormat:@"iPhoneTracking export of %@", currentDeviceName]];
                       template = [template stringByReplacingOccurrencesOfString:@"GENDATE"
                                                                      withString:[self writeISO8601date:[NSDate date]]];
                       template = [template stringByReplacingOccurrencesOfString:@"TRACKPOINTS"
                                                                      withString:trackpoints];
                       [template writeToURL:file
                                 atomically:NO
                                   encoding:NSUTF8StringEncoding
                                      error:NULL];
                       return YES;
                   }];
}

- (IBAction)openAboutPanel:(id)sender {
    
    NSImage *img = [NSImage imageNamed: @"Icon"];
    NSDictionary *options = [NSDictionary dictionaryWithObjectsAndKeys:
               @"1.0", @"Version",
               @"iPhone Tracking", @"ApplicationName",
               img, @"ApplicationIcon",
               @"Copyright 2011, Pete Warden and Alasdair Allan", @"Copyright",
               @"iPhone Tracking v1.0", @"ApplicationVersion",
               nil];
    
    [[NSApplication sharedApplication] orderFrontStandardAboutPanelWithOptions:options];
    
}
@end
