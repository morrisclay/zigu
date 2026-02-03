import asyncio
import time

# Golden example workload for adapter integration testing.
# Emits a heartbeat and performs a simple async sleep loop.

async def heartbeat():
    while True:
        ts = time.time()
        print(f"heartbeat {ts}")
        await asyncio.sleep(1)

async def main():
    print("worker starting")
    await heartbeat()

if __name__ == "__main__":
    asyncio.run(main())
