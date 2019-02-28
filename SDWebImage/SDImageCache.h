/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 NSCache是Foundation框架提供的缓存类的实现，使用方式类似于可变字典，由于NSMutableDictionary的存在，很多人在实现缓存时都会使用可变字典，但NSCache在实现缓存功能时比可变字典更方便，最重要的是它是线程安全的，而NSMutableDictionary不是线程安全的，在多线程环境下使用NSCache是更好的选择。
 
 * 使用NSMutableDictionary自定义实现缓存时需要考虑加锁和释放锁
 * NSCache的键key不会被复制，所以key不需要实现NSCopying协议。
 */

#import <Foundation/Foundation.h>
#import "SDWebImageCompat.h"
#import "SDImageCacheConfig.h"
//获取图片的方式类别枚举
typedef NS_ENUM(NSInteger, SDImageCacheType) {
    /**
     * The image wasn't available the SDWebImage caches, but was downloaded from the web.
     //不是从缓存中拿到的，从网上下载的
     */
    SDImageCacheTypeNone,
    /**
     * The image was obtained from the disk cache.
     //从磁盘中获取的
     */
    SDImageCacheTypeDisk,
    /**
     * The image was obtained from the memory cache.
     //从内存中获取的
     */
    SDImageCacheTypeMemory
};

typedef NS_OPTIONS(NSUInteger, SDImageCacheOptions) {
    /**
     * By default, we do not query disk data when the image is cached in memory. This mask can force to query disk data at the same time.
     */
    SDImageCacheQueryDataWhenInMemory = 1 << 0,
    /**
     * By default, we query the memory cache synchronously, disk cache asynchronously. This mask can force to query disk cache synchronously.
     */
    SDImageCacheQueryDiskSync = 1 << 1
};
//查找缓存完成后的回调块
typedef void(^SDCacheQueryCompletedBlock)(UIImage * _Nullable image, NSData * _Nullable data, SDImageCacheType cacheType);
//在缓存中根据指定key查找图片的回调块
typedef void(^SDWebImageCheckCacheCompletionBlock)(BOOL isInCache);
//计算磁盘缓存图片个数和占用内存大小的回调块
typedef void(^SDWebImageCalculateSizeBlock)(NSUInteger fileCount, NSUInteger totalSize);


/**
 * SDImageCache maintains a memory cache and an optional disk cache. Disk cache write operations are performed
 * asynchronous so it doesn’t add unnecessary latency to the UI.
 SDWebImage真正执行缓存的类
 SDImageCache支持内存缓存，默认也可以进行磁盘存储，也可以选择不进行磁盘存储
 */
@interface SDImageCache : NSObject

#pragma mark - Properties

/**
 *  Cache Config object - storing all kind of settings
 //SDImageCacheConfig对象，缓存策略的配置
 */
@property (nonatomic, nonnull, readonly) SDImageCacheConfig *config;

/**
 * The maximum "total cost" of the in-memory image cache. The cost function is the number of pixels held in memory.
 //内存缓存的最大cost，以像素为单位，后面有具体计算方法  NSCache的totalCostLimit
 */
@property (assign, nonatomic) NSUInteger maxMemoryCost;

/**
 * The maximum number of objects the cache should hold.
 //内存缓存，缓存对象的最大个数  NSCache的countLimit
 */
@property (assign, nonatomic) NSUInteger maxMemoryCountLimit;

#pragma mark - Singleton and initialization

/**
 * Returns global shared cache instance
 *
 * @return SDImageCache global instance
 */
+ (nonnull instancetype)sharedImageCache;

/**
 * Init a new cache store with a specific namespace
 *
 * @param ns The namespace to use for this cache store
 初始化方法，根据指定的namespace创建一个SDImageCache类的对象
 这个namespace默认值是default
 主要用于磁盘缓存时创建文件夹时作为其名称使用
 */
- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns;

/**
 * Init a new cache store with a specific namespace and directory
 *
 * @param ns        The namespace to use for this cache store
 * @param directory Directory to cache disk images in
 //初始化方法，根据指定namespace以及磁盘缓存的文件夹路径来创建一个SDImageCache的对象
 */
- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns
                       diskCacheDirectory:(nonnull NSString *)directory NS_DESIGNATED_INITIALIZER;

#pragma mark - Cache paths
//根据fullNamespace构造一个磁盘缓存的文件夹路径
- (nullable NSString *)makeDiskCachePath:(nonnull NSString*)fullNamespace;

/**
 * Add a read-only cache path to search for images pre-cached by SDImageCache
 * Useful if you want to bundle pre-loaded images with your app
 *
 * @param path The path to use for this read-only cache path
 添加一个只读的缓存路径，以后在查找磁盘缓存时也会从这个路径中查找
 主要用于查找提前添加的图片
 */
- (void)addReadOnlyCachePath:(nonnull NSString *)path;

#pragma mark - Store Ops

/**
 * Asynchronously store an image into memory and disk cache at the given key.
 *
 * @param image           The image to store
 * @param key             The unique image cache key, usually it's image absolute URL
 * @param completionBlock A block executed after the operation is finished
 根据给定的key异步存储图片
 image 要存储的图片
 key 一张图片的唯一ID，一般使用图片的URL
 completionBlock 完成异步存储后的回调块
 该方法并不执行任何实际的操作，而是直接调用下面的下面的那个方法
 */
- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
        completion:(nullable SDWebImageNoParamsBlock)completionBlock;

/**
 * Asynchronously store an image into memory and disk cache at the given key.
 *
 * @param image           The image to store
 * @param key             The unique image cache key, usually it's image absolute URL
 * @param toDisk          Store the image to disk cache if YES
 * @param completionBlock A block executed after the operation is finished
 同上，该方法并不是真正的执行者，而是需要调用下面的那个方法
 根据给定的key异步存储图片
 image 要存储的图片
 key 唯一ID，一般使用URL
 toDisk 是否缓存到磁盘中
 completionBlock 缓存完成后的回调块
 */
- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock;

/**
 * Asynchronously store an image into memory and disk cache at the given key.
 *
 * @param image           The image to store
 * @param imageData       The image data as returned by the server, this representation will be used for disk storage
 *                        instead of converting the given image object into a storable/compressed image format in order
 *                        to save quality and CPU
 * @param key             The unique image cache key, usually it's image absolute URL
 * @param toDisk          Store the image to disk cache if YES
 * @param completionBlock A block executed after the operation is finished
 根据给定的key异步存储图片，真正的缓存执行者
 image 要存储的图片
 imageData 要存储的图片的二进制数据即NSData数据
 key 唯一ID，一般使用URL
 toDisk 是否缓存到磁盘中
 completionBlock
 */
- (void)storeImage:(nullable UIImage *)image
         imageData:(nullable NSData *)imageData
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock;

/**
 * Synchronously store image NSData into disk cache at the given key.
 *
 * @warning This method is synchronous, make sure to call it from the ioQueue
 *
 * @param imageData  The image data to store
 * @param key        The unique image cache key, usually it's image absolute URL
 根据指定key同步存储NSData类型的图片的数据到磁盘中
 这是一个同步的方法，需要放在指定的ioQueue中执行，指定的ioQueue在下面会讲
 imageData 图片的二进制数据即NSData类型的对象
 key 图片的唯一ID，一般使用URL
 */
- (void)storeImageDataToDisk:(nullable NSData *)imageData forKey:(nullable NSString *)key;
/*
 提供了内存缓存和磁盘缓存的不同存储方式方法，提供了不同的接口，但真正执行的方法只有一个，这样的设计方式值得我们学习。
 */
#pragma mark - Query and Retrieve Ops

/**
 *  Async check if image exists in disk cache already (does not load the image)
 *
 *  @param key             the key describing the url
 *  @param completionBlock the block to be executed when the check is done.
 *  @note the completion block will be always executed on the main queue
 */
- (void)diskImageExistsWithKey:(nullable NSString *)key completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock;

/**
 *  Sync check if image data exists in disk cache already (does not load the image)
 *
 *  @param key             the key describing the url
 */
- (BOOL)diskImageDataExistsWithKey:(nullable NSString *)key;

/**
 * Operation that queries the cache asynchronously and call the completion when done.
 *
 * @param key       The unique key used to store the wanted image
 * @param doneBlock The completion block. Will not get called if the operation is cancelled
 *
 * @return a NSOperation instance containing the cache op
 异步方式根据指定的key查询磁盘中是否缓存了这个图片
 key 图片的唯一ID，一般使用URL
 completionBlock 查询完成后的回调块，这个回调块默认会在主线程中执行
 */
- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key done:(nullable SDCacheQueryCompletedBlock)doneBlock;

/**
 * Operation that queries the cache asynchronously and call the completion when done.
 *
 * @param key       The unique key used to store the wanted image
 * @param options   A mask to specify options to use for this cache query
 * @param doneBlock The completion block. Will not get called if the operation is cancelled
 *
 * @return a NSOperation instance containing the cache op
 */
- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key options:(SDImageCacheOptions)options done:(nullable SDCacheQueryCompletedBlock)doneBlock;

/**
 * Query the memory cache synchronously.
 *
 * @param key The unique key used to store the image
 同步查询内存缓存中是否有ID为key的图片
 key 图片的唯一ID，一般使用URL
 */
- (nullable UIImage *)imageFromMemoryCacheForKey:(nullable NSString *)key;

/**
 * Query the disk cache synchronously.
 *
 * @param key The unique key used to store the image
 同步查询磁盘缓存中是否有ID为key的图片
 key 图片的唯一ID，一般使用URL
 */
- (nullable UIImage *)imageFromDiskCacheForKey:(nullable NSString *)key;

/**
 * Query the cache (memory and or disk) synchronously after checking the memory cache.
 *
 * @param key The unique key used to store the image
 同步查询内存缓存和磁盘缓存中是否有ID为key的图片
 key 图片的唯一ID，一般使用URL
 */
- (nullable UIImage *)imageFromCacheForKey:(nullable NSString *)key;

#pragma mark - Remove Ops

/**
 * Remove the image from memory and disk cache asynchronously
 *
 * @param key             The unique image cache key
 * @param completion      A block that should be executed after the image has been removed (optional)
 根据给定key异步方式删除缓存
 key 图片的唯一ID，一般使用URL
 completion 操作完成后的回调块
 */
- (void)removeImageForKey:(nullable NSString *)key withCompletion:(nullable SDWebImageNoParamsBlock)completion;

/**
 * Remove the image from memory and optionally disk cache asynchronously
 *
 * @param key             The unique image cache key
 * @param fromDisk        Also remove cache entry from disk if YES
 * @param completion      A block that should be executed after the image has been removed (optional)
 根据给定key异步方式删除内存中的缓存
 key 图片的唯一ID，一般使用URL
 fromDisk 是否删除磁盘中的缓存，如果为YES那也会删除磁盘中的缓存
 completion 操作完成后的回调块
 */
- (void)removeImageForKey:(nullable NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(nullable SDWebImageNoParamsBlock)completion;

#pragma mark - Cache clean Ops

/**
 * Clear all memory cached images
 //删除所有的内存缓存，即NSCache中的removeAllObjects
 */
- (void)clearMemory;

/**
 * Async clear all disk cached images. Non-blocking method - returns immediately.
 * @param completion    A block that should be executed after cache expiration completes (optional)
 异步方式清空磁盘中的所有缓存
 completion 删除完成后的回调块
 */
- (void)clearDiskOnCompletion:(nullable SDWebImageNoParamsBlock)completion;

/**
 * Async remove all expired cached image from disk. Non-blocking method - returns immediately.
 * @param completionBlock A block that should be executed after cache expiration completes (optional)
 异步删除磁盘缓存中所有超过缓存最大时间的图片，即前面属性中的maxCacheAge
 completionBlock 删除完成后的回调块
 */
- (void)deleteOldFilesWithCompletionBlock:(nullable SDWebImageNoParamsBlock)completionBlock;

#pragma mark - Cache Info

/**
 * Get the size used by the disk cache
 //获取磁盘缓存占用的存储空间大小，单位是字节
 */
- (NSUInteger)getSize;

/**
 * Get the number of images in the disk cache
 //获取磁盘缓存了多少张图片
 */
- (NSUInteger)getDiskCount;

/**
 * Asynchronously calculate the disk cache's size.
 异步方式计算磁盘缓存占用的存储空间大小，单位是字节
 completionBlock 计算完成后的回调块
 */
- (void)calculateSizeWithCompletionBlock:(nullable SDWebImageCalculateSizeBlock)completionBlock;

#pragma mark - Cache Paths

/**
 *  Get the cache path for a certain key (needs the cache path root folder)
 *
 *  @param key  the key (can be obtained from url using cacheKeyForURL)
 *  @param path the cache path root folder
 *
 *  @return the cache path
 根据图片的key以及一个存储文件夹路径，构造一个在本地的图片的路径
 key 图片的唯一ID，一般使用URL
 inPath 本地存储图片的文件夹的路径
 比如:图片URL是http:www.baidu.com/test.png inPath是/usr/local/，那么图片存储到本地后的路径为:/usr/local/test.png
 */
- (nullable NSString *)cachePathForKey:(nullable NSString *)key inPath:(nonnull NSString *)path;

/**
 *  Get the default cache path for a certain key
 *
 *  @param key the key (can be obtained from url using cacheKeyForURL)
 *
 *  @return the default cache path
 根据图片的key获取一个默认的缓存在本地的路径
 key 图片的唯一ID，一般使用URL
 */
- (nullable NSString *)defaultCachePathForKey:(nullable NSString *)key;
//上面几个方法是用来构造图片保存到磁盘中的路径的功能。

@end
