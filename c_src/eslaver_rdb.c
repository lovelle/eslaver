#include "rdb.h"
#include "eslaver_util.h"


int write_log(char *text) {
    FILE *debug;

    if ((debug = fopen("/tmp/debug.txt","a")) == NULL) {
        printf("Cannot write log\n");
        exit(1);
    }
    fprintf(debug, "%s\n", text);
    fclose(debug);
    return 0;
}


static ERL_NIF_TERM save(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    char filename[128];
    int i, flag = -1, usemark = 0;
    char *file_mode = "w";
    ErlNifBinary bin;
    FILE *fp;

    /* argv[0] -> Binary; argv[1] -> Mode, argv[2] -> rdb_filename */
    if(argc != 3) return enif_make_badarg(env);

    /* Arg must be binary */
    if (!enif_inspect_binary(env, argv[0], &bin))
        return mk_error(env, "invalid binary");

    /* Writing mode flag must be an integer */
    if (!enif_get_int(env, argv[1], &flag))
        return mk_error(env, "invalid writing mode argument");

    /* Should get filename */
    if (!enif_get_string(env, argv[2], filename, sizeof(filename), ERL_NIF_LATIN1))
        return mk_error(env, "invalid filename arg");

    /* If internal flag is set to 1, means it has been
     * received large chunked data from tcp, so rdb file must
     * be written in appending mode instead of by default
     * writing mode.
     */
    if (flag) file_mode = "a";

    if ((fp = fopen(filename, file_mode)) == NULL)
        return mk_error(env, "cannot create rdb file");

    /* Write received binary as rdb into file */
    for (i = 0; i < bin.size; i++) {

        /* If flag is set to 0 means the first bulk data is
         * needed to be removed at \n of stream protocol.
         */
        if (!flag) { // flag == 0
            if (bin.data[i] == '\n' && !usemark) {usemark++; continue;}
            if (!usemark) continue;
        }

        fwrite(&bin.data[i], sizeof(bin.data[i]), 1, fp);
    }
    fclose(fp);

    if (i != bin.size)
        return mk_error(env, "rdb file invalid save");

    return mk_atom(env, "ok");
}

static ERL_NIF_TERM load(ErlNifEnv* env, int argc, const ERL_NIF_TERM argv[]) {
    int ret = -1;
    char filename[128];
    ErlNifPid pid;
    Myerl *erl;
    FILE *fp;

    /* argv[0] -> Pid ; argv[1] -> rdb_filename */
    if(argc != 2) return enif_make_badarg(env);

    /* The Pid received must be a valid Pid */
    if(!enif_is_pid(env, argv[0]))
        return mk_error(env, "first arg is not a pid");

    /* Should get filename */
    if (!enif_get_string(env, argv[1], filename, sizeof(filename), ERL_NIF_LATIN1))
        return mk_error(env, "invalid filename arg");

    /* Pid must be local */
    if(!enif_get_local_pid(env, argv[0], &pid))
        return mk_error(env, "pid is not local");

    erl = enif_alloc(sizeof(Myerl));
    erl->env = env;
    erl->pid = pid;
    erl->msg_env = enif_alloc_env();

    assert(erl != NULL);

    if(erl->msg_env == NULL)
        return mk_error(env, "cannot allocate environ");

    if ((fp = fopen(filename,"r")) == NULL)
        return mk_error(env, "cannot open rdb file");

    ret = rdbLoad(erl, filename);

    if (erl->error == NULL) erl->error = "empty response or not valid";
    if (ret != ESLAVER_OK) return mk_error(env, erl->error);

    /* Send EOF */
    if (sendEofPid(erl)) return mk_error(env, erl->error);

    enif_free_env(erl->msg_env);
    enif_free(erl);
    return mk_atom(env, "ok");
}


static ErlNifFunc nif_funcs[] = {
    {"load", 2, load},
    {"save", 3, save}
};


ERL_NIF_INIT(rdb, nif_funcs, NULL, NULL, NULL, NULL);
