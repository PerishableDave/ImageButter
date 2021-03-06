//
//  WebPImageManager.m
//  ImageButter
//
//  Created by Dalton Cherry on 9/1/15.
//

#import "WebPImageManager.h"
#import "WebPDecodeOperation.h"
#import <CommonCrypto/CommonHMAC.h>

static const NSInteger kDefaultCacheMaxCacheAge = 60 * 60 * 24; // 24 hours

typedef void (^WebPDataFinished)(NSData*);

#pragma mark - WebPNetworkImage

@interface WebPNetworkImage : NSObject

@property(nonatomic)NSMutableData *data;
@property(nonatomic,strong)WebPDataFinished finished;
@property(nonatomic,strong)WebPImageProgress progress;

@end


@implementation WebPNetworkImage

- (instancetype)initWithBlock:(WebPDataFinished)finish progress:(WebPImageProgress)progress {
    if (self = [super init]) {
        self.data = [[NSMutableData alloc] init];
        self.finished = finish;
        self.progress = progress;
    }
    return self;
}

@end

#pragma mark - WebPSessionHolder

@interface WebPSessionHolder : NSObject

@property(nonatomic)NSInteger sessionId;
@property(nonatomic,strong)WebPImageFinished finished;
@property(nonatomic,strong)WebPImageProgress progress;

@end


@implementation WebPSessionHolder

- (instancetype)initWithSession:(NSInteger)sessionId finished:(WebPImageFinished)finish
                       progress:(WebPImageProgress)progress {
    if (self = [super init]) {
        self.sessionId = sessionId;
        self.finished = finish;
        self.progress = progress;
    }
    return self;
}

@end

#pragma mark - WebPImageManager

@interface WebPImageManager ()<NSURLSessionDelegate>

//the in-memory cache
@property(nonatomic)NSCache *cache;

//shared network session
@property(nonatomic,strong)NSURLSession *mainSession;

//network session mapping
@property(nonatomic)NSMutableDictionary *networkDict;

//block mappings of running sessions
@property(nonatomic)NSMutableDictionary *sessions;

@property(nonatomic)NSOperationQueue *operationQueue;

@property(nonatomic)dispatch_queue_t dispatchQueue;

@end

@implementation WebPImageManager

+ (instancetype)sharedManager {
    static WebPImageManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[[self class] alloc] init];
    });
    return manager;
}

- (instancetype)init {
    if (self = [super init]) {
        self.cache = [[NSCache alloc] init];
        self.maxCacheAge = kDefaultCacheMaxCacheAge;
        self.mainSession = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration] delegate:self delegateQueue:nil];
        self.networkDict = [[NSMutableDictionary alloc] init];
        self.sessions = [[NSMutableDictionary alloc] init];
        self.operationQueue = [[NSOperationQueue alloc] init];
        self.operationQueue.maxConcurrentOperationCount = 2;
        self.dispatchQueue = dispatch_queue_create("com.dollarshaveclub.imagebutter.queue", DISPATCH_QUEUE_CONCURRENT);
        // Subscribe to memory warning, so we can clear the image cache on iOS
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(clearCache)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
        
    }
    return self;
}

- (NSInteger)imageForUrl:(NSURL*)url progress:(WebPImageProgress)progress finished:(WebPImageFinished)finished {
    
    if(!url) {
        return -1;
    }
    NSString *hash = [self hashForUrl:url];
    WebPImage *img = [self.cache objectForKey:hash];
    if (img) {
        if (finished) {
            finished(img);
        }
        return 0;
    }
    NSInteger sessionId = arc4random_uniform(10000) + 1;
    if ([self mapCheck:hash session:sessionId progress:progress finished:finished]) {
        return sessionId; //there is already request running for this image.
    }
    if ([url isFileURL]) {
        NSData *data = [NSData dataWithContentsOfURL:url];
        if (data.length > 0 && [WebPImage isValidImage:data]) {
            [self finishData:data hash:hash startProgress:0];
        } else {
            [self completeBlocks:nil hash:hash];
        }
        return sessionId;
    }
    [self dataFromCache:hash finished:^(NSData* data){
        if (data.length > 0) {
            [self finishData:data hash:hash startProgress:0];
        } else {
            [self dataFromNetwork:url progress:^(CGFloat pro) {
                NSArray *array = self.sessions[hash];
                for(WebPSessionHolder *holder in array) {
                    if (holder.progress) {
                        holder.progress(pro/2);
                    }
                }
            } finished:^(NSData *data) {
                if (data.length > 0 && [WebPImage isValidImage:data]) {
                    NSString *cachePath = [[self cacheDirectory] stringByAppendingPathComponent:hash];
                    [data writeToFile:cachePath atomically:NO];
                    [self finishData:data hash:hash startProgress:0.5];
                } else {
                    [self completeBlocks:nil hash:hash];
                }
            }];
        }
    }];
    return sessionId;
}

- (void)cancelImageForSession:(NSInteger)session url:(NSURL*)url {
    NSString *hash = [self hashForUrl:url];
    NSMutableArray *array = self.sessions[hash];
    for(WebPSessionHolder *holder in array) {
        if (holder.sessionId == session) {
            [array removeObject:holder];
            return;
        }
    }
}

- (WebPImage*)imageFromCache:(NSURL*)url {
    NSString *hash = [self hashForUrl:url];
    return [self.cache objectForKey:hash];
}

- (void)clearCache {
    [self.cache removeAllObjects];
}

- (void)clearUrlFromCache:(NSURL*)url {
    [self.cache removeObjectForKey:[self hashForUrl:url]];
}

- (void)cleanDisk {
    NSInteger age = -self.maxCacheAge;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT,0),^{
        NSFileManager *manager = [NSFileManager defaultManager];
        NSURL *diskCacheURL = [NSURL fileURLWithPath:[self cacheDirectory] isDirectory:YES];
        NSArray *resourceKeys = @[ NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey];
        
        // This enumerator prefetches useful properties for our cache files.
        NSDirectoryEnumerator *fileEnumerator = [manager enumeratorAtURL:diskCacheURL
                                              includingPropertiesForKeys:resourceKeys
                                                                 options:NSDirectoryEnumerationSkipsHiddenFiles
                                                            errorHandler:NULL];
        
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:age];
        for (NSURL *fileURL in fileEnumerator) {
            NSDictionary *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:NULL];
            
            // Skip directories.
            if ([resourceValues[NSURLIsDirectoryKey] boolValue])
                continue;
            
            NSDate *modifyDate = resourceValues[NSURLContentModificationDateKey];
            if ([[modifyDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [manager removeItemAtURL:fileURL error:NULL];
            }
        }
    });
}

- (BOOL)mapCheck:(NSString*)hash session:(NSInteger)sessionId
        progress:(WebPImageProgress)progress finished:(WebPImageFinished)finished {
    NSMutableArray *array = self.sessions[hash];
    BOOL isRunning = YES;
    if (!array) {
        isRunning = NO;
        array = [[NSMutableArray alloc] init];
        self.sessions[hash] = array;
    }
    WebPSessionHolder *holder = [[WebPSessionHolder alloc] initWithSession:sessionId
                                                                  finished:finished progress:progress];
    [array addObject:holder];
    return isRunning;
}

- (void)finishData:(NSData*)data hash:(NSString*)hash startProgress:(CGFloat)startProgress {
    CGFloat progressScale = 1/startProgress;
    if (startProgress <= 0) {
        progressScale = 1;
        startProgress = 0;
    }
    
    WebPDecodeOperationResult *result = [[WebPDecodeOperationResult alloc] init];
    WebPDecodeOperation *operation = [[WebPDecodeOperation alloc] initWithData:data result:result progress:^(CGFloat pro) {
        CGFloat overallProgress = startProgress + pro/progressScale;
        NSArray *array = self.sessions[hash];
        for(WebPSessionHolder *holder in array) {
            if (holder.progress) {
                holder.progress(overallProgress);
            }
        }
    }];
    
    operation.completionBlock = ^{
        [self.cache setObject:result.image forKey:hash];
        [self completeBlocks:result.image hash:hash];
    };
    
    [self.operationQueue addOperation:operation];
}

- (void)completeBlocks:(WebPImage*)img hash:(NSString*)hash {
    NSArray *array = self.sessions[hash];
    for(WebPSessionHolder *holder in array) {
        if (holder.finished) {
            holder.finished(img);
        }
    }
    [self.sessions removeObjectForKey:hash];
}

- (NSString*)hashForUrl:(NSURL*)url {
    NSString *value = url.absoluteString;
    // Strip trailing slashes
    if ([[value substringFromIndex:[value length]-1] isEqualToString:@"/"]) {
        value = [value substringToIndex:[value length]-1];
    }
    
    const char *cStr = [value UTF8String];
    unsigned char result[16];
    CC_MD5(cStr, (CC_LONG)strlen(cStr), result);
    return [NSString stringWithFormat:@"%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X%02X",
            result[0], result[1], result[2], result[3],result[4], result[5], result[6], result[7],result[8],
            result[9], result[10], result[11],result[12], result[13], result[14], result[15]];
}

- (NSString*)cacheDirectory {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    NSString* dataPath = [[paths objectAtIndex:0] stringByAppendingPathComponent:@"WebPImageCache"];
    
    if (![[NSFileManager defaultManager] fileExistsAtPath:dataPath]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dataPath
                                  withIntermediateDirectories:NO
                                                   attributes:nil
                                                        error:nil];
    }
    return dataPath;
}

- (void)dataFromCache:(NSString*)hash finished:(WebPDataFinished)finished {
    NSInteger age = -self.maxCacheAge;
    dispatch_async(self.dispatchQueue,^{
        NSString *cachePath = [[self cacheDirectory] stringByAppendingPathComponent:hash];
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:age];
        NSFileManager *manager = [NSFileManager defaultManager];
        if ([manager fileExistsAtPath:cachePath]) {
            NSDictionary *attributes = [manager attributesOfItemAtPath:cachePath error:NULL];
            NSDate *modifyDate = [attributes fileModificationDate];
            if ([[modifyDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [manager removeItemAtPath:cachePath error:NULL];
                finished(nil); //no data because it is over the max cache age
                return;
            } else {
                NSData *data = [manager contentsAtPath:cachePath];
                if (data) {
                    finished(data); //found it an image let the manager know
                    return;
                }
                
            }
        }
        
        finished(nil); //no data found on disk
    });
}

- (void)dataFromNetwork:(NSURL*)url progress:(WebPImageProgress)progress finished:(WebPDataFinished)finished {
    dispatch_barrier_async(self.dispatchQueue, ^{
        NSURLSessionDataTask *task = [self.mainSession dataTaskWithURL:url];
        self.networkDict[@(task.taskIdentifier)] = [[WebPNetworkImage alloc] initWithBlock:finished progress:progress];
        [task resume];
    });
}

#pragma mark - NSURLSession delegate methods

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    NSNumber *taskId = @(task.taskIdentifier);
    WebPNetworkImage *netImage = self.networkDict[taskId];
    if (netImage.finished) {
        netImage.finished(netImage.data);
    }
    
    dispatch_barrier_async(self.dispatchQueue, ^{
        [self.networkDict removeObjectForKey:taskId];
    });
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    dispatch_barrier_async(self.dispatchQueue, ^{
        WebPNetworkImage *netImage = self.networkDict[@(task.taskIdentifier)];
        [netImage.data appendData:data];
        if (task.response.expectedContentLength >= netImage.data.length) {
            CGFloat scale = 1/(CGFloat)task.response.expectedContentLength;
            netImage.progress(scale*netImage.data.length);
        }
    });
}

@end