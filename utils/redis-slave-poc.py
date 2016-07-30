#!/usr/bin/python
import time
import socket

HOST='127.0.0.1'
PORT=6379
BUFF=1024

s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect((HOST, PORT))

print "PING"
s.send("PING\r\n")
data = s.recv(BUFF)
print(data)

print "REPLCONF listening-port 6380"
s.send("REPLCONF listening-port 6380\r\n")
data = s.recv(BUFF)
print(data)

print "REPLCONF capa eof"
s.send("REPLCONF capa eof\r\n")
data = s.recv(BUFF)
print(data)

print "PSYNC ? -1"
s.send("PSYNC ? -1\r\n")
data = s.recv(BUFF)
cmd, runid, offset = data.strip().split(" ")
print(data)

while True:
    # time.sleep(1)
    s.send("*3\r\n")
    s.send("$8\r\n")
    s.send("REPLCONF\r\n")
    s.send("$3\r\n")
    s.send("ACK\r\n")
    s.send("$%d\r\n" % len(str(offset)))
    s.send("%s\r\n" % offset)

    data = s.recv(BUFF)
    print "-" * 20
    print(data)
    print "-" * 20

s.close()
