#ifndef _ERRNO_H_SHIM
#define _ERRNO_H_SHIM

int *__errno_location(void);
#define errno (*__errno_location())

#define EPERM   1
#define ENOENT  2
#define EIO     5
#define ENOMEM  12
#define EACCES  13
#define EEXIST  17
#define ENODEV  19
#define EINVAL  22
#define ERANGE  34

#endif
