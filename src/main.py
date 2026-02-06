import ukernel

def heartbeat():
    for i in range(3):
        ukernel.log("python heartbeat " + str(i))
        ukernel.sleep_ms(100)

def net_demo():
    ukernel.log("python net: starting UDP demo")
    sock = ukernel.net_udp_socket()
    ukernel.net_connect(sock, "172.16.0.1", 9000)
    ukernel.net_send(sock, b"hello from ukernel")
    ukernel.log("python net: sent UDP packet")
    ukernel.net_close(sock)
    ukernel.log("python net: done")

def main():
    ukernel.log("python asyncio starting")
    ukernel.log("ukernel version: " + ukernel.version())
    t0 = ukernel.time_ms()
    ukernel.log("boot time: " + str(t0) + " ms")
    heartbeat()
    net_demo()
    ukernel.log("python asyncio done")

main()
