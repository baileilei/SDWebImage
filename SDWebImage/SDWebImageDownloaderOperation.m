/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloaderOperation.h"
#import "SDWebImageManager.h"
#import "NSImage+WebCache.h"
#import "SDWebImageCodersManager.h"

#define LOCK(lock) dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define UNLOCK(lock) dispatch_semaphore_signal(lock);

// iOS 8 Foundation.framework extern these symbol but the define is in CFNetwork.framework. We just fix this without import CFNetwork.framework
#if (__IPHONE_OS_VERSION_MIN_REQUIRED && __IPHONE_OS_VERSION_MIN_REQUIRED < __IPHONE_9_0)
const float NSURLSessionTaskPriorityHigh = 0.75;
const float NSURLSessionTaskPriorityDefault = 0.5;
const float NSURLSessionTaskPriorityLow = 0.25;
#endif

NSString *const SDWebImageDownloadStartNotification = @"SDWebImageDownloadStartNotification";
NSString *const SDWebImageDownloadReceiveResponseNotification = @"SDWebImageDownloadReceiveResponseNotification";
NSString *const SDWebImageDownloadStopNotification = @"SDWebImageDownloadStopNotification";
NSString *const SDWebImageDownloadFinishNotification = @"SDWebImageDownloadFinishNotification";

//进度回调块和下载完成回调块的字符串类型的key
static NSString *const kProgressCallbackKey = @"progress";
static NSString *const kCompletedCallbackKey = @"completed";

//定义了一个可变字典类型的回调块集合，这个字典key的取值就是上面两个字符串
typedef NSMutableDictionary<NSString *, id> SDCallbacksDictionary;
//上述先定义了一些全局变量和数据类型。🔼
@interface SDWebImageDownloaderOperation ()
/*
 回调块数组，数组内的元素即为前面自定义的数据类型
 通过名称不难猜测，上述自定义字典的value就是回调块了
 */
@property (strong, nonatomic, nonnull) NSMutableArray<SDCallbacksDictionary *> *callbackBlocks;

/*
 继承NSOperation需要定义executing和finished属性
 并实现getter和setter，手动触发KVO通知
 */
@property (assign, nonatomic, getter = isExecuting) BOOL executing;
@property (assign, nonatomic, getter = isFinished) BOOL finished;
//可变NSData数据，存储下载的图片数据
@property (strong, nonatomic, nullable) NSMutableData *imageData;
//缓存的图片数据
@property (copy, nonatomic, nullable) NSData *cachedData; // for `SDWebImageDownloaderIgnoreCachedResponse`

// This is weak because it is injected by whoever manages this session. If this gets nil-ed out, we won't be able to run
// the task associated with this operation
//这里是weak修饰的NSURLSession属性
//作者解释到unownedSession有可能不可用，因为这个session是外面传进来的，由其他类负责管理这个session，本类不负责管理
//这个session有可能会被回收，当不可用时使用下面那个session
@property (weak, nonatomic, nullable) NSURLSession *unownedSession;
// This is set if we're using not using an injected NSURLSession. We're responsible of invalidating this one
//strong修饰的session，当上面weak的session不可用时，需要创建一个session,这个session需要由本类负责管理，需要在合适的地方调用*invalid*方法打破引用循环
@property (strong, nonatomic, nullable) NSURLSession *ownedSession;
////NSURLSessionTask具体的下载任务
@property (strong, nonatomic, readwrite, nullable) NSURLSessionTask *dataTask;

@property (strong, nonatomic, nonnull) dispatch_semaphore_t callbacksLock; // a lock to keep the access to `callbackBlocks` thread-safe

//解码queue队列
@property (strong, nonatomic, nonnull) dispatch_queue_t coderQueue; // the queue to do image decoding
#if SD_UIKIT////iOS上支持在后台下载时需要一个identifier
@property (assign, nonatomic) UIBackgroundTaskIdentifier backgroundTaskId;
#endif

//这个解码器在图片没有完全下载完成时也可以解码展示部分图片
@property (strong, nonatomic, nullable) id<SDWebImageProgressiveCoder> progressiveCoder;
/*
 上面的代码还定义了一个队列，在前面分析SDWebImage缓存策略的源码时它也用到了一个串行队列，通过串行队列就可以避免竞争条件，可以不需要手动加锁和释放锁，简化编程。还可以发现它定义了一个NSURLSessionTask属性，所以具体的下载任务一定是交由其子类完成的。
 */
@end

@implementation SDWebImageDownloaderOperation

@synthesize executing = _executing;
@synthesize finished = _finished;
//初始化函数，直接返回下面的初始化构造函数
- (nonnull instancetype)init {
    return [self initWithRequest:nil inSession:nil options:0];
}

- (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
                              inSession:(nullable NSURLSession *)session
                                options:(SDWebImageDownloaderOptions)options {
    if ((self = [super init])) {
        _request = [request copy];
        _shouldDecompressImages = YES;
        _options = options;
        _callbackBlocks = [NSMutableArray new];
        _executing = NO;
        _finished = NO;
        _expectedSize = 0;
        _unownedSession = session;
        _callbacksLock = dispatch_semaphore_create(1);
        _coderQueue = dispatch_queue_create("com.hackemist.SDWebImageDownloaderOperationCoderQueue", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
/*
 合成存取了executing和finished属性，接下来就是两个初始化构造函数，进行了相关的初始化操作，注意看，在初始化方法中将传入的session赋给了unownedSession，所以这个session是外部传入的，本类就不需要负责管理它，但是它有可能会被释放，所以当这个session不可用时需要自己创建一个新的session并自行管理，上面还创建了一个并发队列，但这个队列都是以dispatch_barrier_(a)sync函数来执行，所以在这个并发队列上具体的执行方式还是串行，因为队列会被阻塞，在析构函数中释放这个队列
 */
////添加进度回调块和下载完成回调块
- (nullable id)addHandlersForProgress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                            completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock {
    //创建一个<NSString,id>类型的可变字典，value为回调块
    SDCallbacksDictionary *callbacks = [NSMutableDictionary new];
    //如果进度回调块存在就加进字典里，key为@"progress"
    if (progressBlock) callbacks[kProgressCallbackKey] = [progressBlock copy];
    //如果下载完成回调块存在就加进字典里，key为@"completed"
    if (completedBlock) callbacks[kCompletedCallbackKey] = [completedBlock copy];
    //使用dispatch_barrier_async方法异步方式不阻塞当前线程，但阻塞并发对列，串行执行添加进数组的操作
//    dispatch_barrier_async(self.barrierQueue, ^{
//        [self.callbackBlocks addObject:callbacks];
//    });
    LOCK(self.callbacksLock);
    [self.callbackBlocks addObject:callbacks];
    UNLOCK(self.callbacksLock);
    ////返回的token其实就是这个字典
    return callbacks;
}
//通过key获取回调块数组中所有对应key的回调块
- (nullable NSArray<id> *)callbacksForKey:(NSString *)key {
    /*
    __block NSMutableArray<id> *callbacks = nil;
    //同步方式执行，阻塞当前线程也阻塞队列
    dispatch_sync(self.barrierQueue, ^{
        callbacks = [[self.callbackBlocks valueForKey:key] mutableCopy];
        //通过valueForKey方法如果字典中没有对应key会返回null所以需要删除为null的元素
        [callbacks removeObjectIdenticalTo:[NSNull null]];
    });
    */
    LOCK(self.callbacksLock);
    NSMutableArray<id> *callbacks = [[self.callbackBlocks valueForKey:key] mutableCopy];
    UNLOCK(self.callbacksLock);
    // We need to remove [NSNull null] because there might not always be a progress block for each callback
    //通过valueForKey方法如果字典中没有对应key会返回null所以需要删除为null的元素
    [callbacks removeObjectIdenticalTo:[NSNull null]];
    return [callbacks copy]; // strip mutability here
}
//前文讲过的取消方法
- (BOOL)cancel:(nullable id)token {
    BOOL shouldCancel = NO;
    /* 所谓的   加锁 VS  队列可以替换
    //同步方法阻塞队列阻塞当前线程也阻塞队列
    dispatch_barrier_sync(self.barrierQueue, ^{
        //根据token删除数组中的数据，token就是key为string，value为block的字典
        //删除的就是数组中的字典元素
        [self.callbackBlocks removeObjectIdenticalTo:token];
        //如果回调块数组长度为0就真的要取消下载任务了，因为已经没有人来接收下载完成和下载进度的信息，下载完成也没有任何意义
        if (self.callbackBlocks.count == 0) {
            shouldCancel = YES;
        }
    });
    */
    LOCK(self.callbacksLock);
    //根据token删除数组中的数据，token就是key为string，value为block的字典
    //删除的就是数组中的字典元素
    [self.callbackBlocks removeObjectIdenticalTo:token];
    ////如果回调块数组长度为0就真的要取消下载任务了，因为已经没有人来接收下载完成和下载进度的信息，下载完成也没有任何意义
    if (self.callbackBlocks.count == 0) {
        shouldCancel = YES;
    }
    UNLOCK(self.callbacksLock);
    
    ////如果要真的要取消任务就调用cancel方法
    if (shouldCancel) {
        [self cancel];
    }
    return shouldCancel;
}
/*
 上面三个方法主要就是往一个字典类型的数组中添加回调块，这个字典最多只有两个key-value键值对，数组中可以有多个这样的字典，每添加一个进度回调块和下载完成回调块就会把这个字典返回作为token，在取消任务方法中就会从数组中删除掉这个字典，但是只有当数组中的回调块字典全部被删除完了才会真正取消任务。
*/
//重写NSOperation类的start方法，任务添加到NSOperationQueue后会执行该方法，启动下载任务
- (void)start {
    /*
     同步代码块，防止产生竞争条件？
     其实这里我并不懂为什么要加这个同步代码块
     NSOperation子类加进NSOperationQueue后会自行调用start方法，并且只会执行一次，不太理解为什么需要加这个，懂的读者希望不吝赐教
     */
    @synchronized (self) {
         //判断是否取消了下载任务
        if (self.isCancelled) {
            //如果取消了就设置finished为YES，调用reset方法---sesstion
            self.finished = YES;
            [self reset];
            return;
        }

        // //iOS里支持可以在app进入后台后继续下载
#if SD_UIKIT
        Class UIApplicationClass = NSClassFromString(@"UIApplication");
        BOOL hasApplication = UIApplicationClass && [UIApplicationClass respondsToSelector:@selector(sharedApplication)];
        if (hasApplication && [self shouldContinueWhenAppEntersBackground]) {
            __weak __typeof__ (self) wself = self;
            UIApplication * app = [UIApplicationClass performSelector:@selector(sharedApplication)];
            self.backgroundTaskId = [app beginBackgroundTaskWithExpirationHandler:^{
                __strong __typeof (wself) sself = wself;

                if (sself) {
                    [sself cancel];

                    [app endBackgroundTask:sself.backgroundTaskId];
                    sself.backgroundTaskId = UIBackgroundTaskInvalid;
                }
            }];
        }
#endif
        //根据配置的下载选项获取网络请求的缓存数据
        NSURLSession *session = self.unownedSession;
        //判断unownedSession是否为nil
        if (!session) {
            //为空则自行创建一个NSURLSession对象
            //相关知识前文也讲解过了，session运行在默认模式下
            NSURLSessionConfiguration *sessionConfig = [NSURLSessionConfiguration defaultSessionConfiguration];
            //超时时间15s
            sessionConfig.timeoutIntervalForRequest = 15;
            
            /**
             *  Create the session for this task
             *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
             *  method calls and completion handler calls.
              //delegateQueue为nil，所以回调方法默认在一个子线程的串行队列中执行
             */
            session = [NSURLSession sessionWithConfiguration:sessionConfig
                                                    delegate:self
                                               delegateQueue:nil];
            self.ownedSession = session;
        }
        
        if (self.options & SDWebImageDownloaderIgnoreCachedResponse) {
            // Grab the cached data for later check
            NSURLCache *URLCache = session.configuration.URLCache;
            if (!URLCache) {
                URLCache = [NSURLCache sharedURLCache];
            }
            NSCachedURLResponse *cachedResponse;
            // NSURLCache's `cachedResponseForRequest:` is not thread-safe, see https://developer.apple.com/documentation/foundation/nsurlcache#2317483
            @synchronized (URLCache) {
                cachedResponse = [URLCache cachedResponseForRequest:self.request];
            }
            if (cachedResponse) {
                self.cachedData = cachedResponse.data;
            }
        }
          //使用可用的session来创建一个NSURLSessionDataTask类型的下载任务
        self.dataTask = [session dataTaskWithRequest:self.request];
        //设置NSOperation子类的executing属性，标识开始下载任务
        self.executing = YES;
    }

    //如果这个NSURLSessionDataTask不为空即开启成功
    if (self.dataTask) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability"
        if ([self.dataTask respondsToSelector:@selector(setPriority:)]) {
            if (self.options & SDWebImageDownloaderHighPriority) {
                self.dataTask.priority = NSURLSessionTaskPriorityHigh;
            } else if (self.options & SDWebImageDownloaderLowPriority) {
                self.dataTask.priority = NSURLSessionTaskPriorityLow;
            }
        }
#pragma clang diagnostic pop
        [self.dataTask resume];//NSURLSessionDataTask任务开始执行
        //遍历所有的进度回调块并执行
        for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
            progressBlock(0, NSURLResponseUnknownLength, self.request.URL);
        }
        /*
         在主线程中发送通知，并将self传出去
         在什么线程发送通知，就会在什么线程接收通知
         为了防止其他监听通知的对象在回调方法中修改UI，这里就需要在主线程中发送通知
         */
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStartNotification object:weakSelf];
        });
    } else { //如果创建NSURLSessionDataTask失败就执行失败的回调块
        [self callCompletionBlocksWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorUnknown userInfo:@{NSLocalizedDescriptionKey : @"Task can't be initialized"}]];
        [self done];
        return;
    }
//iOS后台下载相关
#if SD_UIKIT
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    if (self.backgroundTaskId != UIBackgroundTaskInvalid) {
        UIApplication * app = [UIApplication performSelector:@selector(sharedApplication)];
        [app endBackgroundTask:self.backgroundTaskId];
        self.backgroundTaskId = UIBackgroundTaskInvalid;
    }
#endif
}
/*
 上面这个函数就是重写了NSOperation类的start方法，当NSOperation类的子类添加进NSOperationQueue队列中线程调度后就会执行上述方法，上面这个方法也比较简单，主要就是判断session是否可用然后决定是否要自行管理一个NSURLSession对象，接下来就使用这个session创建一个NSURLSessionDataTask对象，这个对象是真正执行下载和服务端交互的对象，接下来就开启这个下载任务然后进行通知和回调块的触发工作，很简单的逻辑。
 */
//SDWebImageOperation协议的cancel方法，取消任务，调用cancelInternal方法
- (void)cancel {
    @synchronized (self) {
        [self cancelInternal];
    }
}
//真的取消下载任务的方法
- (void)cancelInternal {
    //如果下载任务已经结束了直接返回
    if (self.isFinished) return;
    //调用NSOperation类的cancel方法，即，将isCancelled属性置为YES
    [super cancel];
//如果NSURLSessionDataTask下载图片的任务存在
    if (self.dataTask) {
        //调用其cancel方法取消下载任务
        [self.dataTask cancel];
         //在主线程中发出下载停止的通知
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:weakSelf];
        });

        // As we cancelled the task, its callback won't be called and thus won't
        // maintain the isFinished and isExecuting flags.
        //设置两个属性的值
        if (self.isExecuting) self.executing = NO;
        if (!self.isFinished) self.finished = YES;
    }
//调用reset方法
    [self reset];
}
//下载完成后调用的方法
- (void)done {
     //设置finished为YES executing为NO
    self.finished = YES;
    self.executing = NO;
    //调用reset方法
    [self reset];
}

- (void)reset {
     //删除回调块字典数组的所有元素
    LOCK(self.callbacksLock);
    [self.callbackBlocks removeAllObjects];
    UNLOCK(self.callbacksLock);
    //NSURLSessionDataTask对象置为nil，等待回收
    self.dataTask = nil;
    
    //如果ownedSession存在，就需要我们手动调用invalidateAndCancel方法打破引用循环
    if (self.ownedSession) {
        [self.ownedSession invalidateAndCancel];
        self.ownedSession = nil;
    }
}
//NSOperation子类finished属性的stter
- (void)setFinished:(BOOL)finished {
    //手动触发KVO通知
    [self willChangeValueForKey:@"isFinished"];
    _finished = finished;
    [self didChangeValueForKey:@"isFinished"];
}
//NSOperation子类finished属性的stter
- (void)setExecuting:(BOOL)executing {
    //手动触发KVO通知   setter方法的本质？？？
    [self willChangeValueForKey:@"isExecuting"];
    _executing = executing;
    [self didChangeValueForKey:@"isExecuting"];
}
//重写NSOperation方法，标识这是一个并发任务
- (BOOL)isConcurrent {
    return YES;
}

#pragma mark NSURLSessionDataDelegate
//收到服务端响应，在一次请求中只会执行一次
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    //响应处置------取消，继续，becomeDownload  BecomeStream
    NSURLSessionResponseDisposition disposition = NSURLSessionResponseAllow;
    //获取要下载图片的长度
    NSInteger expected = (NSInteger)response.expectedContentLength;
    expected = expected > 0 ? expected : 0;
    ////设置长度
    self.expectedSize = expected;
    //将response赋值到成员变量
    self.response = response;
    NSInteger statusCode = [response respondsToSelector:@selector(statusCode)] ? ((NSHTTPURLResponse *)response).statusCode : 200;
    BOOL valid = statusCode < 400;
    //'304 Not Modified' is an exceptional one. It should be treated as cancelled if no cache data
    //URLSession current behavior will return 200 status code when the server respond 304 and URLCache hit. But this is not a standard behavior and we just add a check
    //根据http状态码判断是否成功响应，需要注意的是304认为是异常响应
    if (statusCode == 304 && !self.cachedData) {
        valid = NO;
    }
    
    if (valid) {
        //遍历进度回调块并触发进度回调块
        for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
            progressBlock(0, expected, self.request.URL);
        }
    } else {
        // Status code invalid and marked as cancelled. Do not call `[self.dataTask cancel]` which may mass up URLSession life cycle
        disposition = NSURLSessionResponseCancel;
    }
    //主线程中发送相关通知
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadReceiveResponseNotification object:weakSelf];
    });
    //如果有回调块就执行
    if (completionHandler) {
        completionHandler(disposition);
    }
}
//收到数据的回调方法，可能执行多次
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {
    if (!self.imageData) {
        self.imageData = [[NSMutableData alloc] initWithCapacity:self.expectedSize];
    }
    //向可变数据中添加接收到的数据
    [self.imageData appendData:data];
  //如果下载选项需要支持progressive下载，即展示已经下载的部分，并且响应中返回的图片大小大于0
    if ((self.options & SDWebImageDownloaderProgressiveDownload) && self.expectedSize > 0) {
        // Get the image data //复制data数据
        __block NSData *imageData = [self.imageData copy];
        // Get the total bytes downloaded //获取已经下载了多大的数据
        const NSInteger totalSize = imageData.length;
        // Get the finish status//判断是否已经下载完成
        BOOL finished = (totalSize >= self.expectedSize);
        //如果这个解码器不存在就创建一个
        if (!self.progressiveCoder) {
            // We need to create a new instance for progressive decoding to avoid conflicts
            for (id<SDWebImageCoder>coder in [SDWebImageCodersManager sharedInstance].coders) {
                if ([coder conformsToProtocol:@protocol(SDWebImageProgressiveCoder)] &&
                    [((id<SDWebImageProgressiveCoder>)coder) canIncrementallyDecodeFromData:imageData]) {
                    self.progressiveCoder = [[[coder class] alloc] init];
                    break;
                }
            }
        }
        
        // progressive decode the image in coder queue
        dispatch_async(self.coderQueue, ^{
            //将数据交给解码器返回一个图片
            UIImage *image = [self.progressiveCoder incrementallyDecodedImageWithData:imageData finished:finished];
            if (image) {
                //通过URL获取缓存的key
                NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:self.request.URL];
                //缩放图片，不同平台图片大小计算方法不同，所以需要处理与喜爱
                image = [self scaledImageForKey:key image:image];
                //是否需要压缩
                if (self.shouldDecompressImages) {
                    //压缩
                    image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&imageData options:@{SDWebImageCoderScaleDownLargeImagesKey: @(NO)}];
                }
                
                // We do not keep the progressive decoding image even when `finished`=YES. Because they are for view rendering but not take full function from downloader options. And some coders implementation may not keep consistent between progressive decoding and normal decoding.
                //触发回调块回传这个图片
                [self callCompletionBlocksWithImage:image imageData:nil error:nil finished:NO];
            }
        });
    }
//调用进度回调块并触发进度回调块
    for (SDWebImageDownloaderProgressBlock progressBlock in [self callbacksForKey:kProgressCallbackKey]) {
        progressBlock(self.imageData.length, self.expectedSize, self.request.URL);
    }
}
//如果要缓存响应时回调该方法
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {
    
    NSCachedURLResponse *cachedResponse = proposedResponse;
//如果request的缓存策略是不缓存本地数据就设置为nil
    if (!(self.options & SDWebImageDownloaderUseNSURLCache)) {
        // Prevents caching of responses
        cachedResponse = nil;
    }
    if (completionHandler) {
        completionHandler(cachedResponse);
    }
}
/*
 上面几个方法就是在接收到服务端响应后进行一个处理，判断是否是正常响应，如果是正常响应就进行各种赋值和初始化操作，并触发回调块，进行通知等操作，如果不是正常响应就结束下载任务。接下来的一个比较重要的方法就是接收到图片数据的处理，接收到数据后就追加到可变数据中，如果需要在图片没有下载完成时就展示部分图片，需要进行一个解码的操作然后调用回调块将图片数据回传，接着就会调用存储的进度回调块来通知现在的下载进度，回传图片的总长度和已经下载长度的信息。
 */

#pragma mark NSURLSessionTaskDelegate
//下载完成或下载失败时的回调方法
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    /*
     又是一个同步代码块...有点不解，望理解的读者周知
     SDWebImage下载的逻辑也挺简单的，本类SDWebImageDownloaderOperation是NSOperation的子类
     所以可以使用NSOperationQueue来实现多线程下载
     但是每一个Operation类对应一个NSURLSessionTask的下载任务
     也就是说，SDWebImageDownloader类在需要下载图片的时候就创建一个Operation，
     然后将这个Operation加入到OperationQueue中，就会执行start方法
     start方法会创建一个Task来实现下载
     所以整个下载任务有两个子线程，一个是Operation执行start方法的线程来开启Task的下载任务
     一个是Task的线程来执行下载任务
     Operation和Task是一对一的关系，应该不会有竞争条件产生呀？
     */
    @synchronized(self) {
        //置空
        self.dataTask = nil;
        //主线程根据error是否为空发送对应通知
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadStopNotification object:weakSelf];
            if (!error) {
                [[NSNotificationCenter defaultCenter] postNotificationName:SDWebImageDownloadFinishNotification object:weakSelf];
            }
        });
    }
    
    // make sure to call `[self done]` to mark operation as finished
    //如果error存在，即下载过程中有我entity
    if (error) {
        //触发对应回调块
        [self callCompletionBlocksWithError:error];
        [self done];
    } else {
        //下载成功
        //判断下载完成回调块个数是否大于0
        if ([self callbacksForKey:kCompletedCallbackKey].count > 0) {
            /**
             *  If you specified to use `NSURLCache`, then the response you get here is what you need.
             //获取不可变data图片数据
             */
            __block NSData *imageData = [self.imageData copy];
            //如果下载的图片存在
            if (imageData) {
                /**  if you specified to only use cached data via `SDWebImageDownloaderIgnoreCachedResponse`,
                 *  then we should check if the cached data is equal to image data
                 //如果下载设置只使用缓存数据就会判断缓存数据与当前获取的数据是否一致，一致就触发完成回调块
                 */
                if (self.options & SDWebImageDownloaderIgnoreCachedResponse && [self.cachedData isEqualToData:imageData]) {
                    // call completion block with nil
                    [self callCompletionBlocksWithImage:nil imageData:nil error:nil finished:YES];
                    [self done];
                } else {//解码图片
                    // decode the image in coder queue
                    dispatch_async(self.coderQueue, ^{
                        //解码图片
                        UIImage *image = [[SDWebImageCodersManager sharedInstance] decodedImageWithData:imageData];
                        //获取缓存图片的唯一key
                        NSString *key = [[SDWebImageManager sharedManager] cacheKeyForURL:self.request.URL];
                        //缩放图片，不同平台图片大小计算方法不同，需要设置一下
                        image = [self scaledImageForKey:key image:image];
                        
                        //下面是GIF WebP格式数据的解码工作
                        BOOL shouldDecode = YES;
                        // Do not force decoding animated GIFs and WebPs
                        if (image.images) {
                            shouldDecode = NO;
                        } else {
#ifdef SD_WEBP
                            SDImageFormat imageFormat = [NSData sd_imageFormatForImageData:imageData];
                            if (imageFormat == SDImageFormatWebP) {
                                shouldDecode = NO;
                            }
#endif
                        }
                        
                        if (shouldDecode) {
                            if (self.shouldDecompressImages) {
                                BOOL shouldScaleDown = self.options & SDWebImageDownloaderScaleDownLargeImages;
                                image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&imageData options:@{SDWebImageCoderScaleDownLargeImagesKey: @(shouldScaleDown)}];
                            }
                        }
                        CGSize imageSize = image.size;
                        if (imageSize.width == 0 || imageSize.height == 0) {
                            [self callCompletionBlocksWithError:[NSError errorWithDomain:SDWebImageErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Downloaded image has 0 pixels"}]];
                        } else {
                            [self callCompletionBlocksWithImage:image imageData:imageData error:nil finished:YES];
                        }
                        [self done];
                    });
                }
            } else {
                [self callCompletionBlocksWithError:[NSError errorWithDomain:SDWebImageErrorDomain code:0 userInfo:@{NSLocalizedDescriptionKey : @"Image data is nil"}]];
                [self done];
            }
        } else {
            [self done];
        }
    }
}
//如果是https访问就需要设置SSL证书相关
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {
    
    NSURLSessionAuthChallengeDisposition disposition = NSURLSessionAuthChallengePerformDefaultHandling;
    __block NSURLCredential *credential = nil;
    
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
        if (!(self.options & SDWebImageDownloaderAllowInvalidSSLCertificates)) {
            disposition = NSURLSessionAuthChallengePerformDefaultHandling;
        } else {
            credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            disposition = NSURLSessionAuthChallengeUseCredential;
        }
    } else {
        if (challenge.previousFailureCount == 0) {
            if (self.credential) {
                credential = self.credential;
                disposition = NSURLSessionAuthChallengeUseCredential;
            } else {
                disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
            }
        } else {
            disposition = NSURLSessionAuthChallengeCancelAuthenticationChallenge;
        }
    }
    
    if (completionHandler) {
        completionHandler(disposition, credential);
    }
}

#pragma mark Helper methods
//不同平台计算图片大小方式不同，图片需要缩放一下，读者可以自行查阅源码，很好理解
- (nullable UIImage *)scaledImageForKey:(nullable NSString *)key image:(nullable UIImage *)image {
    return SDScaledImageForKey(key, image);
}
//是否支持后台下载
- (BOOL)shouldContinueWhenAppEntersBackground {
    return self.options & SDWebImageDownloaderContinueInBackground;
}
//调用完成回调块
- (void)callCompletionBlocksWithError:(nullable NSError *)error {
    [self callCompletionBlocksWithImage:nil imageData:nil error:error finished:YES];
}
//遍历所有的完成回调块，在主线程中触发
- (void)callCompletionBlocksWithImage:(nullable UIImage *)image
                            imageData:(nullable NSData *)imageData
                                error:(nullable NSError *)error
                             finished:(BOOL)finished {
    NSArray<id> *completionBlocks = [self callbacksForKey:kCompletedCallbackKey];
    dispatch_main_async_safe(^{
        for (SDWebImageDownloaderCompletedBlock completedBlock in completionBlocks) {
            completedBlock(image, imageData, error, finished);
        }
    });
}
/*
 在加入到NSOperationQueue以后，执行start方法时就会通过一个可用的NSURLSession对象来创建一个NSURLSessionDataTask的下载任务，并设置回调，在回调方法中接收数据并进行一系列通知和触发回调块。
 */

@end
