#include <stdlib.h>
#include <limits.h>
#include <assert.h>
#include <sys/time.h>
#include "zmalloc.h"
#include "rdb.h"
#include "util.h"
#include "extras.h"
#include "ziplist.h"

/*** redis.c ***/
/* Return the UNIX time in microseconds */
long long ustime(void) {
    struct timeval tv;
    long long ust;

    gettimeofday(&tv, NULL);
    ust = ((long long)tv.tv_sec)*1000000;
    ust += tv.tv_usec;
    return ust;
}

/* Return the UNIX time in milliseconds */
long long mstime(void) {
    return ustime()/1000;
}
/***************/

/*** adlist.c ***/
/* Create a new list. The created list can be freed with
 * AlFreeList(), but private value of every node need to be freed
 * by the user before to call AlFreeList().
 *
 * On error, NULL is returned. Otherwise the pointer to the new list. */
list *listCreate(void)
{
    struct list *list;

    if ((list = zmalloc(sizeof(*list))) == NULL)
        return NULL;
    list->head = list->tail = NULL;
    list->len = 0;
    list->dup = NULL;
    list->free = NULL;
    list->match = NULL;
    return list;
}

/* Return the element at the specified zero-based index
 * where 0 is the head, 1 is the element next to head
 * and so on. Negative integers are used in order to count
 * from the tail, -1 is the last element, -2 the penultimate
 * and so on. If the index is out of range NULL is returned. */
listNode *listIndex(list *list, long index) {
    listNode *n;

    if (index < 0) {
        index = (-index)-1;
        n = list->tail;
        while(index-- && n) n = n->prev;
    } else {
        n = list->head;
        while(index-- && n) n = n->next;
    }
    return n;
}

/* Add a new node to the list, to tail, containing the specified 'value'
 * pointer as value.
 *
 * On error, NULL is returned and no operation is performed (i.e. the
 * list remains unaltered).
 * On success the 'list' pointer you pass to the function is returned. */
list *listAddNodeTail(list *list, void *value)
{
    listNode *node;

    if ((node = zmalloc(sizeof(*node))) == NULL)
        return NULL;
    node->value = value;
    if (list->len == 0) {
        list->head = list->tail = node;
        node->prev = node->next = NULL;
    } else {
        node->prev = list->tail;
        node->next = NULL;
        list->tail->next = node;
        list->tail = node;
    }
    list->len++;
    return list;
}
/****************/

/*** t_hash.c ***/
/* Move to the next entry in the hash. Return REDIS_OK when the next entry
 * could be found and REDIS_ERR when the iterator reaches the end. */
int hashTypeNext(hashTypeIterator *hi) {
    if (hi->encoding == REDIS_ENCODING_ZIPLIST) {
        unsigned char *zl;
        unsigned char *fptr, *vptr;

        zl = hi->subject->ptr;
        fptr = hi->fptr;
        vptr = hi->vptr;

        if (fptr == NULL) {
            /* Initialize cursor */
            assert(vptr == NULL);
            fptr = ziplistIndex(zl, 0);
        } else {
            /* Advance cursor */
            assert(vptr != NULL);
            fptr = ziplistNext(zl, vptr);
        }
        if (fptr == NULL) return REDIS_ERR;

        /* Grab pointer to the value (fptr points to the field) */
        vptr = ziplistNext(zl, fptr);
        assert(vptr != NULL);

        /* fptr, vptr now point to the first or next pair */
        hi->fptr = fptr;
        hi->vptr = vptr;
    } else if (hi->encoding == REDIS_ENCODING_HT) {
        if ((hi->de = dictNext(hi->di)) == NULL) return REDIS_ERR;
    } else {
        printf("Unknown hash encoding");
        return REDIS_ERR;
    }
    return REDIS_OK;
}

/* Return the number of elements in a hash. */
unsigned long hashTypeLength(robj *o) {
    unsigned long length = ULONG_MAX;

    if (o->encoding == REDIS_ENCODING_ZIPLIST) {
        length = ziplistLen(o->ptr) / 2;
    } else if (o->encoding == REDIS_ENCODING_HT) {
        length = dictSize((dict*)o->ptr);
    } else {
        printf("Unknown hash encoding");
    }

    return length;
}

hashTypeIterator *hashTypeInitIterator(robj *subject) {
    hashTypeIterator *hi = zmalloc(sizeof(hashTypeIterator));
    hi->subject = subject;
    hi->encoding = subject->encoding;

    if (hi->encoding == REDIS_ENCODING_ZIPLIST) {
        hi->fptr = NULL;
        hi->vptr = NULL;
    } else if (hi->encoding == REDIS_ENCODING_HT) {
        hi->di = dictGetIterator(subject->ptr);
    } else {
        printf("Unknown hash encoding");
    }

    return hi;
}

void hashTypeReleaseIterator(hashTypeIterator *hi) {
    if (hi->encoding == REDIS_ENCODING_HT) {
        dictReleaseIterator(hi->di);
    }

    zfree(hi);
}

/* Get the field or value at iterator cursor, for an iterator on a hash value
 * encoded as a ziplist. Prototype is similar to `hashTypeGetFromZiplist`. */
void hashTypeCurrentFromZiplist(hashTypeIterator *hi, int what,
                                unsigned char **vstr,
                                unsigned int *vlen,
                                long long *vll)
{
    int ret;
    assert(hi->encoding == REDIS_ENCODING_ZIPLIST);

    if (what & REDIS_HASH_KEY) {
        ret = ziplistGet(hi->fptr, vstr, vlen, vll);
        assert(ret);
    } else {
        ret = ziplistGet(hi->vptr, vstr, vlen, vll);
        assert(ret);
    }
}

static void addHashIteratorCursorToReply(char **elem, hashTypeIterator *hi, int what) {
    if (hi->encoding == REDIS_ENCODING_ZIPLIST) {
        unsigned char *vstr = NULL;
        unsigned int vlen = UINT_MAX;
        long long vll = LLONG_MAX;
        char buf[64];
        int len;

        hashTypeCurrentFromZiplist(hi, what, &vstr, &vlen, &vll);
        if (vstr) {
            *elem = sdsnewlen(vstr, vlen);
        } else {
            len = ll2string(buf,64,vll);
            *elem = sdsnewlen(buf, len);
        }

    } else if (hi->encoding == REDIS_ENCODING_HT) {
//        robj *value;

//        hashTypeCurrentFromHashTable(hi, what, &value);
//        addReplyBulk(c, value);
    } else {
        printf("Unknown hash encoding");
    }
}

int sendHashTuplePid(Myerl *erl, robj *key, robj *val) {
    hashTypeIterator *hi;
    int flags = REDIS_HASH_KEY|REDIS_HASH_VALUE;
    int multiplier = 0;
    int length, count = 0, iter = 0, ret = -1;
    HashDict *hd;

    if (flags & REDIS_HASH_KEY) multiplier++;
    if (flags & REDIS_HASH_VALUE) multiplier++;

    length = hashTypeLength(val) * multiplier;
    hi = hashTypeInitIterator(val);
    hd = zmalloc(sizeof(ERL_NIF_TERM)*length);

//    printf("OK: key name is '%s' type is '%d' \n", (char*)key->ptr, val->type);

    while (hashTypeNext(hi) != REDIS_ERR) {
 
        if (flags & REDIS_HASH_KEY) {
            addHashIteratorCursorToReply(&hd[iter].hkey, hi, REDIS_HASH_KEY);
            count++;
        }
        if (flags & REDIS_HASH_VALUE) {
            addHashIteratorCursorToReply(&hd[iter].hval, hi, REDIS_HASH_VALUE);
            count++;
        }
        iter++;
    }

    /* Send entire hash */
    ret = sendHashPid(erl, key, hd, iter);

    zfree(hd);
    hashTypeReleaseIterator(hi);
    assert(count == length);
    return ret;
}
/****************/
unsigned long listTypeLength(robj *subject) {
    if (subject->encoding == REDIS_ENCODING_ZIPLIST) {
        return ziplistLen(subject->ptr);
    } else if (subject->encoding == REDIS_ENCODING_LINKEDLIST) {
        return listLength((list*)subject->ptr);
    } else {
        printf("Unknown list encoding\n");
        exit(1);
    }
}

int sendListTuplePid(Myerl *erl, robj *key, robj *val) {
    long start = 0, end = -1, llen, rangelen;
    int ret;
    List *lst;
    llen = listTypeLength(val);

    lst = zmalloc(sizeof(ERL_NIF_TERM)*llen*sizeof(long));
    lst->elems = llen;

    /* convert negative indexes */
    if (start < 0) start = llen+start;
    if (end < 0) end = llen+end;
    if (start < 0) start = 0;

    /* Invariant: start >= 0, so this test will be true when end < 0.
     * The range is empty when start > end or start >= length. */
//    if (start > end || start >= llen) {
//        return retError(erl, "empty");
//    }
//    if (end >= llen) end = llen-1;
//    rangelen = (end-start)+1;
    rangelen = llen;

    /* Return the result in form of a multi-bulk reply */
    if (val->encoding == REDIS_ENCODING_ZIPLIST) {
        unsigned char *p = ziplistIndex(val->ptr,start);
        unsigned char *vstr;
        unsigned int vlen;
        long long vlong;
        char buf[64];
        int len;

        while(rangelen--) {
            ziplistGet(p,&vstr,&vlen,&vlong);

            if (vstr) {
                /*if (realloc(lst->data, sizeof(char*)*vlen) == NULL)
                    return retError(erl, "Cannot reallocate list element");
                */
                lst[rangelen].data = sdsnewlen(vstr, vlen);
            } else {
                len = ll2string(buf,64,vlong);
                /*if (realloc(lst->data, sizeof(char*)*len) == NULL)
                    return retError(erl, "Cannot reallocate list element");
                */
                lst[rangelen].data = sdsnewlen(buf, len);
            }
            p = ziplistNext(val->ptr,p);
        }

    } else if (val->encoding == REDIS_ENCODING_LINKEDLIST) {
        listNode *ln;

        /* If we are nearest to the end of the list, reach the element
         * starting from tail and going backward, as it is faster. */
        if (start > llen/2) start -= llen;
        ln = listIndex(val->ptr,start);

        while(rangelen--) {
            lst[rangelen].data = sdsnew(ln->value);
            ln = ln->next;
        }
    } else {
        return retError(erl, "List encoding is not LINKEDLIST nor ZIPLIST!");
    }

    /* Send entire list */
    ret = sendListPid(erl, key, lst);
    zfree(lst);

    return ret;
}


/*** custom ***/
#define SOURCE "loading"

int retError(Myerl *erl, char *error) {
    erl->error = error;
    return -1;
}

ERL_NIF_TERM mk_string(ErlNifEnv* env, const char *data) {
    return enif_make_string(env, data, ERL_NIF_LATIN1);
}

ERL_NIF_TERM mk_atom(ErlNifEnv* env, const char *atom) {
    ERL_NIF_TERM ret;
    if(!enif_make_existing_atom(env, atom, &ret, ERL_NIF_LATIN1))
        return enif_make_atom(env, atom);
    return ret;
}

ERL_NIF_TERM mk_error(ErlNifEnv* env, const char *msg) {
    return enif_make_tuple2(
        env, mk_atom(env, "error"), mk_string(env, msg));
}

ERL_NIF_TERM mk_binary(ErlNifEnv* env, void *buf) {
    ErlNifBinary bin;
    enif_alloc_binary(sdslen(buf), &bin);
    memcpy(bin.data, buf, sdslen(buf));
    return enif_make_binary(env, &bin);
}

int sendHashPid(Myerl *erl, robj *key, HashDict *hd, int iter) {
    ERL_NIF_TERM hash, list, kbin, vbin;

    /* Initialize list of key and values */
    list = enif_make_list(erl->env, 0);

    while(iter--) {
        vbin = mk_binary(erl->env, hd[iter].hval);
        kbin = mk_binary(erl->env, hd[iter].hkey);
        list = enif_make_list_cell(erl->env, vbin, list);
        list = enif_make_list_cell(erl->env, kbin, list);
        sdsfree(hd[iter].hval);
        sdsfree(hd[iter].hkey);
    }

    hash = enif_make_tuple4(erl->env,
        mk_atom(erl->env, SOURCE),
        mk_atom(erl->env, "hash"),
        mk_binary(erl->env, key->ptr),list);
    return _sendPid(erl, hash);
}

int sendListPid(Myerl *erl, robj *key, List *lst) {
    ERL_NIF_TERM elist, list, elem;
    int i;
    long elems = lst->elems;

    /* Initialize list of key and values */
    list = enif_make_list(erl->env, 0);

    for (i = 0; i < elems; ++i) {
        elem = mk_string(erl->env, lst[i].data);
        list = enif_make_list_cell(erl->env, elem, list);
        sdsfree(lst[i].data);
        lst->elems--;
    }

    elist = enif_make_tuple4(erl->env,
        mk_atom(erl->env, SOURCE),
        mk_atom(erl->env, "list"),
        mk_binary(erl->env, key->ptr),list);
    return _sendPid(erl, elist);
}

int sendStringTuplePid(Myerl *erl, robj *key, robj *val) {
    ERL_NIF_TERM string;
    string = enif_make_tuple4(erl->env,
        mk_atom(erl->env, SOURCE),
        mk_atom(erl->env, "string"),
        mk_binary(erl->env, key->ptr),
        mk_binary(erl->env, val->ptr));
    return _sendPid(erl, string);
}

int sendEofPid(Myerl *erl) {
    ERL_NIF_TERM term;
    term = enif_make_tuple2(erl->env,
        mk_atom(erl->env, SOURCE),
        mk_atom(erl->env, "eof"));
    return _sendPid(erl, term);
}

/* Internal function, send data to pid */
int _sendPid(Myerl *erl, ERL_NIF_TERM data) {
    if(!enif_send(erl->env, &erl->pid, erl->msg_env, data)) {
        enif_free(erl->msg_env);
        erl->error = "error_sending_term";
        return -1;
    }
    return 0;
}
/*** custom ***/