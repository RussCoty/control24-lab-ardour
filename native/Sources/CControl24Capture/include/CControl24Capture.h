#ifndef C24_CAPTURE_H
#define C24_CAPTURE_H
#include <stdint.h>
#include <stddef.h>
typedef struct c24_capture c24_capture;
c24_capture *c24_open(const char *interface, const char *source_mac, char *error, size_t error_size);
int c24_next(c24_capture *capture, uint8_t *buffer, size_t capacity);
int c24_send(c24_capture *capture, const uint8_t *destination, const uint8_t *payload, size_t size);
void c24_close(c24_capture *capture);
void c24_install_signals(void);
int c24_should_stop(void);
#endif
