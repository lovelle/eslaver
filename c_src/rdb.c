#include <errno.h>
#include <stdint.h>
#include <limits.h>

#include "lzf.h"
#include "sds.h"
#include "rdb.h"
#include "util.h"
#include "extras.h"
#include "ziplist.h"
#include "zmalloc.h"


/* Load a "type" in RDB format, that is a one byte unsigned integer.
 * This function is not only used to load object types, but also special
 * "types" like the end-of-file type, the EXPIRE type, and so forth. */
int rdbLoadType(rio *rdb) {
    unsigned char type;
    if (rioRead(rdb,&type,1) == 0) return -1;
    return type;
}

time_t rdbLoadTime(rio *rdb) {
    int32_t t32;
    if (rioRead(rdb,&t32,4) == 0) return -1;
    return (time_t)t32;
}

//int rdbSaveMillisecondTime(rio *rdb, long long t) {
//    int64_t t64 = (int64_t) t;
//    return rdbWriteRaw(rdb,&t64,8);
//}

long long rdbLoadMillisecondTime(rio *rdb) {
    int64_t t64;
    if (rioRead(rdb,&t64,8) == 0) return -1;
    return (long long)t64;
}

/* Load an encoded length. The "isencoded" argument is set to 1 if the length
 * is not actually a length but an "encoding type". See the REDIS_RDB_ENC_*
 * definitions in rdb.h for more information. */
uint32_t rdbLoadLen(rio *rdb, int *isencoded) {
    unsigned char buf[2];
    uint32_t len;
    int type;

    if (isencoded) *isencoded = 0;
    if (rioRead(rdb,buf,1) == 0) return REDIS_RDB_LENERR;
    type = (buf[0]&0xC0)>>6;
    if (type == REDIS_RDB_ENCVAL) {
        /* Read a 6 bit encoding type. */
        if (isencoded) *isencoded = 1;
        return buf[0]&0x3F;
    } else if (type == REDIS_RDB_6BITLEN) {
        /* Read a 6 bit len. */
        return buf[0]&0x3F;
    } else if (type == REDIS_RDB_14BITLEN) {
        /* Read a 14 bit len. */
        if (rioRead(rdb,buf+1,1) == 0) return REDIS_RDB_LENERR;
        return ((buf[0]&0x3F)<<8)|buf[1];
    } else {
        /* Read a 32 bit len. */
        if (rioRead(rdb,&len,4) == 0) return REDIS_RDB_LENERR;
        return ntohl(len);
    }
}

/* Loads an integer-encoded object with the specified encoding type "enctype".
 * If the "encode" argument is set the function may return an integer-encoded
 * string object, otherwise it always returns a raw string object. */
robj *rdbLoadIntegerObject(rio *rdb, int enctype, int encode) {
    unsigned char enc[4];
    long long val;

    if (enctype == REDIS_RDB_ENC_INT8) {
        if (rioRead(rdb,enc,1) == 0) return NULL;
        val = (signed char)enc[0];
    } else if (enctype == REDIS_RDB_ENC_INT16) {
        uint16_t v;
        if (rioRead(rdb,enc,2) == 0) return NULL;
        v = enc[0]|(enc[1]<<8);
        val = (int16_t)v;
    } else if (enctype == REDIS_RDB_ENC_INT32) {
        uint32_t v;
        if (rioRead(rdb,enc,4) == 0) return NULL;
        v = enc[0]|(enc[1]<<8)|(enc[2]<<16)|(enc[3]<<24);
        val = (int32_t)v;
    } else {
        val = 0; /* anti-warning */
        printf("Unknown RDB integer encoding type\n");
    }
    if (encode)
        return createStringObjectFromLongLong(val);
    else
        return createObject(REDIS_STRING,sdsfromlonglong(val));
}

robj *rdbLoadLzfStringObject(rio *rdb) {
    unsigned int len, clen;
    unsigned char *c = NULL;
    sds val = NULL;

    if ((clen = rdbLoadLen(rdb,NULL)) == REDIS_RDB_LENERR) return NULL;
    if ((len = rdbLoadLen(rdb,NULL)) == REDIS_RDB_LENERR) return NULL;
    if ((c = zmalloc(clen)) == NULL) goto err;
    if ((val = sdsnewlen(NULL,len)) == NULL) goto err;
    if (rioRead(rdb,c,clen) == 0) goto err;
    if (lzf_decompress(c,clen,val,len) == 0) goto err;
    zfree(c);
    return createObject(REDIS_STRING,val);
err:
    zfree(c);
    sdsfree(val);
    return NULL;
}

robj *rdbGenericLoadStringObject(rio *rdb, int encode) {
    int isencoded;
    uint32_t len; 
    robj *o;

    len = rdbLoadLen(rdb,&isencoded);
    if (isencoded) {
        switch(len) {
        case REDIS_RDB_ENC_INT8:
        case REDIS_RDB_ENC_INT16:
        case REDIS_RDB_ENC_INT32:
            return rdbLoadIntegerObject(rdb,len,encode);
        case REDIS_RDB_ENC_LZF:
            return rdbLoadLzfStringObject(rdb);
        default:
            printf("Unknown RDB encoding type\n");
        }    
    }    

    if (len == REDIS_RDB_LENERR) return NULL;
    o = encode ? createStringObject(NULL,len) :
                 createRawStringObject(NULL,len);
    if (len && rioRead(rdb,o->ptr,len) == 0) {
        decrRefCount(o);
        return NULL;
    }    
    return o;
}

robj *rdbLoadStringObject(rio *rdb) {
    return rdbGenericLoadStringObject(rdb,0);
}

robj *rdbLoadEncodedStringObject(rio *rdb) {
    return rdbGenericLoadStringObject(rdb,1);
}

int rdbLoad(FILE *debug, Myerl *erl, char *filename) {
    uint32_t dbid;
    int type, rdbver;
//    redisDb *db = server.db+0;
    int db = 0;
    char buf[1024];
    long long expiretime, now = mstime();
    FILE *fp;
    rio rdb;

    fprintf(debug, "OK: rdbLoad: debug starting\n");

    if ((fp = fopen(filename,"r")) == NULL) return REDIS_ERR;

    rioInitWithFile(&rdb,fp);
//    rioInitWithBuffer(&rdb, sdsnew(bulk));

    if (rioRead(&rdb,buf,9) == 0) goto eoferr;
    buf[9] = '\0';

    if (memcmp(buf,"REDIS",5) != 0) {
        erl->error = "Wrong signature trying to load DB from file";
        errno = EINVAL;
        return REDIS_ERR;
    }

    rdbver = atoi(buf+5);
    if (rdbver < 1 || rdbver > REDIS_RDB_VERSION) {
        sprintf(erl->error, "Can't handle RDB format version %d", rdbver);
        errno = EINVAL;
        return REDIS_ERR;
    }

    while(1) {
        robj *key, *val;
        expiretime = -1;

        /* Read type. */
        if ((type = rdbLoadType(&rdb)) == -1) goto eoferr;
        if (type == REDIS_RDB_OPCODE_EXPIRETIME) {
            if ((expiretime = rdbLoadTime(&rdb)) == -1) goto eoferr;
            /* We read the time so we need to read the object type again. */
            if ((type = rdbLoadType(&rdb)) == -1) goto eoferr;
            /* the EXPIRETIME opcode specifies time in seconds, so convert
             * into milliseconds. */
            expiretime *= 1000;
        } else if (type == REDIS_RDB_OPCODE_EXPIRETIME_MS) {
            /* Milliseconds precision expire times introduced with RDB
             * version 3. */
            if ((expiretime = rdbLoadMillisecondTime(&rdb)) == -1) goto eoferr;
            /* We read the time so we need to read the object type again. */
            if ((type = rdbLoadType(&rdb)) == -1) goto eoferr;
        }

        if (type == REDIS_RDB_OPCODE_EOF)
            break;

        /* Handle SELECT DB opcode as a special case */
        if (type == REDIS_RDB_OPCODE_SELECTDB) {
            if ((dbid = rdbLoadLen(&rdb,NULL)) == REDIS_RDB_LENERR)
                goto eoferr;
//            if (dbid >= (unsigned)server.dbnum) {
//                printf("FATAL: Data file was created with a Redis server configured to handle more than %d databases. Exiting\n", server.dbnum);
//                exit(1);
//            }
//            db = server.db+dbid;
            db = db+dbid;
            continue;
        }

        /* Read key */
        if ((key = rdbLoadStringObject(&rdb)) == NULL) goto eoferr;
        /* Read value */
        if ((val = rdbLoadObject(type,&rdb, debug)) == NULL) goto eoferr;

        if (expiretime != -1) {
            fprintf(debug, "OK: val now is '%lld' \n", now);
            fprintf(debug, "OK: val expire is '%lld' \n", expiretime);
        }

        fprintf(debug, "OK: key name is '%s' type is '%d' \n", (char*)key->ptr, val->type);

        /* Check if the key already expired. This function is used when loading
         * an RDB file from disk, either at startup, or when an RDB was
         * received from the master. In the latter case, the master is
         * responsible for key expiry. If we would expire keys here, the
         * snapshot taken by the master may not be reflected on the slave. */
        //if (server.masterhost == NULL && expiretime != -1 && expiretime < now) {
        if (expiretime != -1 && expiretime < now) {
            decrRefCount(key);
            decrRefCount(val);
            continue;
        }

        /* Add the new object in the hash table */
        switch(val->type) {
            case REDIS_RDB_TYPE_STRING:
                    if (sendStringTuplePid(erl, key, val)) return REDIS_ERR;
                break;
            case REDIS_RDB_TYPE_LIST:
                    if (sendListTuplePid(erl, key, val)) return REDIS_ERR;
                break;
            case REDIS_RDB_TYPE_SET:
                    ;
                    //sendSetTuplePid(erl, key, val);
                break;
            case REDIS_RDB_TYPE_ZSET:
                    if (sendZsetTuplePid(erl, key, val)) return REDIS_ERR;
                break;
            case REDIS_RDB_TYPE_HASH:
                    if (sendHashTuplePid(erl, key, val)) return REDIS_ERR;
                break;
            default: erl->error = "Unknown rdb object type"; return REDIS_ERR;
        }

        /* Set the expire time if needed */
        //if (expiretime != -1) setExpire(db,key,expiretime);
        decrRefCount(key);
    }
    /* Verify the checksum if RDB version is >= 5 */
    //if (rdbver >= 5 && server.rdb_checksum) {
    /*
    if (rdbver >= 5 && REDIS_DEFAULT_RDB_CHECKSUM) {
        uint64_t cksum, expected = rdb.cksum;

        if (rioRead(&rdb,&cksum,8) == 0) goto eoferr;
//        memrev64ifbe(&cksum);
        if (cksum == 0) {
            fprintf(debug, "RDB file was saved with checksum disabled: no check performed.\n");
        } else if (cksum != expected) {
            fprintf(debug, "cksum -> %llu expected -> %llu\n", cksum, expected );
            erl->error = "Wrong RDB checksum. Aborting now.";
            return REDIS_ERR;
        }
    }
    */

    fprintf(debug, "OK: rdbLoad: debug finished\n");
    return 0;

eoferr: /* unexpected end of file is handled here with a fatal exit */
    erl->error = "Short read or OOM loading DB. Unrecoverable error, aborting now.";
    return REDIS_ERR; /* Just to avoid warning */
}

/*** object.c ***/
robj *createObject(int type, void *ptr) {
    robj *o = zmalloc(sizeof(*o));
    o->type = type;
    o->encoding = REDIS_ENCODING_RAW;
    o->ptr = ptr;
    o->refcount = 1;

    /* Set the LRU to the current lruclock (minutes resolution). */
    //o->lru = LRU_CLOCK();
    return o;
}

/* Create a string object with encoding REDIS_ENCODING_RAW, that is a plain
 * string object where o->ptr points to a proper sds string. */
robj *createRawStringObject(char *ptr, size_t len) {
    return createObject(REDIS_STRING,sdsnewlen(ptr,len));
}

/* Create a string object with encoding REDIS_ENCODING_EMBSTR, that is
 * an object where the sds string is actually an unmodifiable string
 * allocated in the same chunk as the object itself. */
robj *createEmbeddedStringObject(char *ptr, size_t len) {
    robj *o = zmalloc(sizeof(robj)+sizeof(struct sdshdr)+len+1);
    struct sdshdr *sh = (void*)(o+1);

    o->type = REDIS_STRING;
    o->encoding = REDIS_ENCODING_EMBSTR;
    o->ptr = sh+1;
    o->refcount = 1;
    //o->lru = LRU_CLOCK();

    sh->len = len;
    sh->free = 0;
    if (ptr) {
        memcpy(sh->buf,ptr,len);
        sh->buf[len] = '\0';
    } else {
        memset(sh->buf,0,len+1);
    }
    return o;
}

/* Create a string object with EMBSTR encoding if it is smaller than
 * REIDS_ENCODING_EMBSTR_SIZE_LIMIT, otherwise the RAW encoding is
 * used.
 *
 * The current limit of 39 is chosen so that the biggest string object
 * we allocate as EMBSTR will still fit into the 64 byte arena of jemalloc. */

#define REDIS_ENCODING_EMBSTR_SIZE_LIMIT 39
robj *createStringObject(char *ptr, size_t len) {
    if (len <= REDIS_ENCODING_EMBSTR_SIZE_LIMIT)
        return createEmbeddedStringObject(ptr,len);
    else
        return createRawStringObject(ptr,len);
}

robj *createStringObjectFromLongLong(long long value) {
    robj *o;
    if (value >= 0 && value < REDIS_SHARED_INTEGERS) {
        //incrRefCount(shared.integers[value]);
        //o = shared.integers[value];
        o = createObject(REDIS_STRING,(void*)(long)value);
        o->encoding = REDIS_ENCODING_INT;
        incrRefCount(o);
    } else {
        if (value >= LONG_MIN && value <= LONG_MAX) {
            o = createObject(REDIS_STRING, NULL);
            o->encoding = REDIS_ENCODING_INT;
            o->ptr = (void*)((long)value);
        } else {
            o = createObject(REDIS_STRING,sdsfromlonglong(value));
        }
    }
    return o;
}

void incrRefCount(robj *o) {
    o->refcount++;
}

void decrRefCount(robj *o) {
    if (o->refcount <= 0) printf("decrRefCount against refcount <= 0");
    if (o->refcount == 1) {
        switch(o->type) {
        //case REDIS_STRING: freeStringObject(o); break;
        case REDIS_STRING: zfree(o); break;
        //case REDIS_LIST: freeListObject(o); break;
        case REDIS_LIST: zfree(o); break;
        //case REDIS_SET: freeSetObject(o); break;
        case REDIS_SET: zfree(o); break;
        //case REDIS_ZSET: freeZsetObject(o); break;
        case REDIS_ZSET: zfree(o); break;
        //case REDIS_HASH: freeHashObject(o); break;
        case REDIS_HASH: zfree(o); break;
        default: printf("Unknown object type"); break;
        }
        //BUG!!
        //zfree(o);
    } else {
        o->refcount--;
    }
}

/* This variant of decrRefCount() gets its argument as void, and is useful
 * as free method in data structures that expect a 'void free_object(void*)'
 * prototype for the free method. */
void decrRefCountVoid(void *o) {
    decrRefCount(o);
}

robj *createListObject(void) {
    list *l = listCreate();
    robj *o = createObject(REDIS_LIST,l);
    listSetFreeMethod(l,decrRefCountVoid);
    o->encoding = REDIS_ENCODING_LINKEDLIST;
    return o;
}

robj *createZiplistObject(void) {
    unsigned char *zl = ziplistNew();
    robj *o = createObject(REDIS_LIST,zl);
    o->encoding = REDIS_ENCODING_ZIPLIST;
    return o;
}

robj *createHashObject(void) {
    unsigned char *zl = ziplistNew();
    robj *o = createObject(REDIS_HASH, zl);
    o->encoding = REDIS_ENCODING_ZIPLIST;
    return o;
}

/* Get a decoded version of an encoded object (returned as a new object).
 * If the object is already raw-encoded just increment the ref count. */
robj *getDecodedObject(robj *o) {
    robj *dec;

    if (sdsEncodedObject(o)) {
        incrRefCount(o);
        return o;
    }
    if (o->type == REDIS_STRING && o->encoding == REDIS_ENCODING_INT) {
        char buf[32];

        ll2string(buf,32,(long)o->ptr);
        dec = createStringObject(buf,strlen(buf));
        return dec;
    } else {
        printf("Unknown encoding type");
        exit(1);
    }
}
/****************/

/* Load a Redis object of the specified type from the specified file.
 * On success a newly allocated object is returned, otherwise NULL. */
robj *rdbLoadObject(int rdbtype, rio *rdb, FILE *debug) {
    robj *o, *ele, *dec;
    size_t len;
//    unsigned int i;

    if (rdbtype == REDIS_RDB_TYPE_STRING) {
        /* Read string value */
        if ((o = rdbLoadEncodedStringObject(rdb)) == NULL) return NULL;
//        o = tryObjectEncoding(o);
    } else if (rdbtype == REDIS_RDB_TYPE_LIST) {
        /* Read list value */
        if ((len = rdbLoadLen(rdb,NULL)) == REDIS_RDB_LENERR) return NULL;

        /* Use a real list when there are too many entries */
//        if (len > server.list_max_ziplist_entries) {
        if (len > REDIS_LIST_MAX_ZIPLIST_ENTRIES) {
            o = createListObject();
        } else {
            o = createZiplistObject();
        }

        /* Load every single element of the list */
        while(len--) {
            if ((ele = rdbLoadEncodedStringObject(rdb)) == NULL) return NULL;
            
            /* If we are using a ziplist and the value is too big, convert
             * the object to a real list. */
            /*if (o->encoding == REDIS_ENCODING_ZIPLIST &&
                sdsEncodedObject(ele) &&
                sdslen(ele->ptr) > REDIS_LIST_MAX_ZIPLIST_VALUE)
                listTypeConvert(o,REDIS_ENCODING_LINKEDLIST);
            */

            if (o->encoding == REDIS_ENCODING_ZIPLIST) {
                dec = getDecodedObject(ele);
                //o->ptr = ziplistPush(o->ptr,dec->ptr,sdslen(dec->ptr),REDIS_TAIL);
                decrRefCount(dec);
                decrRefCount(ele);
            } else {
            //    ele = tryObjectEncoding(ele);
            //    listAddNodeTail(o->ptr,ele);
                listAddNodeTail(o->ptr,sdsnew(ele->ptr));                
            }
        }
//    } else if (rdbtype == REDIS_RDB_TYPE_SET) {
        /* Read list/set value */
//        if ((len = rdbLoadLen(rdb,NULL)) == REDIS_RDB_LENERR) return NULL;

//        /* Use a regular set when there are too many entries. */
//        if (len > server.set_max_intset_entries) {
//            o = createSetObject();
//            /* It's faster to expand the dict to the right size asap in order
//             * to avoid rehashing */
//            if (len > DICT_HT_INITIAL_SIZE)
//                dictExpand(o->ptr,len);
//        } else {
//            o = createIntsetObject();
//        }
//
//        /* Load every single element of the list/set */
//        for (i = 0; i < len; i++) {
//            long long llval;
//            if ((ele = rdbLoadEncodedStringObject(rdb)) == NULL) return NULL;
//            ele = tryObjectEncoding(ele);
//
//            if (o->encoding == REDIS_ENCODING_INTSET) {
//                /* Fetch integer value from element */
//                if (isObjectRepresentableAsLongLong(ele,&llval) == REDIS_OK) {
//                    o->ptr = intsetAdd(o->ptr,llval,NULL);
//                } else {
//                    setTypeConvert(o,REDIS_ENCODING_HT);
//                    dictExpand(o->ptr,len);
//                }
//            }
//
//            /* This will also be called when the set was just converted
//             * to a regular hash table encoded set */
//            if (o->encoding == REDIS_ENCODING_HT) {
//                dictAdd((dict*)o->ptr,ele,NULL);
//            } else {
//                decrRefCount(ele);
//            }
//        }
//    } else if (rdbtype == REDIS_RDB_TYPE_ZSET) {
        /* Read list/set value */
//        size_t zsetlen;
//        size_t maxelelen = 0;
//        zset *zs;
//
//        if ((zsetlen = rdbLoadLen(rdb,NULL)) == REDIS_RDB_LENERR) return NULL;
//        o = createZsetObject();
//        zs = o->ptr;
//
//        /* Load every single element of the list/set */
//        while(zsetlen--) {
//            robj *ele;
//            double score;
//            zskiplistNode *znode;
//
//            if ((ele = rdbLoadEncodedStringObject(rdb)) == NULL) return NULL;
//            ele = tryObjectEncoding(ele);
//            if (rdbLoadDoubleValue(rdb,&score) == -1) return NULL;
//
//            /* Don't care about integer-encoded strings. */
//            if (sdsEncodedObject(ele) && sdslen(ele->ptr) > maxelelen)
//                maxelelen = sdslen(ele->ptr);
//
//            znode = zslInsert(zs->zsl,score,ele);
//            dictAdd(zs->dict,ele,&znode->score);
//            incrRefCount(ele); /* added to skiplist */
//        }
//
//        /* Convert *after* loading, since sorted sets are not stored ordered. */
//        if (zsetLength(o) <= server.zset_max_ziplist_entries &&
//            maxelelen <= server.zset_max_ziplist_value)
//                zsetConvert(o,REDIS_ENCODING_ZIPLIST);
    } else if (rdbtype == REDIS_RDB_TYPE_HASH) {
        size_t len;
//        int ret;

        len = rdbLoadLen(rdb, NULL);
        if (len == REDIS_RDB_LENERR) return NULL;

        o = createHashObject();

        /* Too many entries? Use a hash table. */
//        if (len > server.hash_max_ziplist_entries)
//        if (len > REDIS_HASH_MAX_ZIPLIST_ENTRIES)
//            hashTypeConvert(o, REDIS_ENCODING_HT);
//
        /* Load every field and value into the ziplist */
        while (o->encoding == REDIS_ENCODING_ZIPLIST && len > 0) {
            robj *field, *value;

            len--;
            /* Load raw strings */
            field = rdbLoadStringObject(rdb);
            if (field == NULL) return NULL;
//            redisAssert(sdsEncodedObject(field));
            value = rdbLoadStringObject(rdb);
            if (value == NULL) return NULL;
//            redisAssert(sdsEncodedObject(value));
            fprintf(debug, "OK: key HASH field char is '%s' \n", (char*)field->ptr);
            fprintf(debug, "OK: val HASH value char is '%s' \n", (char*)value->ptr);

            /* Add pair to ziplist */
            o->ptr = ziplistPush(o->ptr, field->ptr, sdslen(field->ptr), ZIPLIST_TAIL);
            o->ptr = ziplistPush(o->ptr, value->ptr, sdslen(value->ptr), ZIPLIST_TAIL);
//            /* Convert to hash table if size threshold is exceeded */
//            if (sdslen(field->ptr) > REDIS_HASH_MAX_ZIPLIST_VALUE ||
//                sdslen(value->ptr) > REDIS_HASH_MAX_ZIPLIST_VALUE)
//            {
//                decrRefCount(field);
//                decrRefCount(value);
//                hashTypeConvert(o, REDIS_ENCODING_HT);
//                break;
//            }
            decrRefCount(field);
            decrRefCount(value);
        }

        /* Load remaining fields and values into the hash table */
        while (o->encoding == REDIS_ENCODING_HT && len > 0) {
            robj *field, *value;

            len--;
            /* Load encoded strings */
            field = rdbLoadEncodedStringObject(rdb);
            if (field == NULL) return NULL;
            value = rdbLoadEncodedStringObject(rdb);
            if (value == NULL) return NULL;

//            field = tryObjectEncoding(field);
//            value = tryObjectEncoding(value);

            /* Add pair to hash table */
//            ret = dictAdd((dict*)o->ptr, field, value);
//            redisAssert(ret == DICT_OK);
        }

        /* All pairs should be read by now */
//        redisAssert(len == 0);

    } else if (rdbtype == REDIS_RDB_TYPE_HASH_ZIPMAP  ||
               rdbtype == REDIS_RDB_TYPE_LIST_ZIPLIST ||
               rdbtype == REDIS_RDB_TYPE_SET_INTSET   ||
               rdbtype == REDIS_RDB_TYPE_ZSET_ZIPLIST ||
               rdbtype == REDIS_RDB_TYPE_HASH_ZIPLIST)
    {
        robj *aux = rdbLoadStringObject(rdb);
        if (aux == NULL) return NULL;
        o = createObject(REDIS_STRING,NULL); /* string is just placeholder */
        o->ptr = zmalloc(sdslen(aux->ptr));
        memcpy(o->ptr,aux->ptr,sdslen(aux->ptr));
        decrRefCount(aux);

        /* Fix the object encoding, and make sure to convert the encoded
         * data type into the base type if accordingly to the current
         * configuration there are too many elements in the encoded data
         * type. Note that we only check the length and not max element
         * size as this is an O(N) scan. Eventually everything will get
         * converted. */
        switch(rdbtype) {
            case REDIS_RDB_TYPE_HASH_ZIPMAP:
//                /* Convert to ziplist encoded hash. This must be deprecated
//                 * when loading dumps created by Redis 2.4 gets deprecated. */
//                {
//                    unsigned char *zl = ziplistNew();
//                    unsigned char *zi = zipmapRewind(o->ptr);
//                    unsigned char *fstr, *vstr;
//                    unsigned int flen, vlen;
//                    unsigned int maxlen = 0;
//
//                    while ((zi = zipmapNext(zi, &fstr, &flen, &vstr, &vlen)) != NULL) {
//                        if (flen > maxlen) maxlen = flen;
//                        if (vlen > maxlen) maxlen = vlen;
//                        zl = ziplistPush(zl, fstr, flen, ZIPLIST_TAIL);
//                        zl = ziplistPush(zl, vstr, vlen, ZIPLIST_TAIL);
//                    }
//
//                    zfree(o->ptr);
//                    o->ptr = zl;
                    o->type = REDIS_HASH;
                    o->encoding = REDIS_ENCODING_ZIPLIST;
//
//                    if (hashTypeLength(o) > server.hash_max_ziplist_entries ||
//                        maxlen > server.hash_max_ziplist_value)
//                    {
//                        hashTypeConvert(o, REDIS_ENCODING_HT);
//                    }
//                }
                break;
            case REDIS_RDB_TYPE_LIST_ZIPLIST:
                o->type = REDIS_LIST;
                o->encoding = REDIS_ENCODING_ZIPLIST;
//                if (ziplistLen(o->ptr) > server.list_max_ziplist_entries)
//                    listTypeConvert(o,REDIS_ENCODING_LINKEDLIST);
                break;
            case REDIS_RDB_TYPE_SET_INTSET:
                o->type = REDIS_SET;
                o->encoding = REDIS_ENCODING_INTSET;
//                if (intsetLen(o->ptr) > server.set_max_intset_entries)
//                    setTypeConvert(o,REDIS_ENCODING_HT);
                break;
            case REDIS_RDB_TYPE_ZSET_ZIPLIST:
                o->type = REDIS_ZSET;
                o->encoding = REDIS_ENCODING_ZIPLIST;
//                if (zsetLength(o) > server.zset_max_ziplist_entries)
//                    zsetConvert(o,REDIS_ENCODING_SKIPLIST);
                break;
            case REDIS_RDB_TYPE_HASH_ZIPLIST:
                o->type = REDIS_HASH;
                o->encoding = REDIS_ENCODING_ZIPLIST;
                //if (hashTypeLength(o) > server.hash_max_ziplist_entries)
                //if (hashTypeLength(o) > REDIS_HASH_MAX_ZIPLIST_ENTRIES)
                //    hashTypeConvert(o, REDIS_ENCODING_HT);
                break;
            default:
                printf("Unknown encoding");
                break;
        }
    } else {
        printf("Unknown object type");
        return NULL;
    }
    return o;
}
/****************/
static ERL_NIF_TERM rdb2(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    ErlNifPid pid;
    ErlNifBinary bin;
    Myerl *erl = enif_alloc(sizeof(Myerl));    
    unsigned int ret = -1;
    int i;
    char *filename = "/tmp/master/dump.rdb";
    FILE *fp;
    FILE *debug = fopen("/tmp/debug.txt", "a");

    assert(erl != NULL);

    /* argv[0] -> Pid && argv[1] -> Binary */
    if(argc != 2) return enif_make_badarg(env);

    /* The Pid received must be a valid Pid */
    if(!enif_is_pid(env, argv[0])) return mk_error(env, "first arg is not a pid");

    /* Pid must be local */
    if(!enif_get_local_pid(env, argv[0], &pid))
        return mk_error(env, "pid is not local");

    /* Second arg must be binary */
    if (!enif_inspect_binary(env, argv[1], &bin))
        return mk_error(env, "invalid binary");

    erl->env = env;
    erl->pid = pid;
    erl->msg_env = enif_alloc_env();

    if(erl->msg_env == NULL)
        return mk_error(env, "environ_alloc_error");

    //enif_alloc_binary(bin.size, &outbin);
    
    for (i = 0; i < bin.size; i++) {
        //outbin.data[i] = bin.data[i];
    }

    fprintf(debug, "-Starting-\n");
    fprintf(debug, "OK: Performing starting 'rdbLoad'\n");
    ret = rdbLoad(debug, erl, filename);
    fprintf(debug, "OK: Performing finished 'rdbLoad' return %d\n", ret);

    //FIXME
    if (ret != ESLAVER_OK) return mk_error(env, erl->error);

    /* Send EOF */
    if (sendEofPid(erl)) return mk_error(env, erl->error);

    fprintf(debug, "-Finished-\n");
    fclose(debug);
    enif_free_env(erl->msg_env);
    return mk_atom(env, "ok");
}


static ErlNifFunc nif_funcs[] = {
    {"rdb2", 2, rdb2}
};


ERL_NIF_INIT(rdb, nif_funcs, NULL, NULL, NULL, NULL);
