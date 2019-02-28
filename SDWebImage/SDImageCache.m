/*
 * This file is part of the SDWebImage package.
 * (c) Olivier Poitrey <rs@dailymotion.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 */

#import "SDImageCache.h"
#import <CommonCrypto/CommonDigest.h>
#import "NSImage+WebCache.h"
#import "SDWebImageCodersManager.h"

#define LOCK(lock) dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
#define UNLOCK(lock) dispatch_semaphore_signal(lock);

FOUNDATION_STATIC_INLINE NSUInteger SDCacheCostForImage(UIImage *image) {
#if SD_MAC
    return image.size.height * image.size.width;
#elif SD_UIKIT || SD_WATCH
    return image.size.height * image.size.width * image.scale * image.scale;
#endif
}

// A memory cache which auto purge the cache on memory warning and support weak cache.
@interface SDMemoryCache <KeyType, ObjectType> : NSCache <KeyType, ObjectType>

@end

// Private
@interface SDMemoryCache <KeyType, ObjectType> ()

@property (nonatomic, strong, nonnull) NSMapTable<KeyType, ObjectType> *weakCache; // strong-weak cache
@property (nonatomic, strong, nonnull) dispatch_semaphore_t weakCacheLock; // a lock to keep the access to `weakCache` thread-safe

@end

@implementation SDMemoryCache

// Current this seems no use on macOS (macOS use virtual memory and do not clear cache when memory warning). So we only override on iOS/tvOS platform.
// But in the future there may be more options and features for this subclass.
#if SD_UIKIT

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // Use a strong-weak maptable storing the secondary cache. Follow the doc that NSCache does not copy keys
        // This is useful when the memory warning, the cache was purged. However, the image instance can be retained by other instance such as imageViews and alive.
        // At this case, we can sync weak cache back and do not need to load from disk cache
        self.weakCache = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory valueOptions:NSPointerFunctionsWeakMemory capacity:0];
        self.weakCacheLock = dispatch_semaphore_create(1);
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(didReceiveMemoryWarning:)
                                                     name:UIApplicationDidReceiveMemoryWarningNotification
                                                   object:nil];
    }
    return self;
}

- (void)didReceiveMemoryWarning:(NSNotification *)notification {
    // Only remove cache, but keep weak cache
    [super removeAllObjects];
}

// `setObject:forKey:` just call this with 0 cost. Override this is enough
- (void)setObject:(id)obj forKey:(id)key cost:(NSUInteger)g {
    [super setObject:obj forKey:key cost:g];
    if (key && obj) {
        // Store weak cache
        LOCK(self.weakCacheLock);
        [self.weakCache setObject:obj forKey:key];
        UNLOCK(self.weakCacheLock);
    }
}

- (id)objectForKey:(id)key {
    id obj = [super objectForKey:key];
    if (key && !obj) {
        // Check weak cache
        LOCK(self.weakCacheLock);
        obj = [self.weakCache objectForKey:key];
        UNLOCK(self.weakCacheLock);
        if (obj) {
            // Sync cache
            NSUInteger cost = 0;
            if ([obj isKindOfClass:[UIImage class]]) {
                cost = SDCacheCostForImage(obj);
            }
            [super setObject:obj forKey:key cost:cost];
        }
    }
    return obj;
}

- (void)removeObjectForKey:(id)key {
    [super removeObjectForKey:key];
    if (key) {
        // Remove weak cache
        LOCK(self.weakCacheLock);
        [self.weakCache removeObjectForKey:key];
        UNLOCK(self.weakCacheLock);
    }
}

- (void)removeAllObjects {
    [super removeAllObjects];
    // Manually remove should also remove weak cache
    LOCK(self.weakCacheLock);
    [self.weakCache removeAllObjects];
    UNLOCK(self.weakCacheLock);
}

#endif

@end

@interface SDImageCache ()

#pragma mark - Properties
//缓存对象
@property (strong, nonatomic, nonnull) SDMemoryCache *memCache;//真正进行内存缓存的对象。
//磁盘缓存的路径
@property (strong, nonatomic, nonnull) NSString *diskCachePath;
//自定义缓存查询路径，即前面add*方法添加的路径，都添加到这个数组中
@property (strong, nonatomic, nullable) NSMutableArray<NSString *> *customPaths;
//专门用来执行IO操作的队列，这是一个串行队列
//使用串行队列就解决了很多问题，串行队列依次执行就不需要加锁释放锁操作来防止多线程下的异常问题
@property (strong, nonatomic, nullable) dispatch_queue_t ioQueue;
@property (strong, nonatomic, nonnull) NSFileManager *fileManager;

@end


@implementation SDImageCache

#pragma mark - Singleton, init, dealloc

+ (nonnull instancetype)sharedImageCache {
    static dispatch_once_t once;
    static id instance;
    dispatch_once(&once, ^{
        instance = [self new];
    });
    return instance;
}
/*
 默认构造函数，调用initWithNamespace:执行初始化操作
 默认的namespace为default，这个属性就是用来创建一个磁盘缓存存储文件夹
 */
- (instancetype)init {
    return [self initWithNamespace:@"default"];
}
//根据指定的namespace构造一个磁盘缓存的存储路径后调用initWithNamespace:diskCacheDirectory方法完成后续的初始化操作
- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns {
    /*
     makeDiskCachePath的目的是为了创建一个磁盘缓存存储图片的文件夹
     获取一个系统沙盒的cache目录下名称为ns的文件夹的路径
     比如:/usr/local/cache/default
     所以namespace的作用就是为了在沙盒的cache目录下创建一个文件夹时作为它的名称，以后去磁盘中查找时就有路径了
     */
    NSString *path = [self makeDiskCachePath:ns];
    return [self initWithNamespace:ns diskCacheDirectory:path];
}
/*
 真正执行初始化操作的构造函数
 ns 即namespace
 directory 即磁盘缓存存储图片的文件夹路径
 */
- (nonnull instancetype)initWithNamespace:(nonnull NSString *)ns
                       diskCacheDirectory:(nonnull NSString *)directory {
    if ((self = [super init])) {
        //构造一个全限定名的namespace
        NSString *fullNamespace = [@"com.hackemist.SDWebImageCache." stringByAppendingString:ns];
        
        // Create IO serial queue
        //创建一个串行的专门执行IO操作的队列
        _ioQueue = dispatch_queue_create("com.hackemist.SDWebImageCache", DISPATCH_QUEUE_SERIAL);
        //构造一个SDImageCacheConfig对象
        _config = [[SDImageCacheConfig alloc] init];
        
        // Init the memory cache
        //创建一个AutoPurgeCache对象，即NSCache的子类
        _memCache = [[SDMemoryCache alloc] init];
        //指定这个缓存对象的名称为前面的全限定名
        _memCache.name = fullNamespace;

        // Init the disk cache
        //如果传入的磁盘缓存的文件夹路径不为空
        if (directory != nil) {
            //在文件夹路径后面再创建一个文件夹，名称为全限定名名称
            _diskCachePath = [directory stringByAppendingPathComponent:fullNamespace];
        } else {
            //如果传入的磁盘缓存文件夹路径是空的就根据传入的ns获取一个沙盒cache目录下名称为ns的文件夹路径
            NSString *path = [self makeDiskCachePath:ns];
            _diskCachePath = path;
        }
        //同步方法在这个IO队列上进行fileManager的创建工作
        dispatch_sync(_ioQueue, ^{
            self.fileManager = [NSFileManager new];
        });

#if SD_UIKIT
        // Subscribe to app events
 //监听程序即将终止的通知，收到后执行deleteOldFiles方法
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deleteOldFiles)
                                                     name:UIApplicationWillTerminateNotification
                                                   object:nil];
//监听程序进入后台的通知，收到后执行backgroundDeleteOldFiles方法
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(backgroundDeleteOldFiles)
                                                     name:UIApplicationDidEnterBackgroundNotification
                                                   object:nil];
#endif
    }

    return self;
}

- (void)dealloc {
    //移除所有通知的监听器
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Cache paths
//添加只读的用户自行添加的缓存搜索路径
- (void)addReadOnlyCachePath:(nonnull NSString *)path {
    //如果这个路径集合为空就创建一个
    if (!self.customPaths) {
        self.customPaths = [NSMutableArray new];
    }
    //如果路径集合中不包含这个新的路径就添加
    if (![self.customPaths containsObject:path]) {
        [self.customPaths addObject:path];
    }
}
/*
 根据指定的图片的key和指定文件夹路径获取图片存储的绝对路径
 首先通过cachedFileNameForKey:方法根据URL获取一个MD5值作为这个图片的名称
 接着在这个指定路径path后面添加这个MD5名称作为这个图片在磁盘中的绝对路径
 */
- (nullable NSString *)cachePathForKey:(nullable NSString *)key inPath:(nonnull NSString *)path {
    NSString *filename = [self cachedFileNameForKey:key];
    return [path stringByAppendingPathComponent:filename];
}
/*
 该方法与上面的方法一样，内部调用上面的方法
 不过它使用默认的磁盘缓存路径diskCachePath，就是在构造函数中获取的沙盒cache下的一个文件夹的路径
 */
- (nullable NSString *)defaultCachePathForKey:(nullable NSString *)key {
    return [self cachePathForKey:key inPath:self.diskCachePath];
}
/*
 根据图片的key，即URL构造一个MD5串，添加原来的后缀后作为这个图片在磁盘中存储时的名称
 MD5算法保证了不同URL散列出的值不同，也就保证了不同URL图片的名称不同
 具体算法不在本篇博客的讲述范围，有兴趣的读者自行查阅
 */
- (nullable NSString *)cachedFileNameForKey:(nullable NSString *)key {
    const char *str = key.UTF8String;
    if (str == NULL) {
        str = "";
    }
    unsigned char r[CC_MD5_DIGEST_LENGTH];
    CC_MD5(str, (CC_LONG)strlen(str), r);
    NSURL *keyURL = [NSURL URLWithString:key];
    NSString *ext = keyURL ? keyURL.pathExtension : key.pathExtension;
    NSString *filename = [NSString stringWithFormat:@"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%@",
                          r[0], r[1], r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[9], r[10],
                          r[11], r[12], r[13], r[14], r[15], ext.length == 0 ? @"" : [NSString stringWithFormat:@".%@", ext]];
    return filename;
}
/*
 根据给定的fullNamespace构造一个磁盘缓存存储图片的路径
 首先获取了沙盒下的cache目录
 然后将fullNamespace添加进这个路径作为cache下的一个文件夹名称
 */
- (nullable NSString *)makeDiskCachePath:(nonnull NSString*)fullNamespace {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES);
    return [paths[0] stringByAppendingPathComponent:fullNamespace];
}
/*
 上面的一系列方法提供了构造图片存储在磁盘中的绝对路径的功能，主要就是使用MD5算法散列图片的URL来创建图片存储在磁盘的文件名，并且根据namespace构造一个沙盒cache目录下的一个路径。
 */
#pragma mark - Store Ops
//存储图片到缓存，直接调用下面的下面的方法
- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    //使用该方法默认会缓存到磁盘中
    [self storeImage:image imageData:nil forKey:key toDisk:YES completion:completionBlock];
}
//存储图片到缓存，直接调用下面的方法
- (void)storeImage:(nullable UIImage *)image
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    [self storeImage:image imageData:nil forKey:key toDisk:toDisk completion:completionBlock];
}
//真正执行存储操作的方法
- (void)storeImage:(nullable UIImage *)image
         imageData:(nullable NSData *)imageData
            forKey:(nullable NSString *)key
            toDisk:(BOOL)toDisk
        completion:(nullable SDWebImageNoParamsBlock)completionBlock {
    //如果image为nil或image的URL为空直接返回即不执行保存操作
    if (!image || !key) {
        //如果回调块存在就执行完成回调块
        if (completionBlock) {
            completionBlock();
        }
        return;
    }
    // if memory cache is enabled
     //如果缓存策略指明要进行内存缓存
    if (self.config.shouldCacheImagesInMemory) {
         //根据前面的内联函数计算图片的大小作为cost
        NSUInteger cost = SDCacheCostForImage(image);
        //向memCache中添加图片对象，key即图片的URL，cost为上面计算的
        [self.memCache setObject:image forKey:key cost:cost];
    }
    //如果要保存到磁盘中
    if (toDisk) {
        //异步提交任务到串行的ioQueue中执行
        dispatch_async(self.ioQueue, ^{
            //进行磁盘存储的具体的操作，使用@autoreleasepool包围，执行完成后自动释放相关对象
            //我猜测这么做是为了尽快释放产生的局部变量，释放内存
            @autoreleasepool {
                NSData *data = imageData;
                //如果传入的imageData为空，图片不为空
                if (!data && image) {
                    // If we do not have any data to detect image format, check whether it contains alpha channel to use PNG or JPEG format
                    //调用编码方法，获取NSData对象
                    //图片编码为NSData不在本文的讲述范围，可自行查阅
                    SDImageFormat format;
                    if (SDCGImageRefContainsAlpha(image.CGImage)) {
                        format = SDImageFormatPNG;
                    } else {
                        format = SDImageFormatJPEG;
                    }
                    data = [[SDWebImageCodersManager sharedInstance] encodedDataWithImage:image format:format];
                }
                //调用下面的方法用于磁盘存储操作
                [self _storeImageDataToDisk:data forKey:key];
            }
            //存储完成后检查是否存在回调块
            if (completionBlock) {
                //异步提交在主线程中执行回调块
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock();
                });
            }
        });
    //如果不需要保存到磁盘中判断后执行回调块
    } else {
        if (completionBlock) {
            completionBlock();
        }
    }
}
//具体执行磁盘存储的方法
- (void)storeImageDataToDisk:(nullable NSData *)imageData forKey:(nullable NSString *)key {
     //判断图片NSData数据以及图片key是否为空，如果为空直接返回
    if (!imageData || !key) {
        return;
    }
    dispatch_sync(self.ioQueue, ^{
        [self _storeImageDataToDisk:imageData forKey:key];
    });
}

// Make sure to call form io queue by caller
- (void)_storeImageDataToDisk:(nullable NSData *)imageData forKey:(nullable NSString *)key {
    if (!imageData || !key) {
        return;
    }
    //如果构造函数中构造的磁盘缓存存储图片路径的文件夹不存在
    if (![self.fileManager fileExistsAtPath:_diskCachePath]) {
        //那就根据这个路径创建需要的文件夹
        [self.fileManager createDirectoryAtPath:_diskCachePath withIntermediateDirectories:YES attributes:nil error:NULL];
    }
    
    // get cache Path for image key
    // 根据key获取默认磁盘缓存存储路径下的MD5文件名的文件的绝对路径
    // 感觉有点绕口。。就是获取图片二进制文件在磁盘中的绝对路径，名称就是前面使用MD5散列的，路径就是构造函数默认构造的那个路径
    NSString *cachePathForKey = [self defaultCachePathForKey:key];
    // transform to NSUrl
    // 根据这个绝对路径创建一个NSURL对象
    NSURL *fileURL = [NSURL fileURLWithPath:cachePathForKey];
    //使用NSFileManager创建一个文件，文件存储的数据就是imageData
    //到此，图片二进制数据就存储在了磁盘中了
    [imageData writeToURL:fileURL options:self.config.diskCacheWritingOptions error:nil];
    
    // disable iCloud backup
    if (self.config.shouldDisableiCloud) {
        [fileURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
    }
}
/*
 上面就是图片缓存存储的核心方法了，其实看下来感觉也蛮简单的，如果要进行内存缓存就直接添加到memCache对象中，如果要进行磁盘缓存，就构造一个路径，构造一个文件名，然后存储起来就好了。这里面有几个重要的点，首先就是@autoreleasepool的使用，其实这里不添加这个autoreleasepool同样会自动释放内存，但添加后在这个代码块结束后就会立即释放，不会占用太多内存。其次，对于磁盘写入的操作是通过一个指定的串行队列实现的，这样不管执行多少个磁盘存储的操作，都必须一个一个的存储，这样就可以不用编写加锁的操作，可能有读者会疑惑为什么要进行加锁，因为并发情况下这些存储操作都不是线程安全的，很有可能会把路径修改掉或者产生其他异常行为，但使用了串行队列就完全不需要考虑加锁释放锁，一张图片存储完成才可以进行下一张图片存储的操作，这一点值得学习。
 **/

#pragma mark - Query and Retrieve Ops
//异步方式根据key判断磁盘缓存中是否存储了这个图片，查询完成后执行回调块
- (void)diskImageExistsWithKey:(nullable NSString *)key completion:(nullable SDWebImageCheckCacheCompletionBlock)completionBlock {
    //查询操作是异步，也放在指定的串行ioQueue中查询
    dispatch_async(self.ioQueue, ^{
        
        BOOL exists = [self _diskImageDataExistsWithKey:key];
        //查询完成后，如果存在回调块，就在主线程执行回调块并传入exists
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(exists);
            });
        }
    });
}

- (BOOL)diskImageDataExistsWithKey:(nullable NSString *)key {
    if (!key) {
        return NO;
    }
    __block BOOL exists = NO;
    dispatch_sync(self.ioQueue, ^{
        exists = [self _diskImageDataExistsWithKey:key];
    });
    
    return exists;
}

// Make sure to call form io queue by caller
- (BOOL)_diskImageDataExistsWithKey:(nullable NSString *)key {
    if (!key) {
        return NO;
    }
    /*
     调用defualtCachePathForKey:方法获取图片如果在本地存储时的绝对路径
     使用NSFileManager查询这个绝对路径的文件是否存在
     */
    BOOL exists = [self.fileManager fileExistsAtPath:[self defaultCachePathForKey:key]];
    
    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    if (!exists) {//如果不存在
        //再次去掉后缀名查询，这个问题可以自行查看上面git的问题
        exists = [self.fileManager fileExistsAtPath:[self defaultCachePathForKey:key].stringByDeletingPathExtension];
    }
    
    return exists;
}
//查询内存缓存中是否有指定key的缓存数据
- (nullable UIImage *)imageFromMemoryCacheForKey:(nullable NSString *)key {
    //直接调用NSCache的objectForKey:方法查询
    return [self.memCache objectForKey:key];
}
//根据指定的key获取磁盘缓存的图片构造并返回UIImage对象
- (nullable UIImage *)imageFromDiskCacheForKey:(nullable NSString *)key {
    //调用diskImageForKey:方法查询，这个方法下面会讲
    UIImage *diskImage = [self diskImageForKey:key];
    //如果找到了，并且缓存策略使用了内存缓存
    if (diskImage && self.config.shouldCacheImagesInMemory) {
        //计算cost并且将磁盘中获取的图片放入到内存缓存中
        NSUInteger cost = SDCacheCostForImage(diskImage);
        //调用NSCache的setObject:forKey:cost方法设置要缓存的对象
        //之所以要设置是因为如果是第一次从磁盘中拿出此时内存缓存中还没有
        //还有可能是内存缓存中的对象被删除了，然后在磁盘中找到了，此时也需要设置一下
        //setObject:forKey:cost方法的时间复杂度是常量的，所以哪怕内存中有也无所谓
        [self.memCache setObject:diskImage forKey:key cost:cost];
    }

    return diskImage;
}
//查找内存缓存和磁盘缓存中是否有指定key的图片
- (nullable UIImage *)imageFromCacheForKey:(nullable NSString *)key {
    // First check the in-memory cache...
    //首先检查内存缓存中是否有，有就返回，调用了上面的那个方法
    //实际就是执行了NSCache的 objectForKey:方法
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    if (image) {
        return image;
    }
    
    // Second check the disk cache...
    //如果内存缓存中没有再去磁盘中查找
    image = [self imageFromDiskCacheForKey:key];
    return image;
}
//在磁盘中所有的保存路径，包括用户添加的路径中搜索key对应的图片数据
- (nullable NSData *)diskImageDataBySearchingAllPathsForKey:(nullable NSString *)key {
    //首先在默认存储路径中查找，如果有就直接返回
    NSString *defaultPath = [self defaultCachePathForKey:key];
    NSData *data = [NSData dataWithContentsOfFile:defaultPath options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }

    // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
    // checking the key with and without the extension
    //同样的去掉后缀再次查找，找到就返回
    data = [NSData dataWithContentsOfFile:defaultPath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
    if (data) {
        return data;
    }
    //在默认路径中没有找到，则在用户添加的路径中查找，找到就返回
    NSArray<NSString *> *customPaths = [self.customPaths copy];
    for (NSString *path in customPaths) {
        NSString *filePath = [self cachePathForKey:key inPath:path];
        NSData *imageData = [NSData dataWithContentsOfFile:filePath options:self.config.diskCacheReadingOptions error:nil];
        if (imageData) {
            return imageData;
        }

        // fallback because of https://github.com/rs/SDWebImage/pull/976 that added the extension to the disk file name
        // checking the key with and without the extension
        //去掉后缀再次查找
        imageData = [NSData dataWithContentsOfFile:filePath.stringByDeletingPathExtension options:self.config.diskCacheReadingOptions error:nil];
        if (imageData) {
            return imageData;
        }
    }
    //没找到返回nil
    return nil;
}
//在磁盘中查找指定key的图片数据，然后转换为UIImage对象返回
- (nullable UIImage *)diskImageForKey:(nullable NSString *)key {
    //调用上面的方法查找所有路径下是否存在对应key的图片数据
    NSData *data = [self diskImageDataBySearchingAllPathsForKey:key];
    return [self diskImageForKey:key data:data];
}

- (nullable UIImage *)diskImageForKey:(nullable NSString *)key data:(nullable NSData *)data {
    //如果有就解码解压缩后返回UIImage对象
    if (data) {
        UIImage *image = [[SDWebImageCodersManager sharedInstance] decodedImageWithData:data];
        image = [self scaledImageForKey:key image:image];
        if (self.config.shouldDecompressImages) {
            image = [[SDWebImageCodersManager sharedInstance] decompressedImageWithImage:image data:&data options:@{SDWebImageCoderScaleDownLargeImagesKey: @(NO)}];
        }
        return image;
    } else {
        return nil;
    }
}
//在iOS watchOS下图片的真实大小与scale有关，这里做一下缩放处理
- (nullable UIImage *)scaledImageForKey:(nullable NSString *)key image:(nullable UIImage *)image {
    return SDScaledImageForKey(key, image);
}
/*
 在缓存中查找指定key的图片是否存在，完成后执行回调块
 返回一个NSOperation，调用者可以随时取消查询
 提供这个功能主要是因为在磁盘中查找真的很耗时，调用者可能在一段时间后就不查询了
 这个NSOperation更像是一个标记对象，标记调用者是否取消了查询操作，完美的利用了NSOperation的cancel方法
 */
- (NSOperation *)queryCacheOperationForKey:(NSString *)key done:(SDCacheQueryCompletedBlock)doneBlock {
    return [self queryCacheOperationForKey:key options:0 done:doneBlock];
}

- (nullable NSOperation *)queryCacheOperationForKey:(nullable NSString *)key options:(SDImageCacheOptions)options done:(nullable SDCacheQueryCompletedBlock)doneBlock {
    //如果key为空执行回调块返回nil
    if (!key) {
        if (doneBlock) {
            //SDImageCacheTypeNone表示没有缓存数据
            doneBlock(nil, nil, SDImageCacheTypeNone);
        }
        return nil;
    }
    
    // First check the in-memory cache...
    //查找内存缓存中是否存在，调用了前面的方法
    UIImage *image = [self imageFromMemoryCacheForKey:key];
    //如果存在，就在磁盘中查找对应的二进制数据，然后执行回调块
    BOOL shouldQueryMemoryOnly = (image && !(options & SDImageCacheQueryDataWhenInMemory));
    if (shouldQueryMemoryOnly) {
        if (doneBlock) {
            //SDImageCacheTypeMemory表示图片在内存缓存中查找到
            doneBlock(image, nil, SDImageCacheTypeMemory);
        }
        return nil;
    }
    //接下来就需要在磁盘中查找了，由于耗时构造一个NSOperation对象
    //下面是异步方式在ioQueue上进行查询操作，所以直接就返回了NSOperation对象
    NSOperation *operation = [NSOperation new];
    //异步在ioQueue上查询
    void(^queryDiskBlock)(void) =  ^{
        //ioQueue是串行的，而且磁盘操作很慢，有可能还没开始查询调用者就取消查询
        //如果在开始查询后调用者再取消就没有用了，只有在查询前取消才有用
        if (operation.isCancelled) {
            // do not call the completion if cancelled
            //如果是调用者取消查询不执行回调块
            return;
        }
        //同理创建一个自动释放池，
        @autoreleasepool {
            //在磁盘中查找图片二进制数据，和UIImage对象
            NSData *diskData = [self diskImageDataBySearchingAllPathsForKey:key];
            UIImage *diskImage;
            SDImageCacheType cacheType = SDImageCacheTypeDisk;
            if (image) {
                // the image is from in-memory cache
                diskImage = image;
                cacheType = SDImageCacheTypeMemory;
            } else if (diskData) {
                // decode image data only if in-memory cache missed
                diskImage = [self diskImageForKey:key data:diskData];
                if (diskImage && self.config.shouldCacheImagesInMemory) {//找到并且需要内存缓存就设置一下
                    NSUInteger cost = SDCacheCostForImage(diskImage);
                    [self.memCache setObject:diskImage forKey:key cost:cost];
                }
            }
            //在主线程中执行回调块
            if (doneBlock) {
                if (options & SDImageCacheQueryDiskSync) {
                    //SDImageCacheTypeDisk表示在磁盘中找到
                    doneBlock(diskImage, diskData, cacheType);
                } else {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        doneBlock(diskImage, diskData, cacheType);
                    });
                }
            }
        }
    };
    
    if (options & SDImageCacheQueryDiskSync) {
        queryDiskBlock();
    } else {
        dispatch_async(self.ioQueue, queryDiskBlock);
    }
    
    return operation;
}
/**
 上面的方法提供了内存缓存和磁盘缓存中查找的功能，比较精明的设计就是返回NSOperation对象，这个对象并不代表一个任务，仅仅利用了它的cancel方法和isCancelled属性，来取消磁盘查询。
 */

#pragma mark - Remove Ops
//删除缓存总指定key的图片，删除完成后的回调块completion
//该方法也直接调用了下面的方法，默认也删除磁盘的数据
- (void)removeImageForKey:(nullable NSString *)key withCompletion:(nullable SDWebImageNoParamsBlock)completion {
    [self removeImageForKey:key fromDisk:YES withCompletion:completion];
}
//根据指定key删除图片数据
- (void)removeImageForKey:(nullable NSString *)key fromDisk:(BOOL)fromDisk withCompletion:(nullable SDWebImageNoParamsBlock)completion {
    //图片key为nil直接返回
    if (key == nil) {
        return;
    }
    //先判断缓存策略是否有内存缓存，有就删除内存缓存
    if (self.config.shouldCacheImagesInMemory) {
        //调用NSCache的removeObjectForKey方法
        [self.memCache removeObjectForKey:key];
    }
    //如果要删除磁盘数据
    if (fromDisk) {
        //异步方式在ioQueue上执行删除操作
        dispatch_async(self.ioQueue, ^{
            //使用key构造一个默认路径下的文件存储的绝对路径
            //调用NSFileManager删除该路径的文件
            [self.fileManager removeItemAtPath:[self defaultCachePathForKey:key] error:nil];
            //有回调块就在主线程中执行
            if (completion) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completion();
                });
            }
        });
        //不需要删除磁盘数据并且有回调块就直接执行
    } else if (completion){
        completion();
    }
}
/*
 上面的删除操作也很好理解，内存缓存就直接删除NSCache对象的数据，磁盘缓存就直接获取文件的绝对路径后删除即可。
 */

# pragma mark - Mem Cache settings

- (void)setMaxMemoryCost:(NSUInteger)maxMemoryCost {
    self.memCache.totalCostLimit = maxMemoryCost;
}

- (NSUInteger)maxMemoryCost {
    return self.memCache.totalCostLimit;
}

- (NSUInteger)maxMemoryCountLimit {
    return self.memCache.countLimit;
}

- (void)setMaxMemoryCountLimit:(NSUInteger)maxCountLimit {
    self.memCache.countLimit = maxCountLimit;
}

#pragma mark - Cache clean Ops
//清除缓存的操作，在收到系统内存警告通知时执行
- (void)clearMemory {
    //调用NSCache方法删除所有缓存对象
    [self.memCache removeAllObjects];
}
//清空磁盘的缓存，完成后的回调块completion
- (void)clearDiskOnCompletion:(nullable SDWebImageNoParamsBlock)completion {
    //使用异步提交在ioQueue中执行
    dispatch_async(self.ioQueue, ^{
         //获取默认的图片存储路径然后使用NSFileManager删除这个路径的所有文件及文件夹
        [self.fileManager removeItemAtPath:self.diskCachePath error:nil];
        //删除以后再创建一个空的文件夹
        [self.fileManager createDirectoryAtPath:self.diskCachePath
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL];
        //完成后有回调块就在主线程中执行
        if (completion) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completion();
            });
        }
    });
}
//删除磁盘中老的即超过缓存最长时限maxCacheAge的图片，直接调用下面的方法
- (void)deleteOldFiles {
    [self deleteOldFilesWithCompletionBlock:nil];
}
//删除磁盘中老的即超过缓存最长时限maxCacheAge的图片，完成后回调块completionBlock
- (void)deleteOldFilesWithCompletionBlock:(nullable SDWebImageNoParamsBlock)completionBlock {
   //异步方式在ioQueue上执行
    dispatch_async(self.ioQueue, ^{
        //获取磁盘缓存存储图片的路径构造为NSURL对象
        NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];
        //后面会用到，查询文件的属性
        NSArray<NSString *> *resourceKeys = @[NSURLIsDirectoryKey, NSURLContentModificationDateKey, NSURLTotalFileAllocatedSizeKey];

        // This enumerator prefetches useful properties for our cache files.
        //构造一个存储图片目录的迭代器，使用了上面的文件属性
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:resourceKeys
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];
        //构造过期日期，即当前时间往前maxCacheAge秒的日期
        NSDate *expirationDate = [NSDate dateWithTimeIntervalSinceNow:-self.config.maxCacheAge];
        //缓存的文件的字典
        NSMutableDictionary<NSURL *, NSDictionary<NSString *, id> *> *cacheFiles = [NSMutableDictionary dictionary];
        //当前缓存大小
        NSUInteger currentCacheSize = 0;

        // Enumerate all of the files in the cache directory.  This loop has two purposes:
        //
        //  1. Removing files that are older than the expiration date.
        //  2. Storing file attributes for the size-based cleanup pass.
        //需要删除的图片的文件URL
        NSMutableArray<NSURL *> *urlsToDelete = [[NSMutableArray alloc] init];
        //遍历上面创建的那个目录迭代器
        for (NSURL *fileURL in fileEnumerator) {
            NSError *error;
            //根据resourcesKeys获取文件的相关属性
            NSDictionary<NSString *, id> *resourceValues = [fileURL resourceValuesForKeys:resourceKeys error:&error];

            // Skip directories and errors.
            //有错误，然后属性为nil或者路径是个目录就continue
            if (error || !resourceValues || [resourceValues[NSURLIsDirectoryKey] boolValue]) {
                continue;
            }

            // Remove files that are older than the expiration date;
            //获取文件的上次修改日期，即创建日期
            NSDate *modificationDate = resourceValues[NSURLContentModificationDateKey];
            //如果过期就加进要删除的集合中
            if ([[modificationDate laterDate:expirationDate] isEqualToDate:expirationDate]) {
                [urlsToDelete addObject:fileURL];
                continue;
            }

            // Store a reference to this file and account for its total size.
            //获取文件的占用磁盘的大小
            NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
            //累加总缓存大小
            currentCacheSize += totalAllocatedSize.unsignedIntegerValue;
            cacheFiles[fileURL] = resourceValues;
        }
        //遍历要删除的过期的图片文件URL集合，并删除文件
        for (NSURL *fileURL in urlsToDelete) {
            [self.fileManager removeItemAtURL:fileURL error:nil];
        }

        // If our remaining disk cache exceeds a configured maximum size, perform a second
        // size-based cleanup pass.  We delete the oldest files first.
        //如果缓存策略配置了最大缓存大小，并且当前缓存的大小大于这个值则需要清理
        if (self.config.maxCacheSize > 0 && currentCacheSize > self.config.maxCacheSize) {
            // Target half of our maximum cache size for this cleanup pass.
             //清理到只占用最大缓存大小的一半
            const NSUInteger desiredCacheSize = self.config.maxCacheSize / 2;

            // Sort the remaining cache files by their last modification time (oldest first).
            //根据文件创建的日期排序
            NSArray<NSURL *> *sortedFiles = [cacheFiles keysSortedByValueWithOptions:NSSortConcurrent
                                                                     usingComparator:^NSComparisonResult(id obj1, id obj2) {
                                                                         return [obj1[NSURLContentModificationDateKey] compare:obj2[NSURLContentModificationDateKey]];
                                                                     }];

            // Delete files until we fall below our desired cache size.
            //按创建的先后顺序遍历，然后删除，直到缓存大小是最大值的一半
            for (NSURL *fileURL in sortedFiles) {
                if ([self.fileManager removeItemAtURL:fileURL error:nil]) {
                    NSDictionary<NSString *, id> *resourceValues = cacheFiles[fileURL];
                    NSNumber *totalAllocatedSize = resourceValues[NSURLTotalFileAllocatedSizeKey];
                    currentCacheSize -= totalAllocatedSize.unsignedIntegerValue;

                    if (currentCacheSize < desiredCacheSize) {
                        break;
                    }
                }
            }
        }
        //执行完成后在主线程执行回调块
        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock();
            });
        }
    });
}

#if SD_UIKIT
//在ios下才会有的函数
//写不动了，就是在后台删除。。。自己看看吧。。。唉
- (void)backgroundDeleteOldFiles {
    Class UIApplicationClass = NSClassFromString(@"UIApplication");
    if(!UIApplicationClass || ![UIApplicationClass respondsToSelector:@selector(sharedApplication)]) {
        return;
    }
    UIApplication *application = [UIApplication performSelector:@selector(sharedApplication)];
    __block UIBackgroundTaskIdentifier bgTask = [application beginBackgroundTaskWithExpirationHandler:^{
        // Clean up any unfinished task business by marking where you
        // stopped or ending the task outright.
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];

    // Start the long-running task and return immediately.
    [self deleteOldFilesWithCompletionBlock:^{
        [application endBackgroundTask:bgTask];
        bgTask = UIBackgroundTaskInvalid;
    }];
}
#endif

/**
 上面就是删除磁盘中过期的图片，以及当缓存大小大于配置的值时，进行缓存清理。
 */

#pragma mark - Cache Info
//计算磁盘缓存占用空间大小
- (NSUInteger)getSize {
    __block NSUInteger size = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtPath:self.diskCachePath];
        for (NSString *fileName in fileEnumerator) {
            NSString *filePath = [self.diskCachePath stringByAppendingPathComponent:fileName];
            NSDictionary<NSString *, id> *attrs = [self.fileManager attributesOfItemAtPath:filePath error:nil];
            size += [attrs fileSize];
        }
    });
    return size;
}
//计算磁盘缓存图片的个数
- (NSUInteger)getDiskCount {
    __block NSUInteger count = 0;
    dispatch_sync(self.ioQueue, ^{
        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtPath:self.diskCachePath];
        count = fileEnumerator.allObjects.count;
    });
    return count;
}
//同时计算磁盘缓存图片占用空间大小和缓存图片的个数，然后调用回调块，传入相关参数
- (void)calculateSizeWithCompletionBlock:(nullable SDWebImageCalculateSizeBlock)completionBlock {
    NSURL *diskCacheURL = [NSURL fileURLWithPath:self.diskCachePath isDirectory:YES];

    dispatch_async(self.ioQueue, ^{
        NSUInteger fileCount = 0;
        NSUInteger totalSize = 0;

        NSDirectoryEnumerator *fileEnumerator = [self.fileManager enumeratorAtURL:diskCacheURL
                                                   includingPropertiesForKeys:@[NSFileSize]
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 errorHandler:NULL];

        for (NSURL *fileURL in fileEnumerator) {
            NSNumber *fileSize;
            [fileURL getResourceValue:&fileSize forKey:NSURLFileSizeKey error:NULL];
            totalSize += fileSize.unsignedIntegerValue;
            fileCount += 1;
        }

        if (completionBlock) {
            dispatch_async(dispatch_get_main_queue(), ^{
                completionBlock(fileCount, totalSize);
            });
        }
    });
}
//上面的方法就是用来计算磁盘中缓存图片的数量和占用磁盘空间大小

@end

/*
 整个SDWebImage的缓存模块到此就结束了，阅读完后可以发现，整个代码很好理解，但是设计的也很巧妙，各种情况都考虑的很周全，这些都值得我们学习，尤其是所有IO操作使用一个串行队列来执行，避免加锁释放锁的复杂，还有就是使用NSOperation作为一个标识用来取消耗时的磁盘查询任务。整个代码简洁易懂，接口设计的很完善，是我们学习的榜样。
 */

/*
 最近还研究了一下YYCache的源码，YYCache包括了内存缓存和磁盘缓存两部分。
 对于内存缓存可以说作者为了提升性能无所不用其极，使用Core Foundation提供的C字典CFMutableDictionaryRef来存储封装的缓存对象，并构造了一个双向链表，维护链表并使用LRU淘汰算法来剔除超过限制的缓存对象，使用pthread_mutext互斥锁来保证线程安全，包括释放对象使用了一个小技巧使得可以在子线程中释放，而不需要在主线程中执行，直接访问ivar而不使用getter/setter，一系列的优化方法使得YYCache的内存缓存效率超过了NSCache及其他第三方库。
 对于磁盘缓存，作者参考了NSURLCache的实现及其他第三方的实现，采用文件系统结合SQLite的实现方式，实验发现对于20KB以上的数据，文件系统的读写速度高于SQLite，所以当数据大于20KB时直接将数据保存在文件系统中，在数据库中保存元数据，并添加索引，数据小于20KB时直接保存在数据库中，这样，就能够快速统计相关数据来实现淘汰。SDWebImage的磁盘缓存使用的只有文件系统。
 读了YYCache源码让我明白了，不能一味的迷信苹果为我们提供的类，为了追求更极致的性能需要做大量的对比试验来确定技术方案。
 读者可以参考YYCache作者的博客YYCache设计思路，有兴趣的读者可以研究一下其源码，值得学习的有很多。
*/

