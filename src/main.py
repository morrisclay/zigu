import ukernel

def heartbeat():
    for i in range(3):
        ukernel.log("python heartbeat " + str(i))
        ukernel.sleep_ms(100)

def main():
    ukernel.log("python asyncio starting")
    ukernel.log("ukernel version: " + ukernel.version())
    t0 = ukernel.time_ms()
    ukernel.log("boot time: " + str(t0) + " ms")
    heartbeat()
    ukernel.log("python asyncio done")

main()
