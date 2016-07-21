#include <stdio.h>
#include <string.h>
#include <assert.h>
#include "rio.h"
#include "dict.h"
#include "endianconv.h"

/*** redis.h ***/
#define REDIS_OK    0
#define REDIS_ERR   -1

#define REDIS_SHARED_INTEGERS 10000
#define REDIS_DEFAULT_RDB_COMPRESSION 1
#define REDIS_DEFAULT_RDB_CHECKSUM 1
#define REDIS_DEFAULT_RDB_FILENAME "dump.rdb"

/* Object types */
#define REDIS_STRING 0
#define REDIS_LIST 1
#define REDIS_SET 2
#define REDIS_ZSET 3
#define REDIS_HASH 4

/* Objects encoding. Some kind of objects like Strings and Hashes can be
 * internally represented in multiple ways. The 'encoding' field of the object
 * is set to one of this fields for this object. */
#define REDIS_ENCODING_RAW 0     /* Raw representation */
#define REDIS_ENCODING_INT 1     /* Encoded as integer */
#define REDIS_ENCODING_HT 2      /* Encoded as hash table */
#define REDIS_ENCODING_ZIPMAP 3  /* Encoded as zipmap */
#define REDIS_ENCODING_LINKEDLIST 4 /* Encoded as regular linked list */
#define REDIS_ENCODING_ZIPLIST 5 /* Encoded as ziplist */
#define REDIS_ENCODING_INTSET 6  /* Encoded as intset */
#define REDIS_ENCODING_SKIPLIST 7  /* Encoded as skiplist */
#define REDIS_ENCODING_EMBSTR 8  /* Embedded sds string encoding */

/* Protocol and I/O related defines */
#define REDIS_MAX_QUERYBUF_LEN  (1024*1024*1024) /* 1GB max query buffer. */
#define REDIS_IOBUF_LEN         (1024*16)  /* Generic I/O buffer size */
#define REDIS_REPLY_CHUNK_BYTES (16*1024) /* 16k output buffer */
#define REDIS_INLINE_MAX_SIZE   (1024*64) /* Max size of inline reads */
#define REDIS_MBULK_BIG_ARG     (1024*32)
#define REDIS_LONGSTR_SIZE      21          /* Bytes needed for long -> str */
#define REDIS_AOF_AUTOSYNC_BYTES (1024*1024*32) /* fdatasync every 32MB */

/* Zip structure related defaults */
#define REDIS_HASH_MAX_ZIPLIST_ENTRIES 512
#define REDIS_HASH_MAX_ZIPLIST_VALUE 64
#define REDIS_LIST_MAX_ZIPLIST_ENTRIES 512
#define REDIS_LIST_MAX_ZIPLIST_VALUE 64
#define REDIS_SET_MAX_INTSET_ENTRIES 512
#define REDIS_ZSET_MAX_ZIPLIST_ENTRIES 128
#define REDIS_ZSET_MAX_ZIPLIST_VALUE 64

/* List related stuff */
#define REDIS_HEAD 0
#define REDIS_TAIL 1

/* We can print the stacktrace, so our assert is defined this way: */
#define redisAssertWithInfo(_c,_o,_e) ((_e)?(void)0 : (_redisAssertWithInfo(_c,_o,#_e,__FILE__,__LINE__)/*,_exit(1)*/))
#define redisAssert(_e) ((_e)?(void)0 : (_redisAssert(#_e,__FILE__,__LINE__)/*,_exit(1)*/))
//#define redisPanic(_e) _redisPanic(#_e,__FILE__,__LINE__),_exit(1)

/* Debugging stuff */
//void _redisAssertWithInfo(redisClient *c, robj *o, char *estr, char *file, int line);
//void _redisAssert(char *estr, char *file, int line);
//void _redisPanic(char *msg, char *file, int line);
/***************/

/*** rdb.h ***/
/* The current RDB version. When the format changes in a way that is no longer
 * backward compatible this number gets incremented. */
#define REDIS_RDB_VERSION 6

/* Defines related to the dump file format. To store 32 bits lengths for short
 * keys requires a lot of space, so we check the most significant 2 bits of
 * the first byte to interpreter the length:
 *
 * 00|000000 => if the two MSB are 00 the len is the 6 bits of this byte
 * 01|000000 00000000 =>  01, the len is 14 byes, 6 bits + 8 bits of next byte
 * 10|000000 [32 bit integer] => if it's 01, a full 32 bit len will follow
 * 11|000000 this means: specially encoded object will follow. The six bits
 *           number specify the kind of object that follows.
 *           See the REDIS_RDB_ENC_* defines.
 *
 * Lengths up to 63 are stored using a single byte, most DB keys, and may
 * values, will fit inside. */
#define REDIS_RDB_6BITLEN 0
#define REDIS_RDB_14BITLEN 1
#define REDIS_RDB_32BITLEN 2
#define REDIS_RDB_ENCVAL 3
#define REDIS_RDB_LENERR UINT_MAX

/* When a length of a string object stored on disk has the first two bits
 * set, the remaining two bits specify a special encoding for the object
 * accordingly to the following defines: */
#define REDIS_RDB_ENC_INT8 0        /* 8 bit signed integer */
#define REDIS_RDB_ENC_INT16 1       /* 16 bit signed integer */
#define REDIS_RDB_ENC_INT32 2       /* 32 bit signed integer */
#define REDIS_RDB_ENC_LZF 3         /* string compressed with FASTLZ */

/* Dup object types to RDB object types. Only reason is readability (are we
 * dealing with RDB types or with in-memory object types?). */
#define REDIS_RDB_TYPE_STRING 0
#define REDIS_RDB_TYPE_LIST   1
#define REDIS_RDB_TYPE_SET    2
#define REDIS_RDB_TYPE_ZSET   3
#define REDIS_RDB_TYPE_HASH   4

/* Object types for encoded objects. */
#define REDIS_RDB_TYPE_HASH_ZIPMAP    9
#define REDIS_RDB_TYPE_LIST_ZIPLIST  10
#define REDIS_RDB_TYPE_SET_INTSET    11
#define REDIS_RDB_TYPE_ZSET_ZIPLIST  12
#define REDIS_RDB_TYPE_HASH_ZIPLIST  13

/* Test if a type is an object type. */
#define rdbIsObjectType(t) ((t >= 0 && t <= 4) || (t >= 9 && t <= 13))

/* Special RDB opcodes (saved/loaded with rdbSaveType/rdbLoadType). */
#define REDIS_RDB_OPCODE_EXPIRETIME_MS 252
#define REDIS_RDB_OPCODE_EXPIRETIME 253
#define REDIS_RDB_OPCODE_SELECTDB   254
#define REDIS_RDB_OPCODE_EOF        255
/*************/


/*** config.h ***/
/* Define aof_fsync to fdatasync() in Linux and fsync() for all the rest */
#ifdef __linux__
#define aof_fsync fdatasync
#else
#define aof_fsync fsync
#endif
/****************/

/*** redis.h ***/
/* Anti-warning macro... */
#define REDIS_NOTUSED(V) ((void) V)

/* The actual Redis Object */
#define REDIS_LRU_BITS 24
//#define REDIS_LRU_CLOCK_MAX ((1<<REDIS_LRU_BITS)-1) /* Max value of obj->lru */
//#define REDIS_LRU_CLOCK_RESOLUTION 1000 /* LRU clock resolution in ms */
typedef struct redisObject {
    unsigned type:4;
    unsigned encoding:4;
    unsigned lru:REDIS_LRU_BITS; /* lru time (relative to server.lruclock) */
    int refcount;
    void *ptr;
} robj;

/* Structure to hold hash iteration abstraction. Note that iteration over
 * hashes involves both fields and values. Because it is possible that
 * not both are required, store pointers in the iterator to avoid
 * unnecessary memory allocation for fields/values. */
typedef struct {
    robj *subject;
    int encoding;

    unsigned char *fptr, *vptr;

    dictIterator *di;
    dictEntry *de;
} hashTypeIterator;

#define REDIS_HASH_KEY 1
#define REDIS_HASH_VALUE 2
/***************/

/* Redis object implementation */
void decrRefCount(robj *o);
void decrRefCountVoid(void *o);
void incrRefCount(robj *o);
//robj *resetRefCount(robj *obj);
//void freeStringObject(robj *o);
//void freeListObject(robj *o);
//void freeSetObject(robj *o);
//void freeZsetObject(robj *o);
//void freeHashObject(robj *o);
robj *createObject(int type, void *ptr);
robj *createStringObject(char *ptr, size_t len);
robj *createRawStringObject(char *ptr, size_t len);
//robj *createEmbeddedStringObject(char *ptr, size_t len);
//robj *dupStringObject(robj *o);
//int isObjectRepresentableAsLongLong(robj *o, long long *llongval);
//robj *tryObjectEncoding(robj *o);
//robj *getDecodedObject(robj *o);
//size_t stringObjectLen(robj *o);

robj *createStringObjectFromLongLong(long long value);
//robj *createStringObjectFromLongDouble(long double value, int humanfriendly);
robj *createListObject(void);
robj *createZiplistObject(void);
//robj *createSetObject(void);
//robj *createIntsetObject(void);
//robj *createHashObject(void);
//robj *createZsetObject(void);
//robj *createZsetZiplistObject(void);
//int getLongFromObjectOrReply(redisClient *c, robj *o, long *target, const char *msg);
//int checkType(redisClient *c, robj *o, int type);
//int getLongLongFromObjectOrReply(redisClient *c, robj *o, long long *target, const char *msg);
//int getDoubleFromObjectOrReply(redisClient *c, robj *o, double *target, const char *msg);
//int getLongLongFromObject(robj *o, long long *target);
//int getLongDoubleFromObject(robj *o, long double *target);
//int getLongDoubleFromObjectOrReply(redisClient *c, robj *o, long double *target, const char *msg);
//char *strEncoding(int encoding);
//int compareStringObjects(robj *a, robj *b);
//int collateStringObjects(robj *a, robj *b);
//int equalStringObjects(robj *a, robj *b);
//unsigned long long estimateObjectIdleTime(robj *o);
#define sdsEncodedObject(objptr) (objptr->encoding == REDIS_ENCODING_RAW || objptr->encoding == REDIS_ENCODING_EMBSTR)

/* Hash data type */
void hashTypeConvert(robj *o, int enc);
//void hashTypeTryConversion(robj *subject, robj **argv, int start, int end);
//void hashTypeTryObjectEncoding(robj *subject, robj **o1, robj **o2);
//robj *hashTypeGetObject(robj *o, robj *key);
//int hashTypeExists(robj *o, robj *key);
//int hashTypeSet(robj *o, robj *key, robj *value);
//int hashTypeDelete(robj *o, robj *key);
//unsigned long hashTypeLength(robj *o);
hashTypeIterator *hashTypeInitIterator(robj *subject);
//void hashTypeReleaseIterator(hashTypeIterator *hi);
//int hashTypeNext(hashTypeIterator *hi);
//void hashTypeCurrentFromZiplist(hashTypeIterator *hi, int what,
//                                unsigned char **vstr,
//                                unsigned int *vlen,
//                                long long *vll);
//void hashTypeCurrentFromHashTable(hashTypeIterator *hi, int what, robj **dst);
//robj *hashTypeCurrentObject(hashTypeIterator *hi, int what);
//robj *hashTypeLookupWriteOrCreate(redisClient *c, robj *key);
/***************/

/*** rdb.h ***/
int rdbLoadObjectType(rio *rdb);
robj *rdbLoadObject(int type, rio *rdb, FILE *debug);
/*************/


/*** adlist.h ***/
/* Node, List, and Iterator are the only data structures used currently. */
typedef struct listNode {
    struct listNode *prev;
    struct listNode *next;
    void *value;
} listNode;

typedef struct listIter {
    listNode *next;
    int direction;
} listIter;

typedef struct list {
    listNode *head;
    listNode *tail;
    void *(*dup)(void *ptr);
    void (*free)(void *ptr);
    int (*match)(void *ptr, void *key);
    unsigned long len;
} list;

/* Functions implemented as macros */
#define listLength(l) ((l)->len)
#define listFirst(l) ((l)->head)
#define listLast(l) ((l)->tail)
#define listPrevNode(n) ((n)->prev)
#define listNextNode(n) ((n)->next)
#define listNodeValue(n) ((n)->value)

#define listSetDupMethod(l,m) ((l)->dup = (m))
#define listSetFreeMethod(l,m) ((l)->free = (m))
#define listSetMatchMethod(l,m) ((l)->match = (m))

#define listGetDupMethod(l) ((l)->dup)
#define listGetFree(l) ((l)->free)
#define listGetMatchMethod(l) ((l)->match)

/* Prototypes */
listNode *listIndex(list *list, long index);
/****************/