#include "erl_nif.h"
//#include "erl_nif_compat.h"
//#include "nif_util.h"

#define SOURCE "loading"
#define ESLAVER_OK    0
#define ESLAVER_ERR   -1
#define ERL_STR 0
#define ERL_INT 1

typedef struct Myerl {
    ErlNifEnv* env;
    ErlNifPid pid;
    ErlNifEnv* msg_env;
    char *error;
} Myerl;

typedef struct HashDict {
    char *hkey;
    char *hval;
} HashDict;

typedef struct List {
    char *data;
    long elems;
    int type;
} List;

long long ustime(void);
long long mstime(void);

int sendStringTuplePid(Myerl *erl, robj *key, robj *val);
int sendListPid(Myerl *erl, robj *key, List *lst);
int sendHashPid(Myerl *erl, robj *key, HashDict *hd, int iter);
int sendEofPid(Myerl *erl);
int _sendPid(Myerl *erl, ERL_NIF_TERM data);
int retError(Myerl *erl, char *error);

int sendHashTuplePid(Myerl *erl, robj *key, robj *val);
int sendListTuplePid(Myerl *erl, robj *key, robj *val);
int sendZsetTuplePid(Myerl *erl, robj *key, robj *val);

ERL_NIF_TERM mk_error(ErlNifEnv* env, const char *msg);
ERL_NIF_TERM mk_atom(ErlNifEnv* env, const char *atom);


/*** adlist.c ***/
/* Prototypes */
list *listCreate(void);
//void listRelease(list *list);
//list *listAddNodeHead(list *list, void *value);
list *listAddNodeTail(list *list, void *value);
/****************/

/*** ziplist.c ***/
#define ZIPLIST_HEAD 0
#define ZIPLIST_TAIL 1

unsigned char *ziplistNew(void);
/*****************/
