
is inspired in nsync but with sligthly differences:
facilities more than nsync

    use redis internals to save rdb file in disk,  loads rdb file from disk, do lzf compress/decompress, etc. 
    for reducing the possibility of issue overcome and for dont reinvent the wheel, and for compatibility reasons.

    - be nearer to redis behaviour:
        - The slave reads the dump file from the master and write it to the disk
        - When it is complete, the slave loads the dump file from the disk
        - The slave starts processing Redis commands accumulated by the master
    - perform PSYNC when is possible, instead of always SYNC
    - use lzf and rdb parse with all native c code
    - rdb versiona > 6 compatibiliy
    - supervisor main server
    - checksum ?

The goal of `eslaver` is to provide partial syncronization

Since most of the work is done by the Redis team here is the license.
Code in c\_src I just put the pieces together in the right place.
About the code in c\_src is mostly from Redis team, I just put the pieces together in the right place.

I just made the necessary changes in redis logic in order to get it working.

From c code, most of it is from redis source itself, I just put de dots together


Of course, in real life everything is not pink.
Of course, everything in life is not free, there are some changes in order to made this work with erlang nifs.