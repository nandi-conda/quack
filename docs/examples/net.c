#include <stdint.h>
#include <stddef.h>
#include <string.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

int64_t gs_listen(int32_t port, int32_t backlog) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    struct sockaddr_in a;
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons((uint16_t)port);
    if (bind(fd, (struct sockaddr *)&a, sizeof a) != 0) { close(fd); return -1; }
    if (listen(fd, backlog) != 0) { close(fd); return -1; }
    return fd;
}

int64_t gs_accept(int64_t fd) { return accept((int)fd, NULL, NULL); }

int64_t gs_read(int64_t fd, uint8_t *buf, int64_t cap) {
    return (int64_t)read((int)fd, buf, (size_t)cap);
}

int64_t gs_write(int64_t fd, const uint8_t *buf, int64_t len) {
    return (int64_t)write((int)fd, buf, (size_t)len);
}

int64_t gs_close(int64_t fd) { return (int64_t)close((int)fd); }
