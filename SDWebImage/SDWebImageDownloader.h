/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 SDWebImageDownloaderOperation是如何自定义NSOperation子类以及如何使用NSURLSession实现下载的，本文将会讲解SDWebImageDownloader类，来探索SDWebImage如何实现多线程下载多张图片的。
 */

#import <Foundation/Foundation.h>
#import "SDWebImageCompat.h"
#import "SDWebImageOperation.h"
//下载选项设置的一系列枚举
typedef NS_OPTIONS(NSUInteger, SDWebImageDownloaderOptions) {
    /**
     * Put the download in the low queue priority and task priority.
     */
    SDWebImageDownloaderLowPriority = 1 << 0,
    
    /**
     * This flag enables progressive download, the image is displayed progressively during download as a browser would do.
     */
    SDWebImageDownloaderProgressiveDownload = 1 << 1,

    /**
     * By default, request prevent the use of NSURLCache. With this flag, NSURLCache
     * is used with default policies.
     */
    SDWebImageDownloaderUseNSURLCache = 1 << 2,

    /**
     * Call completion block with nil image/imageData if the image was read from NSURLCache
     * (to be combined with `SDWebImageDownloaderUseNSURLCache`).
     */
    SDWebImageDownloaderIgnoreCachedResponse = 1 << 3,
    
    /**
     * In iOS 4+, continue the download of the image if the app goes to background. This is achieved by asking the system for
     * extra time in background to let the request finish. If the background task expires the operation will be cancelled.
     */
    SDWebImageDownloaderContinueInBackground = 1 << 4,

    /**
     * Handles cookies stored in NSHTTPCookieStore by setting 
     * NSMutableURLRequest.HTTPShouldHandleCookies = YES;
     */
    SDWebImageDownloaderHandleCookies = 1 << 5,

    /**
     * Enable to allow untrusted SSL certificates.
     * Useful for testing purposes. Use with caution in production.
     */
    SDWebImageDownloaderAllowInvalidSSLCertificates = 1 << 6,

    /**
     * Put the download in the high queue priority and task priority.
     */
    SDWebImageDownloaderHighPriority = 1 << 7,
    
    /**
     * Scale down the image
     */
    SDWebImageDownloaderScaleDownLargeImages = 1 << 8,
};
//下载图片时的顺序，FIFO或者LIFO
typedef NS_ENUM(NSInteger, SDWebImageDownloaderExecutionOrder) {
    /**
     * Default value. All download operations will execute in queue style (first-in-first-out).
     */
    SDWebImageDownloaderFIFOExecutionOrder,

    /**
     * All download operations will execute in stack style (last-in-first-out).
     */
    SDWebImageDownloaderLIFOExecutionOrder
};
//声明通知的全局变量名
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadStartNotification;
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadStopNotification;
//进度回调块
typedef void(^SDWebImageDownloaderProgressBlock)(NSInteger receivedSize, NSInteger expectedSize, NSURL * _Nullable targetURL);
//下载完成的回调块
typedef void(^SDWebImageDownloaderCompletedBlock)(UIImage * _Nullable image, NSData * _Nullable data, NSError * _Nullable error, BOOL finished);
//http首部数据字典
typedef NSDictionary<NSString *, NSString *> SDHTTPHeadersDictionary;
//http首部可变数据字典
typedef NSMutableDictionary<NSString *, NSString *> SDHTTPHeadersMutableDictionary;
//http首部过滤的一个回调块
typedef SDHTTPHeadersDictionary * _Nullable (^SDWebImageDownloaderHeadersFilterBlock)(NSURL * _Nullable url, SDHTTPHeadersDictionary * _Nullable headers);

/**
 *  A token associated with each download. Can be used to cancel a download
 自定义token类，用于取消下载任务
 这个token第二个属性其实就是SDWebImageDownloaderOperation中使用的token即回调块的字典
 目的相同，都是为了取消特定的下载任务
 */
@interface SDWebImageDownloadToken : NSObject <SDWebImageOperation>

/**
 The download's URL. This should be readonly and you should not modify
 */
@property (nonatomic, strong, nullable) NSURL *url;
/**
 The cancel token taken from `addHandlersForProgress:completed`. This should be readonly and you should not modify
 @note use `-[SDWebImageDownloadToken cancel]` to cancel the token
 */
@property (nonatomic, strong, nullable) id downloadOperationCancelToken;

@end


/**
 * Asynchronous downloader dedicated and optimized for image loading.
 //异步下载图片
 */
@interface SDWebImageDownloader : NSObject

/**
 * Decompressing images that are downloaded and cached can improve performance but can consume lot of memory.
 * Defaults to YES. Set this to NO if you are experiencing a crash due to excessive memory consumption.
 //是否压缩图片
 */
@property (assign, nonatomic) BOOL shouldDecompressImages;

/**
 *  The maximum number of concurrent downloads
 //支持的最大同时下载图片的数量，其实就是NSOperationQueue支持的最大并发数
 */
@property (assign, nonatomic) NSInteger maxConcurrentDownloads;

/**
 * Shows the current amount of downloads that still need to be downloaded
 //当前正在下载图片的数量，其实就是NSOperationQueue的operationCount即正在执行下载任务的operation的数量
 */
@property (readonly, nonatomic) NSUInteger currentDownloadCount;

/**
 *  The timeout value (in seconds) for the download operation. Default: 15.0.
 //下载时连接服务器的超时时间，默认15s
 */
@property (assign, nonatomic) NSTimeInterval downloadTimeout;

/**
 * The configuration in use by the internal NSURLSession.
 * Mutating this object directly has no effect.
 *
 * @see createNewSessionWithConfiguration:
 //session运行模式，默认使用默认模式，即 defaultSessionConfiguration
 */
@property (readonly, nonatomic, nonnull) NSURLSessionConfiguration *sessionConfiguration;


/**
 * Changes download operations execution order. Default value is `SDWebImageDownloaderFIFOExecutionOrder`.
//执行下载任务的顺序，FIFO或LIFO
 */
@property (assign, nonatomic) SDWebImageDownloaderExecutionOrder executionOrder;

/**
 *  Singleton method, returns the shared instance
 *
 *  @return global shared instance of downloader class
 //类方法，获取全局共享的单例对象
 */
+ (nonnull instancetype)sharedDownloader;

/**
 *  Set the default URL credential to be set for request operations.
 //默认的URL credential
 */
@property (strong, nonatomic, nullable) NSURLCredential *urlCredential;

/**
 * Set username
 //用户名，有些图片下载的地址需要做用户认证
 */
@property (strong, nonatomic, nullable) NSString *username;

/**
 * Set password
 //密码
 */
@property (strong, nonatomic, nullable) NSString *password;

/**
 * Set filter to pick headers for downloading image HTTP request.
 *
 * This block will be invoked for each downloading image request, returned
 * NSDictionary will be used as headers in corresponding HTTP request.
 //过滤http首部的回调块
 */
@property (nonatomic, copy, nullable) SDWebImageDownloaderHeadersFilterBlock headersFilter;

/**
 * Creates an instance of a downloader with specified session configuration.
 * @note `timeoutIntervalForRequest` is going to be overwritten.
 * @return new instance of downloader class
 //初始化方法，不使用全局共享的downloader时创建
 */
- (nonnull instancetype)initWithSessionConfiguration:(nullable NSURLSessionConfiguration *)sessionConfiguration NS_DESIGNATED_INITIALIZER;

/**
 * Set a value for a HTTP header to be appended to each download HTTP request.
 *
 * @param value The value for the header field. Use `nil` value to remove the header.
 * @param field The name of the header field to set.
 //为http首部设置值
 */
- (void)setValue:(nullable NSString *)value forHTTPHeaderField:(nullable NSString *)field;

/**
 * Returns the value of the specified HTTP header field.
 *
 * @return The value associated with the header field field, or `nil` if there is no corresponding header field.
 //返回http首部的值
 */
- (nullable NSString *)valueForHTTPHeaderField:(nullable NSString *)field;

/**
 * Sets a subclass of `SDWebImageDownloaderOperation` as the default
 * `NSOperation` to be used each time SDWebImage constructs a request
 * operation to download an image.
 *
 * @param operationClass The subclass of `SDWebImageDownloaderOperation` to set 
 *        as default. Passing `nil` will revert to `SDWebImageDownloaderOperation`.
 //设置下载类的Class，默认使用SDWebImageDownloaderOperation，开发者可以自定义只需实现相关协议
 */
- (void)setOperationClass:(nullable Class)operationClass;

/**
 * Creates a SDWebImageDownloader async downloader instance with a given URL
 *
 * The delegate will be informed when the image is finish downloaded or an error has happen.
 *
 * @see SDWebImageDownloaderDelegate
 *
 * @param url            The URL to the image to download
 * @param options        The options to be used for this download
 * @param progressBlock  A block called repeatedly while the image is downloading
 *                       @note the progress block is executed on a background queue
 * @param completedBlock A block called once the download is completed.
 *                       If the download succeeded, the image parameter is set, in case of error,
 *                       error parameter is set with the error. The last parameter is always YES
 *                       if SDWebImageDownloaderProgressiveDownload isn't use. With the
 *                       SDWebImageDownloaderProgressiveDownload option, this block is called
 *                       repeatedly with the partial image object and the finished argument set to NO
 *                       before to be called a last time with the full image and finished argument
 *                       set to YES. In case of error, the finished argument is always YES.
 *
 * @return A token (SDWebImageDownloadToken) that can be passed to -cancel: to cancel this operation
 下载url对应的图片
 设置下载配置选项、进度回调块、下载完成回调块
 返回一个token，用于取消对应的下载任务
 */
- (nullable SDWebImageDownloadToken *)downloadImageWithURL:(nullable NSURL *)url
                                                   options:(SDWebImageDownloaderOptions)options
                                                  progress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                                                 completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;

/**
 * Cancels a download that was previously queued using -downloadImageWithURL:options:progress:completed:
 *
 * @param token The token received from -downloadImageWithURL:options:progress:completed: that should be canceled.
 //取消下载任务，需要传入上面创建下载任务时返回的token
 */
- (void)cancel:(nullable SDWebImageDownloadToken *)token;

/**
 * Sets the download queue suspension state
 //设置下载队列NSOperationQueue挂起
 */
- (void)setSuspended:(BOOL)suspended;

/**
 * Cancels all download operations in the queue
 //设置取消NSOperationQueue队列中的所有下载任务
 */
- (void)cancelAllDownloads;

/**
 * Forces SDWebImageDownloader to create and use a new NSURLSession that is
 * initialized with the given configuration.
 * @note All existing download operations in the queue will be cancelled.
 * @note `timeoutIntervalForRequest` is going to be overwritten.
 *
 * @param sessionConfiguration The configuration to use for the new NSURLSession
 //要求downloader使用特定运行模式创建一个NSURLSession对象
 */
- (void)createNewSessionWithConfiguration:(nonnull NSURLSessionConfiguration *)sessionConfiguration;

/**
 * Invalidates the managed session, optionally canceling pending operations.
 * @note If you use custom downloader instead of the shared downloader, you need call this method when you do not use it to avoid memory leak
 * @param cancelPendingOperations Whether or not to cancel pending operations.
 * @note Calling this method on the shared downloader has no effect.
 */
- (void)invalidateSessionAndCancel:(BOOL)cancelPendingOperations;

@end
