[![Build Status](https://travis-ci.org/lovelle/eslaver.svg)](https://travis-ci.org/lovelle/eslaver)

Eslaver
===

**E**rlang **slave** **r**edis replication client/server.

Eslaver is a redis slave replication client who behaves exactly in
the same way like any redis slave server, from a master perspective,
there won't be any difference beetween eslaver or any redis slave.


**Warning:** This is still beta code and might not be suitable for production.
Most of the c code is considered stable due to the fact that is from redis stable version.

**Hint:** skip this section if you are already familiar with redis slave logic.

{Explanation about redis slave - TODO}

Eslaver was inspired by [nsync](https://github.com/jkvor/nsync).

Main features
===
 * Same behaviour like any redis slave server.
 * Key notifications. more doc [here](#key-notifications).
 * PSYNC when is possible, instead of always basic SYNC. more doc [here]().
 * Rdb version compatibility with > 6 [TODO].
 * OTP server.
 * Supervised server.

From c code perspective, mostly of it is from redis source itself,
I've made the necessary changes in order to make erlang nif compatible
with redis native basics.

Why I need this / What can I do with eslaver?
===

The main idea, is to be able to set an independent process who behaves exactly as any
redis slave server, so you can setup this process (eslaver) configured with your own
callback function, who will receive any event from redis master, thanks to pattern matching,
you could only be watching for certain commands.

__e.g:__ You can set any redis structure on redis master, and save all those
commands in memory, so, if you have a server which is going to have huge traffic,
you can use ets, or in-memory variable to store data struct from master instead to
directly need to connect to master on each connection/request.

If you have more doubts, see `/examples

Build
===

```sh
$ ./rebar3 compile
```

Run
===

You can use 3 different types of callbacks:

1. Basic anonymous function.
2. A module with a function.
3. A pid.

Startup with anonymous function (supervision activated).

```erlang
1> Cb = fun(X) -> io:format("my callback func -> ~p ~n", [X]) end.
#Fun<erl_eval.6.50752066>
2> eslaver:start(normal, Cb).
```

Startup with module and function (supervision activated).

```erlang
1> eslaver:start(normal, {mymodule, mycallback}).
```

Startup with pid as callback receiver (without supervision activated).

```erlang
1> eslaver_server:start(self()).
...
2> flush().
Shell got {loading,eof}
Shell got {stream,"ping",[]}
ok
```

Startup eslaver with custom redis master configuration.

```erlang
1> application:load(eslaver).
ok
2> application:set_env(eslaver, "master_host", "192.168.0.1").
ok
3> application:set_env(eslaver, "master_port", 6380).
ok
4> eslaver_server:start({mymodule, mycallback}).
```

Usage
===

To see more examples of usage, take a look in `examples/` folder.

{TODO}


Configuration options
===

`master_host`

Ip or domain name of redis master to connect to.
*Default:* "127.0.0.1"

`master_port`

Port number of redis master node.
*Default:* 6379

`master_auth`

Request for authentication in a password-protected Redis server.
*Default:* undef (no password required by server)

`dbfilename`

The filename where to dump the DB.
*Default:* "/tmp/dump_erlang.rdb"

Thanks
===

I'm glad to thank the following people.

* Salvatore Sanfilippo aka [antirez](https://github.com/antirez) for make redis possible.
* [jkvor](https://github.com/jkvor) for make [nsync](https://github.com/jkvor/nsync) possible which is where eslaver was inspired from.
* Everybody who is intended to contribute or has plans to use it.

License
===
See [LICENSE](https://github.com/lovelle/eslaver/blob/master/LICENSE).
