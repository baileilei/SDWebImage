/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import <Foundation/Foundation.h>
#import "SDWebImageDownloader.h"
#import "SDWebImageOperation.h"

//声明一系列通知的名称
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadStartNotification;
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadReceiveResponseNotification;
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadStopNotification;
FOUNDATION_EXPORT NSString * _Nonnull const SDWebImageDownloadFinishNotification;



/**
 SDWebImageDownloaderOperationInterface协议
 开发者可以实现自己的下载操作只需要实现该协议即可
 Describes a downloader operation. If one wants to use a custom downloader op, it needs to inherit from `NSOperation` and conform to this protocol
 For the description about these methods, see `SDWebImageDownloaderOperation`
 */
@protocol SDWebImageDownloaderOperationInterface<NSObject>
//初始化函数，根据指定的request、session和下载选项创建一个下载任务
- (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
                              inSession:(nullable NSURLSession *)session
                                options:(SDWebImageDownloaderOptions)options;
//添加进度和完成后的回调块
- (nullable id)addHandlersForProgress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                            completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;

//是否压缩图片的setter和getter
- (BOOL)shouldDecompressImages;
- (void)setShouldDecompressImages:(BOOL)value;

//NSURLCredential的setter和getetr
- (nullable NSURLCredential *)credential;
- (void)setCredential:(nullable NSURLCredential *)value;

- (BOOL)cancel:(nullable id)token;

@end

/*
 SDWebImageDownloaderOperation类继承自NSOperation
 并遵守了四个协议
 SDWebImageOperation协议只有一个cancel方法
 */
@interface SDWebImageDownloaderOperation : NSOperation <SDWebImageDownloaderOperationInterface, SDWebImageOperation, NSURLSessionTaskDelegate, NSURLSessionDataDelegate>

/**
 * The request used by the operation's task.//下载任务的request
 */
@property (strong, nonatomic, readonly, nullable) NSURLRequest *request;

/**
 * The operation's task//执行下载操作的下载任务
 */
@property (strong, nonatomic, readonly, nullable) NSURLSessionTask *dataTask;

/*
 是否压缩图片
 上面的协议需要实现这个属性的getter和setter方法
 只需要声明一个属性就可以遵守上面两个方法了
 */
@property (assign, nonatomic) BOOL shouldDecompressImages;

/**
 *  Was used to determine whether the URL connection should consult the credential storage for authenticating the connection.
 *  @deprecated Not used for a couple of versions
 */
@property (nonatomic, assign) BOOL shouldUseCredentialStorage __deprecated_msg("Property deprecated. Does nothing. Kept only for backwards compatibility");

/**
 * The credential used for authentication challenges in `-URLSession:task:didReceiveChallenge:completionHandler:`.
 *
 * This will be overridden by any shared credentials that exist for the username or password of the request URL, if present.//https需要使用的凭证
 */
@property (nonatomic, strong, nullable) NSURLCredential *credential;

/**
 * The SDWebImageDownloaderOptions for the receiver.//下载时配置的相关内容
 */
@property (assign, nonatomic, readonly) SDWebImageDownloaderOptions options;

/**
 * The expected size of data.//需要下载的文件的大小
 */
@property (assign, nonatomic) NSInteger expectedSize;

/**
 * The response returned by the operation's task.//连接服务端后的收到的响应
 */
@property (strong, nonatomic, nullable) NSURLResponse *response;

/**
 *  Initializes a `SDWebImageDownloaderOperation` object
 *
 *  @see SDWebImageDownloaderOperation
 *
 *  @param request        the URL request
 *  @param session        the URL session in which this operation will run
 *  @param options        downloader options
 *
 *  @return the initialized instance //初始化方法需要下载文件的request、session以及下载相关配置选项
 */
- (nonnull instancetype)initWithRequest:(nullable NSURLRequest *)request
                              inSession:(nullable NSURLSession *)session
                                options:(SDWebImageDownloaderOptions)options NS_DESIGNATED_INITIALIZER;

/**
 *  Adds handlers for progress and completion. Returns a tokent that can be passed to -cancel: to cancel this set of
 *  callbacks.
 *
 *  @param progressBlock  the block executed when a new chunk of data arrives.
 *                        @note the progress block is executed on a background queue
 *  @param completedBlock the block executed when the download is done.
 *                        @note the completed block is executed on the main queue for success. If errors are found, there is a chance the block will be executed on a background queue
 *
 *  @return the token to use to cancel this set of handlers
 添加一个进度回调块和下载完成后的回调块
 返回一个token，用于取消这个下载任务，这个token其实是一个字典，后文会讲
 */
- (nullable id)addHandlersForProgress:(nullable SDWebImageDownloaderProgressBlock)progressBlock
                            completed:(nullable SDWebImageDownloaderCompletedBlock)completedBlock;

/**
 *  Cancels a set of callbacks. Once all callbacks are canceled, the operation is cancelled.
 *
 *  @param token the token representing a set of callbacks to cancel
 *
 *  @return YES if the operation was stopped because this was the last token to be canceled. NO otherwise.
 这个方法不是用来取消下载任务的，而是删除前一个方法添加的进度回调块和下载完成回调块
 当所有的回调块都删除后，下载任务也会被取消，具体实现在.m文件中有讲解
 需要传入上一个方法返回的token，即回调块字典
 */
- (BOOL)cancel:(nullable id)token;

@end
/*
 上述头文件声明中定义了一个协议，开发者就可以不使用SDWebImage提供的下载任务类，而可以自定义相关类，只需要遵守协议即可，SDWebImageDownloaderOperation类也遵守了该协议，该类继承自NSOperation主要是为了将任务加进并发队列里实现多线程下载多张图片，真正实现下载操作的是NSURLSessionTask类的子类，
 
 作者：WWWWDotPNG
 链接：https://www.jianshu.com/p/fadcb1749846
 来源：简书
 简书著作权归作者所有，任何形式的转载都请联系作者获得授权并注明出处。
 */
