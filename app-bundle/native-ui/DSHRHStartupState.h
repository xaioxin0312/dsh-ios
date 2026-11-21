#ifndef DSHRH_STARTUP_STATE_H
#define DSHRH_STARTUP_STATE_H
#include <stdbool.h>

typedef struct {
    bool startingBackend;
    bool fallbackPending;
} DSHRHStartupState;

static inline void DSHRHStartupBegin(DSHRHStartupState *state) {
    state->startingBackend = true;
    state->fallbackPending = false;
}
static inline void DSHRHStartupComplete(DSHRHStartupState *state) {
    state->startingBackend = false;
}
static inline void DSHRHStartupRequestFallback(DSHRHStartupState *state) {
    state->fallbackPending = true;
}
static inline bool DSHRHStartupCanPresentFallback(const DSHRHStartupState *state,
                                                 bool attachedToWindow,
                                                 bool anotherControllerPresented,
                                                 bool fallbackAlreadyPresented) {
    return state->fallbackPending && !state->startingBackend && attachedToWindow &&
        !anotherControllerPresented && !fallbackAlreadyPresented;
}
#endif
