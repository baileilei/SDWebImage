/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDWebImageDownloader.h"
#import "SDWebImageDownloaderOperation.h"

#define LOCK(lock) dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define UNLOCK(lock) dispatch_semaphore_signal(lock);

@interface SDWebImageDownloadToken ()

@property (nonatomic, weak, nullable) NSOperation<SDWebImageDownloaderOperationInterface> *downloadOperation;

@end

@implementation SDWebImageDownloadToken

- (void)cancel {
    if (self.downloadOperation) {
        SDWebImageDownloadToken *cancelToken = self.downloadOperationCancelToken;
        if (cancelToken) {
            [self.downloadOperation cancel:cancelToken];
        }
    }
}

@end

//遵守NSURLSessionTaskDelegate和NSURLSessionDataDelegate协议
@interface SDWebImageDownloader () <NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

//定义一个NSOperationQueue的下载队列
@property (strong, nonatomic, nonnull) NSOperationQueue *downloadQueue;
//最近一次添加进队列的operation主要用于LIFO时设置依赖
@property (weak, nonatomic, nullable) NSOperation *lastAddedOperation;
//operationClass默认是SDWebImageDownloaderOperation
@property (assign, nonatomic, nullable) Class operationClass;
//可变字典，key是图片的URL，value是对应的下载任务Operation
@property (strong, nonatomic, nonnull) NSMutableDictionary<NSURL *, SDWebImageDownloaderOperation *> *URLOperations;
//<NSString*, NSString*>类型的字典，存储http首部
@property (strong, nonatomic, nullable) SDHTTPHeadersMutableDictionary *HTTPHeaders;
//一个GCD的队列 @property (SDDispatchQueueSetterSementics, nonatomic, nullable) dispatch_queue_t barrierQueue;
@property (strong, nonatomic, nonnull) dispatch_semaphore_t operationsLock; // a lock to keep the access to `URLOperations` thread-safe
@property (strong, nonatomic, nonnull) dispatch_semaphore_t headersLock; // a lock to keep the access to `HTTPHeaders` thread-safe

// The session in which data tasks will run//NSURLSession对象
@property (strong, nonatomic) NSURLSession *session;

@end

@implementation SDWebImageDownloader
//类方法，类加载的时候执行
+ (void)initialize {
    // Bind SDNetworkActivityIndicator if available (download it here: http://github.com/rs/SDNetworkActivityIndicator )
    // To use it, just add #import "SDNetworkActivityIndicator.h" in addition to the SDWebImage import
    //如果导入了SDNetworkActivityIndicator文件，就会展示一个小菊花
    if (NSClassFromString(@"SDNetworkActivityIndicator")) {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id activityIndicator = [NSClassFromString(@"SDNetworkActivityIndicator") performSelector:NSSelectorFromString(@"sharedActivityIndicator")];
#pragma clang diagnostic pop

        // Remove observer in case it was previously added.
        //删除通知后重新添加通知，防止重复添加出现异常
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] removeObserver:activityIndicator name:SDWebImageDownloadStopNotification object:nil];

        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"startActivity")
                                                     name:SDWebImageDownloadStartNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:activityIndicator
                                                 selector:NSSelectorFromString(@"stopActivity")
                                                     name:SDWebImageDownloadStopNotification object:nil];
    }
}
//类方法，返回单例对象
+ (nonnull instancetype)sharedDownloader {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}
//初始化方法调用下面的初始化方法，NSURLSession运行在默认模式下
- (nonnull instancetype)init {
    return [self initWithSessionConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
}
//初始化方法
- (nonnull instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)sessionConfiguration {
    if ((self = [super init])) {
        //默认使用SDWebImageDownloaderOperation作为下载任务Operation
        _operationClass = [SDWebImageDownloaderOperation class];
        _shouldDecompressImages = YES;
        //默认下载顺序FIFO
        _executionOrder = SDWebImageDownloaderFIFOExecutionOrder;
        //创建NSOperationQueue并设置最大并发数为6，即同时最多可以下载6张图片
        _downloadQueue = [NSOperationQueue new];
        _downloadQueue.maxConcurrentOperationCount = 6;
        //设置名称
        _downloadQueue.name = @"com.hackemist.SDWebImageDownloader";
        //设置下载webp格式图片的http首部
        _URLOperations = [NSMutableDictionary new];
#ifdef SD_WEBP
        _HTTPHeaders = [@{@"Accept": @"image/webp,image/*;q=0.8"} mutableCopy];
#else
        _HTTPHeaders = [@{@"Accept": @"image/*;q=0.8"} mutableCopy];
#endif
        _operationsLock = dispatch_semaphore_create(1);
        _headersLock = dispatch_semaphore_create(1);
        //默认超时时间15s
        _downloadTimeout = 15.0;
        //创建一个sessionConfiguration运行默认的NSURLSession对象
        [self createNewSessionWithConfiguration:sessionConfiguration];
    }
    return self;
}
//创建指定运行模式的NSURLSession对象，可能已经创建过了
- (void)createNewSessionWithConfiguration:(NSURLSessionConfiguration *)sessionConfiguration {
    //可能已经创建过，所以需要取消前一个session的下载任务并打破引用循环
    [self cancelAllDownloads];

    if (self.session) {
        [self.session invalidateAndCancel];
    }

    sessionConfiguration.timeoutIntervalForRequest = self.downloadTimeout;

    /**
     *  Create the session for this task
     *  We send nil as delegate queue so that the session creates a serial operation queue for performing all delegate
     *  method calls and completion handler calls.
     */
    self.session = [NSURLSession sessionWithConfiguration:sessionConfiguration
                                                 delegate:self
                                            delegateQueue:nil];
}

- (void)invalidateSessionAndCancel:(BOOL)cancelPendingOperations {
    if (self == [SDWebImageDownloader sharedDownloader]) {
        return;
    }
    if (cancelPendingOperations) {
        [self.session invalidateAndCancel];
    } else {
        [self.session finishTasksAndInvalidate];
    }
}
//在析构函数中调用session的invalidateAndCancel方法取消下载任务并打破引用循环
- (void)dealloc {
    [self.session invalidateAndCancel];
    self.session = nil;
 //NSOperationQueue取消所有的下载操作
    [self.downloadQueue cancelAllOperations];
}
//为http首部设置键值对
- (void)setValue:(nullable NSString *)value forHTTPHeaderField:(nullable NSString *)field {
    LOCK(self.headersLock);
    if (value) {
        self.HTTPHeaders[field] = value;
    } else {
        [self.HTTPHeaders removeObjectForKey:field];
    }
    UNLOCK(self.headersLock);
}
//获取http首部的值
- (nullable NSString *)valueForHTTPHeaderField:(nullable NSString *)field {
    if (!field) {
        return nil;
    }
    return [[self allHTTPHeaderFields] objectForKey:field];
}

- (nonnull SDHTTPHeadersDictionary *)allHTTPHeaderFields {
    LOCK(self.headersLock);
    SDHTTPHeadersDictionary *allHTTPHeaderFields = [self.HTTPHeaders copy];
    UNLOCK(self.headersLock);
    return allHTTPHeaderFields;
}
//设置最大同时下载图片的数量，即NSOperationQueue最大并发数
- (void)setMaxConcurrentDownloads:(NSInteger)maxConcurrentDownloads {
    _downloadQueue.maxConcurrentOperationCount = maxConcurrentDownloads;
}
//当前正在下载图片数量，即NSOperationQueue中正在执行的operation数量
- (NSUInteger)currentDownloadCount {
    return _downloadQueue.operationCount;
}
//获取最大同时下载图片的数量
- (NSInteger)maxConcurrentDownloads {
    return _downloadQueue.maxConcurrentOperationCount;
}
//获取NSURLSession的运行模式配置
- (NSURLSessionConfiguration *)sessionConfiguration {
    return self.session.configuration;
}
//设置operation的Class类对象
- (void)setOperationClass:(nullable Class)operationClass {
    if (operationClass && [operationClass isSubclassOfClass:[NSOperation class]] && [operationClass conformsToProtocol:@protocol(SDWebImageDownloaderOperationInterface)]) {
        _operationClass = operationClass;
    } else {
        _operationClass = [SDWebImageDownloaderOperation class];
    }
}
//下载图片的方法
- (nullable SDWebImageDownloadToken *)downloadImageWithURL:(nullable NSURL *)url
                                                   options:(SDWebImageDownloaderOptions)options
                                                  progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                                 completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock {
    __weak SDWebImageDownloader *wself = self;

    //直接调用另一个方法，后面大片的block代码目的就是为了创建一个SDWebImageDownloaderOperation类的对象
    return [self addProgressCallback:progressBlock completedBlock:completedBlock forURL:url createCallback:^SDWebImageDownloaderOperation *{
        //block中为了防止引用循环和空指针，先weak后strong
        __strong __typeof (wself) sself = wself;
        //设置超时时间
        NSTimeInterval timeoutInterval = sself.downloadTimeout;
        if (timeoutInterval == 0.0) {
            timeoutInterval = 15.0;
        }

        // In order to prevent from potential duplicate caching (NSURLCache + SDImageCache) we disable the cache for image requests if told otherwise//设置缓存策略
        NSURLRequestCachePolicy cachePolicy = options & SDWebImageDownloaderUseNSURLCache ? NSURLRequestUseProtocolCachePolicy : NSURLRequestReloadIgnoringLocalCacheData;
        //创建一个可变的request
        NSMutableURLRequest *request = [[NSMutableURLRequest alloc] initWithURL:url
                                                                    cachePolicy:cachePolicy
                                                                timeoutInterval:timeoutInterval];
         //设置cookie的处理策略
        request.HTTPShouldHandleCookies = (options & SDWebImageDownloaderHandleCookies);
        request.HTTPShouldUsePipelining = YES;
         //过滤http首部
        if (sself.headersFilter) {
            request.allHTTPHeaderFields = sself.headersFilter(url, [sself allHTTPHeaderFields]);
        }
        else {
            request.allHTTPHeaderFields = [sself allHTTPHeaderFields];
        }
        //创建一个SDWebImageDownloaderOperation类的对象
        //传入request、session和下载选项配置options
        SDWebImageDownloaderOperation *operation = [[sself.operationClass alloc] initWithRequest:request inSession:sself.session options:options];
        //设置是否压缩图片
        operation.shouldDecompressImages = sself.shouldDecompressImages;
        //设置认证凭证和https相关
        if (sself.urlCredential) {
            operation.credential = sself.urlCredential;
        } else if (sself.username && sself.password) {
            operation.credential = [NSURLCredential credentialWithUser:sself.username password:sself.password persistence:NSURLCredentialPersistenceForSession];
        }
        //设置下载优先级
        if (options & SDWebImageDownloaderHighPriority) {
            operation.queuePriority = NSOperationQueuePriorityHigh;
        } else if (options & SDWebImageDownloaderLowPriority) {
            operation.queuePriority = NSOperationQueuePriorityLow;
        }
      //如果是LIFO就设置一个依赖
        if (sself.executionOrder == SDWebImageDownloaderLIFOExecutionOrder) {
            // Emulate LIFO execution order by systematically adding new operations as last operation's dependency
            [sself.lastAddedOperation addDependency:operation];
            sself.lastAddedOperation = operation;
        }

        return operation;
    }];
}
//取消一个下载任务，需要传入上一个方法返回的token，其实具体的token是由下一个方法创建的
- (void)cancel:(nullable SDWebImageDownloadToken *)token {
    NSURL *url = token.url;
    if (!url) {
        return;
    }
    LOCK(self.operationsLock);
    //通过token的url获取到这个Operation
    SDWebImageDownloaderOperation *operation = [self.URLOperations objectForKey:url];
    if (operation) {
        //调用Operation自定义的cancel方法来取消任务，传入一个回调块字典的token
        BOOL canceled = [operation cancel:token.downloadOperationCancelToken];
        //如果取消了就从字典中移除掉这个键值对
        if (canceled) {
            [self.URLOperations removeObjectForKey:url];
        }
    }
    UNLOCK(self.operationsLock);
}
/*
 前面download方法调用的方法，返回一个token
 createCallback就是download方法写的，用于创建一个SDWebImageDownloaderOperation
 */
- (nullable SDWebImageDownloadToken *)addProgressCallback:(SDWebImageDownloaderProgressBlock)progressBlock
                                           completedBlock:(SDWebImageDownloaderCompletedBlock)completedBlock
                                                   forURL:(nullable NSURL *)url
                                           createCallback:(SDWebImageDownloaderOperation *(^)(void))createCallback {
    // The URL will be used as the key to the callbacks dictionary so it cannot be nil. If it is nil immediately call the completed block with no image or data.
    //URL为nil就调用下载完成回调块，返回nil
    if (url == nil) {
        if (completedBlock != nil) {
            completedBlock(nil, nil, nil, NO);
        }
        return nil;
    }
    
    LOCK(self.operationsLock);
    //通过URL获取Operation
    SDWebImageDownloaderOperation *operation = [self.URLOperations objectForKey:url];
    if (!operation) {
        //如果URL对应的Operation不存在就调用，createCallback块创建一个
        operation = createCallback();
        __weak typeof(self) wself = self;
        operation.completionBlock = ^{
            __strong typeof(wself) sself = wself;
            if (!sself) {
                return;
            }
            LOCK(sself.operationsLock);
            //下载完成就从字典中删除
            [sself.URLOperations removeObjectForKey:url];
            UNLOCK(sself.operationsLock);
        };
        //添加进字典中
        [self.URLOperations setObject:operation forKey:url];
        // Add operation to operation queue only after all configuration done according to Apple's doc.
        // `addOperation:` does not synchronously execute the `operation.completionBlock` so this will not cause deadlock.
        [self.downloadQueue addOperation:operation];
    }
    UNLOCK(self.operationsLock);

    //取消下载任务时的token，第一个值就是url，第二个值就是回调块字典
    id downloadOperationCancelToken = [operation addHandlersForProgress:progressBlock completed:completedBlock];
    
    SDWebImageDownloadToken *token = [SDWebImageDownloadToken new];
    token.downloadOperation = operation;
    token.url = url;
    token.downloadOperationCancelToken = downloadOperationCancelToken;

    return token;
}
//设置是否挂起下载队列
- (void)setSuspended:(BOOL)suspended {
    self.downloadQueue.suspended = suspended;
}
//取消所有的下载任务
- (void)cancelAllDownloads {
    [self.downloadQueue cancelAllOperations];
}

#pragma mark Helper methods
//通过NSURLSessionTask找到NSOPerationQueue里的任务
- (SDWebImageDownloaderOperation *)operationWithTask:(NSURLSessionTask *)task {
    SDWebImageDownloaderOperation *returnOperation = nil;
    for (SDWebImageDownloaderOperation *operation in self.downloadQueue.operations) {
        if (operation.dataTask.taskIdentifier == task.taskIdentifier) {
            returnOperation = operation;
            break;
        }
    }
    return returnOperation;
}

#pragma mark NSURLSessionDataDelegate
//下面这些代理方法，都是先通过NSURLSessionTask找到对应的SDWebImageDownloaderOperation
//然后调用Operation的代理方法，
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];
    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:didReceiveResponse:completionHandler:)]) {
        [dataOperation URLSession:session dataTask:dataTask didReceiveResponse:response completionHandler:completionHandler];
    } else {
        if (completionHandler) {
            completionHandler(NSURLSessionResponseAllow);
        }
    }
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)dataTask didReceiveData:(NSData *)data {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];
    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)]) {
        [dataOperation URLSession:session dataTask:dataTask didReceiveData:data];
    }
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
 willCacheResponse:(NSCachedURLResponse *)proposedResponse
 completionHandler:(void (^)(NSCachedURLResponse *cachedResponse))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:dataTask];
    if ([dataOperation respondsToSelector:@selector(URLSession:dataTask:willCacheResponse:completionHandler:)]) {
        [dataOperation URLSession:session dataTask:dataTask willCacheResponse:proposedResponse completionHandler:completionHandler];
    } else {
        if (completionHandler) {
            completionHandler(proposedResponse);
        }
    }
}

#pragma mark NSURLSessionTaskDelegate

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    
    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];
    if ([dataOperation respondsToSelector:@selector(URLSession:task:didCompleteWithError:)]) {
        [dataOperation URLSession:session task:task didCompleteWithError:error];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler {
    
    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];
    if ([dataOperation respondsToSelector:@selector(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)]) {
        [dataOperation URLSession:session task:task willPerformHTTPRedirection:response newRequest:request completionHandler:completionHandler];
    } else {
        if (completionHandler) {
            completionHandler(request);
        }
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential *credential))completionHandler {

    // Identify the operation that runs this task and pass it the delegate method
    SDWebImageDownloaderOperation *dataOperation = [self operationWithTask:task];
    if ([dataOperation respondsToSelector:@selector(URLSession:task:didReceiveChallenge:completionHandler:)]) {
        [dataOperation URLSession:session task:task didReceiveChallenge:challenge completionHandler:completionHandler];
    } else {
        if (completionHandler) {
            completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        }
    }
}

@end
/*
 主要使用了自定义NSOperation子类，并在这个自定义NSOperation子类中通过一个可用的NSURLSession来创建一个执行服务器交互数据的NSURLSessionDataTask的下载任务，并由其全权负责下载工作，接着使用NSOperationQueue实现多线程的多图片下载。源码中值得我们学习的地方有很多，比如，在设计第三方库时要设计全面的通知，为了防止竞争条件可以使用一个串行队列或是barrier方法来执行一些可能会产生多线程异常的代码
 */
